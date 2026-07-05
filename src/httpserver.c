
#include "../lib/asgn2_helper_funcs.h"
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

void *runner(void *arg);

void *runner(void *arg) {
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
    listener_new(&sock, port);

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

    int f_size = -1;

    pthread_mutex_lock(&glob);
    int fd = open(uri, O_RDONLY, 0666);
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
    ftruncate(fd, 0);
    pthread_mutex_unlock(&glob);

    struct stat buf;
    fstat(fd, &buf);
    f_size = buf.st_size;

    if (S_ISDIR(buf.st_mode)) {
        res = &RESPONSE_FORBIDDEN;
        conn_send_response(conn, res);
        audit_send_response(conn, res);
        close(fd);
        return;
    }

    if (res == NULL) {
        res = &RESPONSE_OK;
        goto out;
    }

out:
    if (f_size >= 0)
        conn_send_file(conn, fd, f_size);
    if (res == NULL) {
        res = &RESPONSE_OK;
    }
    audit_send_response(conn, res);
    flock(fd, LOCK_UN);
    close(fd);
    return;
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
    const char *msg = response_get_message(res);
    char *requestID = conn_get_header(conn, "Request-Id");

    fprintf(stderr, "%s,%s,%d,%s\n", msg, uri, status_code, requestID);
    if (fflush(stderr) != 0)
        return -1;
    return 1;
}
