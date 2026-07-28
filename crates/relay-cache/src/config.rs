// SPDX-License-Identifier: MIT

//! CLI args + env vars. Mirrors the convention used by the relay binary
//! and relay-coordinator: clap derive, every flag dual-wired to a
//! `RELAY_CACHE_*` env var, sensible production defaults so an operator
//! can run with no flags on the relay host.

use clap::Parser;

#[derive(Debug, Parser)]
#[command(
    name = "relay-cache",
    version,
    about = "Same-host in-memory read cache over public-mirror"
)]
pub struct Args {
    /// Loopback bind for the HTTP read API. Empty string disables the
    /// listener (the crate still maintains subscriptions but serves no
    /// queries — useful for soak testing the ingest path).
    #[arg(long, env = "RELAY_CACHE_BIND", default_value = "127.0.0.1:8089")]
    pub bind: String,

    /// Public-mirror HTTP+WS host (`host:port`). Used for schema fetch,
    /// `/v1/mirrors` discovery/ready-gate, and per-region WS subscribe.
    #[arg(
        long,
        env = "RELAY_CACHE_MIRROR_HOST",
        default_value = "127.0.0.1:3000"
    )]
    pub mirror_host: String,

    /// Full URL for `GET /v1/mirrors`. Defaults to
    /// `http://{mirror_host}/v1/mirrors` when empty.
    #[arg(long, env = "RELAY_CACHE_MIRRORS_URL", default_value = "")]
    pub mirrors_url: String,

    /// Database name used for the one-shot schema fetch. Any live
    /// regional DB works (schemas are shared).
    #[arg(
        long,
        env = "RELAY_CACHE_SCHEMA_DB",
        default_value = "bitcraft-live-14"
    )]
    pub schema_db: String,

    /// Soft memory ceiling in bytes. On approach: log at `warn`, flip the
    /// `/cache-health` ready flag to false, keep serving with whatever data we
    /// have. Never a load shedder — see the README "Memory policy" section.
    #[arg(
        long,
        env = "RELAY_CACHE_MEM_CEILING_BYTES",
        default_value_t = 4 * 1024 * 1024 * 1024
    )]
    pub mem_ceiling_bytes: u64,

    /// Extra ingest diagnostics: 5s heartbeats while waiting on
    /// `SubscribeApplied` (phase + elapsed), ping during that wait, and
    /// `relay_cache=debug` default filter when `RUST_LOG` is unset. Use when
    /// a region hangs mid bulk-load and info-only bookends aren't enough.
    #[arg(long, env = "RELAY_CACHE_DEBUG", default_value_t = false)]
    pub debug: bool,
}

impl Args {
    pub fn resolved_mirrors_url(&self) -> String {
        let t = self.mirrors_url.trim();
        if t.is_empty() {
            format!("http://{}/v1/mirrors", self.mirror_host.trim())
        } else {
            t.to_string()
        }
    }
}
