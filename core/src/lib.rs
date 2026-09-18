//! SmartSwitch core: activation history + Jev-backed next-app prediction.
//! Exposed to Swift through the C ABI at the bottom (`ss_*`).

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_EVENTS: usize = 200;
const MAX_CANDIDATES: usize = 10;
const CONTEXT_EVENTS: usize = 30;
const API_URL: &str = "https://api.typesafe.ai/v1/systemone";
const MODEL: &str = "jev-latest";

/// How an activation happened: "cmd_tab" (user pressed ⌘Tab), "smart" (SmartSwitch did it), "other".
pub const SRC_CMD_TAB: &str = "cmd_tab";
pub const SRC_SMART: &str = "smart";
const MAX_MANUAL: usize = 10;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Event {
    pub id: String,
    pub name: String,
    pub ts: u64,
    #[serde(default)]
    pub source: String,
}

#[derive(Clone, Default, Debug, Serialize, Deserialize)]
pub struct History {
    pub events: Vec<Event>,
}

/// One candidate app: its newest event plus when the user last left it.
#[derive(Debug)]
pub struct Candidate<'a> {
    pub event: &'a Event,
    pub left_at: u64,
}

impl History {
    pub fn record(&mut self, id: &str, name: &str, ts: u64, source: &str) {
        if self.events.last().is_some_and(|e| e.id == id) {
            return; // re-activation of the same app carries no signal
        }
        self.events.push(Event { id: id.into(), name: name.into(), ts, source: source.into() });
        if self.events.len() > MAX_EVENTS {
            let drop = self.events.len() - MAX_EVENTS;
            self.events.drain(..drop);
        }
    }

    pub fn current(&self) -> Option<&Event> {
        self.events.last()
    }

    /// Most recently used distinct apps, newest first, excluding the frontmost.
    /// `running` empty = no filter.
    pub fn candidates(&self, running: &[String], now: u64) -> Vec<Candidate<'_>> {
        let mut seen: HashSet<&str> = HashSet::new();
        if let Some(cur) = self.current() {
            seen.insert(&cur.id);
        }
        let mut out = Vec::new();
        for (i, e) in self.events.iter().enumerate().rev() {
            let running_ok = running.is_empty() || running.iter().any(|r| r == &e.id);
            if running_ok && seen.insert(&e.id) {
                let left_at = self.events.get(i + 1).map_or(now, |n| n.ts);
                out.push(Candidate { event: e, left_at });
                if out.len() == MAX_CANDIDATES {
                    break;
                }
            }
        }
        out
    }
}

#[derive(Serialize, Default, Debug)]
pub struct Outcome {
    pub id: Option<String>,
    pub name: Option<String>,
    /// "jev" | "last_used" | "only_candidate" | "none"
    pub via: &'static str,
    pub confidence: Option<f64>,
    pub probability: Option<f64>,
    pub error: Option<String>,
    pub candidates: usize,
    pub model: Option<String>,
    pub elapsed_ms: u64,
    /// Exact Jev request body and response, for inspection in the menu.
    pub request: Option<Value>,
    pub response: Option<Value>,
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

fn human(secs: u64) -> String {
    match secs {
        s if s < 60 => format!("{s}s"),
        s if s < 3600 => format!("{}m", s / 60),
        s if s < 86400 => format!("{}h", s / 3600),
        s => format!("{}d", s / 86400),
    }
}

/// Local wall clock "HH:MM" and weekday for a unix timestamp.
fn local_clock(ts: u64) -> (String, &'static str) {
    const DAYS: [&str; 7] = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    let t = ts as libc::time_t;
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&t, &mut tm) };
    (format!("{:02}:{:02}", tm.tm_hour, tm.tm_min), DAYS[tm.tm_wday.clamp(0, 6) as usize])
}

