#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>

int i = 0;

// STATIC INITIALIZATION
//pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;

// DYNAMIC INITIALIZATION
pthread_mutex_t mutex;

int thread() {
  pthread_mutex_lock(&mutex);
  i++;
  pthread_mutex_unlock(&mutex);
  return 1;
}

int main() {
  pthread_t t1, t2;
  int count = 0, avios = 0, rc = 0;

  // DYNAMIC INITIALIZATION
  rc = pthread_mutex_init(&mutex, NULL);
  assert (!rc);


  while (count < 1000000) {

    i = 0;
    pthread_create(&t1, NULL, (void *(*)(void*))thread, NULL);
    pthread_create(&t2, NULL, (void *(*)(void*))thread, NULL);

    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    if (i != 2) {
      printf("oh no! result was %d\n", i);
      avios += 1;
    }
    count++;
  }
  printf("found %d violations in %d trials\n", avios, count);

  rc = pthread_mutex_destroy(&mutex);
  assert (!rc);
  return 0;
}
