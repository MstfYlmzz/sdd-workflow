use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Paragraph};
use ratatui::Frame;

use spectatui_core::speckit::SddEventSummary;

use crate::app::{App, Pane};

const SPINNER: [&str; 8] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"];

pub fn draw(frame: &mut Frame, app: &App, area: Rect) {
    let theme = &app.theme;
    let focused = app.focused_pane == Pane::SddActivity;
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
        Span::styled("─┤ ", border_style),
        Span::styled(format!("{marker} SDD Activity · {provider}"), title_style),
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

    if inner.height == 0 || inner.width == 0 {
        app.sdd_activity_scroll_max.set(0);
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

    let mut lines: Vec<Line<'static>> = Vec::new();
    for event in relevant {
        lines.extend(event_lines(event, app, inner.width as usize));
    }

    if lines.is_empty() {
        let state = if running {
            " Agent is active; waiting for the next structured event…"
        } else {
            " Waiting for normalized SDD provider activity…"
        };
        lines.push(Line::from(Span::styled(state.to_string(), theme.faint_style)));
    }

    let available = inner.height as usize;
    let max_scroll = lines.len().saturating_sub(available);
    app.sdd_activity_scroll_max
        .set(max_scroll.min(u16::MAX as usize) as u16);
    let back = (app.sdd_activity_scroll as usize).min(max_scroll);
    let end = lines.len().saturating_sub(back);
    let start = end.saturating_sub(available);
    let visible: Vec<Line<'static>> = lines[start..end].to_vec();

    frame.render_widget(Paragraph::new(visible).style(theme.base), inner);
}

fn event_lines(event: &SddEventSummary, app: &App, width: usize) -> Vec<Line<'static>> {
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
        "command" => {
            let is_test = event.event_type == "gate_command_started";
            (
                if failed { "✗" } else if completed { "✓" } else if is_test { "▷" } else { "▸" },
                if is_test { "test" } else { "terminal" },
                single_line(if event.command.is_empty() { &event.message } else { &event.command }),
                if failed { theme.warn_style } else if running { theme.accent_style } else { theme.dim_style },
            )
        },
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
        "tool" => {
            let body = single_line(&event.message);
            let useful = if body.is_empty() || body.eq_ignore_ascii_case("tool") {
                "working".to_string()
            } else {
                body
            };
            (
                if failed { "✗" } else if completed { "✓" } else { "◇" },
                "tool",
                useful,
                if failed { theme.warn_style } else { theme.dim_style },
            )
        },
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

    let prefix = format!(" {time} {glyph} {label:<8}");
    let prefix_width = prefix.chars().count();
    let first_body_width = width
        .saturating_sub(prefix_width)
        .saturating_sub(duration.chars().count())
        .max(1);
    let continuation_width = width.saturating_sub(prefix_width).max(1);
    let wrapped = wrap_text(&body, first_body_width, continuation_width);

    let mut out = Vec::with_capacity(wrapped.len().max(1));
    if wrapped.is_empty() {
        out.push(Line::from(vec![
            Span::styled(prefix, theme.faint_style),
            Span::styled(duration, theme.faint_style),
        ]));
        return out;
    }

    for (index, part) in wrapped.into_iter().enumerate() {
        if index == 0 {
            out.push(Line::from(vec![
                Span::styled(format!(" {time} "), theme.faint_style),
                Span::styled(format!("{glyph} "), style),
                Span::styled(format!("{label:<8}"), theme.dim_style),
                Span::styled(part, style),
                Span::styled(duration.clone(), theme.faint_style),
            ]));
        } else {
            out.push(Line::from(vec![
                Span::styled(" ".repeat(prefix_width), theme.faint_style),
                Span::styled(part, style),
            ]));
        }
    }
    out
}

fn wrap_text(text: &str, first_width: usize, continuation_width: usize) -> Vec<String> {
    if text.is_empty() {
        return Vec::new();
    }

    let mut out = Vec::new();
    let mut current = String::new();
    let mut width = first_width.max(1);

    for word in text.split_whitespace() {
        let word_len = word.chars().count();
        let sep = usize::from(!current.is_empty());
        if current.chars().count() + sep + word_len <= width {
            if !current.is_empty() {
                current.push(' ');
            }
            current.push_str(word);
            continue;
        }

        if !current.is_empty() {
            out.push(std::mem::take(&mut current));
            width = continuation_width.max(1);
        }

        if word_len <= width {
            current.push_str(word);
            continue;
        }

        let mut chunk = String::new();
        for ch in word.chars() {
            if chunk.chars().count() >= width {
                out.push(std::mem::take(&mut chunk));
                width = continuation_width.max(1);
            }
            chunk.push(ch);
        }
        current = chunk;
    }

    if !current.is_empty() {
        out.push(current);
    }
    out
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
