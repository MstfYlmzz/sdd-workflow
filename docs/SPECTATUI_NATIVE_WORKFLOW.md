# SpectaTUI Native Workflow Experiment

Status: **Phase C / runtime UX PoC**

Branch: **experiment/spectatui-native-workflow**

## Goal

Use the Spec Kit workflow engine as the pipeline execution layer and SpectaTUI as
the run/resume/status frontend without duplicating the mature SDD domain engine.

The existing PowerShell TUI and all current CLI paths remain available.

## Research basis

The implementation was checked against the current Spec Kit workflow engine and
SpectaTUI sources, with compatibility anchored at Spec Kit 1.0.6 because that
release already contains the project-local custom step loader used by this PoC.

Relevant upstream implementation points:

- Spec Kit workflow engine:
  https://github.com/github/spec-kit/tree/main/src/specify_cli/workflows
- Spec Kit custom step loader:
  https://github.com/github/spec-kit/blob/main/src/specify_cli/workflows/__init__.py
- Spec Kit shell step:
  https://github.com/github/spec-kit/blob/main/src/specify_cli/workflows/steps/shell/__init__.py
- Spec Kit workflow commands:
  https://github.com/github/spec-kit/blob/main/src/specify_cli/workflows/_commands.py
- SpectaTUI workflow run/resume/status bindings:
  https://github.com/tinesoft/spectatui/blob/develop/crates/spectatui/src/main.rs
- SpectaTUI CLI streaming:
  https://github.com/tinesoft/spectatui/blob/develop/crates/spectatui-core/src/speckit/cli.rs
- SpectaTUI fixed artifact stepper:
  https://github.com/tinesoft/spectatui/blob/develop/crates/spectatui/src/ui/workflow.rs

## Semantics gap analysis

### Spec Kit engine primitives

| Capability | Classification | Notes |
| --- | --- | --- |
| Sequential step execution | NATIVE | Top-level workflow steps execute in order. |
| workflow run / resume / status | NATIVE | Run state is persisted below .specify/workflows/runs. |
| command | NATIVE | Integration command dispatch. |
| prompt | NATIVE | Inline prompt dispatch. |
| shell | NATIVE | Local subprocess with captured stdout/stderr. |
| gate | NATIVE | Pause/decision primitive. |
| if / switch | NATIVE | Conditional control flow. |
| while / do-while | NATIVE | Loop control flow. |
| fan-out / fan-in | NATIVE | Parallel/aggregate control flow. |
| Step outputs | NATIVE | Persisted and exposed to expressions. |
| Failure state persistence | NATIVE | Failed top-level step is recorded in run state. |
| Top-level resume | NATIVE | Resume continues from the persisted top-level step. |
| Exact nested-step resume | UNSUPPORTED | A nested failure resumes by re-running its parent control-flow step; the PoC deliberately avoids nesting SDD domain operations. |
| Built-in shell live child streaming | UNSUPPORTED | Built-in shell uses captured subprocess output, so child lines are not forwarded as they arrive. |
| Project-local custom step types | NATIVE | .specify/workflows/steps packages are loaded by Spec Kit. |
| Live SDD subprocess streaming | WRAPPED | sdd-process is the minimal custom step used only to forward stdout/stderr and map observation pause. |
| Environment inheritance | NATIVE | Workflow subprocess inherits the parent environment; SPECKIT_WORKFLOW_DIR is also propagated. |
| First-class nested workflow step | UNSUPPORTED | No dedicated nested-workflow step type is used; this PoC does not shell out to another workflow. |

### SDD capability matrix

| SDD capability | Spec Kit native support | Adapter/wrapper required | Native taşınabilir mi? | Classification |
| --- | --- | --- | --- | --- |
| stage sequencing | yes | no | yes, at pipeline boundary | NATIVE |
| agent routing | no | existing config + adapters | no reason to duplicate | WRAPPED |
| retry | no equivalent domain semantics | existing implement loop | no | WRAPPED |
| session resume | no provider-session semantics | existing adapters/ledger | no | WRAPPED |
| effort escalation | no | existing implement loop | no | WRAPPED |
| task ledger | no | .sdd/state.json | no | WRAPPED |
| batch selection | no | existing implement loop | no | WRAPPED |
| dependency resolution | no | existing ledger/loop | no | WRAPPED |
| Tier 0 | no | existing validator | no | WRAPPED |
| Tier 1 | no | existing validator | no | WRAPPED |
| candidate revalidation | no | existing implement loop | no | WRAPPED |
| repair tasks | no | existing implement loop | no | WRAPPED |
| analyze blocking | generic failure only | existing Analyze contract | no | WRAPPED |
| convergence loop | generic loop exists, semantics differ | existing implement/converge functions | no | WRAPPED |
| convergence circuit breaker | generic loops only | existing converge state | no | WRAPPED |
| telemetry | generic workflow log only | existing SDD event bus/provider usage | no | WRAPPED |
| checkpoint commits | no | existing Save-LoopCheckpoint | no | WRAPPED |
| observe pause | generic PAUSED exists | exit 75 mapped by sdd-process | pipeline pause only | WRAPPED |

