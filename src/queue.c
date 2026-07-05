
// Standard Headers
#include <stdbool.h>
#include <stdlib.h>

// Local Headers
#include "../lib/queue.h"

#include <errno.h>
#include <semaphore.h>

// Final-review fix (same rationale as connection.c's B4a): the semaphore ops
// were wrapped in assert() -- `assert(!sem_wait(...))`. assert() compiles away
// entirely under -DNDEBUG, so a release build would have *dropped the sem_wait/
// sem_post/sem_init calls themselves*, leaving the queue completely
// unsynchronized (lost/duplicated connections, head/tail corruption). These are
// now unconditional calls with explicit return-value checks. A semaphore op
// failing here is a non-recoverable programming/OS error with no request
// context to answer, so we abort() -- preserving the old assert's fail-fast
// behavior without depending on NDEBUG. sem_wait is retried on EINTR (the one
// benign transient), which the old assert() would instead have crashed on.
static void sem_wait_checked(sem_t *s) {
    while (sem_wait(s) != 0) {
        if (errno != EINTR)
            abort();
    }
}

static void sem_post_checked(sem_t *s) {
    if (sem_post(s) != 0)
        abort();
}

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

    // Explicit failure propagation: a failed sem_init leaves the queue
    // unusable, so tear down and report allocation failure (queue_new's
    // established error contract) rather than returning a half-initialized
    // queue. (On Linux unnamed semaphores hold no resource beyond the struct
    // memory freed here, so an already-succeeded sem_init needs no destroy.)
    if (sem_init(&q->mutex, 0, 1) != 0 || sem_init(&q->full, 0, (unsigned)size) != 0 ||
        sem_init(&q->empty, 0, 0) != 0) {
        free(q->buffer);
        free(q);
        return NULL;
    }

    return q;
}

bool queue_push(queue_t *q, void *elem) {
    if (q == NULL)
        return false;

    sem_wait_checked(&q->full);
    sem_wait_checked(&q->mutex);

    q->buffer[q->tail] = elem;
    q->tail = (q->tail + 1) % q->size;
    q->count += 1;

    sem_post_checked(&q->mutex);
    sem_post_checked(&q->empty);

    return true;
}

bool queue_pop(queue_t *q, void **elem) {
    if (q == NULL || elem == NULL)
        return false;

    sem_wait_checked(&q->empty);
    sem_wait_checked(&q->mutex);

    *elem = q->buffer[q->head];
    q->head = (q->head + 1) % q->size;
    q->count -= 1;

    sem_post_checked(&q->mutex);
    sem_post_checked(&q->full);
    return true;
}

void queue_delete(queue_t **q) {
    if (q == NULL || *q == NULL)
        return;

    // sem_destroy failure here is benign (the queue is being torn down and
    // these unnamed semaphores hold no external resource), so its return is
    // intentionally not fatal -- but the calls must still run unconditionally,
    // never under an assert() that -DNDEBUG would strip.
    sem_destroy(&(*q)->full);
    sem_destroy(&(*q)->mutex);
    sem_destroy(&(*q)->empty);

    free((*q)->buffer);
    (*q)->buffer = NULL;

    free(*q);
    *q = NULL;
}
