#include <assert.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <regex.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BUFFER_SIZE PATH_MAX

/**
 *  This parses any line that does the following:
 * (1) starts with a word that uses any number of a-zA-Z characters.
 * (2) contains a space
 * (3) has a word that starts with a '/' and contains any number of
       characters in [a-ZA-Z0-9._].
 * (4) has a newline
 */


#define PARSE_REGEX "^([A-zA-Z]*) /([a-zA-Z0-9._]*)\n"



typedef struct {

  // Make an *extra* spot for a null terminator!
  char  buf[BUFFER_SIZE + 1];
  uint16_t bufsize;
  char *command;
  char *location;
} Command;


void cmd_dump(Command *c) {
  if (c->command && c->location)
    fprintf(stderr, "Command: %s\nLocation: %s\n", c->command, c->location);
  else
    fprintf(stderr, "Command not parsed!\n");
}

static ssize_t read_bytes(int fd, char buf[], size_t nbytes) {
    size_t total = 0;
    ssize_t bytes = 0;

    do {
        bytes = read(fd, buf + total, nbytes - total);
        if (bytes < 0) {
            return bytes;
        }
        total += bytes;
    } while (bytes > 0 && total < nbytes);

    return total;
}

static void cmd_parse(Command *c, int fd) {

  regex_t re;
  regmatch_t matches[3];
  int rc;

  // read bytes and set buffersize to 0.
  c->bufsize = read_bytes(fd, c->buf, BUFFER_SIZE);
  if (c->bufsize > 0) {

    // Never forget to null terminate your string!!
    c->buf[c->bufsize] = 0;

    // First step -- compile the regex. If this fails, there's
    // probably an issue with your PARSE_REGEX string
    rc = regcomp(&re, PARSE_REGEX, REG_EXTENDED);
    assert (!rc);

    // Next step -- use the regex on the string.
    // The parameters are
    // (1) the regex,
    // (2) the buffer to search,
    // (3) the number of submatches within the string, plus 1
    // (4) a regexmatch_t to store the submatches
    // (5) options (see the man page for regex)

    // returns 0 when a match is found.  Assigns the i^th submatch to
    // matches[i] (where we index from `1').  Each element in matches
    // includes:
    // (1) rm_so: a start offset of where in buf the match starts
    // (2) rm_eo: an end offset of where in buf the match terminates.
    rc = regexec(&re, (char *)c->buf, 3, matches, 0);

    if (rc == 0) {
      c->command = c->buf;
      c->location = c->buf + matches[2].rm_so;


      // Uncomment me to fixup issues in the above!
      //c->command[matches[1].rm_eo] = '\0';
      //c->location[matches[2].rm_eo - matches[2].rm_so] = '\0';
    }
    else {
      c->command = NULL;
      c->location = NULL;
    }
  }
}

void print_usage(char *exec) {

  printf("usage: %s\n\n", exec);
  printf("Parses a get/set command header that were passed to stdin\n");
  printf("The format for valid a command is:\n");
  printf("\t[method] [location]\\n\n");
  printf("where:\n");
  printf("\t[method] has between 1 and 8 characters in the range [a-zA-Z]\n");
  printf("\t[location] starts with '/' and includes up to 64 characters ");
  printf("in the set [a-zA-Z0-9._]\n");
}



int main(int argc, char *argv[]) {
  Command c;
  (void) c;
  (void) argc;

  // comment this to begin:
  print_usage(argv[0]);
  return 0;

  (void) argv;
  cmd_parse(&c, STDIN_FILENO);
  cmd_dump(&c);
  return 0;
}
