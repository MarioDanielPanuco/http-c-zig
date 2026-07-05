#include "../lib/util.h"
// #include "../lib/asgn2_helper_funcs.h"
#include "../lib/request.h"

// #include <cstdint>
#include <sys/_types/_ssize_t.h>
#include <err.h>
#include <stdio.h>

// Creates a socket for listening for connections.
// Closes the program and prints an error message on error.
static int create_listen_socket(uint16_t port) {
    struct sockaddr_in addr;
    int listenfd = socket(AF_INET, SOCK_STREAM, 0);
    if (listenfd < 0) {
        err(EXIT_FAILURE, "socket error");
    }
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htons(INADDR_ANY);
    addr.sin_port = htons(port);
    if (bind(listenfd, (struct sockaddr *) &addr, sizeof addr) < 0) {
        err(EXIT_FAILURE, "bind error");
    }
    if (listen(listenfd, 128) < 0) {
        err(EXIT_FAILURE, "listen error");
    }
    return listenfd;
}


char *removeSlash(char *str) {
    if (str[0] == '/') {
        str += 1;
    }
    return str;
}

int minimum(int a, int b) {
    return a < b ? a : b;
}

int error_msg(char *msg) {
    write_all(STDERR_FILENO, msg, (ssize_t) sizeof(msg) / sizeof(msg[0]));
    exit(EXIT_FAILURE);
    return 0;
}

void sigterm_handler(int sig) {
    if (sig == SIGTERM) {
        warnx("SIGTERM");
        exit(EXIT_SUCCESS);
    }
}

void sigint_handler(int sig) {
    if (sig == SIGINT) {
        warnx("SIGINT");
        exit(EXIT_SUCCESS);
    }
}

int isFile(char *filename) {
    if (access(filename, F_OK) == 0) {
        struct stat filenameStat;
        stat(filename, &filenameStat);
        return S_ISREG(filenameStat.st_mode);
    }
    return NEW_FILE;
}

int fileChecking() {
    if (errno == ENOENT)
        return 404;
    return SUCCESS;
}

int fSize(int fd) {
    struct stat sBuf;
    if (fstat(fd, &sBuf)) {
        return -1;
    }
    return (int) sBuf.st_size;
}

void print_error(char *string, int errorCode) {
    //    fprintf(stderr, "%s\n", string);
    (void) string;
    exit(errorCode);
}

int errno_check() {
    if (errno == EAGAIN || errno == EWOULDBLOCK) {
        return INTERNAL_SERVER_ERROR;
    }
    return SUCCESS;
}

ssize_t read_all(int connfd, char *buffer) {
    ssize_t readCode = 1;
    ssize_t totalRead = 0;

    ssize_t n = BUFFER_SIZE + 5;
    while ((readCode = read(connfd, buffer + totalRead, n - totalRead)) > 0) {
        //        printf("read buf: %s|", buffer);
        totalRead += readCode;
        if (totalRead == n) {
            return totalRead;
        }
        //        printf("read char: %c|", buffer[totalRead - 1]);
        //        if (buffer[totalRead - 1] == '\n') {
        //            printf("totalRead: %zd", totalRead);
        //            return totalRead;
        //        }
        //        readCode = read(connfd, buffer + totalRead, BUFFER_SIZE);
    }
    //    memset(&buffer[n], '\0', 1);

    //    fprintf(stderr, "%s\n", buffer);
    //    do {
    //        readCode = read(connfd, buffer + totalRead, BUFFER_SIZE);
    //        totalRead += readCode;
    //        printf("read_code: %zd\n", totalRead);
    //
    //        if (readCode < 0)
    //            return -1;
    //
    //    } while (readCode > 0);
    return totalRead;
}
      
ssize_t write_all(int connfd, char buffer[], ssize_t numBytes) {
    ssize_t bytesWritten = 0, bytez = 0;
    while (bytesWritten < numBytes) {
        bytez = write(connfd, buffer + bytesWritten, numBytes - bytesWritten);
        if (bytez < 0)
            return -1;
        bytesWritten += bytez;
    }
    return bytesWritten;
} 

ssize_t pass_bytes(int src, int dst, size_t nbytes) {

  ssize_t bytesWritten = 0; 
  while (bytesWritten < nbytes) {


  }
  
}

