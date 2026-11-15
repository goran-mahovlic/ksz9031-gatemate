/*
 * udp_burst_rx.c — receiver for the gbe_top burst test (UDP 1235), fast enough for 1 Gb/s.
 *
 * Sends one datagram of <size> bytes to <ip>:1235; gbe_rgmii answers with 1 + BURST_N identical
 * copies back to back at line rate. Receives them with recvmmsg (batches of 64) until <idle_ms>
 * of silence and prints count, first-to-last span, Mb/s (UDP payload and on the wire) and the
 * kernel UDP counters (/proc/net/snmp) for the run, so loss in the receiving host
 * (RcvbufErrors) can be told apart from loss on the way (never reached the host).
 *
 *   cc -O2 -o udp_burst_rx udp_burst_rx.c
 *   ./udp_burst_rx <ip> [size=1472] [expect=50001] [repeat=3] [idle_ms=300]
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define BATCH 64
#define WIRE_EXTRA (8 + 14 + 20 + 8 + 4 + 12)   /* preamble+SFD, Ethernet, IPv4, UDP, FCS, IFG */

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void udp_snmp(long *in_dgrams, long *rcvbuf_err)
{
    char line[512], vals[512];
    FILE *f = fopen("/proc/net/snmp", "r");
    *in_dgrams = *rcvbuf_err = -1;
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "Udp: InDatagrams", 16) == 0 && fgets(vals, sizeof vals, f)) {
            long v[6];
            if (sscanf(vals, "Udp: %ld %ld %ld %ld %ld %ld", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) == 6) {
                *in_dgrams = v[0];
                *rcvbuf_err = v[4];
            }
            break;
        }
    }
    fclose(f);
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <ip> [size] [expect] [repeat] [idle_ms]\n", argv[0]);
        return 2;
    }
    const char *ip = argv[1];
    int size   = argc > 2 ? atoi(argv[2]) : 1472;
    long expect = argc > 3 ? atol(argv[3]) : 50001;
    int repeat = argc > 4 ? atoi(argv[4]) : 3;
    int idle_ms = argc > 5 ? atoi(argv[5]) : 300;

    static char bufs[BATCH][2048];
    struct mmsghdr msgs[BATCH];
    struct iovec iov[BATCH];
    memset(msgs, 0, sizeof msgs);
    for (int i = 0; i < BATCH; i++) {
        iov[i].iov_base = bufs[i];
        iov[i].iov_len = sizeof bufs[i];
        msgs[i].msg_hdr.msg_iov = &iov[i];
        msgs[i].msg_hdr.msg_iovlen = 1;
    }

    for (int r = 0; r < repeat; r++) {
        int s = socket(AF_INET, SOCK_DGRAM, 0);
        int rb = 64 << 20;
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rb, sizeof rb);
        socklen_t rl = sizeof rb;
        getsockopt(s, SOL_SOCKET, SO_RCVBUF, &rb, &rl);
        struct timeval tv = { .tv_sec = 0, .tv_usec = idle_ms * 1000 };
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        struct sockaddr_in dst = { .sin_family = AF_INET, .sin_port = htons(1235) };
        inet_pton(AF_INET, ip, &dst.sin_addr);

        char *payload = malloc(size);
        memset(payload, 0x5a, size);
        snprintf(payload, size, "gbe-burst-c-%d-%ld", r, (long)time(NULL));

        long in0, rbe0, in1, rbe1;
        udp_snmp(&in0, &rbe0);
        double t_send = now(), t_first = 0, t_last = 0;
        if (sendto(s, payload, size, 0, (struct sockaddr *)&dst, sizeof dst) != size) {
            perror("sendto");
            return 1;
        }
        long n = 0, good = 0;
        struct timeval first_tv = { .tv_sec = 2, .tv_usec = 0 };
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &first_tv, sizeof first_tv);
        for (;;) {
            int k = recvmmsg(s, msgs, BATCH, 0, NULL);
            if (k <= 0) break;
            double t = now();
            if (n == 0) {
                t_first = t;
                setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            }
            t_last = t;
            for (int i = 0; i < k; i++) {
                n++;
                if ((int)msgs[i].msg_len == size && memcmp(bufs[i], payload, 32) == 0) good++;
            }
        }
        udp_snmp(&in1, &rbe1);
        double span = t_last - t_first;
        double mbps = (n > 1 && span > 0) ? (n - 1) * (double)size * 8 / span / 1e6 : 0;
        printf("burst %d: received %ld/%ld (good %ld), loss %.3f %%, %.1f Mb/s UDP payload, %.1f Mb/s on the wire, "
               "span %.4f s, first after %.2f ms, rcvbuf %d, kernel UDP InDatagrams +%ld RcvbufErrors +%ld\n",
               r + 1, n, expect, good, 100.0 * (1.0 - (double)n / expect), mbps,
               mbps * (size + WIRE_EXTRA) / size, span, n ? (t_first - t_send) * 1e3 : -1.0, rb,
               in1 - in0, rbe1 - rbe0);
        fflush(stdout);
        free(payload);
        close(s);
        sleep(1);
    }
    return 0;
}
