#include "../lib/log.h"

#include <pthread.h>

// A single module-private mutex serializes every audit write. Combined with a
// single fprintf per entry this guarantees the two properties the spec demands:
// atomicity (no interleaved/partial lines across threads) and, because the
// audit write happens while a worker still holds its per-URI lock, that the
// audit order is a valid linearization. See docs/DECISIONS.md D10 for why a
// mutex is used here rather than flockfile(): it is explicit, portable, and
// covers the fflush in the same critical section.
static FILE *log_stream = NULL;
static pthread_mutex_t log_mu = PTHREAD_MUTEX_INITIALIZER;

void log_init(FILE *stream) {
    log_stream = (stream != NULL) ? stream : stderr;
}

void log_audit(const char *oper, const char *uri, int status, const char *rid) {
    pthread_mutex_lock(&log_mu);
    // Shutdown race guard (post-review fix): with `-l`, log_close() fcloses
    // the stream and sets log_stream = NULL under this same mutex, then the
    // signal thread calls exit(). A worker already blocked on log_mu can win
    // the lock in the window before exit() finishes tearing the process down;
    // without this check it would fprintf(NULL, ...) and crash. Dropping the
    // line is correct here -- the process is exiting and the line could never
    // become durable in a closed file anyway -- a segfault is not. The stderr
    // path never hits this: log_close() only fcloses/NULLs streams it doesn't
    // share with the C runtime (`log_stream != stderr` is checked before the
    // fclose), so when auditing to stderr the pointer stays valid for the
    // process's whole life.
    if (log_stream != NULL) {
        fprintf(log_stream, "%s,%s,%d,%s\n", oper, uri, status, rid);
        fflush(log_stream);
    }
    pthread_mutex_unlock(&log_mu);
}

void log_close(void) {
    pthread_mutex_lock(&log_mu);
    if (log_stream != NULL && log_stream != stderr) {
        fclose(log_stream);
        log_stream = NULL;
    }
    pthread_mutex_unlock(&log_mu);
}