/// Build the Jev request and the map from option key back to bundle id.
pub fn build_request(hist: &History, cands: &[Candidate<'_>], now: u64) -> (Value, HashMap<String, String>) {
    let evs = &hist.events;
    let start = evs.len().saturating_sub(CONTEXT_EVENTS);
    let recent: Vec<Value> = evs
        .iter()
        .enumerate()
        .skip(start)
        .map(|(i, e)| {
            let end = evs.get(i + 1).map_or(now, |n| n.ts);
            json!({
                "app": e.name,
                "switched_at": local_clock(e.ts).0,
                "stayed_seconds": end.saturating_sub(e.ts),
            })
        })
        .collect();

    // Switches the user made deliberately with ⌘Tab (never SmartSwitch's own), newest last.
    let mut manual: Vec<Value> = evs
        .iter()
        .enumerate()
        .rev()
        .filter(|(_, e)| e.source == SRC_CMD_TAB)
        .take(MAX_MANUAL)
        .map(|(i, e)| {
            json!({
                "at": local_clock(e.ts).0,
                "from": i.checked_sub(1).map(|p| evs[p].name.as_str()).unwrap_or(""),
                "to": e.name,
            })
        })
        .collect();
    manual.reverse();

    let (clock, weekday) = local_clock(now);
    let state = json!({
        "now": format!("{weekday} {clock}"),
        "foreground_app": hist.current().map(|e| e.name.as_str()).unwrap_or(""),
        "recent_switches": recent,
        "recent_manual_cmd_tab_switches": manual,
    });

    let mut criteria = serde_json::Map::new();
    let mut key_to_id = HashMap::new();
    for c in cands {
        let e = c.event;
        let mut key = e.name.clone();
        if key_to_id.contains_key(&key) {
            key = format!("{} ({})", e.name, e.id);
        }
        let uses: Vec<&Event> = evs.iter().filter(|x| x.id == e.id && now.saturating_sub(x.ts) < 3600).collect();
        let stays: Vec<u64> = evs
            .iter()
            .enumerate()
            .filter(|(_, x)| x.id == e.id)
            .map(|(i, x)| evs.get(i + 1).map_or(now, |n| n.ts).saturating_sub(x.ts))
            .collect();
        let typical = stays.iter().sum::<u64>() / stays.len().max(1) as u64;
        criteria.insert(
            key.clone(),
            json!(format!(
                "last used {} ago; {} activations in the last hour; typical stay {}",
                human(now.saturating_sub(c.left_at)),
                uses.len(),
                human(typical)
            )),
        );
        key_to_id.insert(key, e.id.clone());
    }

    let body = json!({
        "state": state,
        "model": MODEL,
        "questions": {
            "next_app": {
                "type": "choice",
                "instructions": "The user just pressed the app-switch hotkey. Which application are they most likely switching to next? Weigh their recent switching history, how long they stay in each app, the time of day, and especially the deliberate cmd-tab switches they made themselves (recent_manual_cmd_tab_switches).",
                "criteria": criteria,
            }
        }
    });
    (body, key_to_id)
}

fn agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| ureq::AgentBuilder::new().build())
}

const MODELS_URL: &str = "https://api.typesafe.ai/v1/models";
const WARM_INTERVAL: Duration = Duration::from_secs(30); // server keeps idle connections ≥45 s (measured)
const WARM_IDLE_LIMIT_SECS: u64 = 600;
static LAST_ACTIVITY: AtomicU64 = AtomicU64::new(0);

fn touch_activity() {
    LAST_ACTIVITY.store(now_secs(), Ordering::Relaxed);
}

/// A cold connect+TLS to the API costs ~0.4 s of the 1 s budget, so keep one pooled
/// connection warm while the user is active. Any completed round-trip (even a 401) parks
/// the connection in ureq's pool; no API key or tokens are spent.
fn start_keepalive() {
    std::thread::spawn(|| loop {
        if now_secs().saturating_sub(LAST_ACTIVITY.load(Ordering::Relaxed)) <= WARM_IDLE_LIMIT_SECS {
            match agent().get(MODELS_URL).timeout(Duration::from_secs(5)).call() {
                Ok(r) => drop(r.into_string()),
                Err(ureq::Error::Status(_, r)) => drop(r.into_string()),
                Err(_) => {}
            }
        }
        std::thread::sleep(WARM_INTERVAL);
    });
}

/// Hard deadline: ureq's own timeout is per-I/O-op and has been seen to report late,
/// so the request runs on a helper thread and we stop waiting at `timeout` regardless.
fn ask_jev(api_key: &str, body: &Value, timeout: Duration) -> Result<Value, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    let (key, body) = (api_key.to_owned(), body.clone());
    std::thread::spawn(move || {
        let _ = tx.send(send_request(&key, &body, timeout));
    });
    rx.recv_timeout(timeout)
        .unwrap_or_else(|_| Err(format!("timed out after {} ms", timeout.as_millis())))
}

