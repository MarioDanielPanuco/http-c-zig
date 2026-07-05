#ifndef HTTP_H
#define HTTP_H

#include <regex.h>

#include <arpa/inet.h>
#include <err.h>
#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#define BUFFER_SIZE 4096
#include "../lib/request.h"
#include "asgn2_helper_funcs.h" // canonical read_until/write_all/pass_bytes declarations

#define SUCCESS 200
#define NEW_FILE 201
#define BAD_REQUEST 400
#define FORBIDDEN 403
#define NOT_FOUND 404
#define INTERNAL_SERVER_ERROR 500
#define NOT_IMPLEMENTED 501
#define VERSION_NOT_SUPPORTED 505

int fSize(int fd);

char *removeSlash(char *string);

int minimum(int v, int u);

int error_msg(char *msg);

int fileChecking(void);

void sigterm_handler(int sig);

void sigint_handler(int sig);

int isFile(char *filename);

void print_error(char *string, int errorCode);

int errno_check(void);

ssize_t read_all(int connfd, char *buffer);

// write_all/pass_bytes/read_until: declared once, canonically, in
// asgn2_helper_funcs.h (included above) -- this header used to redeclare
// write_all/pass_bytes with a conflicting signature (ssize_t vs size_t
// nbytes), which is a compile-time redeclaration error once both headers
// land in the same translation unit.

#endif // HTTP_H
