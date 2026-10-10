// Linux implementation of the `reps/capture` channel.
//
// Source-write gate, per caller-provided private state directory:
//   - a process mutex guards this process's ticket table;
//   - `admission.lock` (flock LOCK_EX) serializes every admission decision
//     across processes, and the durable record `gate.state` is read and
//     written only while it is held;
//   - `tickets.lock` is held LOCK_SH by every process with at least one
//     admitted ticket, and LOCK_EX by the process holding a capture, so the
//     hold can only be taken once no process has admitted work left, and a
//     dead process's locks vanish with it;
//   - `gate.state` survives process loss: a `preparing` or `held` record
//     keeps admission closed after a crash or restart until an explicit
//     release names the same capture and generation.
//   - while a process has admitted tickets it also keeps a durable marker in
//     `inflight/`, locked by that process; a marker left by a process that
//     died with work in flight makes `drain` answer `recovery_required` until
//     `acknowledgeInterrupted` (an explicit recovery decision) removes it.
// Durable files: write a new temporary file, fsync it, rename, fsync the
// directory. Publication fsyncs the whole staging tree and renames it with
// renameat2(RENAME_NOREPLACE), so an existing destination is refused
// atomically; a filesystem that rejects the flag answers `unsupported`.
#include "include/reps_capture_platform/reps_capture_platform_plugin.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif

