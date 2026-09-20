pub mod cli;
pub mod registry;
pub mod watch;
mod workflow;

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::Deserialize;
pub use registry::{
    ExtensionInfo, ExtensionSource, InstallStatus, IntegrationInfo, PresetInfo, WorkflowInfo,
};
pub use workflow::{TasksProgress, WorkflowStage};

#[derive(Debug, Clone)]
pub struct Project {
    pub root: PathBuf,
    pub constitution: Option<PathBuf>,
    pub features: Vec<Feature>,
    pub extensions: Vec<ExtensionInfo>,
    pub presets: Vec<PresetInfo>,
    pub integrations: Vec<IntegrationInfo>,
    pub workflows: Vec<WorkflowInfo>,
    pub sdd_status: Option<SddStatus>,
    pub sdd_events: Vec<SddEventSummary>,
    pub sdd_config: Option<SddConfigProjection>,
}

#[derive(Debug, Clone)]
pub struct Feature {
    pub id: String,
    pub branch: Option<String>,
    pub dir: PathBuf,
    pub artifacts: FeatureArtifacts,
    pub stage: WorkflowStage,
}

#[derive(Debug, Clone, Default)]
pub struct FeatureArtifacts {
    pub spec: Option<PathBuf>,
    pub plan: Option<PathBuf>,
    pub tasks: Option<PathBuf>,
    pub research: Option<PathBuf>,
    pub data_model: Option<PathBuf>,
    pub quickstart: Option<PathBuf>,
    pub contracts_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SddTaskProgress {
    #[serde(default)]
    pub total: usize,
    #[serde(default)]
    pub done: usize,
    #[serde(default)]
    pub pending: usize,
    #[serde(default)]
    pub blocked: usize,
    #[serde(default)]
    pub manual: usize,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SddFileChange {
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub additions: u64,
    #[serde(default)]
    pub deletions: u64,
    #[serde(default)]
    pub binary: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SddRuntimeStatus {
    #[serde(default)]
    pub batch: Vec<String>,
    #[serde(default)]
    pub batch_number: u32,
    #[serde(default)]
    pub attempt: u32,
    #[serde(default)]
    pub max_attempts: u32,
    #[serde(default)]
    pub agent: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub effort: String,
    #[serde(default)]
    pub convergence_round: u32,
    #[serde(default)]
    pub max_convergence_rounds: u32,
    #[serde(default)]
    pub stop_reason: String,
    #[serde(default)]
    pub active_baseline: String,
    #[serde(default)]
    pub changed_files: u64,
    #[serde(default)]
    pub additions: u64,
    #[serde(default)]
    pub deletions: u64,
    #[serde(default)]
    pub file_changes: Vec<SddFileChange>,
    #[serde(default)]
    pub activity_kind: String,
    #[serde(default)]
    pub activity_label: String,
    #[serde(default)]
    pub activity_detail: String,
    #[serde(default)]
    pub activity_started_at_ms: u64,
    #[serde(default)]
    pub agent_started_at_ms: u64,
    #[serde(default)]
    pub last_activity_at_ms: u64,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SddRouteProfile {
    #[serde(default)]
    pub stage: String,
    #[serde(default)]
    pub agent: String,
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub effort: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SddProviderCatalog {
    #[serde(default)]
    pub agent: String,
    #[serde(default)]
    pub available: bool,
    #[serde(default)]
    pub models: Vec<String>,
    #[serde(default)]
    pub efforts: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SddConfigProjection {
    #[serde(default)]
    pub schema_version: u32,
    #[serde(default)]
    pub authoritative: bool,
    #[serde(default)]
    pub updated_at: String,
    #[serde(default)]
    pub routes: Vec<SddRouteProfile>,
    #[serde(default)]
    pub providers: Vec<SddProviderCatalog>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SddEventSummary {
    #[serde(default)]
    pub timestamp: String,
    #[serde(default)]
    pub run_id: String,
    #[serde(default)]
    pub sequence: u64,
    #[serde(default)]
    pub stage: String,
    #[serde(default)]
    pub category: String,
    #[serde(default)]
    pub event_type: String,
    #[serde(default)]
    pub severity: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub message: String,
    #[serde(default)]
    pub command: String,
    #[serde(default)]
    pub provider: String,
    #[serde(default)]
    pub exit_code: Option<i32>,
    #[serde(default)]
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Default, Deserialize)]
struct SddEventFeed {
    #[serde(default)]
    events: Vec<SddEventSummary>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct SddStatus {
    #[serde(default)]
    pub schema_version: u32,
    #[serde(default)]
    pub authoritative: bool,
    #[serde(default)]
    pub spec_id: String,
    #[serde(default)]
    pub stage: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub updated_at: String,
    #[serde(default)]
    pub tasks: SddTaskProgress,
    #[serde(default)]
    pub runtime: SddRuntimeStatus,
}

impl Project {
    pub fn discover(root: &Path) -> Result<Self> {
        let root = root.canonicalize().context("project root not found")?;
        let constitution = {
            let p = root.join(".specify/memory/constitution.md");
            p.is_file().then_some(p)
        };

        let features = discover_features(&root)?;
        let extensions = registry::load_extensions(&root)?;
        let presets = registry::load_presets(&root)?;
        let integrations = registry::load_integrations(&root)?;
        let sdd_status = load_sdd_status(&root);
        let sdd_events = load_sdd_events(&root);
        let sdd_config = load_sdd_config(&root);

        Ok(Project {
            root,
            constitution,
            features,
            extensions,
            presets,
            integrations,
            workflows: Vec::new(),
            sdd_status,
            sdd_events,
            sdd_config,
        })
    }

    /// `false` when `root` has no `.specify/` directory at all — every collection above
    /// degrades to empty in that case with no error, so callers must check this
    /// separately to distinguish "not a recognized Spec-Kit project" from "a valid,
    /// freshly initialized one with nothing in it yet".
    pub fn has_speckit_structure(&self) -> bool {
        self.root.join(".specify").is_dir()
    }
}

fn load_sdd_status(root: &Path) -> Option<SddStatus> {
    let path = root.join(".specify/sdd-status.json");
    let content = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&content).ok()
}

fn load_sdd_config(root: &Path) -> Option<SddConfigProjection> {
    let path = root.join(".specify/sdd-config.json");
    let content = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&content).ok()
}

fn load_sdd_events(root: &Path) -> Vec<SddEventSummary> {
    let path = root.join(".specify/sdd-events.json");
    let Ok(content) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    serde_json::from_str::<SddEventFeed>(&content)
        .map(|feed| feed.events)
        .unwrap_or_default()
}

fn discover_features(root: &Path) -> Result<Vec<Feature>> {
    let specs_dir = root.join("specs");
    if !specs_dir.is_dir() {
        return Ok(Vec::new());
    }

    let mut entries: Vec<_> = std::fs::read_dir(&specs_dir)
        .context("failed to read specs/")?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().is_dir())
        .collect();

    entries.sort_by_key(|e| e.file_name());

    let mut features = Vec::new();
    for entry in entries {
        let dir = entry.path();
        let id = dir
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string();

        if id.starts_with('.') {
            continue;
        }

        let artifacts = discover_artifacts(&dir);
        let stage = workflow::infer_stage(&artifacts);

        let branch = Some(id.clone());

        features.push(Feature {
            id,
            branch,
            dir,
            artifacts,
            stage,
        });
    }

    Ok(features)
}

fn discover_artifacts(dir: &Path) -> FeatureArtifacts {
    let file_if_exists = |name: &str| {
        let p = dir.join(name);
        p.is_file().then_some(p)
    };
    let dir_if_exists = |name: &str| {
        let p = dir.join(name);
        p.is_dir().then_some(p)
    };

    FeatureArtifacts {
        spec: file_if_exists("spec.md"),
        plan: file_if_exists("plan.md"),
        tasks: file_if_exists("tasks.md"),
        research: file_if_exists("research.md"),
        data_model: file_if_exists("data-model.md"),
        quickstart: file_if_exists("quickstart.md"),
        contracts_dir: dir_if_exists("contracts"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn discover_on_plain_directory_has_no_speckit_structure() {
        let tmp = TempDir::new().unwrap();
        let project = Project::discover(tmp.path()).unwrap();
        assert!(project.features.is_empty());
        assert!(!project.has_speckit_structure());
    }

    #[test]
    fn discover_on_speckit_project_has_speckit_structure() {
        let tmp = TempDir::new().unwrap();
        std::fs::create_dir_all(tmp.path().join(".specify/memory")).unwrap();
        let project = Project::discover(tmp.path()).unwrap();
        assert!(project.has_speckit_structure());
    }

    #[test]
    fn discover_loads_sdd_status_projection() {
        let tmp = TempDir::new().unwrap();
        std::fs::create_dir_all(tmp.path().join(".specify")).unwrap();
        std::fs::write(
            tmp.path().join(".specify/sdd-status.json"),
            r#"{"schema_version":1,"authoritative":false,"spec_id":"001-demo","stage":"converge","status":"running","tasks":{"total":3,"done":2},"runtime":{"batch":["T003"],"attempt":2,"max_attempts":3,"agent":"codex","model":"gpt-test","effort":"high","convergence_round":2,"max_convergence_rounds":3}}"#,
        )
        .unwrap();

        let project = Project::discover(tmp.path()).unwrap();
        let status = project.sdd_status.expect("sdd status");
        assert_eq!(status.spec_id, "001-demo");
        assert_eq!(status.stage, "converge");
        assert_eq!(status.tasks.done, 2);
        assert_eq!(status.runtime.batch, vec!["T003"]);
        assert_eq!(status.runtime.convergence_round, 2);
        assert!(!status.authoritative);
    }

    #[test]
    fn discover_loads_sdd_config_projection() {
        let tmp = TempDir::new().unwrap();
        std::fs::create_dir_all(tmp.path().join(".specify")).unwrap();
        std::fs::write(
            tmp.path().join(".specify/sdd-config.json"),
            r#"{"schema_version":1,"authoritative":false,"routes":[{"stage":"implement","agent":"codex","model":"gpt-test","effort":"medium"}],"providers":[{"agent":"codex","available":true,"models":["gpt-test","gpt-other"],"efforts":["low","medium","high"]}]}"#,
        )
        .unwrap();

        let project = Project::discover(tmp.path()).unwrap();
        let config = project.sdd_config.expect("sdd config");
        assert!(!config.authoritative);
        assert_eq!(config.routes.len(), 1);
        assert_eq!(config.routes[0].stage, "implement");
        assert_eq!(config.routes[0].agent, "codex");
        assert_eq!(config.providers.len(), 1);
        assert_eq!(config.providers[0].models, vec!["gpt-test", "gpt-other"]);
    }

    #[test]
    fn discover_loads_sdd_event_feed() {
        let tmp = TempDir::new().unwrap();
        std::fs::create_dir_all(tmp.path().join(".specify")).unwrap();
        std::fs::write(
            tmp.path().join(".specify/sdd-events.json"),
            r#"{"schema_version":1,"authoritative":false,"events":[{"timestamp":"2026-09-19T21:18:05+03:00","sequence":28,"stage":"implement","category":"gate","event_type":"gate_completed","severity":"info","status":"failed","message":"Tier 1/reference-frame-tests","exit_code":1}]}"#,
        )
        .unwrap();

        let project = Project::discover(tmp.path()).unwrap();
        assert_eq!(project.sdd_events.len(), 1);
        let event = &project.sdd_events[0];
        assert_eq!(event.stage, "implement");
        assert_eq!(event.category, "gate");
        assert_eq!(event.status, "failed");
        assert_eq!(event.exit_code, Some(1));
    }

    #[test]
    fn discover_ignores_malformed_sdd_status_projection() {
        let tmp = TempDir::new().unwrap();
        std::fs::create_dir_all(tmp.path().join(".specify")).unwrap();
        std::fs::write(tmp.path().join(".specify/sdd-status.json"), "{broken").unwrap();
        let project = Project::discover(tmp.path()).unwrap();
        assert!(project.sdd_status.is_none());
    }
}
