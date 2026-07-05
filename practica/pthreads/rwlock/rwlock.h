#include <pthread.h>

#pragma once

struct rwlock {
  int areaders;       //number of active readers
  int awriters;       //number of active writers
  int wreaders;       //number of waiting readers
  int wwriters;       //number of waiting writers

  pthread_mutex_t mu;
  pthread_cond_t rcv;
  pthread_cond_t wcv;
};


typedef struct rwlock rwlock_t;

rwlock_t *rwlock_new();
void  rwlock_destroy(rwlock_t**);

void read_lock(rwlock_t*);
void read_unlock(rwlock_t*);
void write_lock(rwlock_t*);
void write_unlock(rwlock_t*);


