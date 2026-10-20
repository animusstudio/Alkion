/* Test-only CLI. Link the exact reviewed alkion_fileops.c unchanged.
 * No service, general syscall interface, overwrite fallback, retry or cleanup.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

extern int32_t alkion_publish_noreplace(const char *from, const char *to);

enum { PATH_BOUND = 768, BYTE_BOUND = 8 * 1024 * 1024 };
struct observed {
    int error;
    struct stat value;
};

static struct observed observe(int parent, const char *name) {
    struct observed result;
    memset(&result, 0, sizeof(result));
    if (fstatat(parent, name, &result.value, AT_SYMLINK_NOFOLLOW) != 0)
        result.error = errno;
    return result;
}

static void print_observed(const struct observed *value) {
    if (value->error < 0) {
        printf("{\"errno\":null}");
        return;
    }
    if (value->error != 0) {
        printf("{\"errno\":%d}", value->error);
        return;
    }
    const struct stat *s = &value->value;
    printf("{\"errno\":0,\"dev\":%ju,\"ino\":%ju,\"uid\":%ju,\"gid\":%ju,"
           "\"mode\":%ju,\"nlink\":%ju,\"length\":%jd,"
           "\"mtime_sec\":%jd,\"mtime_nsec\":%jd,\"ctime_sec\":%jd,\"ctime_nsec\":%jd}",
           (uintmax_t)s->st_dev, (uintmax_t)s->st_ino,
           (uintmax_t)s->st_uid, (uintmax_t)s->st_gid,
           (uintmax_t)s->st_mode, (uintmax_t)s->st_nlink,
           (intmax_t)s->st_size, (intmax_t)s->st_mtim.tv_sec,
           (intmax_t)s->st_mtim.tv_nsec, (intmax_t)s->st_ctim.tv_sec,
           (intmax_t)s->st_ctim.tv_nsec);
}

static int valid_relative(const char *value) {
    size_t n = strnlen(value, PATH_BOUND + 1);
    if (n == 0 || n > PATH_BOUND || value[0] == '/' || value[n - 1] == '/')
        return 0;
    size_t start = 0;
    for (size_t i = 0; i <= n; ++i) {
        char c = value[i];
        if (c == '/' || c == '\0') {
            size_t length = i - start;
            if (length == 0 || (length == 1 && value[start] == '.') ||
                (length == 2 && value[start] == '.' && value[start + 1] == '.'))
                return 0;
            start = i + 1;
        } else if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                     (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')) {
            return 0;
        }
    }
    return 1;
}

static int valid_nonce(const char *value) {
    if (strnlen(value, 33) != 32) return 0;
    for (size_t i = 0; i < 32; ++i)
        if (!((value[i] >= 'a' && value[i] <= 'f') ||
              (value[i] >= '0' && value[i] <= '9'))) return 0;
    return 1;
}

static int same_file(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
           left->st_uid == right->st_uid && left->st_gid == right->st_gid &&
           left->st_mode == right->st_mode && left->st_nlink == right->st_nlink &&
           left->st_size == right->st_size;
}

/* Existing cache is UID-owned mode02771/GID20151 on the reviewed target.
 * Ancestors may be group-accessible; the new leaf must be private. Never
 * equate GID with UID, follow symlinks, or ignore a foreign UID/world writer.
 */
static int owned_parent(char *relative, uid_t uid) {
    int fd = open(".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    char *part = relative;
    for (;;) {
        struct stat info;
        if (fstat(fd, &info) != 0) {
            int failure = errno; close(fd); errno = failure; return -1;
        }
        if (!S_ISDIR(info.st_mode) || info.st_uid != uid || (info.st_mode & 0002) != 0) {
            close(fd); errno = EPERM; return -1;
        }
        if (part == NULL || *part == '\0') {
            if ((info.st_mode & 0077) != 0) {
                close(fd); errno = EPERM; return -1;
            }
            return fd;
        }
        char *slash = strchr(part, '/');
        if (slash != NULL) *slash = '\0';
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) {
            int failure = errno; close(fd); errno = failure; return -1;
        }
        close(fd); fd = next; part = slash != NULL ? slash + 1 : NULL;
    }
}

