#include "rwlock.h"

#include <assert.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>

#define THREADS 4

// The statistics that we're storing.
int counts[THREADS];

// the done signal (could do atomics, but I don't want to scare the
// kids)

int done = 0;
pthread_mutex_t dmutex = PTHREAD_MUTEX_INITIALIZER;

// the reader/writer lock
rwlock_t *rwlock;


// sleep for a random amount of time.
void random_sleep() {
  unsigned r = rand() % 10000;
  int rc = usleep (r);
  assert (!rc);
}


// safely see if we're done.
int get_done() {
  pthread_mutex_lock(&dmutex);
  int d = done;
  pthread_mutex_unlock(&dmutex);
  return d;
}

// safely say that we're done
void set_done() {
  pthread_mutex_lock(&dmutex);
  done = 1;
  pthread_mutex_unlock(&dmutex);
}

void * reader_thread(void *args) {
  uintptr_t id = (uintptr_t)args;

  while (!get_done()) {
    read_lock(rwlock);
    fprintf(stderr, "reader %lu got lock\n", id);
    counts[id] ++;
    random_sleep();
    fprintf(stderr, "reader %lu done\n", id);
    read_unlock(rwlock);
  }

  fprintf(stderr, "reader %lu exiting\n", id);
  return NULL;
}

void * writer_thread(void *args) {
  uintptr_t id = (uintptr_t)args;

  while (!get_done()) {
    write_lock(rwlock);
    fprintf(stderr, "writer %lu got lock\n", id);
    counts[id] ++;
    random_sleep();
    fprintf(stderr, "writer %lu done\n", id);
    write_unlock(rwlock);
  }

  fprintf(stderr, "writer %lu exiting\n", id);
  return NULL;
}

int main() {
  pthread_t threads[THREADS];
  int rc = 0;
  uintptr_t sum = 0;

  rwlock = rwlock_new();
  pthread_create(threads , NULL, reader_thread, (void*)0);
  pthread_create(threads + 1, NULL, reader_thread, (void*)1);
  pthread_create(threads + 2, NULL, writer_thread, (void*)2);
  pthread_create(threads + 3, NULL, writer_thread, (void*)3);

  // sleep for some time. then cancel all of the threads
  sleep (1);
  set_done();

  for (int i = 0; i < THREADS; ++i) {
    pthread_join(threads[i], NULL);
    sum += counts[i];
  }

  rwlock_destroy(&rwlock);

  for (int i = 0; i < THREADS; ++i) {
    fprintf(stderr, "%i: %i (%lf)\n", i, counts[i], (double)counts[i] / (double)sum);
  }


  assert (!rc);
  return 0;
}
