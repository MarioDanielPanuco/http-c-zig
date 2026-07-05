// IO helper implementations declared in lib/asgn2_helper_funcs.h.
//
// M4 dead-code prune: this file used to also carry a batch of never-called
// asgn2-era helpers (removeSlash, minimum, error_msg, sigterm_handler,
// sigint_handler, isFile, fileChecking, fSize, print_error, errno_check,
// read_all) plus lib/util.h, the header that declared them. A full-repo grep
// turned up zero callers for any of them: src/connection.c gets read_until/
// write_all/pass_bytes straight from asgn2_helper_funcs.h, and SIGTERM/SIGINT
// are now handled properly in src/httpserver.c (see its signal_wait_thread),
// making the old handler stubs (which called exit() from signal-handler
// context -- not async-signal-safe) both dead and unsafe. lib/util.h itself
// had no other includer once these were gone, so it was deleted rather than
// left as a pass-through to asgn2_helper_funcs.h.
#include "../lib/asgn2_helper_funcs.h"

#include <errno.h>
#include <string.h>
#include <unistd.h>

#define BUFFER_SIZE 4096

// write_all: loop until every byte is written or a real error occurs.
// Retries on EINTR (a signal interrupting the write is not a failure).
ssize_t write_all(int connfd, char buffer[], size_t nbytes) {
    size_t total = 0;

    while (total < nbytes) {
        ssize_t n = write(connfd, buffer + total, nbytes - total);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        total += (size_t)n;
    }
    return (ssize_t)total;
}

// pass_bytes: stream nbytes from src to dst through a fixed-size buffer,
// without reading the whole transfer into memory at once. Per
// c-systems-idioms: both read() and write() may transfer fewer bytes than
// requested, so both sides loop; EINTR is retried, not treated as failure.
// (Was previously an empty infinite-loop stub at src/util.c:143-151.)
ssize_t pass_bytes(int src, int dst, size_t nbytes) {
    char buf[BUFFER_SIZE];
    size_t total = 0;

    while (total < nbytes) {
        size_t want = nbytes - total;
        if (want > sizeof(buf))
            want = sizeof(buf);

        ssize_t nread;
        do {
            nread = read(src, buf, want);
        } while (nread < 0 && errno == EINTR);

        if (nread < 0)
            return -1;
        if (nread == 0)
            break; // source EOF before nbytes were transferred

        ssize_t written = write_all(dst, buf, (size_t)nread);
        if (written < 0)
            return -1;

        total += (size_t)nread;
    }

    return (ssize_t)total;
}

// read_until: read from `in` until nbytes have been read, EOF, an error (or
// timeout -- SO_RCVTIMEO surfaces as EAGAIN/EWOULDBLOCK from read(), which we
// deliberately do NOT swallow: the caller maps a timeout to a 500 response),
// or `string` appears in the buffer so far.
ssize_t read_until(int in, char buf[], size_t nbytes, char *string) {
    size_t needle_len = string ? strlen(string) : 0;
    size_t total = 0;

    while (total < nbytes) {
        ssize_t n;
        do {
            n = read(in, buf + total, nbytes - total);
        } while (n < 0 && errno == EINTR);

        if (n < 0)
            return -1;
        if (n == 0)
            break; // EOF

        total += (size_t)n;

        if (needle_len > 0 && total >= needle_len) {
            for (size_t i = 0; i + needle_len <= total; i++) {
                if (memcmp(buf + i, string, needle_len) == 0)
                    return (ssize_t)total;
            }
        }
    }

    return (ssize_t)total;
}
