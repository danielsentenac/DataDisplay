//! Tomcat FFL DataSource — wraps the `/api/v1/datadisplay/...` endpoints.

use std::collections::BTreeMap;
use std::sync::Arc;

use dd_backend::{
    Aggregation, BackendError, BackendResult, CatalogPage, CatalogQuery, DataSource,
    DataSourceFactory, LiveDataSource, LiveSubscription, ReadQuery, SourceCapabilities,
    SourceTarget, StreamDescriptor, StreamKind, SubscribeRequest,
};
use dd_domain::{ChannelDescriptor, DataBlock, Series1D, TimeAxis};

use crate::client::TomcatClient;
use crate::dto::{
    BucketedSeriesDto, ChannelPageDto, LiveRequestDto, LiveResponseDto, LiveSeriesDto,
    QueryRequestDto, RawSeriesDto,
};

// ─── URI format ───────────────────────────────────────────────────────────────
//
// tomcat://<host>:<port>[/base]?ffl=<ffl_id>
//
// Examples:
//   tomcat://olserver134:8080/datadisplay-tomcat-backend?ffl=trend
//   tomcat://localhost:8080?ffl=50Hz
//   tomcat://olserver134:8080?ffl=raw

struct TomcatFflTarget {
    base_url: String,
    ffl_id: String,
}

impl TomcatFflTarget {
    fn parse(target: &SourceTarget) -> BackendResult<Self> {
        let location = target
            .location()
            .ok_or_else(|| BackendError::invalid_query("tomcat:// URI has no host"))?;

        let (host_path, query) = match location.split_once('?') {
            Some((h, q)) => (h, q),
            None => (location, ""),
        };

        let mut ffl_id = String::new();
        for pair in query.split('&').filter(|p| !p.is_empty()) {
            if let Some(("ffl", value)) = pair.split_once('=') {
                ffl_id = value.trim().to_string();
            }
        }
        if ffl_id.is_empty() {
            return Err(BackendError::invalid_query(
                "tomcat:// URI requires a `?ffl=<id>` query parameter",
            ));
        }

        let base_url = format!("http://{}", host_path.trim_end_matches('/'));
        Ok(Self { base_url, ffl_id })
    }
}

// ─── Factory ──────────────────────────────────────────────────────────────────

#[derive(Default, Clone, Debug)]
pub struct TomcatFflFactory;

impl TomcatFflFactory {
    pub fn new() -> Self {
        Self
    }
}

impl DataSourceFactory for TomcatFflFactory {
    fn scheme(&self) -> &str {
        "tomcat"
    }

    fn open(&self, target: &SourceTarget) -> BackendResult<Box<dyn DataSource>> {
        let parsed = TomcatFflTarget::parse(target)?;
        Ok(Box::new(TomcatFflSource {
            uri: target.uri.clone(),
            client: Arc::new(TomcatClient::new(&parsed.base_url)),
            ffl_id: parsed.ffl_id,
        }))
    }
}

// ─── Source ───────────────────────────────────────────────────────────────────

struct TomcatFflSource {
    uri: String,
    client: Arc<TomcatClient>,
    ffl_id: String,
}

impl DataSource for TomcatFflSource {
    fn source_name(&self) -> &str {
        &self.uri
    }

    fn capabilities(&self) -> SourceCapabilities {
        SourceCapabilities {
            catalog_search: true,
            live_subscriptions: true,
            volume3d: false,
            metadata_write: false,
            batch_read: false,
        }
    }

    fn as_live(&self) -> Option<&dyn LiveDataSource> {
        Some(self)
    }

