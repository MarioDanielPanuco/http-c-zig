
#include "../lib/connection.h"
#include "../lib/listener.h"
#include "../lib/log.h"
#include "../lib/opt.h"
#include "../lib/request.h"
#include "../lib/response.h"
#include "../lib/threadpool.h"

#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

void handle_connection(int connfd);

void audit_send_response(conn_t *conn, const Response_t *res);

void handle_get(conn_t *conn);

void handle_put(conn_t *conn);

void handle_unsupported(conn_t *conn);

//////////////////////////////////////////////////////////////////////
// Per-URI locking via flock on a sidecar lockfile (docs/DECISIONS.md D12).
//
// M3 replaces the M2 global file mutex (which serialized every request and
// scored zero on the concurrency rubric) with per-URI flock: LOCK_SH for GET,
// LOCK_EX for PUT. flock on the *target* file cannot work here -- the lock is
// bound to an open file description, so a PUT's create/existence decision on a
// not-yet-existing URI could never be covered by it (the 201-vs-200 result
// would be decided at open() time, decoupled from lock order, breaking the
// audit-log linearization that conflict_stress_put/conflict_pause_puts gate
// on). Instead each URI gets a dedicated *lockfile* that can exist -- and be
// flocked -- before the target does. The critical section under that flock is:
// existence check -> open target (no O_TRUNC) -> ftruncate under lock (PUT)
// -> file I/O -> audit write -> unlock.
//
// Lockfile location: /tmp/.httpserver.locks.<dev>.<ino>/ where dev/ino
// identify the server's working directory. Keying by cwd identity (not pid)
// means two server processes serving the same directory share one lock
// namespace -- real cross-process coherency, the property flock buys over any
// in-process table. Lockfiles live outside the serve directory, so no
// workload URI (resolved relative to cwd) can collide with them. Within the
// directory the URI->lockfile mapping replaces '/' with '%'; '%' is outside
// the URI charset ([a-zA-Z0-9/_.]), so the mapping is injective.
//
// Lockfiles are opened per request and closed after unlock (no cache, no
// cleanup problem; fd churn is acceptable). They are never truncated, never
// served, and never unlinked while any server for this cwd may be running:
// unlinking would let a later open create a *new* inode for the same path
// while an old fd still holds flock on the orphaned one, silently splitting
// the lock in two.
static char lock_dir[96];

static int lockdir_init(void) {
    struct stat st;
    if (stat(".", &st) < 0)
        return -1;
    snprintf(lock_dir, sizeof(lock_dir), "/tmp/.httpserver.locks.%ju.%ju", (uintmax_t)st.st_dev,
             (uintmax_t)st.st_ino);
    if (mkdir(lock_dir, 0700) < 0 && errno != EEXIST)
        return -1;
    return 0;
}

// Build the sidecar lockfile path for a URI (injective; see above).
static void lock_path_for(const char *uri, char *buf, size_t n) {
    size_t off = (size_t)snprintf(buf, n, "%s/", lock_dir);
    for (const char *p = uri; *p != '\0' && off + 1 < n; ++p)
        buf[off++] = (*p == '/') ? '%' : *p;
    buf[off] = '\0';
}

// Open (creating if needed, never truncating) the lockfile for `uri` and take
// `op` (LOCK_SH or LOCK_EX), retrying flock on EINTR. Returns the lockfile fd
// with the lock held, or -1 on failure (caller responds 500).
static int uri_lock(const char *uri, int op) {
    char path[192];
    lock_path_for(uri, path, sizeof(path));

    int fd = open(path, O_CREAT | O_RDONLY, 0600);
    if (fd < 0)
        return -1;
    while (flock(fd, op) < 0) {
        if (errno != EINTR) {
            close(fd);
            return -1;
        }
    }
    return fd;
}

static void uri_unlock(int lockfd) {
    if (lockfd >= 0) {
        flock(lockfd, LOCK_UN);
        close(lockfd);
    }
}

int main(int argc, char **argv) {
    struct OPT opts;
    if (opt_parse(argc, argv, &opts) != 0)
        return EXIT_FAILURE;

    FILE *log_stream = stderr;
    if (opts.log_path != NULL) {
        log_stream = fopen(opts.log_path, "w");
        if (log_stream == NULL)
            err(EXIT_FAILURE, "%s", opts.log_path);
    }
    log_init(log_stream);

    if (lockdir_init() < 0)
        err(EXIT_FAILURE, "failed to create lock directory");

    // A client hanging up mid-response must not kill the server.
    signal(SIGPIPE, SIG_IGN);

    threadpool_t *pool = threadpool_new(opts.n_threads, opts.n_threads, handle_connection);
    if (pool == NULL)
        errx(EXIT_FAILURE, "failed to create thread pool");

    Listener_Socket sock;
    if (listener_init(&sock, opts.port) < 0)
        errx(EXIT_FAILURE, "failed to listen on port %d", opts.port);

    // Dispatcher loop: accept connections and hand them to the worker pool.
    for (;;) {
        int connfd = listener_accept(&sock);
        if (connfd < 0)
            continue;
        threadpool_submit(pool, connfd);
    }

    // Unreachable in normal operation (terminated by signal), but kept so the
    // shutdown path is defined and leak-free: join all workers, free the pool,
    // close the log.
    threadpool_destroy(pool);
    log_close();
    return EXIT_SUCCESS;
}

