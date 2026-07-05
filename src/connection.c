// conn_t implementation.
//
// Ported from old_proj_states/asgn2/request.c per docs/REFERENCE.md:
//   - process_request  (L72)  -> request-line regex parse
//   - parse_headers    (L30)  -> header loop + Content-Length
//                                (+ ADDED: Request-Id capture, asgn2 gap)
//   - validate_uri      (L227) -> static-correctness bounds check only
//                                (asgn2's version also open()/fstat()'d the
//                                file -- that's *semantic* validation, which
//                                lib/connection.h's conn_parse contract
//                                explicitly excludes; the real open/fstat
//                                happens in src/httpserver.c's handle_get/
//                                handle_put, per the asgn4 handler split)
//   - process_get/process_set (L172/L196) -> folded into conn_send_file /
//                                conn_recv_file, including the
//                                buffered-leftover-before-streaming gem
//                                (docs/REFERENCE.md gem #2).
//
// Known asgn2 defects intentionally NOT copied (docs/REFERENCE.md):
//   - the dead `(rm_eo - rm_eo)` branch in process_request is removed;
//     parse_headers is just called once (both branches did the same thing).
//   - the post-loop re-regexec "quirk" at the end of parse_headers is
//     removed; it re-ran regexec on the same buffer for no discernible
//     effect on the returned status once the header loop already consumed
//     every header line.
//   - error_msg's `sizeof(ptr)` bug (util.c) -- not this file, but fixed
//     alongside (see src/util.c).
//
// Everything else (method/uri/version match logic, using match[4] --
// the *minor* version capture -- as the "must be 1" check, `strncmp` with
// the captured key length rather than the literal keyword length) is kept
// verbatim per the binding porting rule: tidy naming/whitespace, don't
// redesign the logic.

#include "../lib/connection.h"
#include "../lib/asgn2_helper_funcs.h"

#include <errno.h>
#include <inttypes.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BUFFER_SIZE 4096

// M4 (review backlog B2, spec ruling): the assignment PDF's audit-log section
// describes the URI "with the same limitations as in Assignment 2, i.e., the
// format /%63[A-Za-z.-]s" -- which explicitly includes '-'. asgn2's own
// reference regex (this file's porting source) omitted the hyphen; since the
// spec text names it, we extend the charset to add '-' while keeping the
// digits/underscore/slash asgn2 already required (real workloads route
// multi-segment and digit/underscore-bearing URIs -- e.g. "test1.txt" --
// through this same regex, so a literal, no-digits reading of the PDF's
// paraphrase would break those). See docs/DECISIONS.md.
#define REQUEST_LINE "^([a-zA-Z]{1,8}) /([a-zA-Z0-9/_.-]{1,63}) HTTP/([0-9]{1,2}).([0-9]{1,2})\r\n"
#define HEADER_FIELD "([a-zA-Z0-9.-]{1,128}):[[:space:]]([a-zA-Z0-9.:/*-]{1,128})\r\n"

struct Conn {
    int connfd;
    char buffer[BUFFER_SIZE + 1]; // +1: spare byte for the regexec null terminator
    ssize_t bytes_read;
    int message_start; // offset into buffer where the body/leftover begins
    int in_message;    // buffered leftover body bytes: bytes_read - message_start
    ssize_t content_length;
    char content_length_str[32];
    char uri[64];
    char request_id[129];
    const Request_t *request;
};

// M4 (review backlog item B3): a bare connect-then-close (0 bytes ever read --
// no request line, nothing) is not a request at all -- there is nothing to
// validate, respond to, or audit. conn_parse still returns RESPONSE_BAD_REQUEST
// for this case (so callers that never check conn_is_empty keep working), but
// exposes this predicate so httpserver.c's handle_connection can distinguish
// "malformed request, send 400 and log it" from "no request was sent, close
// silently." See docs/DECISIONS.md for the spec ruling.
//
// "Empty" means exactly: read_until() returned 0, i.e. the client closed the
// connection (EOF) having sent zero bytes. It is NOT true for the error/
// timeout path (read_until returns -1): a request that sent partial bytes and
// then timed out (SO_RCVTIMEO -> EAGAIN) must still get its 500 response and
// audit line. conn_parse records read_until's raw return value -- including
// -1 -- into conn->bytes_read *before* branching on its sign, precisely so
// this predicate cannot misclassify the error path as empty. (Post-review
// fix: the original M4 version assigned bytes_read only on the success path,
// so the calloc'd 0 made every timeout/read-error look like an empty
// connection, silently dropping its response and audit line.)
bool conn_is_empty(conn_t *conn) {
    return conn->bytes_read == 0;
}