    fn catalog(&self, query: &CatalogQuery) -> BackendResult<CatalogPage> {
        let q = query.text.as_deref().unwrap_or("");
        let limit = query.limit.unwrap_or(100).to_string();
        let offset = query.offset.to_string();
        let params: Vec<(&str, &str)> = vec![
            ("q", q),
            ("ffl", &self.ffl_id),
            ("limit", &limit),
            ("offset", &offset),
        ];
        let page: ChannelPageDto = self.client.get_json_with_params(
            "/api/v1/datadisplay/channels/search",
            &params,
        )?;

        let streams = page
            .channels
            .into_iter()
            .map(|ch| {
                let mut channel = ChannelDescriptor::new(&ch.name, &ch.display_name);
                channel.unit = ch.unit;
                channel.sample_rate_hz = Some(ch.sample_rate_hz);
                if let Some(cat) = ch.category {
                    channel.metadata.insert("category".to_string(), cat);
                }
                channel.metadata.insert("ffl_source".to_string(), self.ffl_id.clone());
                StreamDescriptor {
                    channel,
                    kind: StreamKind::Series1D,
                    sample_shape: Vec::new(),
                    tags: vec![format!("ffl:{}", self.ffl_id)],
                    extra: BTreeMap::new(),
                }
            })
            .collect();

        Ok(CatalogPage {
            total_count: page.total,
            streams,
        })
    }

    fn read(&self, query: &ReadQuery) -> BackendResult<DataBlock> {
        query.validate()?;

        let start_utc_ms = query.time_range.start_ns / 1_000_000;
        let end_utc_ms = query.time_range.end_ns / 1_000_000;

        let target_buckets = match &query.resolution_hint {
            Some(hint) if hint.max_points > 0 && query.aggregation == Aggregation::MinMax => {
                Some(hint.max_points as u32)
            }
            _ => None,
        };

        let request = QueryRequestDto {
            channels: vec![query.channel_id.clone()],
            ffl_source: self.ffl_id.clone(),
            start_utc_ms,
            end_utc_ms,
            target_buckets,
            cursor_start_utc_ms: None,
        };

        let response: crate::dto::QueryResponseDto =
            self.client.post_json("/api/v1/datadisplay/plots/query", &request)?;

        let series_value = response
            .series
            .into_iter()
            .next()
            .ok_or_else(|| BackendError::not_found(format!("channel `{}` returned no data", query.channel_id)))?;

        parse_series_block(series_value)
    }
}

fn parse_series_block(value: serde_json::Value) -> BackendResult<DataBlock> {
    let mode = value
        .get("sampling_mode")
        .and_then(|v| v.as_str())
        .unwrap_or("raw");

    match mode {
        "raw" => {
            let dto: RawSeriesDto = serde_json::from_value(value)
                .map_err(|e| BackendError::io(format!("failed to parse raw series: {e}")))?;
            raw_series_to_block(dto)
        }
        "minmax_bucket" => {
            let dto: BucketedSeriesDto = serde_json::from_value(value)
                .map_err(|e| BackendError::io(format!("failed to parse bucketed series: {e}")))?;
            bucketed_series_to_block(dto)
        }
        other => Err(BackendError::internal(format!(
            "unknown sampling_mode `{other}` in Tomcat response"
        ))),
    }
}

fn raw_series_to_block(dto: RawSeriesDto) -> BackendResult<DataBlock> {
    let values: Vec<f64> = dto.values.into_iter().map(|v| v.unwrap_or(f64::NAN)).collect();
    let len = values.len();
    let mut channel = ChannelDescriptor::new(&dto.channel, dto.display_name.as_deref().unwrap_or(&dto.channel));
    channel.unit = dto.unit;
    if let Some(src) = dto.ffl_source {
        channel.metadata.insert("ffl_source".to_string(), src);
    }
    let sample_period_ns = dto.step_ns.max(1);
    let start_ns = dto.start_utc_ms * 1_000_000;
    Ok(DataBlock::Series1D(Series1D {
        channel,
        axis: TimeAxis::Regular { start_ns, sample_period_ns, len },
        values,
        metadata: BTreeMap::new(),
    }))
}

