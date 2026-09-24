#include "tcp_link.h"

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "lwip/sockets.h"

#include "siot_led.h"

#define TCP_LISTEN_PORT   5340
#define TCP_BACKLOG       2
#define RX_CHUNK_SIZE     256
#define KEEPALIVE_IDLE_S  5   /* a root that lost power is dropped in ~11 s */
#define KEEPALIVE_INTVL_S 2
#define KEEPALIVE_CNT     3

static tcp_link_frame_cb_t s_on_uplink_frame;
static volatile int s_client_fd = -1; /* -1 = nobody connected */

void tcp_link_send(const uint8_t *frame, size_t len)
{
    const int fd = s_client_fd;
    if (fd < 0) return; /* dropped: no root connected right now */

    size_t sent = 0;
    while (sent < len) {
        const int n = send(fd, frame + sent, len - sent, 0);
        if (n <= 0) return; /* connection gone; accept loop will notice on next read */
        sent += (size_t)n;
    }
    siot_led_comm_blink(); /* bench LED: a frame went down into the mesh */
}

/* Reframes the stream: SOF+LEN+CRC exactly like
 * mocked-device/main/mocked-device.c's rx_task, but reading from a socket. */
static void reassemble_and_dispatch(uint8_t *acc, size_t *acc_len,
                                    const uint8_t *chunk, size_t n)
{
    if (*acc_len + n > SAFR_MAX_FRAME * 2) *acc_len = 0; /* overflow guard */
    memcpy(&acc[*acc_len], chunk, n);
    *acc_len += n;

    size_t pos = 0;
    while (*acc_len - pos >= SAFR_MIN_FRAME) {
        if (acc[pos] != SAFR_SOF) { pos++; continue; }
        const size_t flen = ((size_t)acc[pos + 2] << 8) | acc[pos + 3];
        if (flen < SAFR_MIN_FRAME || flen > SAFR_MAX_FRAME) { pos++; continue; }
        if (*acc_len - pos < flen) break; /* wait for more bytes */

        safr_rx_frame_t rx;
        if (safr_parse_frame(&acc[pos], flen, &rx)) {
            if (s_on_uplink_frame) s_on_uplink_frame(&acc[pos], flen, &rx);
            pos += flen;
        } else {
            pos++; /* false SOF or corrupt frame: resync by one byte */
        }
    }
    memmove(acc, &acc[pos], *acc_len - pos);
    *acc_len -= pos;
}

static void drop_client(int *client)
{
    if (*client < 0) return;
    s_client_fd = -1;
    close(*client);
    *client = -1;
}

/* One root at a time, but never stuck on a dead one: select() watches the
 * listening socket and the current client together, so a new root (after
 * failover) replaces the old connection the moment it arrives, and TCP
 * keepalive reaps a root that vanished without closing. */
static void tcp_link_task(void *arg)
{
    (void)arg;

    const int listen_fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listen_fd < 0) vTaskDelete(NULL);

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(TCP_LISTEN_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY), /* board's own AP IP, 192.168.4.1 */
    };
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 ||
        listen(listen_fd, TCP_BACKLOG) != 0) {
        close(listen_fd);
        vTaskDelete(NULL);
    }

    static uint8_t acc[SAFR_MAX_FRAME * 2];
    size_t acc_len = 0;
    uint8_t chunk[RX_CHUNK_SIZE];
    int client = -1;

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(listen_fd, &rfds);
        int maxfd = listen_fd;
        if (client >= 0) {
            FD_SET(client, &rfds);
            if (client > maxfd) maxfd = client;
        }
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        if (select(maxfd + 1, &rfds, NULL, NULL, &tv) < 0) continue;

        if (FD_ISSET(listen_fd, &rfds)) {
            struct sockaddr_in peer;
            socklen_t peer_len = sizeof(peer);
            const int fd = accept(listen_fd, (struct sockaddr *)&peer, &peer_len);
            if (fd >= 0) {
                drop_client(&client); /* newest root wins */
                const int ka = 1, idle = KEEPALIVE_IDLE_S, intvl = KEEPALIVE_INTVL_S,
                          cnt = KEEPALIVE_CNT;
                setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &ka, sizeof(ka));
                setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
                setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
                setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));
                client = fd;
                acc_len = 0;
                s_client_fd = fd;
            }
        }

        if (client >= 0 && FD_ISSET(client, &rfds)) {
            const int n = recv(client, chunk, sizeof(chunk), 0);
            if (n <= 0) {
                drop_client(&client); /* peer closed, or keepalive gave up */
                acc_len = 0;
                continue;
            }
            reassemble_and_dispatch(acc, &acc_len, chunk, (size_t)n);
        }
    }
}

void tcp_link_init(tcp_link_frame_cb_t on_uplink_frame)
{
    s_on_uplink_frame = on_uplink_frame;
    xTaskCreate(tcp_link_task, "tcp_link", 4096, NULL, 10, NULL);
}
