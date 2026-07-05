EXECBINS  = user_none user_wstarve user_rstarve
SOURCES  = $(wildcard *.c)

CC       = clang
FORMAT   = clang-format
CFLAGS   = -Wall -Wpedantic -Werror -Wextra

.PHONY: all clean format

all: $(EXECBINS)

user_none: user.o rwlock.o policy_none.o
	$(CC) -o $@ $^

user_wstarve: user.o rwlock.o policy_wstarve.o
	$(CC) -o $@ $^


user_rstarve: user.o rwlock.o policy_rstarve.o
	$(CC) -o $@ $^



%.o : %.c
	$(CC) $(CFLAGS) -c $<

clean:
	rm -f $(EXECBINS) *.o

