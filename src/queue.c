
// Standard Headers
#include <stdbool.h>
#include <stdlib.h>
#include <unistd.h>

// Local Headers
#include "../lib/queue.h"

#include <semaphore.h>
#include <assert.h>

struct queue {
    int size;
    int count;
    void **buffer;
    int head;
    int tail;
};

sem_t sem;
sem_t empty;
sem_t full;

void set_fields(queue_t *q, int size) {
    q->size = size;
    q->count = 0;
    q->tail = 0;
    q->head = 0;
}

queue_t *queue_new(int size) {

    assert(!sem_init(&sem, 0, 1));
    assert(!sem_init(&full, 0, size));
    assert(!sem_init(&empty, 0, 0));

    queue_t *queue_new = (queue_t *) malloc(sizeof(struct queue));
    queue_new->buffer = (void **) malloc(sizeof(void *) * size);
    set_fields(queue_new, size);

    return queue_new;
}

bool queue_push(queue_t *q, void *elem) {
    if (elem == NULL || q == NULL)
        return false;

    assert(!sem_wait(&full));
    assert(!sem_wait(&sem));

    q->buffer[q->tail] = elem;
    q->tail = (q->tail + 1) % q->size;
    q->count += 1;

    assert(!sem_post(&sem));
    assert(!sem_post(&empty));

    return true;
}

bool queue_pop(queue_t *q, void **elem) {
    if (q == NULL || elem == NULL)
        return false;

    assert(!sem_wait(&empty));
    assert(!sem_wait(&sem));

    *elem = q->buffer[q->head];
    q->head = (q->head + 1) % q->size;
    q->count -= 1;

    assert(!sem_post(&sem));
    assert(!sem_post(&full));
    return true;
}

void queue_delete(queue_t **q) {
    if (q == NULL)
        return;

    free((*q)->buffer);
    (*q)->buffer = NULL;
    /*    for (int i = 0; i < (*q)->count; i++) {
        free((*q)->buffer[i]);
        (*q)->buffer[i] = NULL;
    }*/

    assert(!sem_destroy(&full));
    assert(!sem_destroy(&sem));
    assert(!sem_destroy(&empty));

    free(*q);
    *q = NULL;
}

bool queue_empty(queue_t *q) {
    if (q == NULL)
        return false;
    return q->size == 0;
}

bool queue_full(queue_t *q) {
    if (q == NULL)
        return false;
    return q->size == q->count;
}



void printQueue(queue_t *q) {
    int index = q->head;
    fprintf(stdout, "%s", "Queue: ");
    for (int i = 0; i < q->count; i++) {
        fprintf(stdout, "%d ", q->array[index]);
        index++;
    }
    fprintf(stdout, "%s\n", "");
}



