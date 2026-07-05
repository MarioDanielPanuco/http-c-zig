#include <fcntl.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>



void print_usage(char *exec) {

  printf("usage: %s filename\n\n", exec);
  printf("Writes the contents of filename to stdout.\n");
  printf("If there is no file named filename, prints 'Invalid\n"
         "filename\\n' to stderr and exits.\n\n");
  printf("Note: this differs from your memory in a few key ways:\n");
  printf("(1) dump_file takes the filename through a command line\n"
         "    argument whereas memory takes all input through stdin\n");
  printf("(2) dump_file only supports 'gets' of a file whereas memory\n"
         "    supports both getting and setting a file's contents\n");

}

int main(int argc, char **argv) {
  char *filename = NULL;

  // the "best" approach is to use stdarg, but that adds a lot of
  // complexity without too much gain.  Instead, a simple print usage
  // with basic command line parsing will do:

  if (argc < 2) {
    print_usage(argv[0]);
    return 1;
  }

  filename = argv[1];

  // make compiler errors go away
  (void) filename;

  // code to open filename.

  // code to read filename and write it to stdout
  return 0;
}