impl LiveDataSource for TomcatFflSource {
    fn subscribe(
        &self,
        request: SubscribeRequest,
    ) -> BackendResult<Box<dyn LiveSubscription>> {
        let channel = request.channel_id.trim();
        if channel.is_empty() {
            return Err(BackendError::invalid_query(
                "live subscription requires a non-empty channel_id",
            ));
        }
        let cursor_utc_ms = match request.time_range {
            Some(range) if range.start_ns > 0 => range.start_ns / 1_000_000,
            _ => {
                use std::time::{SystemTime, UNIX_EPOCH};
                let now_ms = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_millis() as i64)
                    .unwrap_or(0);
                now_ms - 30_000
            }
        };
        Ok(Box::new(TomcatLiveSubscription {
            client: Arc::clone(&self.client),
            channel: channel.to_string(),
            ffl_id: self.ffl_id.clone(),
            cursor_utc_ms,
        }))
    }
}

pub struct TomcatLiveSubscription {
    client: Arc<TomcatClient>,
    channel: String,
    ffl_id: String,
    cursor_utc_ms: i64,
}

impl LiveSubscription for TomcatLiveSubscription {
    fn poll_next(&mut self) -> BackendResult<Option<DataBlock>> {
        let request = LiveRequestDto {
            channels: vec![self.channel.clone()],
            after_utc_ms: self.cursor_utc_ms,
        };
        let response: LiveResponseDto = self
            .client
            .post_json("/api/v1/datadisplay/plots/live", &request)?;

        let series = response
            .series
            .into_iter()
            .find(|s| s.channel == self.channel);

        let Some(series) = series else {
            return Ok(None);
        };
        if series.values.is_empty() {
            return Ok(None);
        }

        let block = live_series_to_block(series, &self.ffl_id);
        self.cursor_utc_ms = match &block {
            DataBlock::Series1D(s1d) => match s1d.axis {
                TimeAxis::Regular {
                    start_ns,
                    sample_period_ns,
                    len,
                } => {
                    let end_ns = start_ns + sample_period_ns.saturating_mul(len as i64);
                    end_ns / 1_000_000
                }
                _ => self.cursor_utc_ms,
            },
            _ => self.cursor_utc_ms,
        };
        Ok(Some(block))
    }
}

fn live_series_to_block(series: LiveSeriesDto, ffl_id: &str) -> DataBlock {
    let values: Vec<f64> = series
        .values
        .into_iter()
        .map(|v| v.unwrap_or(f64::NAN))
        .collect();
    let len = values.len();
    let mut channel = ChannelDescriptor::new(&series.channel, &series.channel);
    channel
        .metadata
        .insert("ffl_source".to_string(), ffl_id.to_string());
    let sample_period_ns = (series.step_ms as i64).max(1) * 1_000_000;
    let start_ns = series.start_utc_ms * 1_000_000;
    DataBlock::Series1D(Series1D {
        channel,
        axis: TimeAxis::Regular {
            start_ns,
            sample_period_ns,
            len,
        },
        values,
        metadata: BTreeMap::new(),
    })
}

fn bucketed_series_to_block(dto: BucketedSeriesDto) -> BackendResult<DataBlock> {
    // Return min values as the primary series; max values are attached as metadata.
    // A future MinMax DataBlock variant would carry both cleanly.
    let values: Vec<f64> = dto.min_values.into_iter().map(|v| v.unwrap_or(f64::NAN)).collect();
    let len = values.len();
    let mut channel = ChannelDescriptor::new(&dto.channel, dto.display_name.as_deref().unwrap_or(&dto.channel));
    channel.unit = dto.unit;
    if let Some(src) = dto.ffl_source {
        channel.metadata.insert("ffl_source".to_string(), src);
    }
    channel.metadata.insert("sampling_mode".to_string(), "minmax_bucket".to_string());
    let sample_period_ns = dto.bucket_ns.max(1);
    let start_ns = dto.start_utc_ms * 1_000_000;
    let max_values: Vec<f64> = dto.max_values.into_iter().map(|v| v.unwrap_or(f64::NAN)).collect();
    channel.metadata.insert(
        "max_values_json".to_string(),
        serde_json::to_string(&max_values).unwrap_or_default(),
    );
    Ok(DataBlock::Series1D(Series1D {
        channel,
        axis: TimeAxis::Regular { start_ns, sample_period_ns, len },
        values,
        metadata: BTreeMap::new(),
    }))
}
