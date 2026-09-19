use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};
use ratatui::Frame;

use spectatui_core::speckit::SddEventSummary;

use crate::app::App;

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
        lines.push(Line::from(vec![
            Span::styled(" tasks ", theme.dim_style),
            Span::styled(
                format!(
                    "{}/{} done · {} pending · {} blocked",
                    status.tasks.done, status.tasks.total, status.tasks.pending, status.tasks.blocked
                ),
                theme.info_style,
            ),
        ]));

        if !status.runtime.batch.is_empty() {
            lines.push(Line::from(vec![
                Span::styled(" batch ", theme.dim_style),
                Span::styled(
                    format!("#{} {}", status.runtime.batch_number, status.runtime.batch.join(", ")),
                    theme.info_style,
                ),
            ]));
        }

        if !status.runtime.agent.is_empty() || !status.runtime.model.is_empty() {
            lines.push(Line::from(vec![
                Span::styled(" route ", theme.dim_style),
                Span::styled(
                    format!(
                        "{}/{} · {}",
                        status.runtime.agent, status.runtime.model, status.runtime.effort
                    ),
                    theme.info_style,
                ),
            ]));
        }
    } else {
        lines.push(Line::from(Span::styled(
            " No SDD projection for the selected feature.",
            theme.faint_style,
        )));
    }

    let available = inner.height as usize;
    if lines.len() < available {
        lines.push(Line::default());
    }
    let event_slots = available.saturating_sub(lines.len());
    if event_slots > 0 {
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
                    && !matches!(
                        event.category.as_str(),
                        "assistant" | "reasoning_summary" | "tool" | "usage"
                    )
            })
            .rev()
            .take(event_slots)
            .collect();
        for event in recent.into_iter().rev() {
            lines.push(event_line(event, app));
        }
    }

    frame.render_widget(Paragraph::new(lines).style(theme.base), inner);
}

fn event_line(event: &SddEventSummary, app: &App) -> Line<'static> {
    let theme = &app.theme;
    let failed = event.severity == "error"
        || matches!(
            event.status.as_str(),
            "failed" | "blocked" | "interrupted"
        );
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

    let time = event
        .timestamp
        .split('T')
        .nth(1)
        .map(|part| part.chars().take(8).collect::<String>())
        .unwrap_or_default();
    let body = if event.message.trim().is_empty() {
        event.event_type.clone()
    } else {
        event.message.trim().to_string()
    };

    Line::from(vec![
        Span::styled(format!(" {time} "), theme.faint_style),
        Span::styled(format!("{glyph} "), glyph_style),
        Span::styled(body, if failed { theme.warn_style } else { theme.dim_style }),
    ])
}
