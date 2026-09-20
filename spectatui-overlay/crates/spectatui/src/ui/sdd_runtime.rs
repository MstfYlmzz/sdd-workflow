use std::time::{SystemTime, UNIX_EPOCH};

use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};
use ratatui::Frame;

use spectatui_core::speckit::SddEventSummary;

use crate::app::App;

const SPINNER: [&str; 8] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"];

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let theme = &app.theme;
    let selected_id = app
        .selected_feature()
        .map(|f| f.id.as_str())
        .unwrap_or("none");
    let sdd = app
        .project
        .sdd_status
        .as_ref()
        .filter(|status| status.spec_id == selected_id);

    let title_text = match sdd {
        Some(status) if status.status == "running" => {
            let spinner = SPINNER[(app.indexing_tick as usize) % SPINNER.len()];
            format!("{spinner} SDD Runtime · {} · running", status.stage)
        }
        Some(status) => format!("SDD Runtime · {} · {}", status.stage, status.status),
        None => "SDD Runtime".to_string(),
    };
    let title = Line::from(vec![
        Span::styled("─┤ ", theme.border_unfocused),
        Span::styled(title_text, theme.title_unfocused),
        Span::styled(" ├", theme.border_unfocused),
    ]);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(theme.border_unfocused)
        .title(title)
        .padding(super::PANEL_PADDING);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if inner.height == 0 || inner.width == 0 {
        return;
    }

    let mut lines: Vec<Line> = Vec::new();
    if let Some(status) = sdd {
        let runtime = &status.runtime;
        let now = now_ms();
        let elapsed = duration_text(now.saturating_sub(runtime.agent_started_at_ms));
        let quiet_ms = now.saturating_sub(runtime.last_activity_at_ms);
        let idle = duration_text(quiet_ms);
        let active = status.status == "running";
        let quiet = active && runtime.last_activity_at_ms > 0 && quiet_ms >= 90_000;

        let state_style = if quiet {
            theme.warn_style
        } else if active {
            theme.accent_bold
        } else if matches!(status.status.as_str(), "failed" | "blocked" | "interrupted") {
            theme.warn_style
        } else {
            theme.good_style
        };

        if active && runtime.agent_started_at_ms > 0 {
            lines.push(Line::from(vec![
                Span::styled(" agent ", theme.dim_style),
                Span::styled(
                    format!(
                        "{} / {} · {} · {} {}",
                        empty_as(&runtime.agent, "agent"),
                        empty_as(&runtime.model, "default"),
                        elapsed,
                        if quiet { "quiet" } else { "last" },
                        idle
                    ),
                    state_style,
                ),
            ]));
        } else {
            lines.push(Line::from(vec![
                Span::styled(" state ", theme.dim_style),
                Span::styled(status.status.clone(), state_style),
            ]));
        }

        lines.push(Line::from(vec![
            Span::styled(" work  ", theme.dim_style),
            Span::styled(
                format!(
                    "{}/{} done · {} pending",
                    status.tasks.done, status.tasks.total, status.tasks.pending
                ),
                theme.info_style,
            ),
            if runtime.batch.is_empty() {
                Span::raw("")
            } else {
                Span::styled(
                    format!(" · batch #{} {}", runtime.batch_number, runtime.batch.join(",")),
                    theme.dim_style,
                )
            },
        ]));

        if quiet {
            lines.push(Line::from(vec![
                Span::styled(" !     ", theme.warn_style),
                Span::styled(
                    "No structured activity for 90s+; provider may be busy or stalled.",
                    theme.warn_style,
                ),
            ]));
        }

        if !runtime.activity_kind.is_empty() || !runtime.activity_detail.is_empty() {
            let detail = if runtime.activity_detail.is_empty() {
                runtime.activity_label.clone()
            } else {
                runtime.activity_detail.clone()
            };
            let activity_elapsed = if active && runtime.activity_started_at_ms > 0 {
                format!(" · {}", duration_text(now.saturating_sub(runtime.activity_started_at_ms)))
            } else {
                String::new()
            };
            let detail_width = inner
                .width
                .saturating_sub(16)
                .saturating_sub(activity_elapsed.chars().count() as u16) as usize;
            lines.push(Line::from(vec![
                Span::styled(
                    format!(" {} ", activity_glyph(&runtime.activity_kind)),
                    theme.accent_style,
                ),
                Span::styled(
                    format!("{:<9}", empty_as(&runtime.activity_label, &runtime.activity_kind)),
                    theme.dim_style,
                ),
                Span::styled(clip(&single_line(&detail), detail_width), theme.info_style),
                Span::styled(activity_elapsed, theme.faint_style),
            ]));
        }

        if runtime.changed_files > 0 {
            lines.push(Line::from(vec![
                Span::styled(" Δ     ", theme.accent_style),
                Span::styled(
                    format!(
                        "{} files · +{} / -{}",
                        runtime.changed_files, runtime.additions, runtime.deletions
                    ),
                    theme.info_style,
                ),
            ]));
            let room = inner
                .height
                .saturating_sub(lines.len() as u16)
                .saturating_sub(1) as usize;
            for file in runtime.file_changes.iter().take(room.min(4)) {
                let stat = if file.status == "untracked" {
                    "new".to_string()
                } else if file.binary {
                    "binary".to_string()
                } else {
                    format!("+{} -{}", file.additions, file.deletions)
                };
                let path_width = inner.width.saturating_sub(16) as usize;
                lines.push(Line::from(vec![
                    Span::styled("       ", theme.faint_style),
                    Span::styled(clip(&file.path, path_width), theme.dim_style),
                    Span::styled(format!("  {stat}"), theme.faint_style),
                ]));
            }
        }
    } else {
        lines.push(Line::from(Span::styled(
            " No SDD projection for the selected feature.",
            theme.faint_style,
        )));
    }

    let available = inner.height as usize;
    if lines.len() < available {
        let event_slots = available.saturating_sub(lines.len());
        let latest_run = app
            .project
            .sdd_events
            .iter()
            .rev()
            .find(|event| event.event_type == "run_started" && !event.run_id.is_empty())
            .map(|event| event.run_id.as_str());
        let recent: Vec<&SddEventSummary> = app
            .project
            .sdd_events
            .iter()
            .filter(|event| {
                latest_run.map(|run| event.run_id == run).unwrap_or(true)
                    && matches!(event.category.as_str(), "workflow" | "error")
            })
            .rev()
            .take(event_slots)
            .collect();
        for event in recent.into_iter().rev() {
            lines.push(event_line(event, app, inner.width as usize));
        }
    }

    if lines.len() > available {
        lines = lines.split_off(lines.len() - available);
    }

    frame.render_widget(Paragraph::new(lines).style(theme.base), inner);
}

