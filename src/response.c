// Response_t implementation.
//
// Status table ported from old_proj_states/asgn2/response.c `send_response`
// (L18-98). asgn2 combined the status table with the socket-writing logic in
// one function; the new conn_t-based API (lib/connection.h) separates the
// two -- this file owns only the code<->message mapping, and src/connection.c
// owns writing bytes to the socket. See docs/REFERENCE.md.

#include "../lib/response.h"

struct Response {
    uint16_t code;
    const char *message;
};

const Response_t RESPONSE_OK                   = { 200, "OK" };
const Response_t RESPONSE_CREATED              = { 201, "Created" };
const Response_t RESPONSE_BAD_REQUEST          = { 400, "Bad Request" };
const Response_t RESPONSE_FORBIDDEN            = { 403, "Forbidden" };
const Response_t RESPONSE_NOT_FOUND            = { 404, "Not Found" };
const Response_t RESPONSE_INTERNAL_SERVER_ERROR = { 500, "Internal Server Error" };
const Response_t RESPONSE_NOT_IMPLEMENTED      = { 501, "Not Implemented" };
const Response_t RESPONSE_VERSION_NOT_SUPPORTED = { 505, "Version Not Supported" };

uint16_t response_get_code(const Response_t *res) {
    return res->code;
}

const char *response_get_message(const Response_t *res) {
    return res->message;
}
