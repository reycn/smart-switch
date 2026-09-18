#ifndef SS_CORE_H
#define SS_CORE_H
#include <stdint.h>

/// Load history from `path` (JSON; created on first record).
void ss_init(const char *path);
/// Record an app activation. `source`: "cmd_tab" (user pressed ⌘Tab), "smart" (SmartSwitch did it), "other".
void ss_record(const char *bundle_id, const char *name, const char *source);
/// Decide the switch target. Returns JSON:
/// {"id","name","via":"jev|last_used|only_candidate|none","confidence","probability","error","candidates",
///  "model","elapsed_ms","request":{…exact Jev body…},"response":{…exact Jev reply…}}
/// `running_json` is a JSON array of running bundle ids used to filter candidates. Free with ss_free.
char *ss_predict(const char *api_key, uint32_t timeout_ms, const char *running_json);
void ss_free(char *s);

#endif
