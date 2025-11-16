# KCP Makefile for manual compilation

PRIV_DIR = priv
C_SRC_DIR = c_src

ifeq ($(shell uname),Darwin)
	LDFLAGS = 
	CFLAGS = -std=c99 -O3 -Wall -Wextra
else ifeq ($(shell uname),Linux)
	LDFLAGS = 
	CFLAGS = -std=c99 -O3 -Wall -Wextra
else
	LDFLAGS = 
	CFLAGS = -std=c99 -O3 -Wall -Wextra
endif

all: $(PRIV_DIR)/kcp_port

$(PRIV_DIR)/kcp_port: $(C_SRC_DIR)/kcp_port.c $(C_SRC_DIR)/ikcp.c
	@mkdir -p $(PRIV_DIR)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -rf $(PRIV_DIR)/kcp_port
	rm -rf _build
	rm -rf ebin

.PHONY: all clean
