#ifndef OPT_H
#define OPT_H

#include <getopt.h>
#include <stdlib.h>
#include <sys/types.h>
#include "util.h"

#define OPTIONS "t:l:"
#define DEFAULT_THREAD_COUNT 2 

struct OPT {
  int n_threads; 
  char *log_path;
};

/* @brief Parses the command line arguments
 * @param argc: Number of arguments provided to the program
 * @param argv: The program arguments
 * @returns -1 if error, 0 if 
 *
 */
ssize_t opt_parse (int argc, char* argv[]); 

#endif // !OPT_H