namespace {

struct Result {
  std::string code;
  std::string ticket;
  int64_t generation = -1;
  int64_t tickets = -1;
  int64_t interrupted = -1;
  int64_t bytes = -1;
};

Result Code(const std::string& code) {
  Result r;
  r.code = code;
  return r;
}

// ---- Durable file primitives ------------------------------------------

enum Fault { kNoFault = 0, kFileSync = 1, kDirSync = 2 };
#ifndef NDEBUG
// Debug builds only: the next flush of this kind fails (see injectFault).
std::atomic<int> g_fault{kNoFault};
#endif

// fsync, failing once with EIO when a debug build injected [kind].
int SyncFd(int fd, Fault kind) {
#ifndef NDEBUG
  int expected = kind;
  if (g_fault.compare_exchange_strong(expected, kNoFault)) {
    errno = EIO;
    return -1;
  }
#else
  (void)kind;
#endif
  int rc;
  do {
    rc = fsync(fd);
  } while (rc != 0 && errno == EINTR);
  return rc;
}

bool SyncDir(const std::string& dir) {
  int fd = open(dir.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (fd < 0) return false;
  bool ok = SyncFd(fd, kDirSync) == 0;
  return close(fd) == 0 && ok;
}

bool WriteAll(int fd, const uint8_t* data, size_t len) {
  while (len > 0) {
    ssize_t n = write(fd, data, len);
    if (n < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    data += n;
    len -= static_cast<size_t>(n);
  }
  return true;
}

std::string Dirname(const std::string& path) {
  size_t pos = path.find_last_of('/');
  if (pos == std::string::npos) return ".";
  if (pos == 0) return "/";
  return path.substr(0, pos);
}

std::atomic<uint64_t> g_tmp_counter{0};

std::string DurableReplace(const std::string& path, const uint8_t* data,
                           size_t len) {
  if (path.empty() || path.back() == '/') return "invalid_argument";
  const std::string tmp = path + ".capture-tmp-" + std::to_string(getpid()) +
                          "-" + std::to_string(++g_tmp_counter);
  int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  if (fd < 0) {
    return (errno == ENOENT || errno == ENOTDIR) ? "invalid_argument"
                                                 : "io_error";
  }
  bool ok = WriteAll(fd, data, len) && SyncFd(fd, kFileSync) == 0;
  if (close(fd) != 0) ok = false;
  if (!ok || rename(tmp.c_str(), path.c_str()) != 0) {
    unlink(tmp.c_str());
    return "io_error";
  }
  // The rename is only durable once the directory entry is.
  return SyncDir(Dirname(path)) ? "ok" : "io_error";
}

// Makes every directory from [base] (which must exist) down to [path] exist
// durably: each missing component is created (mode 0700), and the parent of
// EVERY component below [base] is flushed, whether this call created it or
// not. A component left unflushed by an earlier failed or killed call is
// therefore flushed by the next call before success is reported. Symbolic
// links below [base] are refused.
std::string EnsureDirectory(const std::string& path, const std::string& base) {
  if (path.empty() || base.empty() || path[0] != '/' || base[0] != '/') {
    return "invalid_argument";
  }
  std::string trimmed_base = base;
  while (trimmed_base.size() > 1 && trimmed_base.back() == '/') {
    trimmed_base.pop_back();
  }
  std::string rest;
  if (path == trimmed_base) {
    rest = "";
  } else if (path.compare(0, trimmed_base.size() + 1, trimmed_base + "/") == 0) {
    rest = path.substr(trimmed_base.size() + 1);
  } else {
    return "invalid_argument";
  }
  struct stat st;
  if (stat(trimmed_base.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
    return "invalid_argument";
  }
  std::string current = trimmed_base;
  size_t start = 0;
  while (start <= rest.size()) {
    size_t end = rest.find('/', start);
    if (end == std::string::npos) end = rest.size();
    const std::string part = rest.substr(start, end - start);
    start = end + 1;
    if (part.empty()) {
      if (end == rest.size()) break;  // trailing '/'
      return "invalid_argument";
    }
    if (part == "." || part == "..") return "invalid_argument";
    const std::string parent = current;
    current += "/" + part;
    if (mkdir(current.c_str(), 0700) != 0 && errno != EEXIST) {
      return errno == ENOTDIR ? "not_a_directory" : "io_error";
    }
    if (lstat(current.c_str(), &st) != 0) return "io_error";
    if (!S_ISDIR(st.st_mode)) return "not_a_directory";
    if (!SyncDir(parent)) return "io_error";
  }
  return "ok";
}

// fsyncs every regular file and directory under [path], children first.
std::string SyncTree(const std::string& path) {
  struct stat st;
  if (lstat(path.c_str(), &st) != 0) return "io_error";
  if (S_ISREG(st.st_mode)) {
    int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
    if (fd < 0) return "io_error";
    bool ok = SyncFd(fd, kFileSync) == 0;
    if (close(fd) != 0) ok = false;
    return ok ? "ok" : "io_error";
  }
  if (!S_ISDIR(st.st_mode)) return "invalid_argument";
  DIR* dir = opendir(path.c_str());
  if (dir == nullptr) return "io_error";
  std::vector<std::string> children;
  errno = 0;
  while (struct dirent* entry = readdir(dir)) {
    if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    children.push_back(path + "/" + entry->d_name);
  }
  const bool listed = errno == 0;
  closedir(dir);
  if (!listed) return "io_error";
  for (const auto& child : children) {
    std::string code = SyncTree(child);
    if (code != "ok") return code;
  }
  return SyncDir(path) ? "ok" : "io_error";
}

std::string PublishNoReplace(const std::string& staging,
                             const std::string& destination) {
  if (staging.empty() || destination.empty()) return "invalid_argument";
  struct stat st;
  if (lstat(staging.c_str(), &st) != 0 || !S_ISDIR(st.st_mode)) {
    return "invalid_argument";
  }
  std::string code = SyncTree(staging);
  if (code != "ok") return code;
  long rc = syscall(SYS_renameat2, AT_FDCWD, staging.c_str(), AT_FDCWD,
                    destination.c_str(), RENAME_NOREPLACE);
  if (rc != 0) {
    switch (errno) {
      case EEXIST:
      case ENOTEMPTY:
        return "destination_exists";
      case EXDEV:
        return "cross_device";
      case EINVAL:
      case ENOSYS:
      case EOPNOTSUPP:
        return "unsupported";
      case ENOENT:
      case ENOTDIR:
        return "invalid_argument";
      default:
        return "io_error";
    }
  }
  bool ok = SyncDir(Dirname(destination));
  if (Dirname(staging) != Dirname(destination)) {
    ok = SyncDir(Dirname(staging)) && ok;
  }
  return ok ? "ok" : "io_error";
}

// ---- Source-write gate ------------------------------------------------

struct Ticket {
  int refs;
  int64_t generation;
};

struct GateDir {
  int ticket_fd = -1;  // LOCK_SH while this process has admitted tickets
  int hold_fd = -1;    // LOCK_EX while this process holds a capture
  int marker_fd = -1;  // LOCK_EX on this process's in-flight marker
  std::string marker_path;
  std::map<std::string, Ticket> tickets;
};

std::mutex g_mutex;
std::map<std::string, GateDir> g_dirs;
uint64_t g_ticket_counter = 0;

struct Record {
  int64_t generation = 0;
  std::string state = "open";
  std::string capture;
  std::string decision;
};

bool ValidToken(const std::string& s) {
  if (s.empty() || s.size() > 128) return false;
  for (char c : s) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' ||
          c == ':')) {
      return false;
    }
  }
  return true;
}

bool ParseInt(const std::string& s, int64_t* out) {
  if (s.empty() || s.size() > 18) return false;
  int64_t v = 0;
  for (char c : s) {
    if (c < '0' || c > '9') return false;
    v = v * 10 + (c - '0');
  }
  *out = v;
  return true;
}

const char* kRecordHeader = "reps-capture-gate/1";

std::string ReadRecord(const std::string& dir, Record* record) {
  *record = Record();
  int fd = open((dir + "/gate.state").c_str(), O_RDONLY | O_CLOEXEC);
  if (fd < 0) return errno == ENOENT ? "ok" : "io_error";
  char buffer[2048];
  std::string text;
  for (;;) {
    ssize_t n = read(fd, buffer, sizeof buffer);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) {
      close(fd);
      return "io_error";
    }
    if (n == 0) break;
    text.append(buffer, static_cast<size_t>(n));
    if (text.size() > 4096) break;
  }
  close(fd);
  // Exactly: header, generation, state, capture, decision; anything else is
  // corrupt and keeps admission closed.
  std::vector<std::string> lines;
  size_t start = 0;
  while (start < text.size()) {
    size_t end = text.find('\n', start);
    if (end == std::string::npos) return "state_corrupt";
    lines.push_back(text.substr(start, end - start));
    start = end + 1;
  }
  if (lines.size() != 5 || lines[0] != kRecordHeader) return "state_corrupt";
  const char* keys[] = {"generation=", "state=", "capture=", "decision="};
  std::string values[4];
  for (int i = 0; i < 4; i++) {
    const std::string& line = lines[i + 1];
    size_t k = strlen(keys[i]);
    if (line.compare(0, k, keys[i]) != 0) return "state_corrupt";
    values[i] = line.substr(k);
  }
  if (!ParseInt(values[0], &record->generation)) return "state_corrupt";
  record->state = values[1];
  record->capture = values[2];
  record->decision = values[3];
  const bool open_state = record->state == "open";
  if (!open_state && record->state != "preparing" && record->state != "held") {
    return "state_corrupt";
  }
  if (open_state != record->capture.empty()) return "state_corrupt";
  if (!record->capture.empty() && !ValidToken(record->capture)) {
    return "state_corrupt";
  }
  if (!record->decision.empty() && !ValidToken(record->decision)) {
    return "state_corrupt";
  }
  return "ok";
}

