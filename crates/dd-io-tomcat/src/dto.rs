//! Rust mirror of the Tomcat backend DTOs.
//! Field names use snake_case to match the JSON keys emitted by DdDtoMapper.

use serde::Deserialize;

// ─── FFL list ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct FflItemDto {
    pub id: String,
    pub label: String,
    pub sample_rate_hz: f64,
}

// ─── Channel search ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct ChannelPageDto {
    pub total: usize,
    pub offset: usize,
    pub limit: usize,
    pub channels: Vec<ChannelItemDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ChannelItemDto {
    pub name: String,
    pub display_name: String,
    pub unit: Option<String>,
    pub category: Option<String>,
    pub sample_rate_hz: f64,
}

// ─── Query request ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, serde::Serialize)]
pub struct QueryRequestDto {
    pub channels: Vec<String>,
    pub ffl_source: String,
    pub start_utc_ms: i64,
    pub end_utc_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_buckets: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor_start_utc_ms: Option<i64>,
}

// ─── Query response ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct QueryResponseDto {
    pub meta: QueryMetaDto,
    pub series: Vec<serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct QueryMetaDto {
    pub channel_count: usize,
    pub ffl_source: String,
    pub resolved_start_utc_ms: i64,
    pub resolved_start_gps: i64,
    pub requested_end_utc_ms: i64,
    pub loaded_end_utc_ms: i64,
    pub next_chunk_start_utc_ms: Option<i64>,
    pub history_complete: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RawSeriesDto {
    pub channel: String,
    pub display_name: Option<String>,
    pub unit: Option<String>,
    pub ffl_source: Option<String>,
    pub start_utc_ms: i64,
    pub step_ns: i64,
    pub values: Vec<Option<f64>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BucketedSeriesDto {
    pub channel: String,
    pub display_name: Option<String>,
    pub unit: Option<String>,
    pub ffl_source: Option<String>,
    pub start_utc_ms: i64,
    pub bucket_ns: i64,
    pub min_values: Vec<Option<f64>>,
    pub max_values: Vec<Option<f64>>,
}

// ─── Live request ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, serde::Serialize)]
pub struct LiveRequestDto {
    pub channels: Vec<String>,
    pub after_utc_ms: i64,
}

// ─── Live response ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Deserialize)]
pub struct LiveResponseDto {
    pub server_now_utc_ms: i64,
    pub series: Vec<LiveSeriesDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LiveSeriesDto {
    pub channel: String,
    pub start_utc_ms: i64,
    pub step_ms: i32,
    pub values: Vec<Option<f64>>,
}