int main(int argc, char **argv) {
    const char *nonce = "", *from = "", *to = "";
    uid_t expected = 0, uid = getuid(), euid = geteuid();
    int parent = -1, source_fd = -1, precondition_errno = EINVAL;
    int pre_fsync_errno = -1, native_errno = -1, post_fsync_errno = -1;
    int exit_code = 2, source_consumed = 0;
    const char *stage = "invocation";
    struct observed before = { .error = -1 }, final_before = { .error = -1 };
    struct observed after = { .error = -1 }, final_after = { .error = -1 };
    char from_parent[PATH_BOUND + 1], to_parent[PATH_BOUND + 1];
    const char *from_leaf = NULL, *to_leaf = NULL;

    if (argc != 5) goto report;
    if (strnlen(argv[1], 6) != 5) goto report;
    for (size_t i = 0; i < 5; ++i)
        if (argv[1][i] < '0' || argv[1][i] > '9') goto report;
    char *end = NULL;
    errno = 0;
    unsigned long requested = strtoul(argv[1], &end, 10);
    if (errno != 0 || end == argv[1] || *end != '\0' ||
        requested < 10000 || requested >= 100000 ||
        !valid_nonce(argv[2]) || !valid_relative(argv[3]) || !valid_relative(argv[4]))
        goto report;
    expected = (uid_t)requested;
    nonce = argv[2]; from = argv[3]; to = argv[4];
    if (uid != expected || euid != expected) {
        precondition_errno = EPERM; goto report;
    }
    if (strcmp(from, to) == 0) goto report;
    memcpy(from_parent, from, strlen(from) + 1);
    memcpy(to_parent, to, strlen(to) + 1);
    char *from_slash = strrchr(from_parent, '/');
    char *to_slash = strrchr(to_parent, '/');
    /* Root-level names are outside this test publisher's private namespace. */
    if (from_slash == NULL || to_slash == NULL) goto report;
    *from_slash = '\0'; *to_slash = '\0';
    from_leaf = from_slash + 1; to_leaf = to_slash + 1;
    if (strcmp(from_parent, to_parent) != 0) goto report;
    stage = "parent";
    parent = owned_parent(from_parent, expected);
    if (parent < 0) { precondition_errno = errno; goto report; }

    stage = "source";
    before = observe(parent, from_leaf);
    final_before = observe(parent, to_leaf);
    if (before.error != 0) { precondition_errno = before.error; goto report; }
    if (final_before.error != 0 && final_before.error != ENOENT) {
        precondition_errno = final_before.error; goto report;
    }
    if (!S_ISREG(before.value.st_mode) || before.value.st_uid != expected ||
        before.value.st_nlink != 1 || (before.value.st_mode & 07777) != 0600 ||
        before.value.st_size < 0 || before.value.st_size > BYTE_BOUND) {
        precondition_errno = EPERM; goto report;
    }
    source_fd = openat(parent, from_leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (source_fd < 0) { precondition_errno = errno; goto report; }
    struct stat opened;
    if (fstat(source_fd, &opened) != 0) { precondition_errno = errno; goto report; }
    if (!same_file(&before.value, &opened)) {
        precondition_errno = EAGAIN; goto report;
    }
    precondition_errno = 0;
    stage = "source-fsync";
    pre_fsync_errno = fsync(source_fd) == 0 ? 0 : errno;
    if (pre_fsync_errno != 0) { exit_code = 1; goto report; }
    if (fchdir(parent) != 0) {
        precondition_errno = errno; exit_code = 2; goto report;
    }

    stage = "native";
    /* The single publication operation; errno comes from that same C call. */
    native_errno = alkion_publish_noreplace(from_leaf, to_leaf);
    if (native_errno < 0) { exit_code = 1; goto report; }
    exit_code = 1;
    if (native_errno == 0) {
        source_consumed = 1;
        stage = "directory-fsync";
        post_fsync_errno = fsync(parent) == 0 ? 0 : errno;
    }
    after = observe(parent, from_leaf);
    final_after = observe(parent, to_leaf);
    if (native_errno == 0 && post_fsync_errno == 0 && after.error == ENOENT &&
        final_after.error == 0 && same_file(&before.value, &final_after.value)) {
        stage = "complete"; exit_code = 0;
    }

report:
    /* Metadata observations are not a hash/readback or physical durability
     * claim. A missing reply/timeout is UNKNOWN even if the rename succeeded.
     */
    printf("{\"format\":\"alkion-test-noreplace/1\",\"nonce\":\"%s\","
           "\"expected_uid\":%ju,\"uid\":%ju,\"euid\":%ju,"
           "\"from\":\"%s\",\"to\":\"%s\",\"stage\":\"%s\","
           "\"precondition_errno\":%d,\"pre_fsync_errno\":",
           nonce, (uintmax_t)expected, (uintmax_t)uid, (uintmax_t)euid,
           from, to, stage, precondition_errno);
    if (pre_fsync_errno < 0) printf("null"); else printf("%d", pre_fsync_errno);
    printf(",\"rename_errno\":");
    if (native_errno < 0) printf("null"); else printf("%d", native_errno);
    printf(",\"post_fsync_errno\":");
    if (post_fsync_errno < 0) printf("null"); else printf("%d", post_fsync_errno);
    printf(",\"published\":%s,\"source_consumed\":%s,\"source_before\":",
           native_errno == 0 ? "true" : "false", source_consumed ? "true" : "false");
    print_observed(&before);
    printf(",\"source_after\":"); print_observed(&after);
    printf(",\"final_before\":"); print_observed(&final_before);
    printf(",\"final_after\":"); print_observed(&final_after);
    printf(",\"exit_code\":%d}\n", exit_code);
    if (source_fd >= 0) close(source_fd);
    if (parent >= 0) close(parent);
    return exit_code;
}