std::string WriteRecord(const std::string& dir, const Record& record) {
  const std::string text = std::string(kRecordHeader) + "\n" +
                           "generation=" + std::to_string(record.generation) +
                           "\nstate=" + record.state +
                           "\ncapture=" + record.capture +
                           "\ndecision=" + record.decision + "\n";
  return DurableReplace(dir + "/gate.state",
                        reinterpret_cast<const uint8_t*>(text.data()),
                        text.size());
}

std::string LockErrorCode(int error) {
  return (error == EOPNOTSUPP || error == ENOLCK || error == EINVAL)
             ? "unsupported"
             : "io_error";
}

// Holds `admission.lock` exclusively for one admission decision.
class AdmissionLock {
 public:
  explicit AdmissionLock(const std::string& dir) {
    fd_ = open((dir + "/admission.lock").c_str(),
               O_RDWR | O_CREAT | O_CLOEXEC, 0600);
    if (fd_ < 0) {
      code_ = "io_error";
      return;
    }
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (flock(fd_, LOCK_EX | LOCK_NB) != 0) {
      if (errno == EINTR) continue;
      if (errno != EWOULDBLOCK) {
        code_ = LockErrorCode(errno);
        return;
      }
      if (std::chrono::steady_clock::now() > deadline) {
        code_ = "busy";
        return;
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    code_ = "ok";
  }
  ~AdmissionLock() {
    if (fd_ >= 0) close(fd_);  // closing the descriptor drops the lock
  }
  const std::string& code() const { return code_; }

 private:
  int fd_ = -1;
  std::string code_;
};

std::string EnsureShared(GateDir& gate, const std::string& dir) {
  if (gate.ticket_fd >= 0) return "ok";
  int fd = open((dir + "/tickets.lock").c_str(), O_RDWR | O_CREAT | O_CLOEXEC,
                0600);
  if (fd < 0) return "io_error";
  while (flock(fd, LOCK_SH | LOCK_NB) != 0) {
    if (errno == EINTR) continue;
    int error = errno;
    close(fd);
    // Another process holds the exclusive capture lock.
    return error == EWOULDBLOCK ? "admission_closed" : LockErrorCode(error);
  }
  gate.ticket_fd = fd;
  return "ok";
}

// ---- In-flight markers ---------------------------------------------------
//
// While a process has admitted tickets it keeps a durable marker file
// `inflight/<pid>-<nonce>.marker`, locked LOCK_EX by that process alone. A
// marker whose lock can be taken by someone else belongs to a process that
// died with admitted work in flight: its half-finished cross-store work was
// never drained, so no hold may be taken over it until an explicit recovery
// acknowledgement removes the marker.

std::string ProcessNonce() {
  static const std::string nonce = [] {
    unsigned char bytes[8] = {0};
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    bool ok = fd >= 0 && read(fd, bytes, sizeof bytes) == sizeof bytes;
    if (fd >= 0) close(fd);
    if (!ok) {
      uint64_t t = static_cast<uint64_t>(
          std::chrono::steady_clock::now().time_since_epoch().count());
      memcpy(bytes, &t, sizeof bytes);
    }
    char hex[17];
    for (int i = 0; i < 8; i++) snprintf(hex + 2 * i, 3, "%02x", bytes[i]);
    return std::string(hex, 16);
  }();
  return nonce;
}

std::string EnsureMarker(GateDir& gate, const std::string& dir) {
  if (gate.marker_fd >= 0) return "ok";
  const std::string inflight = dir + "/inflight";
  if (mkdir(inflight.c_str(), 0700) == 0) {
    if (!SyncDir(dir)) return "io_error";
  } else if (errno != EEXIST) {
    return "io_error";
  }
  const std::string path = inflight + "/" + std::to_string(getpid()) + "-" +
                           ProcessNonce() + ".marker";
  int fd = open(path.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) return "io_error";
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    int error = errno;
    close(fd);
    return LockErrorCode(error);
  }
  if (SyncFd(fd, kFileSync) != 0 || !SyncDir(inflight)) {
    unlink(path.c_str());
    close(fd);
    return "io_error";
  }
  gate.marker_fd = fd;
  gate.marker_path = path;
  return "ok";
}

// Removes the marker (still locked, so no scan can mistake it for an
// orphan), then drops the shared ticket lock.
void ReleaseSharedIfIdle(GateDir& gate) {
  if (!gate.tickets.empty()) return;
  if (gate.marker_fd >= 0) {
    unlink(gate.marker_path.c_str());
    SyncDir(Dirname(gate.marker_path));
    close(gate.marker_fd);
    gate.marker_fd = -1;
    gate.marker_path.clear();
  }
  if (gate.ticket_fd >= 0) {
    close(gate.ticket_fd);
    gate.ticket_fd = -1;
  }
}

// Scans other processes' markers. Returns "ok" when there are none,
// "pending" when a live owner still holds one, otherwise
// "recovery_required" with [orphans] counted (and removed when [remove]).
std::string ScanMarkers(const GateDir& gate, const std::string& dir,
                        bool remove, int64_t* orphans) {
  *orphans = 0;
  const std::string inflight = dir + "/inflight";
  DIR* d = opendir(inflight.c_str());
  if (d == nullptr) return errno == ENOENT ? "ok" : "io_error";
  std::vector<std::string> markers;
  errno = 0;
  while (struct dirent* entry = readdir(d)) {
    const std::string name = entry->d_name;
    if (name.size() > 7 && name.compare(name.size() - 7, 7, ".marker") == 0) {
      markers.push_back(inflight + "/" + name);
    }
  }
  const bool listed = errno == 0;
  closedir(d);
  if (!listed) return "io_error";
  bool live = false;
  for (const auto& path : markers) {
    if (path == gate.marker_path) continue;
    int fd = open(path.c_str(), O_RDWR | O_CLOEXEC);
    if (fd < 0) {
      if (errno == ENOENT) continue;  // its owner just finished
      return "io_error";
    }
    if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
      (*orphans)++;
      if (remove) unlink(path.c_str());
    } else if (errno == EWOULDBLOCK) {
      live = true;
    } else {
      int error = errno;
      close(fd);
      return LockErrorCode(error);
    }
    close(fd);
  }
  if (remove && *orphans > 0 && !SyncDir(inflight)) return "io_error";
  if (live) return "pending";
  return *orphans > 0 ? "recovery_required" : "ok";
}

