//
// Created by Daniel on 3/12/2023.
// M3: full rewrite. The previous version dereferenced a NULL `tp`, never
// allocated the `threads` array, double-popped the queue, freed an
// un-malloc'd pointer, and mismatched `threadpool_destory` vs the header's
// `threadpool_destroy`. It was also dead code (httpserver.c had an inline
// pool). This is now the sole, correct pool and httpserver.c adopts it.
//
#include "../lib/threadpool.h"
#include "../lib/queue.h"

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>

// Sentinel pushed onto the queue to tell a worker to exit. Real connection fds
// are always >= 0, so (intptr_t)-1 can never collide with one.
#define STOP_SENTINEL ((void *)(intptr_t)-1)

struct threadpool {
    pthread_t *threads;
    int nthreads;
    queue_t *q;
    conn_handler_t handler;
};

// Worker loop: block on the queue, run the handler, repeat until the stop
// sentinel is dequeued. Exactly one queue_pop per iteration (the old bug was a
// second, redundant pop that dropped every other connection).
static void *worker(void *arg) {
    threadpool_t *tp = (threadpool_t *)arg;

    for (;;) {
        void *item = NULL;
        queue_pop(tp->q, &item);
        if (item == STOP_SENTINEL)
            break;
        tp->handler((int)(intptr_t)item);
    }

    return NULL;
}

threadpool_t *threadpool_new(int nthreads, int queue_size, conn_handler_t handler) {
    if (nthreads <= 0 || queue_size <= 0 || handler == NULL)
        return NULL;

    threadpool_t *tp = (threadpool_t *)malloc(sizeof(*tp));
    if (tp == NULL)
        return NULL;

    tp->nthreads = nthreads;
    tp->handler = handler;
    tp->threads = (pthread_t *)malloc(sizeof(pthread_t) * nthreads);
    tp->q = queue_new(queue_size);
    if (tp->threads == NULL || tp->q == NULL) {
        free(tp->threads);
        if (tp->q != NULL)
            queue_delete(&tp->q);
        free(tp);
        return NULL;
    }

    for (int i = 0; i < nthreads; ++i) {
        if (pthread_create(&tp->threads[i], NULL, worker, tp) != 0) {
            // Roll back: stop the workers already created, then bail out.
            for (int j = 0; j < i; ++j)
                queue_push(tp->q, STOP_SENTINEL);
            for (int j = 0; j < i; ++j)
                pthread_join(tp->threads[j], NULL);
            queue_delete(&tp->q);
            free(tp->threads);
            free(tp);
            return NULL;
        }
    }

    return tp;
}

bool threadpool_submit(threadpool_t *tp, int connfd) {
    if (tp == NULL)
        return false;
    return queue_push(tp->q, (void *)(intptr_t)connfd);
}

void threadpool_destroy(threadpool_t *tp) {
    if (tp == NULL)
        return;

    // One sentinel per worker so each wakes exactly once and exits.
    for (int i = 0; i < tp->nthreads; ++i)
        queue_push(tp->q, STOP_SENTINEL);
    for (int i = 0; i < tp->nthreads; ++i)
        pthread_join(tp->threads[i], NULL);

    queue_delete(&tp->q);
    free(tp->threads);
    free(tp);
}
