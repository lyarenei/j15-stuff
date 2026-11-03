// camstream - expose the Midea J15 live H.264 stream on a local TCP port.
//
// video_node publishes encoded frames on the "camera_stream" mass topic
// (nanomsg SUB on ipc:///tmp/camera_stream + /dev/shm/camera_stream) once
// `media.engine.control start_push` is called over ubus. We load the vendor
// libsample_plugin.so at runtime and subscribe through its own API.
//
// The nanomsg message is only a slot descriptor (struct shm_meta); the frame
// itself is a VideoFrame struct at shm_base + meta.offset.
//
// Modes:
//   camstream [-b addr] -p 8555   serve raw Annex-B H.264 to one TCP client
//   camstream -d out.h264 -n 200  write N frames of raw H.264 to a file

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define TOPIC "camera_stream"
#define SHM_PATH "/dev/shm/camera_stream"
#define SHM_DATA_SIZE 1572864UL /* (3145792 - 64) / 2 */
#define UBUS "ubus -s /tmp/ubus.sock call media.engine.control "

// Descriptor sent over nanomsg (see mass_shm_cpyout_ptr in libsample_plugin.so).
struct shm_meta {
    uint64_t timestamp_ms;
    uint64_t offset;
    uint64_t length;
    uint64_t timeout_ms;
};

// clean_robot::message::VideoFrame as filled by midea::VideoPush::PushProcess.
#define VF_NOT_KEYFRAME 0x04 /* u32: 0 when the frame starts with an SPS */
#define VF_SIZE 0x10         /* u32: H.264 byte count */
#define VF_DATA 0x24         /* Annex-B H.264 */
#define VF_TOTAL 0x100024UL
#define VF_MAX_DATA (VF_TOTAL - VF_DATA)

static const uint8_t *shm_base;
static size_t shm_size;
static uint8_t frame_buf[VF_MAX_DATA];

typedef void (*mass_cb)(const void *data, unsigned long len, void *user);
typedef void *(*sub_create_shm_fn)(const char *topic, unsigned long size, mass_cb cb);
typedef int (*sub_spin_fn)(void *sub, void *user);

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int client_fd = -1;
static int wait_keyframe = 1;
static int pushing = 0;

static FILE *dump_fp;
static long dump_left;

static void ubus_call(const char *method)
{
    char cmd[256];
    snprintf(cmd, sizeof(cmd), UBUS "%s >/dev/null 2>&1", method);
    if (system(cmd) != 0)
        fprintf(stderr, "camstream: ubus %s failed\n", method);
}

static void set_push(int on)
{
    if (on == pushing)
        return;
    pushing = on;
    ubus_call(on ? "start_push" : "stop_push");
    if (on)
        ubus_call("request_idr");
    fprintf(stderr, "camstream: push %s\n", on ? "started" : "stopped");
}

static int map_shm(void)
{
    int fd = open(SHM_PATH, O_RDONLY);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) < 0) {
        perror("camstream: " SHM_PATH);
        return -1;
    }
    void *p = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        perror("camstream: mmap");
        return -1;
    }
    shm_base = p;
    shm_size = (size_t)st.st_size;
    return 0;
}

static void drop_client_locked(void)
{
    if (client_fd >= 0) {
        close(client_fd);
        client_fd = -1;
        fprintf(stderr, "camstream: client disconnected\n");
    }
    set_push(0);
}

static void on_frame(const void *data, unsigned long len, void *user)
{
    (void)user;
    struct shm_meta meta;
    if (len != sizeof(meta))
        return;
    memcpy(&meta, data, sizeof(meta));
    if (meta.offset + VF_TOTAL > shm_size)
        return;

    // Copy out right away; the publisher reuses this slot two frames later.
    const uint8_t *vf = shm_base + meta.offset;
    uint32_t size, not_key;
    memcpy(&size, vf + VF_SIZE, sizeof(size));
    memcpy(&not_key, vf + VF_NOT_KEYFRAME, sizeof(not_key));
    if (size == 0 || size > VF_MAX_DATA)
        return;
    memcpy(frame_buf, vf + VF_DATA, size);

    const uint8_t *p = frame_buf;
    unsigned long n_left = size;

    if (dump_fp) {
        static int got_key;
        if (!got_key && not_key)
            return;
        got_key = 1;
        fwrite(p, 1, n_left, dump_fp);
        if (--dump_left <= 0) {
            fclose(dump_fp);
            ubus_call("stop_push");
            fprintf(stderr, "camstream: dump complete\n");
            _exit(0);
        }
        return;
    }

    pthread_mutex_lock(&lock);
    if (client_fd < 0)
        goto out;

    if (wait_keyframe) {
        if (not_key)
            goto out;
        wait_keyframe = 0;
    }

    while (n_left > 0) {
        ssize_t n = send(client_fd, p, n_left, MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0 && errno == EINTR)
                continue;
            drop_client_locked();
            break;
        }
        p += n;
        n_left -= (unsigned long)n;
    }