fn event_line(event: &SddEventSummary, app: &App, width: usize) -> Line<'static> {
    let theme = &app.theme;
    let failed = event.severity == "error"
        || matches!(event.status.as_str(), "failed" | "blocked" | "interrupted");
    let completed = matches!(event.status.as_str(), "passed" | "completed");
    let running = event.status == "running";

    let (glyph, glyph_style) = if failed {
        ("✗", theme.warn_style)
    } else if completed {
        ("✓", theme.good_style)
    } else if running {
        ("▶", theme.accent_style)
    } else if event.severity == "warning" {
        ("!", theme.warn_style)
    } else {
        ("•", theme.faint_style)
    };

    let time = clock(&event.timestamp);
    let body = if event.message.trim().is_empty() {
        event.event_type.clone()
    } else {
        single_line(event.message.trim())
    };

    Line::from(vec![
        Span::styled(format!(" {time} "), theme.faint_style),
        Span::styled(format!("{glyph} "), glyph_style),
        Span::styled(
            clip(&body, width.saturating_sub(12)),
            if failed { theme.warn_style } else { theme.dim_style },
        ),
    ])
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn duration_text(ms: u64) -> String {
    let seconds = ms / 1000;
    if seconds < 60 {
        return format!("{seconds}s");
    }
    let minutes = seconds / 60;
    if minutes < 60 {
        return format!("{}m {:02}s", minutes, seconds % 60);
    }
    format!("{}h {:02}m", minutes / 60, minutes % 60)
}

fn clock(timestamp: &str) -> String {
    timestamp
        .split('T')
        .nth(1)
        .map(|part| part.chars().take(8).collect::<String>())
        .unwrap_or_default()
}

fn activity_glyph(kind: &str) -> &'static str {
    match kind {
        "terminal" => "▸",
        "test" => "✓",
        "file" => "Δ",
        "thinking" => "⋯",
        "tool" => "◇",
        "error" => "✗",
        "done" => "✓",
        _ => "●",
    }
}

fn single_line(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn clip(text: &str, width: usize) -> String {
    if width == 0 {
        return String::new();
    }
    let count = text.chars().count();
    if count <= width {
        return text.to_string();
    }
    if width <= 1 {
        return "…".to_string();
    }
    text.chars().take(width - 1).collect::<String>() + "…"
}

fn empty_as<'a>(value: &'a str, fallback: &'a str) -> &'a str {
    if value.is_empty() { fallback } else { value }
}
