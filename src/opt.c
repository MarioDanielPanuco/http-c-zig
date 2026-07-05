
#include "../lib/opt.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

// M3: `opt_parse` now actually populates an `struct OPT` and returns a status,
// instead of parsing into a discarded local and falling off the end of an
// ssize_t function with no return (the old bug). Also fixes the garbled
// "optichar *ons" format string and adds the positional port + `-l PATH`.

static void usage(const char *prog) {
    fprintf(stderr, "usage: %s [-t threads] [-l logfile] <port>\n", prog);
}

// Parse a strictly-positive base-10 integer that fits in an int. Returns -1 on
// malformed input or overflow: strtol saturates + sets ERANGE on long
// overflow, and anything > INT_MAX would otherwise wrap when the caller casts
// to int (e.g. `-t 4294967297` silently becoming 1).
static long parse_positive(const char *s) {
    if (s == NULL || *s == '\0')
        return -1;
    char *end = NULL;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno == ERANGE || *end != '\0' || v <= 0 || v > INT_MAX)
        return -1;
    return v;
}

int opt_parse(int argc, char *argv[], struct OPT *opts) {
    opts->n_threads = DEFAULT_THREAD_COUNT;
    opts->log_path = NULL;
    opts->port = 0;

    int opt;
    optind = 1;
    while ((opt = getopt(argc, argv, OPTIONS)) != -1) {
        switch (opt) {
        case 't': {
            long n = parse_positive(optarg);
            if (n < 0) {
                usage(argv[0]);
                return -1;
            }
            opts->n_threads = (int)n;
            break;
        }
        case 'l':
            opts->log_path = optarg;
            break;
        default:
            usage(argv[0]);
            return -1;
        }
    }

    if (optind >= argc) {
        usage(argv[0]);
        return -1;
    }

    long port = parse_positive(argv[optind]);
    if (port < 0 || port > 65535) {
        usage(argv[0]);
        return -1;
    }
    opts->port = (int)port;
    return 0;
}
