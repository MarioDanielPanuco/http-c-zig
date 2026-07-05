
#ifndef LOG_H
#define LOG_H

#include <stdio.h>

// NOTE: this is a placeholder for M1 (compile-only). The real log module
// (log_init(), thread-safe writes) is milestone M3 -- see docs/ROADMAP.md.
// `logFile` has external linkage (defined once in src/log.c) rather than
// `static` in the header: a `static FILE *logFile` here would give every
// including .c file its own unused copy, which is a -Wunused-variable error
// under -Werror since nothing calls LOG(...) yet.
extern FILE *logFile;

#define LOG(...) fprintf(logFile, __VA_ARGS__);



#endif //LOG_H

