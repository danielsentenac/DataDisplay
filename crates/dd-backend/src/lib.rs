//! Backend abstraction for DATADISPLAY.

use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;
use std::sync::Arc;

use dd_domain::{ChannelDescriptor, DataBlock, TimeRange};

pub type BackendResult<T> = Result<T, BackendError>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BackendErrorKind {
    Unsupported,
    NotFound,
    InvalidQuery,
    Io,
    Internal,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackendError {
    pub kind: BackendErrorKind,
    pub message: String,
}

impl BackendError {
    pub fn unsupported(message: impl Into<String>) -> Self {
        Self {
            kind: BackendErrorKind::Unsupported,
            message: message.into(),
        }
    }

    pub fn not_found(message: impl Into<String>) -> Self {
        Self {
            kind: BackendErrorKind::NotFound,
            message: message.into(),
        }
    }

    pub fn invalid_query(message: impl Into<String>) -> Self {
        Self {
            kind: BackendErrorKind::InvalidQuery,
            message: message.into(),
        }
    }

    pub fn io(message: impl Into<String>) -> Self {
        Self {
            kind: BackendErrorKind::Io,
            message: message.into(),
        }
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self {
            kind: BackendErrorKind::Internal,
            message: message.into(),
        }
    }
}

impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.kind, self.message)
    }
}

impl Error for BackendError {}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SourceTarget {
    pub uri: String,
}

impl SourceTarget {
    pub fn new(uri: impl Into<String>) -> Self {
        Self { uri: uri.into() }
    }

    pub fn scheme(&self) -> Option<&str> {
        self.uri.split_once("://").map(|(scheme, _)| scheme)
    }

