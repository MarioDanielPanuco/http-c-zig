#include <assert.h>
#include <semaphore.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>

int i = 0;

sem_t sem;

int thread() {
  sem_wait(&sem);
  i++;
  sem_post(&sem);
  return 1;
}

int main() {
  pthread_t t1, t2;
  int count = 0, avios = 0, rc = 0;

  // Init semaphore. Parameters:
  // 1. pointer to semaphore.
  // 2. indicates if you need to support multiple processes (always 0 for cse130)
  // 3. the initial value of the semaphore (1 in this case).
  rc = sem_init(&sem, 0, 1);
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

  rc = sem_destroy(&sem);
  assert (!rc);
  return 0;
}
