//! Live check against the Jev API: `TYPESAFE_API_KEY=… cargo run --example predict [history.json]`
use ss_core::{predict, History};
use std::time::Duration;

fn main() {
    let key = std::env::var("TYPESAFE_API_KEY").unwrap_or_default();
    let hist: History = std::env::args()
        .nth(1)
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_else(|| {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs();
            let mut h = History::default();
            for (i, (id, name)) in [
                ("com.apple.Safari", "Safari"),
                ("com.apple.dt.Xcode", "Xcode"),
                ("com.apple.Terminal", "Terminal"),
                ("com.apple.dt.Xcode", "Xcode"),
                ("com.apple.Safari", "Safari"),
                ("com.apple.dt.Xcode", "Xcode"),
                ("com.apple.Terminal", "Terminal"),
                ("com.apple.dt.Xcode", "Xcode"),
            ]
            .iter()
            .enumerate()
            {
                h.record(id, name, now - 600 + i as u64 * 60, if i % 2 == 0 { "cmd_tab" } else { "other" });
            }
            h
        });
    let t = std::time::Instant::now();
    let out = predict(&hist, &key, Duration::from_millis(std::env::var("SS_TIMEOUT_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(1000)), &[]);
    println!("{} in {:?}", serde_json::to_string_pretty(&out).unwrap(), t.elapsed());
    if let Ok(s) = std::env::var("SS_REPEAT_SECS").map(|v| v.parse::<u64>().unwrap_or(0)) {
        for _ in 0..3 { std::thread::sleep(Duration::from_secs(s)); let t = std::time::Instant::now(); let o = predict(&hist, &key, Duration::from_millis(1000), &[]); println!("after {s}s: via={} err={:?} in {:?}", o.via, o.error, t.elapsed()); }
    }
}
// keep-alive probe: SS_REPEAT_SECS=30 → second call after a pause, in the same process
