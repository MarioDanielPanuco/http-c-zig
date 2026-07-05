


#include "../lib/listener.h"


int listener_new(Listener_Socket *sock, int port) {
    struct sockaddr_in addr;

    // Create a TCP socket
    sock->fd = socket(AF_INET, SOCK_STREAM, 0);
    if (sock->fd < 0) {
      
 
      warnx("Invalid sock file discriptor: %n", &sock->fd);
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
    if (bind(sock->fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
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
