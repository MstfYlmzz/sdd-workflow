use ratatui::layout::Rect;
use ratatui::style::Modifier;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};
use ratatui::Frame;

use spectatui_core::speckit::WorkflowStage;

use crate::app::{App, Pane};

const STAGES: &[(&str, WorkflowStage)] = &[
    ("cons", WorkflowStage::NotStarted),
    ("spec", WorkflowStage::Specified),
    ("clar", WorkflowStage::Clarified),
    ("plan", WorkflowStage::Planned),
    ("task", WorkflowStage::TasksGenerated),
    ("anly", WorkflowStage::Analyzed),
    ("impl", WorkflowStage::Implementing),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SddDisplayStage {
    label: &'static str,
    verb: &'static str,
    rank: u8,
}

fn sdd_display_stage(stage: &str) -> Option<SddDisplayStage> {
    match stage {
        "spec" | "specify" => Some(SddDisplayStage { label: "spec", verb: "specify", rank: 1 }),
        "plan" => Some(SddDisplayStage { label: "plan", verb: "plan", rank: 3 }),
        "tasks" | "task" => Some(SddDisplayStage { label: "task", verb: "tasks", rank: 4 }),
        "analyze" | "analysis" => Some(SddDisplayStage { label: "anly", verb: "analyze", rank: 5 }),
        "implement" | "implementation" => Some(SddDisplayStage { label: "impl", verb: "implement", rank: 6 }),
        "converge" | "convergence" => Some(SddDisplayStage { label: "conv", verb: "converge", rank: 7 }),
        _ => None,
    }
}

fn badge_rank(label: &str) -> Option<u8> {
    match label {
        "cons" => Some(0),
        "spec" => Some(1),
        "clar" => Some(2),
        "plan" => Some(3),
        "task" => Some(4),
        "anly" => Some(5),
        "impl" => Some(6),
        "conv" => Some(7),
        _ => None,
    }
}

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let theme = &app.theme;
    let focused = app.focused_pane == Pane::Workflow;
    let border_style = if focused {
        theme.border_focused
    } else {
        theme.border_unfocused
    };
    let title_style = if focused {
        theme.title_focused
    } else {
        theme.title_unfocused
    };

    let feature_id = app
        .selected_feature()
        .map(|f| f.id.as_str())
        .unwrap_or("none");

    let title = Line::from(vec![
        Span::styled("─┤ ", border_style),
        Span::styled(format!("Workflow · {feature_id}"), title_style),
        Span::styled(" ├", border_style),
    ]);

    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(border_style)
        .title(title)
        .padding(super::PANEL_PADDING);

    let inner = block.inner(area);
    frame.render_widget(block, area);

    let Some(feature) = app.selected_feature() else {
        let empty = Paragraph::new(Line::from(Span::styled(
            "No feature selected",
            theme.faint_style,
        )))
        .style(theme.base);
        frame.render_widget(empty, inner);
        return;
    };

    let current_stage = feature.stage;
    let sdd_status = app
        .project
        .sdd_status
        .as_ref()
        .filter(|status| status.spec_id == feature.id);
    // Matching SDD projection wins for display. Artifact inference is only a
    // fallback for projects/runs that do not have SDD state.
    let sdd_display = sdd_status.and_then(|status| sdd_display_stage(&status.stage));
    let done_style = theme.stepper_done_style(app.theme_mode);

    let mut stepper_spans: Vec<Span> = vec![Span::raw(" ")];

    for (i, (label, min_stage)) in STAGES.iter().enumerate() {
        if i > 0 {
            stepper_spans.push(Span::styled("─►", theme.faint_style));
        }

        let badge_text = format!(" {label} ");
        let style = if let Some(sdd_stage) = sdd_display {
            let rank = badge_rank(label).unwrap_or(u8::MAX);
            if rank < sdd_stage.rank {
                done_style
            } else if rank == sdd_stage.rank {
                theme
                    .stage_badge(label, app.theme_mode)
                    .add_modifier(Modifier::BOLD)
            } else {
                ratatui::style::Style::default()
                    .fg(theme.faint)
                    .bg(theme.bg)
            }
        } else if current_stage == WorkflowStage::Unknown {
            // Unknown sorts after every real stage (declared last for Ord), which would
            // otherwise make every badge below look "done" — show the stepper as neutral
            // instead; the distinct "unk" badge is shown separately below.
            ratatui::style::Style::default()
                .fg(theme.faint)
                .bg(theme.bg)
        } else if current_stage > *min_stage
            || (matches!(current_stage, WorkflowStage::Implemented) && *label == "impl")
        {
            done_style
        } else if current_stage == *min_stage
            || (current_stage == WorkflowStage::Implementing && *label == "impl")
        {
            theme
                .stage_badge(label, app.theme_mode)
                .add_modifier(Modifier::BOLD)
        } else {
            ratatui::style::Style::default()
                .fg(theme.faint)
                .bg(theme.bg)
        };

        stepper_spans.push(Span::styled(badge_text, style));
    }

    if let Some(sdd) = sdd_status {
        stepper_spans.push(Span::styled("─►", theme.faint_style));
        let conv_style = if matches!(sdd_display, Some(stage) if stage.label == "conv") {
            theme.accent_style.add_modifier(Modifier::BOLD)
        } else if sdd.runtime.convergence_round > 0 {
            done_style
        } else {
            ratatui::style::Style::default()
                .fg(theme.faint)
                .bg(theme.bg)
        };
        stepper_spans.push(Span::styled(" conv ", conv_style));
    }

    let stepper_line = Line::from(stepper_spans);

    let mut lines = vec![stepper_line, Line::default()];

    let available_height = inner.height as usize;

    let (current_label, current_badge_style, stage_verb) =
        if let Some(sdd_stage) = sdd_display {
            let style = if sdd_stage.label == "conv" {
                theme.accent_style.add_modifier(Modifier::BOLD)
            } else {
                theme
                    .stage_badge(sdd_stage.label, app.theme_mode)
                    .add_modifier(Modifier::BOLD)
            };
            (sdd_stage.label, style, sdd_stage.verb)
        } else {
            let label = current_stage.label();
            (
                label,
                theme.stage_badge(label, app.theme_mode),
                stage_verb(current_stage),
            )
        };

    if available_height > 4 {
        let mut stage_line = vec![
            Span::styled("  Current stage: ", theme.dim_style),
            Span::styled(format!(" {current_label} "), current_badge_style),
            Span::styled(format!(" {stage_verb}"), theme.dim_style),
        ];
        if let Some(sdd) = sdd_status {
            if !sdd.status.is_empty() {
                stage_line.push(Span::styled(format!(" · {}", sdd.status), theme.info_style));
            }
        }
        lines.push(Line::from(stage_line));
    }

    if available_height > 5 {
        let sdd_progress = sdd_status
            .filter(|sdd| sdd.tasks.total > 0)
            .map(|sdd| {
                let percent = ((sdd.tasks.done as f64 / sdd.tasks.total as f64) * 100.0) as u8;
                (sdd.tasks.done, sdd.tasks.total, percent)
            });
        let artifact_progress = if sdd_progress.is_none() {
            app.selected_tasks_progress()
                .map(|progress| (progress.done, progress.total, progress.percent()))
        } else {
            None
        };

        if let Some((done, total, percent)) = sdd_progress.or(artifact_progress) {
            let bar_w = (inner.width as usize).saturating_sub(26).clamp(7, 40);
            let filled = (done * bar_w).checked_div(total).unwrap_or(0);
            let empty = bar_w - filled;
            let bar = format!("{}{}", "█".repeat(filled), "░".repeat(empty));
            lines.push(Line::from(vec![
                Span::styled("  Tasks [", theme.dim_style),
                Span::styled(bar, theme.accent_style),
                Span::styled(
                    format!("] {done}/{total} {percent}%"),
                    theme.dim_style,
                ),
            ]));
        }
    }

    if let Some(sdd) = sdd_status {
        if available_height > 6 && (!sdd.runtime.agent.is_empty() || !sdd.runtime.model.is_empty()) {
            lines.push(Line::from(vec![
                Span::styled("  route   ", theme.dim_style),
                Span::styled(
                    format!(
                        "{}/{} · {}",
                        sdd.runtime.agent, sdd.runtime.model, sdd.runtime.effort
                    ),
                    theme.info_style,
                ),
            ]));
        }
        if available_height > 7 && !sdd.runtime.batch.is_empty() {
            lines.push(Line::from(vec![
                Span::styled("  batch   ", theme.dim_style),
                Span::styled(
                    format!("#{} {}", sdd.runtime.batch_number, sdd.runtime.batch.join(", ")),
                    theme.info_style,
                ),
            ]));
        }
        if available_height > 8 && sdd.runtime.attempt > 0 {
            lines.push(Line::from(vec![
                Span::styled("  retry   ", theme.dim_style),
                Span::styled(
                    format!("attempt {}/{}", sdd.runtime.attempt, sdd.runtime.max_attempts),
                    theme.info_style,
                ),
            ]));
        }
        if available_height > 9 && sdd.runtime.max_convergence_rounds > 0 {
            lines.push(Line::from(vec![
                Span::styled("  conv    ", theme.dim_style),
                Span::styled(
                    format!(
                        "round {}/{}",
                        sdd.runtime.convergence_round, sdd.runtime.max_convergence_rounds
                    ),
                    if sdd.stage == "converge" {
                        theme.accent_bold
                    } else {
                        theme.info_style
                    },
                ),
            ]));
        }
    }

    if available_height > 7 {
        if let Some(branch) = feature.branch.as_deref() {
            lines.push(Line::from(vec![
                Span::styled("  branch  ", theme.dim_style),
                Span::styled(branch.to_string(), theme.info_style),
            ]));
        }
    }

    // Fill remaining space before footer
    while lines.len() < (inner.height as usize).saturating_sub(1) {
        lines.push(Line::default());
    }
    lines.push(Line::from(Span::styled(
        "[enter] open spec   [a] sessions",
        theme.faint_style,
    )));

    let content = Paragraph::new(lines).style(theme.base);
    frame.render_widget(content, inner);
}

fn stage_verb(stage: WorkflowStage) -> &'static str {
    match stage {
        WorkflowStage::NotStarted => "constitution",
        WorkflowStage::Specified => "specify",
        WorkflowStage::Clarified => "clarify",
        WorkflowStage::Planned => "plan",
        WorkflowStage::TasksGenerated => "tasks",
        WorkflowStage::Analyzed => "analyze",
        WorkflowStage::Implementing => "implement",
        WorkflowStage::Implemented => "implement",
        WorkflowStage::Unknown => "unrecognized artifact format",
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sdd_projection_stage_mapping_overrides_artifact_inference() {
        let implement = sdd_display_stage("implement").expect("implement stage");
        assert_eq!(implement.label, "impl");
        assert_eq!(implement.verb, "implement");
        assert_eq!(implement.rank, 6);
        assert!(badge_rank("task").unwrap() < implement.rank);

        let converge = sdd_display_stage("converge").expect("converge stage");
        assert_eq!(converge.label, "conv");
        assert_eq!(converge.rank, 7);

        assert!(sdd_display_stage("unknown-stage").is_none());
    }
}
