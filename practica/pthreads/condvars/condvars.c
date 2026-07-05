#include <assert.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>

int i = 0;

// DYNAMIC INITIALIZATION
pthread_mutex_t mutex;
pthread_cond_t cv;

void * thread(void *args) {

  // get the compiler to not complain about my cast
  int id = (int)((uintptr_t)args % INT_MAX);

  pthread_mutex_lock(&mutex);
  while (i < id) {
    pthread_cond_wait(&cv, &mutex);
  }
  i++;
  fprintf(stderr, "thread %d incremented to %d\n", id, i);
  pthread_mutex_unlock(&mutex);
  pthread_cond_signal(&cv);
  return NULL;
}

int main() {
  pthread_t t1, t2;
  int rc = 0;

  rc = pthread_mutex_init(&mutex, NULL);
  assert (!rc);
  rc = pthread_cond_init(&cv, NULL);
  assert (!rc);

  pthread_create(&t1, NULL, thread, (void*)0);
  pthread_create(&t2, NULL, thread, (void*)1);

  pthread_join(t1, NULL);
  pthread_join(t2, NULL);


  rc = pthread_mutex_destroy(&mutex);
  rc = pthread_cond_destroy(&cv);
  assert (!rc);
  return 0;
}