Result NewTicket(GateDir& gate, int64_t generation) {
  Result r = Code("ok");
  r.ticket = std::to_string(getpid()) + "-" + std::to_string(++g_ticket_counter);
  r.generation = generation;
  gate.tickets[r.ticket] = Ticket{1, generation};
  return r;
}

bool Canonical(const char* dir, std::string* out) {
  if (dir == nullptr || dir[0] == '\0') return false;
  char resolved[PATH_MAX];
  if (realpath(dir, resolved) == nullptr) return false;
  struct stat st;
  if (stat(resolved, &st) != 0 || !S_ISDIR(st.st_mode)) return false;
  *out = resolved;
  return true;
}

Result Admit(const std::string& dir, const std::string& parent) {
  std::lock_guard<std::mutex> guard(g_mutex);
  GateDir& gate = g_dirs[dir];
  if (!parent.empty()) {
    auto it = gate.tickets.find(parent);
    if (it == gate.tickets.end()) return Code("parent_completed");
    it->second.refs++;
    Result r = Code("ok");
    r.ticket = parent;
    r.generation = it->second.generation;
    return r;
  }
  AdmissionLock lock(dir);
  if (lock.code() != "ok") return Code(lock.code());
  Record record;
  std::string code = ReadRecord(dir, &record);
  if (code != "ok") return Code(code);
  if (record.state != "open") return Code("admission_closed");
  code = EnsureShared(gate, dir);
  if (code == "ok") code = EnsureMarker(gate, dir);
  if (code != "ok") {
    ReleaseSharedIfIdle(gate);
    return Code(code);
  }
  return NewTicket(gate, record.generation);
}