static const Response_t *validate_uri(conn_t *conn) {
    // asgn2's validate_uri opened/fstat'd the file and returned 200/201/403/
    // 404/500 based on errno -- that's semantic validation of a specific URI
    // (does it exist? is it a directory?), which the conn_parse contract
    // (lib/connection.h) explicitly defers to the caller. What we keep here
    // is the *static* check: the regex already bounds the uri to 1-63 chars
    // of an allowed charset, so an empty capture is the only bounds failure
    // left to catch.
    if (conn->uri[0] == '\0') {
        return &RESPONSE_BAD_REQUEST;
    }
    return NULL;
}

// Header loop + Content-Length extraction, ported from asgn2 parse_headers
// (request.c L30). ADDED: Request-Id capture (asgn2 never parsed it; the
// audit log needs it, docs/REFERENCE.md "Request-Id Gap"). Defaults to "0"
// when absent, per the audit-log spec.
static const Response_t *parse_headers(conn_t *conn) {
    regex_t re;
    int comp_rc = regcomp(&re, HEADER_FIELD, REG_EXTENDED);
    if (comp_rc != 0) {
        // regcomp only fails if HEADER_FIELD itself is malformed -- a
        // programming bug, not a runtime condition -- but crashing the whole
        // server via assert() on it is worse than a clean 500 (M4 review
        // backlog item B4a: assert(comp_rc == 0) is also a set-but-unused
        // warning under -DNDEBUG, since the assert body compiles away).
        return &RESPONSE_INTERNAL_SERVER_ERROR;
    }

    char *headers = conn->buffer + conn->message_start;
    int offset = 0;
    regmatch_t match[3];
    static const char CONTENT_LENGTH_KEY[] = "Content-Length";
    static const char REQUEST_ID_KEY[] = "Request-Id";

    while (regexec(&re, headers + offset, 3, match, 0) == 0) {
        int key_len = match[1].rm_eo - match[1].rm_so;
        int value_len = match[2].rm_eo - match[2].rm_so;

        char value[129];
        memcpy(value, headers + offset + match[2].rm_so, (size_t)value_len);
        value[value_len] = '\0';

        // B4c: match the keyword *exactly*, not just its first key_len bytes.
        // strncmp(haystack, "Content-Length", key_len) is true for any key
        // that is a prefix of "Content-Length" (e.g. a captured key of
        // "Content-Len" would falsely match) -- gate on length equality with
        // the literal keyword first. Deliberate defect fix over verbatim asgn2.
        if ((size_t)key_len == sizeof(CONTENT_LENGTH_KEY) - 1 &&
            strncmp(headers + offset + match[1].rm_so, CONTENT_LENGTH_KEY, (size_t)key_len) == 0) {
            conn->content_length = (ssize_t)strtoull(value, NULL, 10);
        } else if ((size_t)key_len == sizeof(REQUEST_ID_KEY) - 1 &&
                   strncmp(headers + offset + match[1].rm_so, REQUEST_ID_KEY, (size_t)key_len) ==
                       0) {
            strncpy(conn->request_id, value, sizeof(conn->request_id) - 1);
            conn->request_id[sizeof(conn->request_id) - 1] = '\0';
        }

        offset += (int)match[0].rm_eo;
    }

    conn->message_start += offset + 2; // skip the blank line ("\r\n") ending headers
    regfree(&re);
    return NULL;
}

