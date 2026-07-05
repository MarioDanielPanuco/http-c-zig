#include "../lib/util.h"

#include <errno.h>
#include <string.h>

char *removeSlash(char *str) {
    if (str[0] == '/') {
        str += 1;
    }
    return str;
}

int minimum(int a, int b) {
    return a < b ? a : b;
}

// Security note (see docs/REFERENCE.md gem #3): write the *exact* message to
// stderr and exit -- no fprintf/format string built from untrusted input.
// The original asgn2 version used `sizeof(msg) / sizeof(msg[0])`, which on a
// `char *` parameter computes sizeof(char*)/sizeof(char) (8 on most 64-bit
// platforms) instead of the string length -- a known asgn2 defect
// (docs/REFERENCE.md "sizeof applied to pointer"). Fixed here to strlen(msg).
int error_msg(char *msg) {
    write_all(STDERR_FILENO, msg, strlen(msg));
    exit(EXIT_FAILURE);
    return 0;
}

void sigterm_handler(int sig) {
    if (sig == SIGTERM) {
        warnx("SIGTERM");
        exit(EXIT_SUCCESS);
    }
}

void sigint_handler(int sig) {
    if (sig == SIGINT) {
        warnx("SIGINT");
        exit(EXIT_SUCCESS);
    }
}

int isFile(char *filename) {
    if (access(filename, F_OK) == 0) {
        struct stat filenameStat;
        stat(filename, &filenameStat);
        return S_ISREG(filenameStat.st_mode);
    }
    return NEW_FILE;
}

int fileChecking(void) {
    if (errno == ENOENT)
        return 404;
    return SUCCESS;
}

int fSize(int fd) {
    struct stat sBuf;
    if (fstat(fd, &sBuf)) {
        return -1;
    }
    return (int) sBuf.st_size;
}

void print_error(char *string, int errorCode) {
    (void) string;
    exit(errorCode);
}

int errno_check(void) {
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return INTERNAL_SERVER_ERROR;
    }
    return SUCCESS;
}

ssize_t read_all(int connfd, char *buffer) {
    ssize_t readCode = 1;
    ssize_t totalRead = 0;

    ssize_t n = BUFFER_SIZE + 5;
    while ((readCode = read(connfd, buffer + totalRead, n - totalRead)) > 0) {
        totalRead += readCode;
        if (totalRead == n) {
            return totalRead;
        }
    }
    return totalRead;
}

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
        total += (size_t) n;
    }
    return (ssize_t) total;
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

        ssize_t written = write_all(dst, buf, (size_t) nread);
        if (written < 0)
            return -1;

        total += (size_t) nread;
    }

    return (ssize_t) total;
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

        total += (size_t) n;

        if (needle_len > 0 && total >= needle_len) {
            for (size_t i = 0; i + needle_len <= total; i++) {
                if (memcmp(buf + i, string, needle_len) == 0)
                    return (ssize_t) total;
            }
        }
    }

    return (ssize_t) total;
}