Result Complete(const std::string& dir, const std::string& ticket) {
  std::lock_guard<std::mutex> guard(g_mutex);
  GateDir& gate = g_dirs[dir];
  auto it = gate.tickets.find(ticket);
  if (it == gate.tickets.end()) return Code("unknown_ticket");
  if (--it->second.refs == 0) gate.tickets.erase(it);
  ReleaseSharedIfIdle(gate);
  return Code("ok");
}

Result Prepare(const std::string& dir, const std::string& capture) {
  if (!ValidToken(capture)) return Code("invalid_argument");
  std::lock_guard<std::mutex> guard(g_mutex);
  GateDir& gate = g_dirs[dir];
  AdmissionLock lock(dir);
  if (lock.code() != "ok") return Code(lock.code());
  Record record;
  std::string code = ReadRecord(dir, &record);
  if (code != "ok") return Code(code);
  if (record.state != "open") return Code("capture_in_progress");
  code = EnsureShared(gate, dir);
  if (code == "ok") code = EnsureMarker(gate, dir);
  if (code != "ok") {
    ReleaseSharedIfIdle(gate);
    return Code(code);
  }
  Record next = record;
  next.generation = record.generation + 1;
  next.state = "preparing";
  next.capture = capture;
  code = WriteRecord(dir, next);
  if (code != "ok") {
    ReleaseSharedIfIdle(gate);
    return Code(code);
  }
  return NewTicket(gate, next.generation);
}

