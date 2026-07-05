
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
#include <pthread.h>
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
// the URI charset ([a-zA-Z0-9/_.-], see docs/DECISIONS.md D14), so the
// mapping is injective.
//
// Lockfiles are opened per request and closed after unlock (no cache, no
// cleanup problem; fd churn is acceptable). They are never truncated, never
// served, and never unlinked while any server for this cwd may be running:
// unlinking would let a later open create a *new* inode for the same path
// while an old fd still holds flock on the orphaned one, silently splitting
// the lock in two.
static char lock_dir[96];

// M4 (review backlog B5): mkdir's EEXIST tells us *a* directory entry is
// already there, not that it is safe to use -- /tmp is world-writable, so
// another user could have pre-created (or symlinked) this exact path ahead of
// us. After EEXIST, lstat the path (not stat: don't follow a symlink planted
// by an attacker) and require it to be a real directory we own before trusting
// it as the lock namespace; otherwise fail startup with a clear diagnostic
// rather than silently flock-ing through a squatted path.
static int lockdir_init(void) {
    struct stat st;
    if (stat(".", &st) < 0)
        return -1;
    snprintf(lock_dir, sizeof(lock_dir), "/tmp/.httpserver.locks.%ju.%ju", (uintmax_t)st.st_dev,
             (uintmax_t)st.st_ino);

    if (mkdir(lock_dir, 0700) == 0)
        return 0;
    if (errno != EEXIST) {
        warn("mkdir %s", lock_dir);
        return -1;
    }

    struct stat lock_st;
    if (lstat(lock_dir, &lock_st) < 0) {
        warn("lstat %s", lock_dir);
        return -1;
    }
    if (!S_ISDIR(lock_st.st_mode) || lock_st.st_uid != geteuid()) {
        warnx("refusing to use %s: exists but is not a directory we own "
              "(possible /tmp squatting)",
              lock_dir);
        return -1;
    }
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

//////////////////////////////////////////////////////////////////////
// SIGTERM/SIGINT handling for audit-log durability (M4 plan item 2; the
// commented-out placeholder handlers at the old httpserver.c L84-85).
//
// The spec requires log entries to be durable across a SIGTERM: "your server
// must ensure that log entries are resident in the log after we send your
// server a SIGTERM signal." log_audit already fflushes every line as it's
// written (docs/DECISIONS.md D10), so durability is already satisfied by the
// time any signal arrives; what a handler adds is a *clean exit* instead of
// the default disposition (immediate termination without a chance to close a
// `-l` logfile's stream, or -- if the plan called for it -- to drain more
// state).
//
// Design (per posix-threading skill): a signal handler body is restricted to
// async-signal-safe calls, and log_close()/fclose() are not on that list, so
// this does *not* run cleanup from a signal handler. Instead, SIGTERM and
// SIGINT are blocked (via pthread_sigmask) before any worker thread is
// created, so every thread in the process -- dispatcher and workers alike --
// inherits the block. A dedicated thread then sits in sigwait() on exactly
// those two signals; sigwait() is not a signal handler, so it runs with the
// full C library available. When it wakes, it flushes/closes the audit log
// and calls exit(), which tears down the whole process (closing every fd,
// releasing every flock/lockfile the workers may be holding) -- there is
// nothing to "stop accepting" separately, because the dispatcher's accept()
// loop and every in-flight worker die with the process.
//
// Repeated SIGINT/SIGTERM cannot deadlock: the signal stays blocked in every
// thread for the process's entire remaining lifetime (nothing ever unblocks
// it), so a second delivery is simply queued/coalesced by the kernel and
// never reaches a second sigwait() call or handler body -- there is no lock
// this path acquires that a repeat delivery could contend.
static sigset_t shutdown_set;

static void *signal_wait_thread(void *arg) {
    (void)arg;
    int sig = 0;
    sigwait(&shutdown_set, &sig);
    log_close(); // flush + close a `-l` logfile (fflush already keeps stderr durable per-line)
    exit(EXIT_SUCCESS);
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
        return EXIT_FAILURE; // lockdir_init already printed a specific diagnostic

    // A client hanging up mid-response must not kill the server.
    signal(SIGPIPE, SIG_IGN);

    // Block SIGTERM/SIGINT in this thread *before* spawning the pool's
    // workers or the signal-waiting thread below, so every thread the process
    // ever has inherits the block (see the design note above).
    sigemptyset(&shutdown_set);
    sigaddset(&shutdown_set, SIGTERM);
    sigaddset(&shutdown_set, SIGINT);
    if (pthread_sigmask(SIG_BLOCK, &shutdown_set, NULL) != 0)
        err(EXIT_FAILURE, "pthread_sigmask");

    threadpool_t *pool = threadpool_new(opts.n_threads, opts.n_threads, handle_connection);
    if (pool == NULL)
        errx(EXIT_FAILURE, "failed to create thread pool");

    pthread_t sig_tid;
    if (pthread_create(&sig_tid, NULL, signal_wait_thread, NULL) != 0)
        errx(EXIT_FAILURE, "failed to create signal-handling thread");
    pthread_detach(sig_tid);

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
        // M4 (review backlog B3, spec ruling): a bare connect-then-close (no
        // bytes ever sent) is not a request -- nothing was asked of the
        // server, so there is nothing to answer or audit. Close silently.
        // (This is also what the M6 zig harness's own liveness probe does to
        // the server, and had to be filtered out downstream -- docs/DECISIONS
        // D11 item 2 -- precisely because a real audit line for it corrupts
        // the ordering/replay checks; the ruling here fixes it at the source.)
        if (conn_is_empty(conn)) {
            conn_delete(&conn);
            close(connfd);
            return;
        }

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
