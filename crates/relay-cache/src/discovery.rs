// SPDX-License-Identifier: MIT

//! Discover regional mirrors from public-mirror `GET /v1/mirrors`.
//!
//! Skips `bitcraft-live-global` (cross-region reference data, out of
//! scope for the regional gameplay tables the cache serves).

use anyhow::{bail, Context, Result};
use serde::Deserialize;

/// One regional mirror on the local public-mirror process.
#[derive(Debug, Clone)]
pub struct DiscoveredRegion {
    pub region: u32,
    pub database: String,
}

#[derive(Debug, Deserialize)]
struct MirrorsResponse {
    mirrors: Vec<MirrorRow>,
}

#[derive(Debug, Deserialize)]
struct MirrorRow {
    database: String,
    #[serde(default)]
    connectivity: Option<String>,
    #[serde(default)]
    tables_live: Option<u32>,
    #[serde(default)]
    tables_total: Option<u32>,
}

/// Poll `mirrors_url` and return regional (`bitcraft-live-N`) databases.
pub async fn discover_regions(mirrors_url: &str) -> Result<Vec<DiscoveredRegion>> {
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(4))
        .build()
        .context("build mirrors HTTP client")?;
    let resp = http
        .get(mirrors_url)
        .send()
        .await
        .with_context(|| format!("GET {mirrors_url}"))?;
    if !resp.status().is_success() {
        bail!("GET {mirrors_url} returned {}", resp.status());
    }
    let body: MirrorsResponse = resp
        .json()
        .await
        .with_context(|| format!("decode {mirrors_url}"))?;

    let mut out = Vec::new();
    for row in body.mirrors {
        if row.database == "bitcraft-live-global" || row.database.ends_with("-global") {
            continue;
        }
        let Some(region) = parse_region_number(&row.database) else {
            tracing::warn!(
                target: "relay_cache::discovery",
                database = %row.database,
                "skipping mirror: cannot parse region number"
            );
            continue;
        };
        out.push(DiscoveredRegion {
            region,
            database: row.database,
        });
    }
    out.sort_by_key(|r| r.region);
    Ok(out)
}

/// True when this mirror row is ready for cache subscribe.
pub fn mirror_row_ready(connectivity: Option<&str>, tables_live: Option<u32>, tables_total: Option<u32>) -> bool {
    connectivity == Some("live")
        && tables_live.is_some()
        && tables_live == tables_total
}

/// Poll until the named database is `live` with full table sync.
///
/// Returns `Ok(true)` when ready, `Ok(false)` on shutdown.
pub async fn wait_for_mirror_ready(
    mirrors_url: &str,
    database: &str,
    http: &reqwest::Client,
    shutdown: &mut std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>,
) -> Result<bool> {
    let mut backoff = std::time::Duration::from_secs(2);
    let max_backoff = std::time::Duration::from_secs(30);
    loop {
        match http.get(mirrors_url).send().await {
            Ok(resp) if resp.status().is_success() => {
                if let Ok(body) = resp.json::<MirrorsResponse>().await {
                    if let Some(row) = body.mirrors.iter().find(|m| m.database == database) {
                        if mirror_row_ready(
                            row.connectivity.as_deref(),
                            row.tables_live,
                            row.tables_total,
                        ) {
                            return Ok(true);
                        }
                    }
                }
            }
            _ => {}
        }
        tokio::select! {
            biased;
            _ = &mut *shutdown => return Ok(false),
            _ = tokio::time::sleep(backoff) => {}
        }
        backoff = (backoff * 2).min(max_backoff);
    }
}

/// `"bitcraft-live-14"` → `Some(14)`.
fn parse_region_number(name: &str) -> Option<u32> {
    name.strip_prefix("bitcraft-live-")?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_region_from_database_name() {
        assert_eq!(parse_region_number("bitcraft-live-14"), Some(14));
        assert_eq!(parse_region_number("bitcraft-live-3"), Some(3));
        assert_eq!(parse_region_number("bitcraft-live-global"), None);
        assert_eq!(parse_region_number("bitcraft-live-"), None);
        assert_eq!(parse_region_number("relay-mirror-bc14"), None);
    }

    #[test]
    fn ready_requires_live_and_full_tables() {
        assert!(mirror_row_ready(Some("live"), Some(12), Some(12)));
        assert!(!mirror_row_ready(Some("live"), Some(11), Some(12)));
        assert!(!mirror_row_ready(Some("subscribing"), Some(12), Some(12)));
        assert!(!mirror_row_ready(Some("disconnected"), Some(0), Some(12)));
    }
}