The rule is intentional: **pipeline mechanics move to Spec Kit; SDD domain
semantics stay in the already tested SDD engine.**

## Chosen architecture

Phase A uses three top-level workflow steps:

    SpectaTUI
        |
        v
    specify workflow run sdd-native
        |
        +-- tasks-ready
        |     sdd workflow-stage prepare
        |
        +-- analyze
        |     sdd workflow-stage analyze
        |
        +-- autonomous-closure
              sdd workflow-stage closure
                    |
                    +-- existing implement loop
                    +-- Tier 0 / Tier 1
                    +-- retry + provider session resume
                    +-- final strict Tier 1
                    +-- existing LLM-based Converge
                    +-- append-only validation
                    +-- convergence tasks -> implement again
                    +-- convergence circuit breaker

There is deliberately no YAML recreation of batching, retry, validation, or
Converge semantics.

## Why autonomous closure is one top-level step

Spec Kit persists the top-level step index. Nested control-flow steps may rerun
their parent when resumed. Keeping the mature autonomous loop behind one
top-level process gives clean ownership:

- Spec Kit decides **which pipeline step is active**.
- .sdd/state.json decides **which SDD task/attempt/session/convergence round is active**.
- If autonomous closure stops, Spec Kit resumes the same top-level step and the
  existing SDD ledger decides the exact domain continuation point.

This avoids a second authoritative task state machine.

## State ownership

### Spec Kit

.specify/workflows/runs/<run-id>/state.json owns:

- workflow run ID
- current top-level step
- step completion/failure/pause
- workflow resume position

The whole workflows/runs directory is ignored by Git because it is machine-local
pipeline state. This is required so the SDD clean-worktree invariant is not
broken by the workflow engine itself.

### SDD

.sdd/state.json remains authoritative for:

- stages
- tasks and dependencies
- attempts
- provider session IDs
- agent/model/effort records
- gate baseline and validation state
- checkpoint state
- convergence round and outcome

No task status is copied into Spec Kit run state.

## Agent routing

The workflow YAML contains no provider or model names.

All routing still comes from .sdd/config.yaml:

    agents:
      spec:      ...
      plan:      ...
      tasks:     ...
      analyze:   ...
      implement: ...
      converge:  ...

The workflow bridge calls the existing Invoke-Analyze and Invoke-ImplementLoop
functions, which resolve the same adapters as the current CLI/TUI path.

## Converge

Converge remains the existing LLM-driven speckit-converge skill.

The deterministic layer still only checks:

- write boundary
- append-only tasks.md
- task ID integrity
- ledger synchronization
- state transition
- max convergence rounds

The sdd-native workflow does not inspect Converge output with a new heuristic and
does not turn Converge into a deterministic Tier 2.

## Live output

Stock Spec Kit shell steps buffer child output. For this reason Phase A adds one
project-local custom step type: sdd-process.

sdd-process:

- executes only the workflow-authored local command
- forwards child stdout and stderr to the parent process immediately
- preserves captured stdout/stderr in the step result
- maps exit code 75 to Spec Kit PAUSED
- maps non-zero exits to FAILED

SpectaTUI already streams the outer Specify CLI stdout/stderr line-by-line into
its CLI job popup, so no SpectaTUI fork is required for Phase A.

SDD workflow bridge commands use raw event mode. Raw mode enables provider
partial streaming so agent/tool/workflow events can travel through the same
pipe.

Phase B adds a second, deliberately non-authoritative channel for structured UI
state: `.specify/sdd-status.json`. The SDD engine derives this projection from
`.sdd/state.json` at event-context boundaries, loop checkpoints, active batch
selection, revalidation and Converge start. The projection is Git-ignored and is
never read back by the SDD engine as control state.

## Resume semantics

- prepare failure -> Spec Kit resumes prepare.
- analyze failure -> Spec Kit resumes analyze.
- autonomous closure failure -> Spec Kit resumes closure.
- retry/session resume inside closure -> existing .sdd/state.json and provider
  session IDs decide the continuation.
- observation pause -> closure returns exit 75; sdd-process reports PAUSED;
  workflow resume re-enters closure.

No nested Spec Kit loop is used, specifically to avoid nested resume ambiguity.

## Phase A user path

Prerequisites:

1. The project is already initialized with sdd init.
2. spec.md, plan.md and tasks.md exist for the active feature.
3. The approved task state is committed and the working tree is clean.
4. sdd upgrade has installed the current managed workflow assets.
5. Spec Kit 1.0.6 or later and SpectaTUI are available.

From SpectaTUI:

1. Open Automation Workflows.
2. Select **SDD Native Closure**.
3. Press r to run.
4. Use R to resume the last interrupted/paused run.
5. Use s for workflow status/history.

