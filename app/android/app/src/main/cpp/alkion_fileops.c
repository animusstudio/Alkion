#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdint.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef __NR_renameat2
#error "Atomic exclusive publication requires renameat2"
#endif

// The compiler selects the syscall ABI, including on Android API24-29 where
// bionic does not export renameat2. No overwriting or check-then-rename fallback.
// Success consumes from. Failure leaves the names unchanged and returns errno
// captured within this native call, before any Dart allocation/free/logging.
__attribute__((visibility("default")))
int32_t alkion_publish_noreplace(const char *from, const char *to) {
  if (syscall(__NR_renameat2, AT_FDCWD, from, AT_FDCWD, to,
              RENAME_NOREPLACE) == 0) {
    return 0;
  }
  const int failure = errno;
  return failure > 0 ? failure : EIO;
}
