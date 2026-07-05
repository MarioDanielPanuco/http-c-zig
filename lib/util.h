#ifndef HTTP_H
#define HTTP_H

#include <regex.h>

#include <err.h>
#include <fcntl.h>
#include <inttypes.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <getopt.h>
#include <errno.h>
#include <sys/stat.h>
#include <arpa/inet.h>
#define BUFFER_SIZE 4096
#include "../lib/request.h"

#define SUCCESS               200
#define NEW_FILE              201
#define BAD_REQUEST           400
#define FORBIDDEN             403
#define NOT_FOUND             404
#define INTERNAL_SERVER_ERROR 500
#define NOT_IMPLEMENTED       501
#define VERSION_NOT_SUPPORTED 505

int fSize(int fd);

char *removeSlash(char *string);

int minimum(int v, int u);

int error_msg(char *msg);

int fileChecking();

void sigterm_handler(int sig);

void sigint_handler(int sig);

int isFile(char *filename);

void print_error(char *string, int errorCode);

int errno_check();

ssize_t read_all(int connfd, char *buffer); 

ssize_t write_all(int connfd, char buffer[], ssize_t numBytes); 

ssize_t pass_bytes(int src, int dst, size_t nbytes); 

#endif //HTTP_H

