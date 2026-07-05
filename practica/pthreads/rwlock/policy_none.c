#include "rwlock.h"

#include <assert.h>
#include <pthread.h>

int reader_wait(rwlock_t * rwlock) {
  (void) rwlock;
  return 0;
}
int writer_wait(rwlock_t *rwlock) {
  (void) rwlock;
  return 0;
}