fn send_request(api_key: &str, body: &Value, timeout: Duration) -> Result<Value, String> {
    let resp = agent()
        .post(API_URL)
        .set("Authorization", &format!("Bearer {api_key}"))
        .timeout(timeout)
        .send_json(body);
    match resp {
        Ok(r) => r.into_json::<Value>().map_err(|e| format!("bad json: {e}")),
        Err(ureq::Error::Status(code, r)) => {
            Err(format!("HTTP {code}: {}", r.into_string().unwrap_or_default().chars().take(200).collect::<String>()))
        }
        Err(e) => Err(e.to_string()),
    }
}

/// Decide where to switch. Never fails: falls back to the most recently used candidate.
pub fn predict(hist: &History, api_key: &str, timeout: Duration, running: &[String]) -> Outcome {
    let started = std::time::Instant::now();
    let mut out = decide(hist, api_key, timeout, running);
    out.elapsed_ms = started.elapsed().as_millis() as u64;
    out
}

fn decide(hist: &History, api_key: &str, timeout: Duration, running: &[String]) -> Outcome {
    let now = now_secs();
    let cands = hist.candidates(running, now);
    let mut out = Outcome { candidates: cands.len(), via: "none", ..Default::default() };
    let Some(first) = cands.first() else {
        out.error = Some("no candidates".into());
        return out;
    };
    let fallback = |mut out: Outcome, err: String| {
        out.id = Some(first.event.id.clone());
        out.name = Some(first.event.name.clone());
        out.via = "last_used";
        out.error = Some(err);
        out
    };
    if cands.len() == 1 {
        out.id = Some(first.event.id.clone());
        out.name = Some(first.event.name.clone());
        out.via = "only_candidate";
        return out;
    }
    if api_key.is_empty() {
        return fallback(out, "no API key".into());
    }

    let (body, key_to_id) = build_request(hist, &cands, now);
    out.request = Some(body.clone());
    let answer = match ask_jev(api_key, &body, timeout) {
        Ok(v) => v,
        Err(e) => return fallback(out, e),
    };
    out.model = answer["model"].as_str().map(String::from);
    out.response = Some(answer.clone());
    let a = &answer["answers"]["next_app"];
    let Some(choice) = a["choice"].as_str() else {
        return fallback(out, "no choice in answer".into());
    };
    let Some(id) = key_to_id.get(choice) else {
        return fallback(out, format!("unknown choice {choice}"));
    };
    out.id = Some(id.clone());
    out.name = cands.iter().find(|c| &c.event.id == id).map(|c| c.event.name.clone());
    out.via = "jev";
    out.confidence = a["confidence"].as_f64();
    out.probability = a["probabilities"][choice].as_f64();
    out
}

// ---------------------------------------------------------------- C ABI

struct Store {
    path: PathBuf,
    hist: History,
}

static STORE: OnceLock<Mutex<Store>> = OnceLock::new();

fn cstr(p: *const c_char) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned()
}

