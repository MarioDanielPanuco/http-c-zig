#include "../lib/listener.h"

#include <sys/time.h>

int listener_init(Listener_Socket *sock, int port) {
    struct sockaddr_in addr;

    // Create a TCP socket
    sock->fd = socket(AF_INET, SOCK_STREAM, 0);
    if (sock->fd < 0) {
        warnx("Invalid sock file descriptor");
        // Error creating socket
        return -1;
    }

    // Set socket options to reuse address
    int optval = 1;
    if (setsockopt(sock->fd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(optval)) < 0) {
        // Error setting socket options
        close(sock->fd);
        return -1;
    }

    // Initialize the address structure

    // Setting addr full of bytes '0'
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);

    // Bind the socket to the address and port
    if (bind(sock->fd, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
        // Error binding socket
        close(sock->fd);
        return -1;
    }

    // Start listening on the socket
    if (listen(sock->fd, SOMAXCONN) < 0) {
        // Error listening on socket
        close(sock->fd);
        return -1;
    }

    return 0; // Success
}

// Accept a new connection and arm a 5 second timeout on both directions, per
// the contract documented in lib/listener.h / lib/asgn2_helper_funcs.h:38-46.
// A timed-out read/write on the accepted fd will surface to the caller as
// EAGAIN/EWOULDBLOCK (see docs/REFERENCE.md gem #1: that must become a 500,
// not a crash/close).
int listener_accept(Listener_Socket *sock) {
    struct sockaddr_in client_addr;
    socklen_t client_len = sizeof(client_addr);

    int connfd = accept(sock->fd, (struct sockaddr *) &client_addr, &client_len);
    if (connfd < 0) {
        return -1;
    }

    struct timeval timeout;
    timeout.tv_sec = 5;
    timeout.tv_usec = 0;

    if (setsockopt(connfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
        close(connfd);
        return -1;
    }
    if (setsockopt(connfd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout)) < 0) {
        close(connfd);
        return -1;
    }

    return connfd;
}
