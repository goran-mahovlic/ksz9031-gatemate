/*
 * udp_echo_blast.c — echo throughput of gbe_top (UDP 1234): paced numbered datagrams, count echoes.
 *
 * The echo path runs through the 25 MHz MAC + stack (one byte per clock), so its ceiling is about
 * 25 MB/s minus framing; this finds the rate where loss starts. Sends <size>-byte datagrams with a
 * 32-bit sequence number at <mbps> (UDP payload rate) for <seconds>, receives with recvmmsg and
 * prints offered / echoed Mb/s, loss and duplicates.
 *
 *   cc -O2 -o udp_echo_blast udp_echo_blast.c
 *   ./udp_echo_blast <ip> <mbps> [seconds=2] [size=1472]
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define BATCH 64

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <ip> <mbps> [seconds] [size]\n", argv[0]);
        return 2;
    }
    const char *ip = argv[1];
    double mbps = atof(argv[2]);
    double secs = argc > 3 ? atof(argv[3]) : 2.0;
    int size = argc > 4 ? atoi(argv[4]) : 1472;
    long maxn = (long)(mbps * 1e6 * secs / (size * 8.0)) + 16;

    int s = socket(AF_INET, SOCK_DGRAM, 0);
    int rb = 64 << 20;
    setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rb, sizeof rb);
    struct sockaddr_in dst = { .sin_family = AF_INET, .sin_port = htons(1234) };
    inet_pton(AF_INET, ip, &dst.sin_addr);
    if (connect(s, (struct sockaddr *)&dst, sizeof dst) < 0) { perror("connect"); return 1; }

    uint8_t *seen = calloc(maxn, 1);
    static char rbuf[BATCH][2048];
    struct mmsghdr rm[BATCH];
    struct iovec riov[BATCH];
    memset(rm, 0, sizeof rm);
    for (int i = 0; i < BATCH; i++) {
        riov[i].iov_base = rbuf[i];
        riov[i].iov_len = sizeof rbuf[i];
        rm[i].msg_hdr.msg_iov = &riov[i];
        rm[i].msg_hdr.msg_iovlen = 1;
    }
    char *msg = malloc(size);
    memset(msg, 0xa5, size);

    long sent = 0, echoed = 0, dup = 0, bad = 0;
    double gap = size * 8.0 / (mbps * 1e6);
    double t0 = now(), end = t0 + secs, tail = end + 0.3, next = t0;
    for (;;) {
        double t = now();
        if (t >= tail) break;
        while (t < end && t >= next && sent < maxn) {
            uint32_t seq = htonl((uint32_t)sent);
            memcpy(msg, &seq, 4);
            if (send(s, msg, size, MSG_DONTWAIT) == size) { sent++; next += gap; }
            else break;
        }
        int k = recvmmsg(s, rm, BATCH, MSG_DONTWAIT, NULL);
        for (int i = 0; i < k; i++) {
            uint32_t seq;
            memcpy(&seq, rbuf[i], 4);
            seq = ntohl(seq);
            if ((int)rm[i].msg_len != size || seq >= (uint32_t)maxn) bad++;
            else if (seen[seq]) dup++;
            else { seen[seq] = 1; echoed++; }
        }
    }
    printf("echo %d B @ %.0f Mb/s target: sent %ld (%.1f Mb/s), echoed %ld (%.1f Mb/s), loss %.3f %%, dup %ld, bad %ld\n",
           size, mbps, sent, sent * size * 8.0 / secs / 1e6, echoed, echoed * size * 8.0 / secs / 1e6,
           sent ? 100.0 * (1.0 - (double)echoed / sent) : 100.0, dup, bad);
    return 0;
}
