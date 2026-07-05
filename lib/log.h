#ifndef LOG_H
#define LOG_H

#include <stdio.h>

// M3: real audit-log module. Replaces the M1 placeholder (the broken
// `lFile`/`logFile` extern + `LOG(...)` macro that had no synchronization).
// The audit log is the linearization witness for the server, so every line
// must be written atomically with respect to other threads.

// Point the audit log at a stream. Pass stderr for the default, or the FILE*
// opened for a `-l PATH` argument. Must be called once before any log_audit.
void log_init(FILE *stream);

// Write one audit line "<oper>,<uri>,<status>,<rid>\n" atomically. Safe to
// call from any worker thread concurrently; lines never interleave.
void log_audit(const char *oper, const char *uri, int status, const char *rid);

// Flush and, if the stream was opened from a path (not stderr), close it.
void log_close(void);

#endif // LOG_H