/// Load history from `path` (created on first record).
#[no_mangle]
pub extern "C" fn ss_init(path: *const c_char) {
    let path = PathBuf::from(cstr(path));
    let hist = std::fs::read(&path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default();
    if STORE.set(Mutex::new(Store { path, hist })).is_ok() {
        touch_activity();
        start_keepalive();
    }
}

/// `source`: "cmd_tab" | "smart" | "other".
#[no_mangle]
pub extern "C" fn ss_record(bundle_id: *const c_char, name: *const c_char, source: *const c_char) {
    let Some(store) = STORE.get() else { return };
    touch_activity();
    let mut s = store.lock().unwrap_or_else(|e| e.into_inner());
    s.hist.record(&cstr(bundle_id), &cstr(name), now_secs(), &cstr(source));
    if let Some(dir) = s.path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    // ponytail: rewrite whole file per activation (~20 KB); debounce if it ever shows up in a profile
    let _ = std::fs::write(&s.path, serde_json::to_vec(&s.hist).unwrap_or_default());
}

/// Returns a JSON `Outcome`; free with `ss_free`. `running_json` is a JSON array of bundle ids.
#[no_mangle]
pub extern "C" fn ss_predict(api_key: *const c_char, timeout_ms: u32, running_json: *const c_char) -> *mut c_char {
    let hist = STORE
        .get()
        .map(|s| s.lock().unwrap_or_else(|e| e.into_inner()).hist.clone())
        .unwrap_or_default();
    let running: Vec<String> = serde_json::from_str(&cstr(running_json)).unwrap_or_default();
    touch_activity();
    let out = predict(&hist, &cstr(api_key), Duration::from_millis(timeout_ms as u64), &running);
    CString::new(serde_json::to_string(&out).unwrap_or_default())
        .map_or(std::ptr::null_mut(), CString::into_raw)
}

#[no_mangle]
pub extern "C" fn ss_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hist(seq: &[(&str, u64)]) -> History {
        let mut h = History::default();
        for (id, ts) in seq {
            h.record(id, &id.to_uppercase(), *ts, "other");
        }
        h
    }

    #[test]
    fn request_lists_only_cmd_tab_switches_with_from_to() {
        let mut h = hist(&[("a", 1), ("b", 2)]);
        h.record("c", "C", 3, SRC_CMD_TAB);
        h.record("a", "A", 4, SRC_SMART);
        h.record("b", "B", 5, SRC_CMD_TAB);
        let cands = h.candidates(&[], 10);
        let (body, _) = build_request(&h, &cands, 10);
        let manual = body["state"]["recent_manual_cmd_tab_switches"].as_array().unwrap();
        assert_eq!(manual.len(), 2);
        assert_eq!(manual[0]["from"], "B");
        assert_eq!(manual[0]["to"], "C");
        assert_eq!(manual[1]["from"], "A");
        assert_eq!(manual[1]["to"], "B");
    }

    #[test]
    fn record_dedupes_consecutive_and_caps() {
        let mut h = hist(&[("a", 1), ("a", 2), ("b", 3)]);
        assert_eq!(h.events.len(), 2);
        for i in 0..(MAX_EVENTS as u64 * 2) {
            h.record(if i % 2 == 0 { "x" } else { "y" }, "", 100 + i, "other");
        }
        assert_eq!(h.events.len(), MAX_EVENTS);
    }

    #[test]
    fn candidates_exclude_current_dedupe_filter_and_order() {
        let h = hist(&[("a", 1), ("b", 2), ("c", 3), ("a", 4), ("d", 5)]);
        let ids: Vec<&str> = h.candidates(&[], 10).iter().map(|c| c.event.id.as_str()).collect();
        assert_eq!(ids, ["a", "c", "b"]); // d is current; a newest, then c, b
        let running = vec!["b".to_string(), "d".to_string()];
        let ids: Vec<&str> = h.candidates(&running, 10).iter().map(|c| c.event.id.as_str()).collect();
        assert_eq!(ids, ["b"]);
        assert_eq!(h.candidates(&[], 10)[0].left_at, 5); // user left "a" when "d" was activated
    }

    #[test]
    fn predict_without_key_falls_back_to_last_used() {
        let h = hist(&[("a", 1), ("b", 2), ("c", 3)]);
        let o = predict(&h, "", Duration::from_millis(10), &[]);
        assert_eq!(o.id.as_deref(), Some("b"));
        assert_eq!(o.via, "last_used");
        let o = predict(&hist(&[("a", 1), ("b", 2)]), "", Duration::from_millis(10), &[]);
        assert_eq!(o.via, "only_candidate");
        assert_eq!(predict(&hist(&[("a", 1)]), "", Duration::from_millis(10), &[]).via, "none");
    }

    #[test]
    fn request_has_choice_per_candidate() {
        let h = hist(&[("a", 1), ("b", 2), ("c", 3)]);
        let cands = h.candidates(&[], 10);
        let (body, map) = build_request(&h, &cands, 10);
        let crit = body["questions"]["next_app"]["criteria"].as_object().unwrap();
        assert_eq!(crit.len(), 2);
        assert_eq!(map["B"], "b");
        assert_eq!(body["state"]["foreground_app"], "C");
        assert_eq!(body["state"]["recent_switches"].as_array().unwrap().len(), 3);
    }
}
