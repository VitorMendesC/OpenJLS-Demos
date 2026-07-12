# OpenJLS Ethernet demo — portable C server (board) and client (host).
#
# Native build (on the board or the host):   make
# Cross build for a 32-bit ARM board:        make CROSS_COMPILE=arm-linux-gnueabihf-
# Cross build for a 64-bit ARM board:        make CROSS_COMPILE=aarch64-linux-gnu-

CROSS_COMPILE ?=
CC      := $(CROSS_COMPILE)gcc
CFLAGS  ?= -O2 -g
CFLAGS  += -std=c11 -Wall -Wextra -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -Icommon -Isrc

SERVER_SRC := src/ojls_server.c src/uio.c src/udmabuf.c src/axidma.c
CLIENT_SRC := host/ojls_client.c

all: ojls_server ojls_client

ojls_server: $(SERVER_SRC) src/uio.h src/udmabuf.h src/axidma.h src/ojls_regs.h common/ojls_proto.h
	$(CC) $(CFLAGS) -o $@ $(SERVER_SRC)

ojls_client: $(CLIENT_SRC) common/ojls_proto.h
	$(CC) $(CFLAGS) -o $@ $(CLIENT_SRC)

clean:
	rm -f ojls_server ojls_client

.PHONY: all clean
