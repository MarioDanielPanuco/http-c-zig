//
// Created by Daniel on 3/11/2023.
// M3: rewritten as a correct dispatcher/worker module (see docs/DECISIONS.md).
//

#ifndef ASGN4_THREADPOOL_H
#define ASGN4_THREADPOOL_H

#include "queue.h"

// Callback a worker invokes for each accepted connection file descriptor.
typedef void (*conn_handler_t)(int connfd);

typedef struct threadpool threadpool_t;

/* CREATE AND DESTROY */

// Create a pool of `nthreads` worker threads backed by a bounded queue of
// capacity `queue_size`. Each worker blocks on the queue and calls `handler`
// for every connection fd submitted. Returns NULL on allocation failure.
threadpool_t *threadpool_new(int nthreads, int queue_size, conn_handler_t handler);

// Signal every worker to finish the current job and exit, join them all, then
// free the pool and its queue. No double-pop, no leaked threads.
void threadpool_destroy(threadpool_t *tp);

/* THREAD POOL OPERATIONS */

// Hand an accepted connection fd to the pool. Blocks if the queue is full
// (back-pressure while all workers are busy). Returns false only if tp is NULL.
bool threadpool_submit(threadpool_t *tp, int connfd);

#endif // ASGN4_THREADPOOL_H