// Request-line parse, ported from asgn2 process_request (request.c L72).
static const Response_t *process_request(conn_t *conn) {
    regex_t re;
    int comp_rc = regcomp(&re, REQUEST_LINE, REG_EXTENDED);
    if (comp_rc != 0) {
        // See parse_headers' comp_rc check (M4 review backlog B4a): a
        // malformed *pattern* is a programming bug, but assert()-crashing the
        // server is worse than answering 500, and is a set-but-unused warning
        // waiting to happen under -DNDEBUG.
        return &RESPONSE_INTERNAL_SERVER_ERROR;
    }

    regmatch_t match[5];
    if (regexec(&re, conn->buffer, 5, match, 0) != 0) {
        regfree(&re);
        return &RESPONSE_BAD_REQUEST;
    }

    if (strncmp(conn->buffer + match[1].rm_so, "GET", 3) == 0) {
        conn->request = &REQUEST_GET;
    } else if (strncmp(conn->buffer + match[1].rm_so, "PUT", 3) == 0) {
        conn->request = &REQUEST_PUT;
    } else {
        // Not a static-correctness failure -- the caller (httpserver.c)
        // dispatches unsupported methods to a 501 response.
        conn->request = &REQUEST_UNSUPPORTED;
    }

    // M4 (review backlog B1): capture the URI *before* the version check, so
    // that a request with both a valid method/URI and a bad HTTP version
    // (-> 505) still has conn->uri populated for the audit line. Previously
    // the URI copy ran after this block, so any 505 return logged an empty
    // URI. This is the one sanctioned connection.c behavior change.
    int uri_len = match[2].rm_eo - match[2].rm_so;
    if (uri_len >= (int)sizeof(conn->uri)) {
        regfree(&re);
        return &RESPONSE_BAD_REQUEST;
    }
    memcpy(conn->uri, conn->buffer + match[2].rm_so, (size_t)uri_len);
    conn->uri[uri_len] = '\0';

    // Version check (kept verbatim from asgn2): match[4] is the *minor*
    // version digit group; asgn2 checked it (not match[3], the major) as
    // the "must be 1" gate. Not one of the three named defects to fix, so
    // it is ported as-is rather than "corrected".
    if (match[4].rm_eo - match[4].rm_so > 1) {
        regfree(&re);
        return &RESPONSE_BAD_REQUEST;
    }
    if (strncmp(conn->buffer + match[4].rm_so, "1", 1) != 0) {
        regfree(&re);
        return &RESPONSE_VERSION_NOT_SUPPORTED;
    }

    conn->message_start = (int)match[4].rm_eo + 2; // skip \r\n after HTTP/x.y

    regfree(&re);

    const Response_t *res = validate_uri(conn);
    if (res != NULL) {
        return res;
    }

    return parse_headers(conn);
}

conn_t *conn_new(int connfd) {
    conn_t *conn = (conn_t *)calloc(1, sizeof(conn_t));
    if (conn == NULL) {
        return NULL;
    }
    conn->connfd = connfd;
    conn->request = &REQUEST_UNSUPPORTED;
    strcpy(conn->request_id, "0"); // audit-log default when header is absent
    return conn;
}

void conn_delete(conn_t **conn) {
    if (conn == NULL || *conn == NULL) {
        return;
    }
    free(*conn);
    *conn = NULL;
}

const Response_t *conn_parse(conn_t *conn) {
    ssize_t bytes_read = read_until(conn->connfd, conn->buffer, BUFFER_SIZE, "\r\n\r\n");

    // Record read_until's raw result -- including -1 -- BEFORE branching on
    // it. conn_is_empty() keys on bytes_read == 0, which must mean exactly
    // "EOF with zero bytes ever sent" (read_until only returns 0 in that
    // case; any partial data makes it return a positive count, and an error/
    // timeout returns -1 regardless of what was already buffered). Assigning
    // only on the success path -- the original M4 bug -- left the calloc'd 0
    // in place for the error path, making a timed-out partial request look
    // like a silent connect-then-close and dropping its 500 + audit line.
    conn->bytes_read = bytes_read;

    if (bytes_read < 0) {
        // Gem (docs/REFERENCE.md #1): SO_RCVTIMEO firing surfaces as
        // EAGAIN/EWOULDBLOCK -- that must become a 500, not a crash/close.
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return &RESPONSE_INTERNAL_SERVER_ERROR;
        }
        return &RESPONSE_BAD_REQUEST;
    }
    if (bytes_read == 0) {
        return &RESPONSE_BAD_REQUEST;
    }

    conn->buffer[bytes_read] = '\0'; // null-terminate before regexec (c-systems-idioms)

    const Response_t *res = process_request(conn);
    if (res != NULL) {
        return res;
    }

    // Gem (docs/REFERENCE.md #2): whatever of the PUT body was already
    // buffered by the read_until() call above belongs to the body, not the
    // headers -- conn_recv_file writes it out before streaming the rest.
    conn->in_message = (int)conn->bytes_read - conn->message_start;

    return NULL;
}

