// Request_t implementation.
//
// Trivial method table, modeled on asgn2's `Method` enum (GET, PUT, NONE)
// but exposed as the opaque Request_t pointers the conn_t API compares
// against (lib/request.h): conn_get_request(conn) == &REQUEST_GET, etc.

#include "../lib/request.h"

struct Request {
    const char *str;
};

const Request_t REQUEST_GET         = { "GET" };
const Request_t REQUEST_PUT         = { "PUT" };
const Request_t REQUEST_UNSUPPORTED = { "UNSUPPORTED" };

const Request_t *requests[NUM_REQUESTS] = {
    &REQUEST_GET,
    &REQUEST_PUT,
    &REQUEST_UNSUPPORTED,
};

const char *request_get_str(const Request_t *req) {
    return req->str;
}
