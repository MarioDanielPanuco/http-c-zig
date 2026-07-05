// Dr. Q's reader-writer lock impl

#include "rwlock.h"

#include <assert.h>
#include <malloc.h>
#include <pthread.h>


int reader_wait(rwlock_t *);
int writer_wait(rwlock_t *);
void rwlock_wakeup(rwlock_t *);

rwlock_t *rwlock_new() {
  rwlock_t *rwlock = (rwlock_t*)malloc(sizeof(rwlock_t));

  int rc = pthread_mutex_init(&rwlock->mu, NULL);
  assert (!rc);

  rc = pthread_cond_init(&rwlock->rcv, NULL);
  assert (!rc);

  rc = pthread_cond_init(&rwlock->wcv, NULL);
  assert (!rc);


  rwlock->areaders = 0;
  rwlock->awriters = 0;
  rwlock->wreaders = 0;
  rwlock->wwriters = 0;
  return rwlock;
}

void  rwlock_destroy(rwlock_t **rwlock) {

  int rc = pthread_mutex_destroy(&(*rwlock)->mu);
  if (rc) {
    fprintf(stderr, "pthread_mutex_destroy compained: %d\n", rc);
  }
  assert (!rc);
  rc = pthread_cond_destroy(&(*rwlock)->rcv);
  assert (!rc);

  rc = pthread_cond_destroy(&(*rwlock)->wcv);
  assert (!rc);


  free (*rwlock);
  *rwlock = NULL;
}


void read_lock(rwlock_t *rwlock) {
  pthread_mutex_lock(&rwlock->mu);

  rwlock->wreaders ++;
  while (reader_wait(rwlock)) {
    pthread_cond_wait(&rwlock->rcv, &rwlock->mu);
  }

  rwlock->wreaders --;
  rwlock->areaders ++;

  pthread_mutex_unlock(&rwlock->mu);
}

void read_unlock(rwlock_t *rwlock) {
  pthread_mutex_lock(&rwlock->mu);
  rwlock->areaders -= 1;

  rwlock_wakeup(rwlock);
  pthread_mutex_unlock(&rwlock->mu);
}

void write_lock(rwlock_t *rwlock) {
  pthread_mutex_lock(&rwlock->mu);

  rwlock->wwriters ++;
  while (writer_wait(rwlock)) {
    pthread_cond_wait(&rwlock->wcv, &rwlock->mu);
  }

  rwlock->wwriters --;
  rwlock->awriters ++;

  pthread_mutex_unlock(&rwlock->mu);
}

void write_unlock(rwlock_t *rwlock) {
  pthread_mutex_lock(&rwlock->mu);
  rwlock->awriters -= 1;

  rwlock_wakeup(rwlock);
  pthread_mutex_unlock(&rwlock->mu);
}

void rwlock_wakeup(rwlock_t *rwlock) {
  //  assert (rwlock->awriters == 0);

  // We know there won't be deadlock if we always wake everyone up!
  if (rwlock->wreaders) {
    pthread_cond_broadcast(&rwlock->rcv);
  }
  if (rwlock->wwriters) {
    pthread_cond_broadcast(&rwlock->wcv);
  }
}