    pub fn location(&self) -> Option<&str> {
        self.uri.split_once("://").map(|(_, location)| location)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StreamKind {
    Series1D,
    Sampled,
    Grid2D,
    Volume3D,
    EventSeries,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StreamDescriptor {
    pub channel: ChannelDescriptor,
    pub kind: StreamKind,
    pub sample_shape: Vec<usize>,
    pub tags: Vec<String>,
    pub extra: BTreeMap<String, String>,
}

impl StreamDescriptor {
    pub fn matches(&self, query: &CatalogQuery) -> bool {
        if let Some(text) = &query.text {
            let needle = text.trim().to_ascii_lowercase();
            if !needle.is_empty() && !self.matches_text(&needle) {
                return false;
            }
        }

        query.tags.iter().all(|tag| {
            self.tags
                .iter()
                .any(|candidate| candidate.eq_ignore_ascii_case(tag))
        })
    }

    fn matches_text(&self, needle: &str) -> bool {
        [
            self.channel.id.as_str(),
            self.channel.display_name.as_str(),
            self.channel.unit.as_deref().unwrap_or_default(),
        ]
        .into_iter()
        .chain(self.tags.iter().map(String::as_str))
        .chain(self.extra.keys().map(String::as_str))
        .chain(self.extra.values().map(String::as_str))
        .chain(self.channel.metadata.keys().map(String::as_str))
        .chain(self.channel.metadata.values().map(String::as_str))
        .any(|value| value.to_ascii_lowercase().contains(needle))
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SourceCapabilities {
    pub catalog_search: bool,
    pub live_subscriptions: bool,
    pub volume3d: bool,
    pub metadata_write: bool,
    pub batch_read: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CatalogQuery {
    pub text: Option<String>,
    pub tags: Vec<String>,
    pub offset: usize,
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct CatalogPage {
    pub total_count: usize,
    pub streams: Vec<StreamDescriptor>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Aggregation {
    Raw,
    Mean,
    MinMax,
    Rms,
    Spectrogram { window_len: usize, step_len: usize },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolutionHint {
    pub max_points: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadQuery {
    pub channel_id: String,
    pub time_range: TimeRange,
    pub resolution_hint: Option<ResolutionHint>,
    pub aggregation: Aggregation,
    pub allow_gaps: bool,
}

impl ReadQuery {
    pub fn validate(&self) -> BackendResult<()> {
        if !self.time_range.is_valid() {
            return Err(BackendError::invalid_query(
                "read query uses an invalid time range",
            ));
        }

        if let Some(hint) = &self.resolution_hint {
            if hint.max_points == 0 {
                return Err(BackendError::invalid_query(
                    "resolution_hint.max_points must be greater than zero",
                ));
            }
        }

        match self.aggregation {
            Aggregation::Spectrogram {
                window_len,
                step_len,
            } if window_len == 0 || step_len == 0 => Err(BackendError::invalid_query(
                "spectrogram aggregation requires non-zero window_len and step_len",
            )),
            _ => Ok(()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubscribeRequest {
    pub channel_id: String,
    pub time_range: Option<TimeRange>,
}

pub trait DataSource: Send + Sync {
    fn source_name(&self) -> &str;
    fn capabilities(&self) -> SourceCapabilities;
    fn catalog(&self, query: &CatalogQuery) -> BackendResult<CatalogPage>;
    fn read(&self, query: &ReadQuery) -> BackendResult<DataBlock>;

    fn read_many(&self, queries: &[ReadQuery]) -> BackendResult<Vec<DataBlock>> {
        queries.iter().map(|query| self.read(query)).collect()
    }
}

pub trait LiveSubscription: Send {
    fn poll_next(&mut self) -> BackendResult<Option<DataBlock>>;
}

pub trait LiveDataSource: Send + Sync {
    fn subscribe(&self, request: SubscribeRequest) -> BackendResult<Box<dyn LiveSubscription>>;
}

pub trait DataSourceFactory: Send + Sync {
    fn scheme(&self) -> &str;
    fn open(&self, target: &SourceTarget) -> BackendResult<Box<dyn DataSource>>;
}

#[derive(Default)]
pub struct SourceRegistry {
    factories: Vec<Arc<dyn DataSourceFactory>>,
}

impl SourceRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_factory(mut self, factory: Arc<dyn DataSourceFactory>) -> Self {
        self.register(factory);
        self
    }

    pub fn register(&mut self, factory: Arc<dyn DataSourceFactory>) {
        self.factories.push(factory);
    }

    pub fn registered_schemes(&self) -> Vec<String> {
        self.factories
            .iter()
            .map(|factory| factory.scheme().to_string())
            .collect()
    }

    pub fn open_uri(&self, uri: impl Into<String>) -> BackendResult<Box<dyn DataSource>> {
        self.open(&SourceTarget::new(uri))
    }

    pub fn open(&self, target: &SourceTarget) -> BackendResult<Box<dyn DataSource>> {
        let scheme = target
            .scheme()
            .ok_or_else(|| BackendError::invalid_query("source URI is missing a scheme"))?;

        let factory = self
            .factories
            .iter()
            .find(|factory| factory.scheme() == scheme)
            .ok_or_else(|| {
                BackendError::not_found(format!("no backend registered for scheme `{scheme}`"))
            })?;

        factory.open(target)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct DummyFactory;

    impl DataSourceFactory for DummyFactory {
        fn scheme(&self) -> &str {
            "demo"
        }

        fn open(&self, target: &SourceTarget) -> BackendResult<Box<dyn DataSource>> {
            Ok(Box::new(DummySource {
                name: target.uri.clone(),
            }))
        }
    }

    struct DummySource {
        name: String,
    }

    impl DataSource for DummySource {
        fn source_name(&self) -> &str {
            &self.name
        }

        fn capabilities(&self) -> SourceCapabilities {
            SourceCapabilities::default()
        }

        fn catalog(&self, _query: &CatalogQuery) -> BackendResult<CatalogPage> {
            Ok(CatalogPage::default())
        }

        fn read(&self, _query: &ReadQuery) -> BackendResult<DataBlock> {
            Err(BackendError::unsupported("not needed in test"))
        }
    }

    #[test]
    fn registry_opens_registered_scheme() {
        let registry = SourceRegistry::new().with_factory(Arc::new(DummyFactory));
        let source = registry
            .open_uri("demo://local")
            .expect("registered factory should open source");

        assert_eq!(source.source_name(), "demo://local");
        assert_eq!(registry.registered_schemes(), vec!["demo".to_string()]);
    }

    #[test]
    fn registry_rejects_uri_without_scheme() {
        let registry = SourceRegistry::new();
        let error = match registry.open_uri("/tmp/file.h5") {
            Ok(_) => panic!("missing scheme should be rejected"),
            Err(error) => error,
        };

        assert_eq!(error.kind, BackendErrorKind::InvalidQuery);
    }

    #[test]
    fn stream_descriptor_matches_text_and_tags() {
        let descriptor = StreamDescriptor {
            channel: ChannelDescriptor {
                id: "ENV.CEB.MIC".to_string(),
                display_name: "Acoustic microphone".to_string(),
                unit: Some("Pa".to_string()),
                sample_rate_hz: Some(20_000.0),
                metadata: BTreeMap::from([("group".to_string(), "environment".to_string())]),
            },
            kind: StreamKind::Series1D,
            sample_shape: Vec::new(),
            tags: vec!["environment".to_string(), "acoustic".to_string()],
            extra: BTreeMap::from([("storage".to_string(), "hdf5".to_string())]),
        };

        let query = CatalogQuery {
            text: Some("microphone".to_string()),
            tags: vec!["acoustic".to_string()],
            offset: 0,
            limit: None,
        };

        assert!(descriptor.matches(&query));
    }
}