The current PowerShell TUI remains available as the fallback path.

## Phase B observability overlay

SpectaTUI 1.1.0 does not expose a project UI-plugin surface; Spec Kit extensions
can add workflow assets but cannot add Ratatui panes or fields. Phase B therefore
uses a small, pinned source overlay rather than duplicating the SDD engine or
maintaining a broad SpectaTUI fork.

The overlay is based on upstream SpectaTUI commit:

    c039831190588c336abf4adba8a0d7c91c148774

It changes only three upstream source files:

- `spectatui-core/src/speckit/mod.rs` reads the optional
  `.specify/sdd-status.json` projection read-only.
- `ui/workflow.rs` adds an explicit `conv` badge and current route/batch/retry/
  convergence round details to the selected feature workflow pane.
- `ui/workflows.rs` adds the same SDD runtime details to the
  **SDD Native Closure** workflow detail view.

The patched binary is built and installed **side-by-side** as
`spectatui-sdd`; stock `spectatui` is not replaced. The installer verifies
the pinned upstream commit, runs the projection unit test, compiles the patched
application and creates a release build.

### Projection contract

`.specify/sdd-status.json` currently exposes:

- active spec ID
- SDD stage and status
- task totals: done/pending/blocked/manual
- current batch IDs and batch number
- current attempt / max attempts
- agent / model / effort
- Converge round / max rounds
- stop reason

The document includes `"authoritative": false`. If it is missing or malformed,
patched SpectaTUI degrades to the normal stock view; SDD execution is unaffected.

### Phase B user path

After `sdd upgrade`, install the experimental UI once:

    sdd spectatui install

This requires Git and a Rust/Cargo stable toolchain because the pinned
SpectaTUI source is compiled locally. Then open a project with:

    spectatui-sdd -p .

The existing `spectatui`, `sdd tui`, and all existing `sdd` CLI paths
remain available as fallback paths.

## Phase C runtime UX

Phase C keeps the Spec Kit workflow as the execution owner but stops treating its
raw subprocess output as the primary SDD user interface.

- `sdd-native` run/resume jobs start as background CLI jobs and return directly
  to the Overview dashboard.
- The Overview dashboard adds a read-only **SDD Runtime** pane between the
  lifecycle pane and the normal coding-agent output pane when an SDD projection
  is present.
- Meaningful SDD events are projected to `.specify/sdd-events.json` as a capped,
  non-authoritative event feed. Raw command-output and partial-token events are
  deliberately excluded so the pane stays operational rather than becoming a
  JSON/log console.
- The existing CLI job still captures the full raw output for debugging; it is
  no longer forced open for `sdd-native`.
- New SpectaTUI installs default their UI config to `~/.spectatui.toml` instead
  of creating `./.spectatui.toml` in every project. The SDD clean-worktree
  check also ignores a legacy project-local `.spectatui.toml`.
- The Agent Output pane remains dedicated to the selected feature's tmux coding
  agent session. It is not repurposed as the orchestration console.

### Remaining UX gaps

- token/provider usage is still available in SDD telemetry but not yet summarized
  in the rich runtime pane
- workflow input collection for starting a brand-new spec from free-form user
  text is not implemented; the PoC starts from an existing tasks artifact
- the Phase C runtime pane is intentionally read-only; pause/resume and raw-log
  drill-down still use the workflow manager / CLI job surfaces
- interactive Windows-terminal latency and idle-CPU measurements are still
  required before the legacy PowerShell TUI can be considered removable

These are UI/observability/input gaps, not domain-engine gaps.

## Tests

Three levels are provided:

- tests/spectatui-workflow.integration.ps1
  - managed asset installation
  - no provider hardcoding
  - prepare/analyze/closure bridge semantics
  - state preservation on domain failure
  - raw partial streaming contract
- tests/spec-kit-workflow.e2e.ps1
  - real Spec Kit workflow run
  - real failed top-level step
  - persisted run ID/state
  - real workflow resume
  - workflow status after resume
  - .specify workflow state and .sdd domain state do not conflict
- tests/spectatui-status.integration.ps1
  - projection remains non-authoritative
  - task counters, active batch, retry and routing fields
  - explicit Converge round projection
  - projection is Git-ignored
- separate CI overlay job
  - pins SpectaTUI 1.1.0 source
  - runs the SDD projection Rust unit test
  - cargo-checks the patched TUI
  - builds the release binary

CI installs pinned Spec Kit v1.0.6 for the E2E while the normal PowerShell suite
remains runnable without an extra Spec Kit installation.

## Performance status

No numerical SpectaTUI-vs-PowerShell-TUI performance claim is made yet.
Phase B proves the patched UI compiles and the SDD projection updates through
tested execution paths, but startup, keypress-to-render, projection refresh,
subprocess-stream latency and idle CPU must still be measured on the actual
Windows terminal.

The existing PowerShell TUI therefore remains in place until that interactive
acceptance/performance pass is complete.
