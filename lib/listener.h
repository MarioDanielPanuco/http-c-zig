#ifndef LISTENER_H
#define LISTENER_H

#include <stdint.h>
#include <sys/types.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <err.h>

#include <unistd.h>
#include <fcntl.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>

#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

/** @struct Listener_Socket
 *  @brief This structure represents a socket listening for connections
 */
typedef struct {

    /** @brief The socket for the listening connection. Note: do not use
   *         this directly! Take a look at listener_init and
   *         listener_accept instead!
   */
    int fd;
} Listener_Socket;


/** @brief Initializes a listener socket that listens on the provided
 *         port on all of the interfaces for the host.
 *
 *  @param sock The Listener_Socket to initialize.
 *
 *  @param port The port on which to listen.
 *
 *  @return 0, indicating success, or -1, indicating that it failed to
 *          listen.
 */
int listener_new(Listener_Socket *sock, int port);

/** @brief Accept a new connection and initialize a 5 second timeout
 *
 *  @param sock The Listener_Socket from which to get the new
 *              connection.
 *
 *  @return An socket for the new connection, or -1, if there is an
 *          error. Sets errno according to any errors that occur.
 */
int listener_accept(Listener_Socket *sock);

#endif //LISTENER_H

