
#ifndef LOG_H
#define LOG_H


static FILE *lFile;

// Initializing global static log file 

#define LOG(...) fprintf(logFile, __VA_ARGS__);



#endif //LOG_H

