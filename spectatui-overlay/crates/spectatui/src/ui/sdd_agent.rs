use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};
use ratatui::Frame;

use spectatui_core::speckit::SddEventSummary;

use crate::app::App;

const SPINNER: [&str; 8] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"];

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let theme = &app.theme;
    let provider = app
        .project
        .sdd_status
        .as_ref()
        .map(|s| s.runtime.agent.as_str())
        .filter(|s| !s.is_empty())
        .or_else(|| {
            app.project
                .sdd_events
                .iter()
                .rev()
                .find(|e| !e.provider.is_empty())
                .map(|e| e.provider.as_str())
        })
        .unwrap_or("idle");

    let running = app
        .project
        .sdd_status
        .as_ref()
        .map(|s| s.status == "running")
        .unwrap_or(false);
    let marker = if running {
        SPINNER[(app.indexing_tick as usize) % SPINNER.len()]
    } else {
        "·"
    };

    let title = Line::from(vec![
        Span::styled("─┤ ", theme.border_unfocused),
        Span::styled(
            format!("{marker} SDD Activity · {provider}"),
            theme.title_unfocused,
        ),
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

    let latest_run = app
        .project
        .sdd_events
        .iter()
        .rev()
        .find(|event| event.event_type == "run_started" && !event.run_id.is_empty())
        .map(|event| event.run_id.as_str());

    let relevant: Vec<&SddEventSummary> = app
        .project
        .sdd_events
        .iter()
        .filter(|event| {
            latest_run.map(|run| event.run_id == run).unwrap_or(true)
                && matches!(
                    event.category.as_str(),
                    "agent"
                        | "assistant"
                        | "reasoning_summary"
                        | "command"
                        | "tool"
                        | "file_change"
                        | "gate"
                        | "usage"
                        | "error"
                )
        })
        .collect();

    let mut lines: Vec<Line> = relevant
        .iter()
        .rev()
        .take((inner.height as usize).saturating_mul(4).max(12))
        .rev()
        .map(|event| event_line(event, app, inner.width as usize))
        .collect();

    let available = inner.height as usize;
    if lines.len() > available {
        lines = lines.split_off(lines.len() - available);
    }

    if lines.is_empty() {
        let state = if running {
            " Agent is active; waiting for the next structured event…"
        } else {
            " Waiting for normalized SDD provider activity…"
        };
        lines.push(Line::from(Span::styled(state, theme.faint_style)));
    }

    frame.render_widget(Paragraph::new(lines).style(theme.base), inner);
}

fn event_line(event: &SddEventSummary, app: &App, width: usize) -> Line<'static> {
    let theme = &app.theme;
    let time = clock(&event.timestamp);
    let failed = event.severity == "error"
        || matches!(event.status.as_str(), "failed" | "blocked" | "interrupted");
    let completed = matches!(event.status.as_str(), "passed" | "completed" | "success");
    let running = matches!(event.status.as_str(), "running" | "started");
    let duration = event
        .duration_ms
        .filter(|value| *value > 0)
        .map(|value| format!(" · {}", duration_text(value)))
        .unwrap_or_default();

    let (glyph, label, body, style) = match event.category.as_str() {
        "agent" => (
            if failed { "✗" } else if completed { "✓" } else { "●" },
            "agent",
            single_line(&event.message),
            if failed { theme.warn_style } else { theme.accent_bold },
        ),
        "assistant" => (
            "AI",
            if event.provider.is_empty() { "agent" } else { event.provider.as_str() },
            single_line(&event.message),
            theme.info_style,
        ),
        "reasoning_summary" => (
            "⋯",
            "think",
            single_line(&event.message),
            theme.dim_style,
        ),
        "command" => (
            if failed { "✗" } else if completed { "✓" } else { "▸" },
            "terminal",
            single_line(if event.command.is_empty() { &event.message } else { &event.command }),
            if failed { theme.warn_style } else if running { theme.accent_style } else { theme.dim_style },
        ),
        "file_change" => (
            "Δ",
            "file",
            single_line(&event.message),
            theme.info_style,
        ),
        "gate" => (
            if failed { "✗" } else if completed { "✓" } else { "▸" },
            "test",
            single_line(if event.command.is_empty() { &event.message } else { &event.command }),
            if failed { theme.warn_style } else if completed { theme.good_style } else { theme.accent_style },
        ),
        "tool" => (
            if failed { "✗" } else if completed { "✓" } else { "◇" },
            "tool",
            single_line(&event.message),
            if failed { theme.warn_style } else { theme.dim_style },
        ),
        "usage" => (
            "·",
            "usage",
            if event.provider.is_empty() { "usage".to_string() } else { event.provider.clone() },
            theme.faint_style,
        ),
        "error" => (
            "✗",
            "error",
            single_line(&event.message),
            theme.warn_style,
        ),
        _ => (
            "·",
            "event",
            single_line(&event.message),
            theme.dim_style,
        ),
    };

    let prefix_width = 8 + glyph.chars().count() + 1 + label.chars().count() + 1;
    let body_width = width.saturating_sub(prefix_width + duration.chars().count());

    Line::from(vec![
        Span::styled(format!(" {time} "), theme.faint_style),
        Span::styled(format!("{glyph} "), style),
        Span::styled(format!("{label:<8}"), theme.dim_style),
        Span::styled(clip(&body, body_width), style),
        Span::styled(duration, theme.faint_style),
    ])
}

fn clock(timestamp: &str) -> String {
    timestamp
        .split('T')
        .nth(1)
        .map(|part| part.chars().take(8).collect::<String>())
        .unwrap_or_default()
}

fn duration_text(ms: u64) -> String {
    if ms < 1000 {
        return format!("{ms}ms");
    }
    let seconds = ms / 1000;
    if seconds < 60 {
        return format!("{seconds}s");
    }
    format!("{}m {:02}s", seconds / 60, seconds % 60)
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