bool Matches(const Record& record, const std::string& capture,
             int64_t generation) {
  return record.state != "open" && record.capture == capture &&
         record.generation == generation;
}

Result Drain(const std::string& dir, const std::string& capture,
             int64_t generation) {
  std::lock_guard<std::mutex> guard(g_mutex);
  GateDir& gate = g_dirs[dir];
  AdmissionLock lock(dir);
  if (lock.code() != "ok") return Code(lock.code());
  Record record;
  std::string code = ReadRecord(dir, &record);
  if (code != "ok") return Code(code);
  if (!Matches(record, capture, generation)) return Code("mismatch");
  if (gate.hold_fd >= 0) return Code("held");
  if (!gate.tickets.empty()) {
    Result r = Code("pending");
    r.tickets = static_cast<int64_t>(gate.tickets.size());
    return r;
  }
  int fd = open((dir + "/tickets.lock").c_str(), O_RDWR | O_CREAT | O_CLOEXEC,
                0600);
  if (fd < 0) return Code("io_error");
  while (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    if (errno == EINTR) continue;
    int error = errno;
    close(fd);
    // Another process still has admitted work.
    return Code(error == EWOULDBLOCK ? "pending" : LockErrorCode(error));
  }
  // No live process has tickets now; a marker left behind means its owner
  // died with work in flight.
  int64_t orphans = 0;
  code = ScanMarkers(gate, dir, false, &orphans);
  if (code != "ok") {
    close(fd);
    Result r = Code(code);
    if (orphans > 0) r.interrupted = orphans;
    return r;
  }
  if (record.state == "preparing") {
    record.state = "held";
    code = WriteRecord(dir, record);
    if (code != "ok") {
      close(fd);
      return Code(code);
    }
  }
  gate.hold_fd = fd;
  return Code("held");
}

Result Release(const std::string& dir, const std::string& capture,
               int64_t generation, const std::string& decision) {
  if (!ValidToken(decision)) return Code("invalid_argument");
  std::lock_guard<std::mutex> guard(g_mutex);
  GateDir& gate = g_dirs[dir];
  AdmissionLock lock(dir);
  if (lock.code() != "ok") return Code(lock.code());
  Record record;
  std::string code = ReadRecord(dir, &record);
  if (code != "ok") return Code(code);
  if (!Matches(record, capture, generation)) return Code("mismatch");
  Record next = record;
  next.state = "open";
  next.capture.clear();
  next.decision = decision;
  code = WriteRecord(dir, next);
  if (code != "ok") return Code(code);
  if (gate.hold_fd >= 0) {
    close(gate.hold_fd);
    gate.hold_fd = -1;
  }
  return Code("ok");
}

Result VerifyHold(const std::string& dir, const std::string& capture,
                  int64_t generation) {
  std::lock_guard<std::mutex> guard(g_mutex);
  GateDir& gate = g_dirs[dir];
  AdmissionLock lock(dir);
  if (lock.code() != "ok") return Code(lock.code());
  Record record;
  std::string code = ReadRecord(dir, &record);
  if (code != "ok") return Code(code);
  if (record.state == "open") return Code("open");
  if (!Matches(record, capture, generation)) return Code("mismatch");
  if (record.state == "preparing") return Code("preparing");
  return Code(gate.hold_fd >= 0 ? "held" : "recorded");
}

// Explicit recovery decision: removes the markers of processes that died
// with work in flight. Never called automatically.
Result AcknowledgeInterrupted(const std::string& dir,
                              const std::string& decision) {
  if (!ValidToken(decision)) return Code("invalid_argument");
  std::lock_guard<std::mutex> guard(g_mutex);
  GateDir& gate = g_dirs[dir];
  AdmissionLock lock(dir);
  if (lock.code() != "ok") return Code(lock.code());
  int64_t orphans = 0;
  std::string code = ScanMarkers(gate, dir, true, &orphans);
  if (code == "io_error") return Code(code);
  Result r = Code("ok");
  r.interrupted = orphans;
  return r;
}

