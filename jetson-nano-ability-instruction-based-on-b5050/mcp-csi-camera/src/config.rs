use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct Config {
    /// If `Some`, every capture is also written to this directory as a
    /// `capture-<timestamp>.jpg` file (debug aid). If `None`, captures live
    /// only in the inline base64 image content of the MCP response — nothing
    /// is written to disk.
    pub output_dir: Option<PathBuf>,
}
