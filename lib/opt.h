#ifndef OPT_H
#define OPT_H

#include <getopt.h>
#include <stdlib.h>
#include <sys/types.h>

#define OPTIONS "t:l:"
#define DEFAULT_THREAD_COUNT 4

// Parsed command-line options for `./httpserver [-t threads] [-l logfile] <port>`.
struct OPT {
    int n_threads;  // -t N, default DEFAULT_THREAD_COUNT
    char *log_path; // -l PATH, or NULL for stderr (owned by argv, do not free)
    int port;       // required positional argument
};

/* @brief Parse argc/argv into *opts.
 * @param argc  argument count
 * @param argv  argument vector
 * @param opts  out-param populated with threads/log_path/port
 * @returns 0 on success; -1 on any usage error (a usage message is printed to
 *          stderr). The caller should exit non-zero on -1.
 */
int opt_parse(int argc, char *argv[], struct OPT *opts);

#endif // !OPT_H