Result Dispatch(const std::string& method, const char* dir_arg,
                const std::string& a1, const std::string& a2,
                const std::string& a3) {
  std::string dir;
  if (!Canonical(dir_arg, &dir)) return Code("invalid_argument");
  int64_t generation = -1;
  if (method == "admit") return Admit(dir, a2);
  if (method == "complete") return Complete(dir, a1);
  if (method == "prepare") return Prepare(dir, a1);
  if (method == "acknowledgeInterrupted") {
    return AcknowledgeInterrupted(dir, a1);
  }
  if (!ParseInt(a2, &generation)) return Code("invalid_argument");
  if (method == "drain") return Drain(dir, a1, generation);
  if (method == "release") return Release(dir, a1, generation, a3);
  if (method == "verifyHold") return VerifyHold(dir, a1, generation);
  return Code("unsupported");
}

// ---- Channel glue -------------------------------------------------------

std::string StringArg(FlValue* args, const char* key) {
  FlValue* v = fl_value_lookup_string(args, key);
  return (v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_STRING)
             ? fl_value_get_string(v)
             : "";
}

std::string IntArg(FlValue* args, const char* key) {
  FlValue* v = fl_value_lookup_string(args, key);
  return (v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_INT &&
          fl_value_get_int(v) >= 0)
             ? std::to_string(fl_value_get_int(v))
             : "";
}

FlValue* ResultValue(const Result& r) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, "code", fl_value_new_string(r.code.c_str()));
  if (!r.ticket.empty()) {
    fl_value_set_string_take(map, "ticket",
                             fl_value_new_string(r.ticket.c_str()));
  }
  if (r.generation >= 0) {
    fl_value_set_string_take(map, "generation",
                             fl_value_new_int(r.generation));
  }
  if (r.tickets >= 0) {
    fl_value_set_string_take(map, "tickets", fl_value_new_int(r.tickets));
  }
  if (r.interrupted >= 0) {
    fl_value_set_string_take(map, "interrupted",
                             fl_value_new_int(r.interrupted));
  }
  if (r.bytes >= 0) {
    fl_value_set_string_take(map, "bytes", fl_value_new_int(r.bytes));
  }
  return map;
}

void Respond(FlMethodCall* call, const Result& r) {
  g_autoptr(FlValue) value = ResultValue(r);
  fl_method_call_respond_success(call, value, nullptr);
}

struct PendingResponse {
  FlMethodCall* call;
  Result result;
};

gboolean RespondOnMainThread(gpointer data) {
  auto* pending = static_cast<PendingResponse*>(data);
  Respond(pending->call, pending->result);
  g_object_unref(pending->call);
  delete pending;
  return G_SOURCE_REMOVE;
}

// File primitives flush to disk; run them off the platform thread.
template <typename Work>
void RespondFromWorker(FlMethodCall* call, Work work) {
  g_object_ref(call);
  std::thread([call, work]() {
    auto* pending = new PendingResponse{call, Code(work())};
    g_idle_add(RespondOnMainThread, pending);
  }).detach();
}

