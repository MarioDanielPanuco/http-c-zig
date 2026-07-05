#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>

void* thread(void *args) {
  uintptr_t threadid = (uintptr_t)args;
  fprintf(stderr, "I am thread %lu!\n", threadid);
  return args;
}

int main() {
  pthread_t t1, t2;
  uintptr_t rc1, rc2;

  pthread_create(&t1, NULL, thread, (void*)1);
  pthread_create(&t2, NULL, thread, (void*)2);

  fprintf(stderr, "I am main\n");

  pthread_join(t1, (void **)&rc1);
  pthread_join(t2, (void **)&rc2);

  printf("thread1 returned %lu; thread 2 returned %lu\n", rc1, rc2);

  return 0;
}
