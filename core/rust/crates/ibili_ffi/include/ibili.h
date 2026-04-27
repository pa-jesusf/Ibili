#ifndef IBILI_H
#define IBILI_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IbiliCore IbiliCore;

/// Create a core handle. Returns NULL on failure.
IbiliCore* ibili_core_new(const char* config_json);

/// Destroy a core handle.
void ibili_core_free(IbiliCore* core);

/// Free a string previously returned by an ibili_* function.
void ibili_string_free(char* s);

/// Dispatch a JSON-encoded method call. The returned string is a
/// freshly-allocated UTF-8 JSON document of the form:
///   { "ok": true, "data": <value> }
/// or
///   { "ok": false, "error": { "category": "...", "message": "...", "code": <int|null> } }
///
/// The caller MUST free the returned pointer with `ibili_string_free`.
char* ibili_call(IbiliCore* core, const char* method, const char* args_json);

#ifdef __cplusplus
}
#endif

#endif // IBILI_H
