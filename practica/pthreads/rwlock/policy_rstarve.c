#include "rwlock.h"

#include <assert.h>
#include <pthread.h>

int reader_wait(rwlock_t * rwlock) {
  // wait for a current or waiting writer :
  return (rwlock->awriters || rwlock->wwriters);

}
int writer_wait(rwlock_t *rwlock) {

  // wait for any active actor
  return  (rwlock->awriters || rwlock->areaders);
}
