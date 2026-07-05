EXECBIN  = httpserver
SOURCES  = $(wildcard src/*.c)
OBJECTS  = $(SOURCES:src/%.c=%.o)

CC       = clang
FORMAT   = clang-format
# -std=gnu17 keeps the language standard in lockstep with build.zig's C flags.
# -pthread is required for the worker pool (correct pthread compile + link).
CFLAGS   = -Wall -Wextra -Werror -pedantic -std=gnu17 -pthread -Ilib

.PHONY: all clean format

all: $(EXECBIN)

$(EXECBIN): $(OBJECTS)
	$(CC) $(CFLAGS) -o $@ $^

%.o: src/%.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(EXECBIN) $(OBJECTS)

format:
	$(FORMAT) -i src/*.c lib/*.h
