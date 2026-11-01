/* Load generator: N loopback clients, each sends one 170-byte AES-128-CFB8-encrypted batch (5 position frames) every 1/hz s, spread over the period,
 * and reads (and discards) whatever the server sends.  usage: loadgen port N hz seconds */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/resource.h>
#include <openssl/evp.h>
#include <signal.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    int port = atoi(argv[1]), N = atoi(argv[2]), hz = atoi(argv[3]); double secs = atof(argv[4]);
    struct rlimit rl = { 200000, 200000 }; setrlimit(RLIMIT_NOFILE, &rl);
    int *fd = calloc(N, sizeof(int)); EVP_CIPHER_CTX **enc = calloc(N, sizeof(void *));
    unsigned char key[16], plain[170], ct[170], rb[65536]; int i, j, ep = epoll_create1(0);
    for (i = 0; i < 16; i++) key[i] = i;
    for (i = 0; i < 5; i++) { plain[i * 34] = 33; plain[i * 34 + 1] = 28; for (j = 0; j < 32; j++) plain[i * 34 + 2 + j] = i * 7 + j * 3; }
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port) }; inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    int connected = 0;
    for (i = 0; i < N; i++) {
        fd[i] = socket(AF_INET, SOCK_STREAM, 0);
        if (fd[i] < 0) { fprintf(stderr, "socket %d: %s\n", i, strerror(errno)); break; }
        if (connect(fd[i], (struct sockaddr *) &a, sizeof a) < 0) { fprintf(stderr, "connect %d: %s\n", i, strerror(errno)); break; }
        fcntl(fd[i], F_SETFL, O_NONBLOCK); int one = 1; setsockopt(fd[i], IPPROTO_TCP, 1, &one, sizeof one);
        enc[i] = EVP_CIPHER_CTX_new(); EVP_EncryptInit_ex(enc[i], EVP_aes_128_cfb8(), NULL, key, key);
        struct epoll_event e = { EPOLLIN, { .u32 = i } }; epoll_ctl(ep, EPOLL_CTL_ADD, fd[i], &e); connected++;
        if (i % 200 == 199) usleep(20000);                /* let the server accept; its listen queue is finite */
    }
    fprintf(stderr, "connected %d of %d\n", connected, N);
    usleep(1500000);                                      /* settle */
    double t0 = now(), period = 1.0 / hz; long nmsg = 0, rcvd = 0, short_w = 0; int cur = 0; long k = 0;
    struct epoll_event ev[512];
    while (now() - t0 < secs) {
        double t = now();
        int did = 0;
        while (t >= t0 + k * period + (double) cur * period / N) {          /* connection `cur` is due: one encrypted batch */
            int outl = 0; ssize_t w;
            EVP_EncryptUpdate(enc[cur], ct, &outl, plain, 170);
            w = write(fd[cur], ct, 170); if (w != 170) short_w++; else nmsg++;
            if (++cur == N) { cur = 0; k++; }
            did = 1; if ((nmsg & 255) == 0) t = now();
        }
        int n = epoll_wait(ep, ev, 512, did ? 0 : 1);
        for (i = 0; i < n; i++) { for (;;) { ssize_t r = read(fd[ev[i].data.u32], rb, sizeof rb); if (r <= 0) break; rcvd += r; } }
    }
    double el = now() - t0;
    printf("LOADGEN connected=%d msgs_sent=%ld (%.0f/s) short_writes=%ld rcvd=%.1f MB (%.1f MB/s)\n", connected, nmsg, nmsg / el, short_w, rcvd / 1e6, rcvd / 1e6 / el);
    return 0;
}