void HandleMethodCall(FlMethodCall* call) {
  const std::string method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    Respond(call, Code("invalid_argument"));
    return;
  }
  if (method == "durableReplace") {
    FlValue* bytes = fl_value_lookup_string(args, "bytes");
    if (bytes == nullptr ||
        fl_value_get_type(bytes) != FL_VALUE_TYPE_UINT8_LIST) {
      Respond(call, Code("invalid_argument"));
      return;
    }
    const uint8_t* data = fl_value_get_uint8_list(bytes);
    std::vector<uint8_t> copy(data, data + fl_value_get_length(bytes));
    const std::string path = StringArg(args, "path");
    RespondFromWorker(call, [path, copy]() {
      return DurableReplace(path, copy.data(), copy.size());
    });
    return;
  }
  if (method == "ensureDirectory") {
    const std::string path = StringArg(args, "path");
    const std::string base = StringArg(args, "base");
    RespondFromWorker(call, [path, base]() {
      return EnsureDirectory(path, base);
    });
    return;
  }
  if (method == "publishNoReplace") {
    const std::string staging = StringArg(args, "staging");
    const std::string destination = StringArg(args, "final");
    RespondFromWorker(call, [staging, destination]() {
      return PublishNoReplace(staging, destination);
    });
    return;
  }
  if (method == "availableBytes") {
    // Bytes an unprivileged writer may still use on the file system holding
    // `path` (statvfs f_bavail * f_frsize). Read only.
    const std::string path = StringArg(args, "path");
    struct statvfs st;
    if (path.empty()) {
      Respond(call, Code("invalid_argument"));
    } else if (statvfs(path.c_str(), &st) != 0) {
      Respond(call, Code(errno == ENOENT || errno == ENOTDIR
                             ? "invalid_argument"
                             : "io_error"));
    } else {
      Result r = Code("ok");
      const uint64_t available =
          static_cast<uint64_t>(st.f_bavail) * static_cast<uint64_t>(st.f_frsize);
      r.bytes = available > static_cast<uint64_t>(INT64_MAX)
                    ? INT64_MAX
                    : static_cast<int64_t>(available);
      Respond(call, r);
    }
    return;
  }
  if (method == "injectFault") {
#ifndef NDEBUG
    const std::string fault = StringArg(args, "fault");
    if (fault == "file_sync" || fault == "dir_sync") {
      g_fault = fault == "file_sync" ? kFileSync : kDirSync;
      Respond(call, Code("ok"));
    } else {
      Respond(call, Code("invalid_argument"));
    }
#else
    Respond(call, Code("unsupported"));
#endif
    return;
  }
  const std::string dir = StringArg(args, "dir");
  std::string a1, a2, a3;
  if (method == "admit") {
    a1 = StringArg(args, "operation");
    a2 = StringArg(args, "parent");
  } else if (method == "complete") {
    a1 = StringArg(args, "ticket");
  } else if (method == "acknowledgeInterrupted") {
    a1 = StringArg(args, "decisionDigest");
  } else {
    a1 = StringArg(args, "captureId");
    a2 = IntArg(args, "generation");
    a3 = StringArg(args, "decisionDigest");
  }
  Respond(call, Dispatch(method, dir.c_str(), a1, a2, a3));
}

}  // namespace

int reps_capture_native_call(const char* method, const char* dir,
                             const char* a1, const char* a2, const char* a3,
                             char* out, size_t out_len) {
  auto str = [](const char* s) { return std::string(s == nullptr ? "" : s); };
  Result r = method == nullptr ? Code("invalid_argument")
                               : Dispatch(method, dir, str(a1), str(a2), str(a3));
  std::string text = "code=" + r.code;
  if (!r.ticket.empty()) text += ";ticket=" + r.ticket;
  if (r.generation >= 0) text += ";generation=" + std::to_string(r.generation);
  if (r.tickets >= 0) text += ";tickets=" + std::to_string(r.tickets);
  if (r.interrupted >= 0) {
    text += ";interrupted=" + std::to_string(r.interrupted);
  }
  if (out != nullptr && out_len > 0) {
    snprintf(out, out_len, "%s", text.c_str());
  }
  return (r.code == "ok" || r.code == "held" || r.code == "pending") ? 0 : 1;
}

#define REPS_CAPTURE_PLATFORM_PLUGIN(obj)                                  \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), reps_capture_platform_plugin_get_type(), \
                              RepsCapturePlatformPlugin))

struct _RepsCapturePlatformPlugin {
  GObject parent_instance;
};

G_DEFINE_TYPE(RepsCapturePlatformPlugin, reps_capture_platform_plugin,
              g_object_get_type())

static void reps_capture_platform_plugin_class_init(
    RepsCapturePlatformPluginClass* klass) {}

static void reps_capture_platform_plugin_init(RepsCapturePlatformPlugin* self) {}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  HandleMethodCall(method_call);
}

void reps_capture_platform_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  RepsCapturePlatformPlugin* plugin = REPS_CAPTURE_PLATFORM_PLUGIN(
      g_object_new(reps_capture_platform_plugin_get_type(), nullptr));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "reps/capture", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);
  g_object_unref(plugin);
}