void handle_connection(int connfd) {
    conn_t *conn = conn_new(connfd);
    const Response_t *res = conn_parse(conn);

    if (res != NULL) {
        // 501 (unsupported method) takes precedence over 505 (bad version):
        // if both conditions are true, return 501.
        if (res == &RESPONSE_VERSION_NOT_SUPPORTED &&
            conn_get_request(conn) == &REQUEST_UNSUPPORTED) {
            res = &RESPONSE_NOT_IMPLEMENTED;
        }
        conn_send_response(conn, res);
        audit_send_response(conn, res);
    } else {
        const Request_t *req = conn_get_request(conn);
        if (req == &REQUEST_GET) {
            handle_get(conn);
        } else if (req == &REQUEST_PUT) {
            handle_put(conn);
        } else {
            handle_unsupported(conn);
        }
    }

    conn_delete(&conn);
    close(connfd);
}

void handle_get(conn_t *conn) {
    const Response_t *res = NULL;
    char *uri = conn_get_uri(conn);

    // Shared flock: concurrent GETs to the same URI proceed in parallel, but a
    // PUT to this URI is excluded for the whole critical section (open through
    // audit). This is what conflict_pause_gets needs -- three stalled readers
    // must not block a fourth reader on the same URI.
    int lockfd = uri_lock(uri, LOCK_SH);
    if (lockfd < 0) {
        res = &RESPONSE_INTERNAL_SERVER_ERROR;
        conn_send_response(conn, res);
        audit_send_response(conn, res);
        return;
    }

    // GET never modifies the file it serves: open read-only, no truncate.
    int fd = open(uri, O_RDONLY);
    if (fd < 0) {
        if (errno == EACCES || errno == EISDIR) {
            res = &RESPONSE_FORBIDDEN;
        } else if (errno == ENOENT) {
            res = &RESPONSE_NOT_FOUND;
        } else {
            res = &RESPONSE_INTERNAL_SERVER_ERROR;
        }
        conn_send_response(conn, res);
        audit_send_response(conn, res);
        uri_unlock(lockfd);
        return;
    }

    struct stat st;
    if (fstat(fd, &st) < 0) {
        res = &RESPONSE_INTERNAL_SERVER_ERROR;
        conn_send_response(conn, res);
        audit_send_response(conn, res);
        close(fd);
        uri_unlock(lockfd);
        return;
    }

    if (S_ISDIR(st.st_mode)) {
        res = &RESPONSE_FORBIDDEN;
        conn_send_response(conn, res);
        audit_send_response(conn, res);
        close(fd);
        uri_unlock(lockfd);
        return;
    }

    // Intended status is 200 once we know the file is a readable regular file;
    // conn_send_file's own success/failure (e.g. the client hanging up mid
    // transfer) does not change the *intended* code we audit (httpserver-spec).
    res = &RESPONSE_OK;
    conn_send_file(conn, fd, (uint64_t)st.st_size);
    audit_send_response(conn, res);
    close(fd);
    uri_unlock(lockfd);
}

void handle_unsupported(conn_t *conn) {
    conn_send_response(conn, &RESPONSE_NOT_IMPLEMENTED);
    audit_send_response(conn, &RESPONSE_NOT_IMPLEMENTED);
}

void handle_put(conn_t *conn) {
    char *uri = conn_get_uri(conn);
    const Response_t *res = NULL;

    // Exclusive flock: serialize all writers to this URI. Crucially, the
    // existence check, the file I/O, and the audit write all happen inside this
    // one critical section, so the 201-vs-200 decision matches audit order --
    // the first PUT to reach a not-yet-existing URI logs 201, every later one
    // logs 200 (the property watson replays).
    int lockfd = uri_lock(uri, LOCK_EX);
    if (lockfd < 0) {
        res = &RESPONSE_INTERNAL_SERVER_ERROR;
        conn_send_response(conn, res);
        audit_send_response(conn, res);
        return;
    }

    bool existed = access(uri, F_OK) == 0;

    // Open (creating if absent) WITHOUT O_TRUNC; truncate only after the lock
    // is held. Because we hold the exclusive URI lock, no reader can observe a
    // half-truncated file. Errno mapping matches the spec: EACCES/EISDIR/ENOENT
    // -> 403, anything else -> 500.
    int fd = open(uri, O_CREAT | O_WRONLY, 0600);
    if (fd < 0) {
        if (errno == EACCES || errno == EISDIR || errno == ENOENT) {
            res = &RESPONSE_FORBIDDEN;
        } else {
            res = &RESPONSE_INTERNAL_SERVER_ERROR;
        }
        conn_send_response(conn, res);
        audit_send_response(conn, res);
        uri_unlock(lockfd);
        return;
    }

    if (ftruncate(fd, 0) < 0) {
        res = &RESPONSE_INTERNAL_SERVER_ERROR;
        conn_send_response(conn, res);
        audit_send_response(conn, res);
        close(fd);
        uri_unlock(lockfd);
        return;
    }
    res = conn_recv_file(conn, fd);

    if (res == NULL)
        res = existed ? &RESPONSE_OK : &RESPONSE_CREATED;

    conn_send_response(conn, res);
    audit_send_response(conn, res);
    close(fd);
    uri_unlock(lockfd);
}

void audit_send_response(conn_t *conn, const Response_t *res) {
    uint16_t status_code = response_get_code(res);
    char *uri = conn_get_uri(conn);
    // Oper is the HTTP verb (GET/PUT), not the response message.
    const char *verb = request_get_str(conn_get_request(conn));
    char *requestID = conn_get_header(conn, "Request-Id");

    log_audit(verb, uri, status_code, requestID);
}
