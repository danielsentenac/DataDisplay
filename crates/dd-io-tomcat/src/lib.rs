//! DataDisplay Tomcat backend adapter.
//!
//! Registers a `tomcat://` URI scheme that proxies catalog and read requests to
//! the DataDisplay Tomcat backend (`/api/v1/datadisplay/...`).
//!
//! URI format:  `tomcat://<host>:<port>[/context-path]?ffl=<ffl_id>`
//! Example:     `tomcat://olserver134:8080/datadisplay-tomcat-backend?ffl=trend`

mod client;
mod dto;
mod ffl;

pub use ffl::TomcatFflFactory;
