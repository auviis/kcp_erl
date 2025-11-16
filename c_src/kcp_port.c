/*
 * KCP Erlang Port Driver
 * 
 * This port program provides a safe interface between Erlang and the KCP protocol.
 * Communication is done via stdin/stdout using Erlang's external term format.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/time.h>
#include "ikcp.h"

#define MAX_KCP_INSTANCES 1024
#define MAX_BUFFER_SIZE 4096
#define CMD_CREATE 1
#define CMD_RELEASE 2
#define CMD_SEND 3
#define CMD_RECV 4
#define CMD_UPDATE 5
#define CMD_CHECK 6
#define CMD_FLUSH 7
#define CMD_INPUT 8
#define CMD_PEEKSIZE 9
#define CMD_SETMTU 10
#define CMD_WNDSIZE 11
#define CMD_WAITSND 12
#define CMD_NODELAY 13

typedef struct {
    ikcpcb *kcp;
    int active;
    uint32_t conv;
} kcp_instance_t;

static kcp_instance_t instances[MAX_KCP_INSTANCES];
static int initialized = 0;

/* Get current timestamp in milliseconds */
static uint32_t iclock() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint32_t)((tv.tv_sec % 86400) * 1000 + tv.tv_usec / 1000);
}

/* KCP output callback - sends data back to Erlang */
static int kcp_output(const char *buf, int len, ikcpcb *kcp, void *user) {
    uint32_t conv = (uint32_t)(uintptr_t)user;
    unsigned char header[9];
    
    /* Response format: [1, Conv(4 bytes), DataLen(4 bytes), Data] */
    header[0] = 1; /* Output type */
    header[1] = (conv >> 24) & 0xFF;
    header[2] = (conv >> 16) & 0xFF;
    header[3] = (conv >> 8) & 0xFF;
    header[4] = conv & 0xFF;
    header[5] = (len >> 24) & 0xFF;
    header[6] = (len >> 16) & 0xFF;
    header[7] = (len >> 8) & 0xFF;
    header[8] = len & 0xFF;
    
    fwrite(header, 1, 9, stdout);
    fwrite(buf, 1, len, stdout);
    fflush(stdout);
    
    return 0;
}

/* Initialize KCP instances array */
static void init_instances() {
    if (!initialized) {
        memset(instances, 0, sizeof(instances));
        initialized = 1;
    }
}

/* Find free slot for new KCP instance */
static int find_free_slot() {
    for (int i = 0; i < MAX_KCP_INSTANCES; i++) {
        if (!instances[i].active) {
            return i;
        }
    }
    return -1;
}

/* Find instance by handle */
static kcp_instance_t* get_instance(int handle) {
    if (handle < 0 || handle >= MAX_KCP_INSTANCES || !instances[handle].active) {
        return NULL;
    }
    return &instances[handle];
}

/* Send response to Erlang */
static void send_response(unsigned char type, const void *data, int len) {
    unsigned char header[5];
    header[0] = type;
    header[1] = (len >> 24) & 0xFF;
    header[2] = (len >> 16) & 0xFF;
    header[3] = (len >> 8) & 0xFF;
    header[4] = len & 0xFF;
    
    fwrite(header, 1, 5, stdout);
    if (len > 0 && data != NULL) {
        fwrite(data, 1, len, stdout);
    }
    fflush(stdout);
}

/* Send error response */
static void send_error(const char *msg) {
    send_response(0, msg, strlen(msg));
}

/* Send OK response */
static void send_ok(const void *data, int len) {
    send_response(2, data, len);
}

/* Process CREATE command */
static void cmd_create(unsigned char *data, int len) {
    if (len < 4) {
        send_error("invalid_conv");
        return;
    }
    
    uint32_t conv = ((uint32_t)data[0] << 24) | 
                    ((uint32_t)data[1] << 16) |
                    ((uint32_t)data[2] << 8) | 
                    data[3];
    
    int slot = find_free_slot();
    if (slot < 0) {
        send_error("too_many_instances");
        return;
    }
    
    ikcpcb *kcp = ikcp_create(conv, (void*)(uintptr_t)conv);
    if (!kcp) {
        send_error("create_failed");
        return;
    }
    
    kcp->output = kcp_output;
    instances[slot].kcp = kcp;
    instances[slot].active = 1;
    instances[slot].conv = conv;
    
    unsigned char response[4];
    response[0] = (slot >> 24) & 0xFF;
    response[1] = (slot >> 16) & 0xFF;
    response[2] = (slot >> 8) & 0xFF;
    response[3] = slot & 0xFF;
    
    send_ok(response, 4);
}

