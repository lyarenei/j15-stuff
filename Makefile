# Cross-compiles camstream for the robot (aarch64 Linux, glibc 2.29).
# Zig is the default because it can target an old glibc with no sysroot.
# Any aarch64 toolchain with glibc <= 2.29 also works:
#   make CROSS_CC=aarch64-linux-gnu-gcc

CROSS_CC ?= zig cc -target aarch64-linux-gnu.2.17
CFLAGS   ?= -O2 -Wall -Wextra
LDLIBS   := -ldl -lpthread

# make install ROBOT=192.168.1.50 SSH_ARGS="-i ~/.ssh/robot"
ROBOT    ?=
SSH_ARGS ?=

build/camstream: src/camstream.c
	@mkdir -p build
	$(CROSS_CC) $(CFLAGS) -o $@ $< $(LDLIBS)

.PHONY: all install uninstall status clean
all: build/camstream

install: build/camstream
	./install.sh install $(ROBOT) $(SSH_ARGS)

uninstall:
	./install.sh uninstall $(ROBOT) $(SSH_ARGS)

status:
	./install.sh status $(ROBOT) $(SSH_ARGS)

clean:
	rm -rf build
