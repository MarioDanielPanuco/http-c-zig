
#include "../lib/listener.h"
#include "../lib/connection.h"
#include "../lib/response.h"
#include "../lib/request.h"
#include "../lib/queue.h"

#include <fcntl.h>
#include <sys/file.h>
#include <err.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <sys/stat.h>
#include <pthread.h>

#define DEFAULT_THREAD_COUNT 2

void handle_connection(uintptr_t connfd);

int audit_send_response(conn_t *conn, const Response_t *res);

void handle_get(conn_t *conn);

void handle_put(conn_t *conn);

void handle_unsupported(conn_t *conn);

pthread_mutex_t glob;
pthread_mutex_t f_lock;
queue_t *q;

// static: src/threadpool.c (unused/M3, see docs/ROADMAP.md) defines its own
// non-static `runner`; without `static` here the two collide at link time.
static void *runner(void *arg);

static void *runner(void *arg) {
    (void) arg;

    while (1) {
        uintptr_t connfd;
        queue_pop(q, (void **) &connfd);
        handle_connection((int) connfd);
    }
}
 

int main(int argc, char **argv) {
    int opt;
    size_t port;
    int n_threads = DEFAULT_THREAD_COUNT;

    while ((opt = getopt(argc, argv, "t:")) != -1) {
        switch (opt) {
        case 't':
            n_threads = atoi(optarg);
            if (n_threads <= 0)
                errx(EXIT_FAILURE, "Initialized with less than zero threads");
            break;
        default: warnx("Wrong options: %s threads", argv[0]); return EXIT_FAILURE;
        }
    }

    if (optind >= argc) {
        errx(EXIT_FAILURE, "wrong number arguments");
    } else {
        char *endptr = NULL;
        port = (size_t) strtoull(argv[optind], &endptr, 10);

        if (endptr && *endptr != '\0') {
            warnx("invalid port number: %s", argv[1]);
            return EXIT_FAILURE;
        }
    }

    pthread_mutex_init(&glob, NULL);
    q = queue_new(n_threads);
    pthread_t pool[n_threads];

    // Listen sigint and sigterm
    signal(SIGPIPE, SIG_IGN);
    // signal(SIGTERM, sigterm_handler);
    // signal(SIGINT, sigint_handler);


    for (int i = 0; i < n_threads; ++i) {
        pthread_create(pool + i, NULL, runner, NULL);
    }

    Listener_Socket sock;
    listener_init(&sock, port);

    while (1) {
        intptr_t connfd = listener_accept(&sock);
        queue_push(q, (void *) connfd);
    }

    //threadpool_destroy(pool);
    pthread_mutex_destroy(&glob);
    queue_delete(&q);
    return EXIT_SUCCESS;
}

void handle_connection(uintptr_t connfd) {
    conn_t *conn = conn_new(connfd);
    const Response_t *res = conn_parse(conn);

    if (res != NULL) {
        // 501 (unsupported method) takes precedence over 505 (bad version):
        // if both conditions are true, return 501
        if (res == &RESPONSE_VERSION_NOT_SUPPORTED
            && conn_get_request(conn) == &REQUEST_UNSUPPORTED) {
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

    // GET must never modify the file it serves: open read-only, no
    // ftruncate. (M2 fix: this previously did ftruncate(fd, 0) here,
    // destroying the file's contents right before serving them.)
    pthread_mutex_lock(&glob);
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
        pthread_mutex_unlock(&glob);
        return;
    }

    flock(fd, LOCK_SH);
    pthread_mutex_unlock(&glob);

    struct stat st;
    fstat(fd, &st);

    if (S_ISDIR(st.st_mode)) {
        res = &RESPONSE_FORBIDDEN;
        conn_send_response(conn, res);
        audit_send_response(conn, res);
        flock(fd, LOCK_UN);
        close(fd);
        return;
    }

    // The intended status is 200 once we know the file is a readable
    // regular file; conn_send_file's own success/failure (e.g. the client
    // hanging up mid-transfer) does not change the *intended* code that
    // goes in the audit log -- see httpserver-spec skill's audit-log note.
    res = &RESPONSE_OK;
    conn_send_file(conn, fd, (uint64_t) st.st_size);
    audit_send_response(conn, res);
    flock(fd, LOCK_UN);
    close(fd);
}

void handle_unsupported(conn_t *conn) {
    conn_send_response(conn, &RESPONSE_NOT_IMPLEMENTED);
    audit_send_response(conn, &RESPONSE_NOT_IMPLEMENTED);
}

void handle_put(conn_t *conn) {
    char *uri = conn_get_uri(conn);
    const Response_t *res = NULL;

    // Check if file already exists before opening it.
    pthread_mutex_lock(&glob);
    bool existed = access(uri, F_OK) == 0;

    // Open the file..
    int fd = open(uri, O_CREAT | O_WRONLY, 0600);
    if (fd < 0) {
        // debug("%s: %d", uri, errno);
        if (errno == EACCES || errno == EISDIR || errno == ENOENT) {
            res = &RESPONSE_FORBIDDEN;
            conn_send_response(conn, res);
            audit_send_response(conn, res);
            pthread_mutex_unlock(&glob);
            return;
        } else {
            res = &RESPONSE_INTERNAL_SERVER_ERROR;
            conn_send_response(conn, res);
            audit_send_response(conn, res);
            pthread_mutex_unlock(&glob);
            return;
        }
    }
    flock(fd, LOCK_EX);
    ftruncate(fd, 0);
    pthread_mutex_unlock(&glob);

    res = conn_recv_file(conn, fd);

    if (res == NULL && existed) {
        res = &RESPONSE_OK;
    } else if (res == NULL && !existed) {
        res = &RESPONSE_CREATED;
    }

    conn_send_response(conn, res);
    audit_send_response(conn, res);
    flock(fd, LOCK_UN);
    close(fd);
}

int audit_send_response(conn_t *conn, const Response_t *res) {
    uint16_t status_code = response_get_code(res);
    char *uri = conn_get_uri(conn);
    // Oper is the HTTP verb (GET/PUT), not the response message -- the
    // response message (e.g. "OK") was the M2 audit-log format bug.
    const char *verb = request_get_str(conn_get_request(conn));
    char *requestID = conn_get_header(conn, "Request-Id");

    fprintf(stderr, "%s,%s,%d,%s\n", verb, uri, status_code, requestID);
    if (fflush(stderr) != 0)
        return -1;
    return 1;
}