const Request_t *conn_get_request(conn_t *conn) {
    return conn->request;
}

char *conn_get_uri(conn_t *conn) {
    return conn->uri;
}

char *conn_get_header(conn_t *conn, char *header) {
    if (strcmp(header, "Content-Length") == 0) {
        snprintf(conn->content_length_str, sizeof(conn->content_length_str), "%jd",
                 (intmax_t)conn->content_length);
        return conn->content_length_str;
    }
    if (strcmp(header, "Request-Id") == 0) {
        return conn->request_id;
    }
    return NULL;
}

const Response_t *conn_recv_file(conn_t *conn, int fd) {
    ssize_t total_written = 0;

    if (conn->in_message > 0) {
        // Verbatim asgn2 behavior (docs/DECISIONS.md D3, D18): the *entire*
        // buffered leftover is written out, even if `in_message` exceeds
        // Content-Length (an over-long first segment writes past the declared
        // length; `remaining` below then just goes negative and no further
        // bytes are streamed). The ztest mock clamps this write to
        // Content-Length, so the two implementations diverge on an over-long
        // first segment; the divergence is intentional and D3-protected -- do
        // NOT "fix" the C side to clamp.
        total_written = write_all(fd, &conn->buffer[conn->message_start], (size_t)conn->in_message);
        if (total_written < 0) {
            return &RESPONSE_INTERNAL_SERVER_ERROR;
        }
    }

    ssize_t remaining = conn->content_length - total_written;
    if (remaining > 0) {
        ssize_t rc = pass_bytes(conn->connfd, fd, (size_t)remaining);
        if (rc < 0) {
            return &RESPONSE_INTERNAL_SERVER_ERROR;
        }
    }

    return NULL;
}

const Response_t *conn_send_file(conn_t *conn, int fd, uint64_t count) {
    char header[BUFFER_SIZE];
    int header_len =
        snprintf(header, sizeof(header), "HTTP/1.1 %d %s\r\nContent-Length: %" PRIu64 "\r\n\r\n",
                 response_get_code(&RESPONSE_OK), response_get_message(&RESPONSE_OK), count);

    if (write_all(conn->connfd, header, (size_t)header_len) < 0) {
        return &RESPONSE_INTERNAL_SERVER_ERROR;
    }

    if (count > 0) {
        ssize_t rc = pass_bytes(fd, conn->connfd, (size_t)count);
        if (rc < 0) {
            return &RESPONSE_INTERNAL_SERVER_ERROR;
        }
    }

    return NULL;
}

const Response_t *conn_send_response(conn_t *conn, const Response_t *res) {
    uint16_t code = response_get_code(res);
    const char *msg = response_get_message(res);

    char body[BUFFER_SIZE];
    int body_len = snprintf(body, sizeof(body), "%s\n", msg);

    char header[BUFFER_SIZE];
    int header_len =
        snprintf(header, sizeof(header), "HTTP/1.1 %d %s\r\nContent-Length: %d\r\n\r\n%s", code,
                 msg, body_len, body);

    if (write_all(conn->connfd, header, (size_t)header_len) < 0) {
        return &RESPONSE_INTERNAL_SERVER_ERROR;
    }

    return NULL;
}

char *conn_str(conn_t *conn) {
    return conn->uri;
}
