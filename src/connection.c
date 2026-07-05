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

#include <assert.h>
#include <errno.h>
#include <inttypes.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BUFFER_SIZE 4096

#define REQUEST_LINE "^([a-zA-Z]{1,8}) /([a-zA-Z0-9/_.]{1,63}) HTTP/([0-9]{1,2}).([0-9]{1,2})\r\n"
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
    assert(comp_rc == 0);

    char *headers = conn->buffer + conn->message_start;
    int offset = 0;
    regmatch_t match[3];

    while (regexec(&re, headers + offset, 3, match, 0) == 0) {
        int key_len = match[1].rm_eo - match[1].rm_so;
        int value_len = match[2].rm_eo - match[2].rm_so;

        char key[129];
        char value[129];
        memcpy(key, headers + offset + match[1].rm_so, (size_t)key_len);
        key[key_len] = '\0';
        memcpy(value, headers + offset + match[2].rm_so, (size_t)value_len);
        value[value_len] = '\0';

        if (strncmp(headers + offset + match[1].rm_so, "Content-Length", (size_t)key_len) == 0) {
            conn->content_length = (ssize_t)strtoull(value, NULL, 10);
        } else if (strncmp(headers + offset + match[1].rm_so, "Request-Id", (size_t)key_len) == 0) {
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
    assert(comp_rc == 0);

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

    int uri_len = match[2].rm_eo - match[2].rm_so;
    if (uri_len >= (int)sizeof(conn->uri)) {
        regfree(&re);
        return &RESPONSE_BAD_REQUEST;
    }
    memcpy(conn->uri, conn->buffer + match[2].rm_so, (size_t)uri_len);
    conn->uri[uri_len] = '\0';

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

    conn->bytes_read = bytes_read;
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
