#include "../lib/log.h"
#include <stdio.h>


static FILE *logFile;
# define LOG(...) fprintf(logFile, __VA_ARGS__);
