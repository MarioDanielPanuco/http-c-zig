
// Standard Headers
#include <stdbool.h>
#include <stdlib.h>

// Local Headers
#include "../lib/queue.h"

#include <assert.h>
#include <semaphore.h>

// M4 dead-code prune: queue_empty/queue_full/printQueue were never declared
// in lib/queue.h and never called by src/threadpool.c or anywhere else (a
// full grep confirmed zero callers) -- removed along with the now-unused
// <stdio.h>/<unistd.h> includes they were the only users of.

// M3: the three semaphores now live *inside* the queue struct rather than as
// file-global `sem_t`s. With file-globals, a second `queue_new` re-`sem_init`s
// the same three objects, so only one queue instance could ever work in a
// process. Per-instance semaphores let multiple queues coexist (e.g. a future
// second pool) and make the module reentrant.
struct queue {
    int size;
    int count;
    void **buffer;
    int head;
    int tail;
    sem_t mutex; // binary lock protecting head/tail/count/buffer
    sem_t empty; // counts elements available to pop
    sem_t full;  // counts free slots available to push
};

static void set_fields(queue_t *q, int size) {
    q->size = size;
    q->count = 0;
    q->tail = 0;
    q->head = 0;
}

queue_t *queue_new(int size) {
    queue_t *q = (queue_t *)malloc(sizeof(struct queue));
    if (q == NULL)
        return NULL;

    q->buffer = (void **)malloc(sizeof(void *) * size);
    if (q->buffer == NULL) {
        free(q);
        return NULL;
    }
    set_fields(q, size);

    assert(!sem_init(&q->mutex, 0, 1));
    assert(!sem_init(&q->full, 0, size));
    assert(!sem_init(&q->empty, 0, 0));

    return q;
}

bool queue_push(queue_t *q, void *elem) {
    if (q == NULL)
        return false;

    assert(!sem_wait(&q->full));
    assert(!sem_wait(&q->mutex));

    q->buffer[q->tail] = elem;
    q->tail = (q->tail + 1) % q->size;
    q->count += 1;

    assert(!sem_post(&q->mutex));
    assert(!sem_post(&q->empty));

    return true;
}

bool queue_pop(queue_t *q, void **elem) {
    if (q == NULL || elem == NULL)
        return false;

    assert(!sem_wait(&q->empty));
    assert(!sem_wait(&q->mutex));

    *elem = q->buffer[q->head];
    q->head = (q->head + 1) % q->size;
    q->count -= 1;

    assert(!sem_post(&q->mutex));
    assert(!sem_post(&q->full));
    return true;
}

void queue_delete(queue_t **q) {
    if (q == NULL || *q == NULL)
        return;

    assert(!sem_destroy(&(*q)->full));
    assert(!sem_destroy(&(*q)->mutex));
    assert(!sem_destroy(&(*q)->empty));

    free((*q)->buffer);
    (*q)->buffer = NULL;

    free(*q);
    *q = NULL;
}
