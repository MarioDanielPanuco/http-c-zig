//
// Created by Daniel on 3/12/2023.
//
#include "../lib/threadpool.h"
#include "../lib/queue.h"
#include <stdlib.h>
#include <pthread.h>

// void* runner(void *tp);

void *runner(void *arg) {
    // (void)*arg;
    thread_pool_t *tp = (thread_pool_t*)arg;

    while (1) {
        int connfd = thread_pop(tp);
        queue_pop(tp->q, (void*) &connfd);
        // queue_pop(tp->q, (void *) &connfd);
        tp->func(&connfd);
    }
}

thread_pool_t threadpool_init(int count, int q_size, void *(*func)(void *) ) {
    thread_pool_t *tp = NULL;

    tp->pool_cap = count;
    tp->func = func;
    tp->q = queue_new(q_size);

    // Creating threads to run in runner function
    for (int i = 0; i < count; ++i) {
        pthread_create(&tp->threads[i], NULL,  &runner, (void*) tp);
    }

    return *tp;
}


void threadpool_destory(thread_pool_t *tp) {
    tp->pool_cap = 0;
    for (int i = 0; i < tp->pool_cap; ++i) {
        pthread_join(tp->threads[i], NULL);
    }
    free(tp->threads);
    queue_delete(&tp->q);
}

/* THREAD POOL OPERATIONS */
void thread_push(thread_pool_t *pool, int connfd) {
    queue_push(pool->q, (int *) &connfd);
}

int thread_pop(thread_pool_t *tp) {
    int *connfd = NULL;
    queue_pop(tp->q, (void **) &connfd);
    intptr_t ret = (intptr_t) connfd;
    free(connfd);
    return ret;
}
