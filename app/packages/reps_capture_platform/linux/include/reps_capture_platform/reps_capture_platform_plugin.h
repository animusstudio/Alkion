#ifndef FLUTTER_PLUGIN_REPS_CAPTURE_PLATFORM_PLUGIN_H_
#define FLUTTER_PLUGIN_REPS_CAPTURE_PLATFORM_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>
#include <stddef.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

typedef struct _RepsCapturePlatformPlugin RepsCapturePlatformPlugin;
typedef struct {
  GObjectClass parent_class;
} RepsCapturePlatformPluginClass;

FLUTTER_PLUGIN_EXPORT GType reps_capture_platform_plugin_get_type();

FLUTTER_PLUGIN_EXPORT void reps_capture_platform_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

// The native source-write gate behind the `reps/capture` channel, as a plain
// C entry point. The channel handler calls the same functions; the entry
// point lets a second OS process drive the very same code (qualification
// tests load this library into a helper process).
//
// `method` is one of admit(dir, operation, parent), complete(dir, ticket),
// prepare(dir, capture), drain(dir, capture, generation),
// release(dir, capture, generation, decision) or verifyHold(dir, capture,
// generation); unused arguments may be NULL. The result is written to `out`
// as `code=<code>[;ticket=<id>][;generation=<n>][;tickets=<n>]`. Returns 0
// when the code is `ok`, `held` or `pending`, and 1 otherwise.
FLUTTER_PLUGIN_EXPORT int reps_capture_native_call(const char* method,
                                                   const char* dir,
                                                   const char* a1,
                                                   const char* a2,
                                                   const char* a3, char* out,
                                                   size_t out_len);

G_END_DECLS

#endif  // FLUTTER_PLUGIN_REPS_CAPTURE_PLATFORM_PLUGIN_H_
