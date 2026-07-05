EXECBIN  = httpserver
SOURCES  = $(wildcard src/*.c)
OBJECTS  = $(SOURCES:src/%.c=%.o)

CC       = clang
FORMAT   = clang-format
CFLAGS   = -Wall -Wextra -Werror -pedantic -Ilib

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
