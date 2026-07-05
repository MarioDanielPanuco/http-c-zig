#include "rwlock.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>

int reader_wait(rwlock_t * rwlock) {
  // wait for a current writer:
  return rwlock->awriters;

}
int writer_wait(rwlock_t *rwlock) {

  // wait for any active actor
  return  (rwlock->awriters || rwlock->areaders);
}
