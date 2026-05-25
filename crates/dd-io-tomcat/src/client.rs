//! Thin HTTP client wrapper around `ureq` for the DataDisplay Tomcat backend.

use dd_backend::{BackendError, BackendResult};
use serde::de::DeserializeOwned;
use serde::Serialize;

pub struct TomcatClient {
    base_url: String,
    agent: ureq::Agent,
}

impl TomcatClient {
    pub fn new(base_url: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into().trim_end_matches('/').to_string(),
            agent: ureq::AgentBuilder::new()
                .timeout_connect(std::time::Duration::from_secs(5))
                .timeout_read(std::time::Duration::from_secs(60))
                .build(),
        }
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub fn get_json<T: DeserializeOwned>(&self, path: &str) -> BackendResult<T> {
        let url = format!("{}{}", self.base_url, path);
        let response = self
            .agent
            .get(&url)
            .call()
            .map_err(|e| BackendError::io(format!("GET {url}: {e}")))?;
        response
            .into_json::<T>()
            .map_err(|e| BackendError::io(format!("failed to parse JSON from GET {url}: {e}")))
    }

    pub fn post_json<B: Serialize, T: DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> BackendResult<T> {
        let url = format!("{}{}", self.base_url, path);
        let response = self
            .agent
            .post(&url)
            .set("Content-Type", "application/json")
            .send_json(serde_json::to_value(body).map_err(|e| {
                BackendError::internal(format!("failed to serialise request for {url}: {e}"))
            })?)
            .map_err(|e| BackendError::io(format!("POST {url}: {e}")))?;
        response
            .into_json::<T>()
            .map_err(|e| BackendError::io(format!("failed to parse JSON from POST {url}: {e}")))
    }

    /// GET with a single query parameter.
    pub fn get_json_with_params<T: DeserializeOwned>(
        &self,
        path: &str,
        params: &[(&str, &str)],
    ) -> BackendResult<T> {
        let query: String = params
            .iter()
            .map(|(k, v)| format!("{}={}", k, urlenccode(v)))
            .collect::<Vec<_>>()
            .join("&");
        let sep = if path.contains('?') { '&' } else { '?' };
        let path_with_query = format!("{path}{sep}{query}");
        self.get_json(&path_with_query)
    }
}

fn urlenccode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for byte in s.bytes() {
        let c = byte as char;
        if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '~') {
            out.push(c);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}