out:
    pthread_mutex_unlock(&lock);
}

static void *spin_thread(void *arg)
{
    void **a = arg;
    sub_spin_fn spin = (sub_spin_fn)a[0];
    for (;;) {
        spin(a[1], NULL);
        usleep(100000);
    }
    return NULL;
}

static void on_signal(int sig)
{
    (void)sig;
    ubus_call("stop_push");
    _exit(0);
}

static void usage(const char *argv0)
{
    fprintf(stderr,
        "usage: %s [-b addr] [-p port]\n"
        "       %s -d file [-n frames]\n"
        "\n"
        "  -b addr    address to listen on (default 0.0.0.0)\n"
        "  -p port    TCP port to serve raw H.264 on (default 8555)\n"
        "  -d file    write raw H.264 to file instead of serving it\n"
        "  -n frames  number of frames to write with -d (default 200, ~10 s)\n",
        argv0, argv0);
}

int main(int argc, char **argv)
{
    int port = 8555;
    const char *bind_addr = "0.0.0.0";
    const char *dump_path = NULL;
    dump_left = 200;

    int opt;
    while ((opt = getopt(argc, argv, "b:p:d:n:h")) != -1) {
        switch (opt) {
        case 'b': bind_addr = optarg; break;
        case 'p': port = atoi(optarg); break;
        case 'd': dump_path = optarg; break;
        case 'n': dump_left = atol(optarg); break;
        case 'h': usage(argv[0]); return 0;
        default: usage(argv[0]); return 2;
        }
    }

    struct sockaddr_in addr = { .sin_family = AF_INET, .sin_port = htons(port) };
    if (port <= 0 || port > 65535 || inet_pton(AF_INET, bind_addr, &addr.sin_addr) != 1) {
        fprintf(stderr, "camstream: invalid address %s:%d\n", bind_addr, port);
        return 2;
    }

    signal(SIGPIPE, SIG_IGN);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    void *lib = dlopen("libsample_plugin.so", RTLD_NOW);
    if (!lib) {
        fprintf(stderr, "camstream: dlopen: %s\n", dlerror());
        return 1;
    }
    sub_create_shm_fn create = (sub_create_shm_fn)dlsym(lib,
        "_ZN11clean_robot6plugin4mass25mass_subscribe_create_shmEPKcmPFvPKvmPvE");
    sub_spin_fn spin = (sub_spin_fn)dlsym(lib,
        "_ZN11clean_robot6plugin4mass19mass_subscribe_spinEPNS1_11__subscribeEPv");
    if (!create || !spin) {
        fprintf(stderr, "camstream: missing mass symbols\n");
        return 1;
    }

    void *sub = create(TOPIC, SHM_DATA_SIZE, on_frame);
    if (!sub) {
        fprintf(stderr, "camstream: subscribe to %s failed\n", TOPIC);
        return 1;
    }
    if (map_shm() < 0)
        return 1;

    static void *spin_args[2];
    spin_args[0] = (void *)spin;
    spin_args[1] = sub;
    pthread_t th;
    pthread_create(&th, NULL, spin_thread, spin_args);

    if (dump_path) {
        dump_fp = fopen(dump_path, "wb");
        if (!dump_fp) {
            perror("camstream: fopen");
            return 1;
        }
        ubus_call("start_push");
        ubus_call("request_idr");
        fprintf(stderr, "camstream: writing %ld frames to %s\n", dump_left, dump_path);
        for (;;)
            pause();
    }

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(srv, 1) < 0) {
        perror("camstream: bind/listen");
        return 1;
    }
    fprintf(stderr, "camstream: listening on %s:%d\n", bind_addr, port);

    for (;;) {
        int fd = accept(srv, NULL, NULL);
        if (fd < 0)
            continue;
        struct timeval tv = { .tv_sec = 2 };
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        pthread_mutex_lock(&lock);
        if (client_fd >= 0)
            close(client_fd); /* newest client wins */
        client_fd = fd;
        wait_keyframe = 1;
        fprintf(stderr, "camstream: client connected\n");
        if (pushing)
            ubus_call("request_idr");
        else
            set_push(1);
        pthread_mutex_unlock(&lock);
    }
}
