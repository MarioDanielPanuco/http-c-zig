//
// Created by Daniel on 3/11/2023.
//

#ifndef ASGN4_THREADPOOL_H
#define ASGN4_THREADPOOL_H

#include <pthread.h>
#include "queue.h"

struct thread_pool_t {
    pthread_t *threads;
    queue_t *q;
    int pool_cap;
    int size;
    void *(*func)(void *);
};

typedef struct thread_task thread_task;

typedef struct thread_pool_t thread_pool_t;

struct thread_pool_task {
  void *(*func)(void *);
  void *arg;
};

void *runner(void*);

/* CREATE AND DESTROY */
thread_pool_t threadpool_init(int count, int q_size, void *(*func)(void *));

void threadpool_destroy(thread_pool_t *tp);

/* THREAD POOL OPERATIONS */
void thread_push(thread_pool_t *pool, int connfd);

int thread_pop(thread_pool_t *tp);

#endif //ASGN4_THREADPOOL_H