/* Process RELEASE command */
static void cmd_release(unsigned char *data, int len) {
    if (len < 4) {
        send_error("invalid_handle");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    ikcp_release(inst->kcp);
    inst->active = 0;
    inst->kcp = NULL;
    
    send_ok(NULL, 0);
}

/* Process SEND command */
static void cmd_send(unsigned char *data, int len) {
    if (len < 4) {
        send_error("invalid_handle");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    int datalen = len - 4;
    int ret = ikcp_send(inst->kcp, (char*)(data + 4), datalen);
    
    if (ret < 0) {
        send_error("send_failed");
        return;
    }
    
    /* Immediately flush to trigger output callback */
    ikcp_flush(inst->kcp);
    
    send_ok(NULL, 0);
}

/* Process RECV command */
static void cmd_recv(unsigned char *data, int len) {
    if (len < 4) {
        send_error("invalid_handle");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    unsigned char buffer[MAX_BUFFER_SIZE];
    int recvlen = ikcp_recv(inst->kcp, (char*)buffer, MAX_BUFFER_SIZE);
    
    if (recvlen < 0) {
        send_error("no_data");
        return;
    }
    
    send_ok(buffer, recvlen);
}

/* Process UPDATE command */
static void cmd_update(unsigned char *data, int len) {
    if (len < 8) {
        send_error("invalid_params");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    uint32_t current = ((uint32_t)data[4] << 24) | ((uint32_t)data[5] << 16) |
                       ((uint32_t)data[6] << 8) | data[7];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    ikcp_update(inst->kcp, current);
    send_ok(NULL, 0);
}

/* Process FLUSH command */
static void cmd_flush(unsigned char *data, int len) {
    if (len < 4) {
        send_error("invalid_params");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    ikcp_flush(inst->kcp);
    send_ok(NULL, 0);
}

/* Process CHECK command */
static void cmd_check(unsigned char *data, int len) {
    if (len < 8) {
        send_error("invalid_params");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    uint32_t current = ((uint32_t)data[4] << 24) | ((uint32_t)data[5] << 16) |
                       ((uint32_t)data[6] << 8) | data[7];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    uint32_t next = ikcp_check(inst->kcp, current);
    
    unsigned char response[4];
    response[0] = (next >> 24) & 0xFF;
    response[1] = (next >> 16) & 0xFF;
    response[2] = (next >> 8) & 0xFF;
    response[3] = next & 0xFF;
    
    send_ok(response, 4);
}

/* Process INPUT command (called when receiving UDP data) */
static void cmd_input(unsigned char *data, int len) {
    if (len < 4) {
        send_error("invalid_handle");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    int datalen = len - 4;
    int ret = ikcp_input(inst->kcp, (char*)(data + 4), datalen);
    
    if (ret < 0) {
        send_error("input_failed");
        return;
    }
    
    send_ok(NULL, 0);
}

/* Process NODELAY command */
static void cmd_nodelay(unsigned char *data, int len) {
    if (len < 20) {
        send_error("invalid_params");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    int nodelay = ((int)data[4] << 24) | ((int)data[5] << 16) |
                  ((int)data[6] << 8) | data[7];
    
    int interval = ((int)data[8] << 24) | ((int)data[9] << 16) |
                   ((int)data[10] << 8) | data[11];
    
    int resend = ((int)data[12] << 24) | ((int)data[13] << 16) |
                 ((int)data[14] << 8) | data[15];
    
    int nc = ((int)data[16] << 24) | ((int)data[17] << 16) |
             ((int)data[18] << 8) | data[19];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    int ret = ikcp_nodelay(inst->kcp, nodelay, interval, resend, nc);
    
    if (ret < 0) {
        send_error("nodelay_failed");
        return;
    }
    
    send_ok(NULL, 0);
}

/* Process WNDSIZE command */
static void cmd_wndsize(unsigned char *data, int len) {
    if (len < 12) {
        send_error("invalid_params");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    int sndwnd = ((int)data[4] << 24) | ((int)data[5] << 16) |
                 ((int)data[6] << 8) | data[7];
    
    int rcvwnd = ((int)data[8] << 24) | ((int)data[9] << 16) |
                 ((int)data[10] << 8) | data[11];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    int ret = ikcp_wndsize(inst->kcp, sndwnd, rcvwnd);
    
    if (ret < 0) {
        send_error("wndsize_failed");
        return;
    }
    
    send_ok(NULL, 0);
}

/* Process SETMTU command */
static void cmd_setmtu(unsigned char *data, int len) {
    if (len < 8) {
        send_error("invalid_params");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    int mtu = ((int)data[4] << 24) | ((int)data[5] << 16) |
              ((int)data[6] << 8) | data[7];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    int ret = ikcp_setmtu(inst->kcp, mtu);
    
    if (ret < 0) {
        send_error("setmtu_failed");
        return;
    }
    
    send_ok(NULL, 0);
}

/* Process PEEKSIZE command */
static void cmd_peeksize(unsigned char *data, int len) {
    if (len < 4) {
        send_error("invalid_handle");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    int size = ikcp_peeksize(inst->kcp);
    
    unsigned char response[4];
    response[0] = (size >> 24) & 0xFF;
    response[1] = (size >> 16) & 0xFF;
    response[2] = (size >> 8) & 0xFF;
    response[3] = size & 0xFF;
    
    send_ok(response, 4);
}

/* Process WAITSND command */
static void cmd_waitsnd(unsigned char *data, int len) {
    if (len < 4) {
        send_error("invalid_handle");
        return;
    }
    
    int handle = ((int)data[0] << 24) | ((int)data[1] << 16) |
                 ((int)data[2] << 8) | data[3];
    
    kcp_instance_t *inst = get_instance(handle);
    if (!inst) {
        send_error("invalid_handle");
        return;
    }
    
    int count = ikcp_waitsnd(inst->kcp);
    
    unsigned char response[4];
    response[0] = (count >> 24) & 0xFF;
    response[1] = (count >> 16) & 0xFF;
    response[2] = (count >> 8) & 0xFF;
    response[3] = count & 0xFF;
    
    send_ok(response, 4);
}

/* Read exact number of bytes */
static int read_exact(unsigned char *buf, int len) {
    int got = 0;
    while (got < len) {
        int n = read(STDIN_FILENO, buf + got, len - got);
        if (n <= 0) {
            return -1;
        }
        got += n;
    }
    return got;
}

/* Main command processing loop */
static void process_commands() {
    unsigned char header[5];
    unsigned char buffer[MAX_BUFFER_SIZE];
    
    while (1) {
        /* Read command header: [cmd(1 byte), len(4 bytes)] */
        if (read_exact(header, 5) < 0) {
            break;
        }
        
        int cmd = header[0];
        int len = ((int)header[1] << 24) | ((int)header[2] << 16) |
                  ((int)header[3] << 8) | header[4];
        
        if (len < 0 || len > MAX_BUFFER_SIZE) {
            send_error("invalid_length");
            continue;
        }
        
        /* Read command data */
        if (len > 0) {
            if (read_exact(buffer, len) < 0) {
                break;
            }
        }
        
        /* Process command */
        switch (cmd) {
            case CMD_CREATE:
                cmd_create(buffer, len);
                break;
            case CMD_RELEASE:
                cmd_release(buffer, len);
                break;
            case CMD_SEND:
                cmd_send(buffer, len);
                break;
            case CMD_RECV:
                cmd_recv(buffer, len);
                break;
            case CMD_UPDATE:
                cmd_update(buffer, len);
                break;
            case CMD_CHECK:
                cmd_check(buffer, len);
                break;
            case CMD_FLUSH:
                cmd_flush(buffer, len);
                break;
            case CMD_INPUT:
                cmd_input(buffer, len);
                break;
            case CMD_PEEKSIZE:
                cmd_peeksize(buffer, len);
                break;
            case CMD_SETMTU:
                cmd_setmtu(buffer, len);
                break;
            case CMD_WNDSIZE:
                cmd_wndsize(buffer, len);
                break;
            case CMD_WAITSND:
                cmd_waitsnd(buffer, len);
                break;
            case CMD_NODELAY:
                cmd_nodelay(buffer, len);
                break;
            default:
                send_error("unknown_command");
                break;
        }
    }
}

int main(int argc, char *argv[]) {
    /* Set binary mode for stdin/stdout */
    #ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    #endif
    
    init_instances();
    process_commands();
    
    /* Cleanup */
    for (int i = 0; i < MAX_KCP_INSTANCES; i++) {
        if (instances[i].active) {
            ikcp_release(instances[i].kcp);
        }
    }
    
    return 0;
}
