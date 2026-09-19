use ratatui::layout::Rect;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Paragraph, Wrap};
use ratatui::Frame;

use spectatui_core::speckit::SddEventSummary;

use crate::app::App;

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

    let title = Line::from(vec![
        Span::styled("─┤ ", theme.border_unfocused),
        Span::styled(
            format!("SDD Agent · {provider}"),
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

    let relevant: Vec<&SddEventSummary> = app
        .project
        .sdd_events
        .iter()
        .filter(|event| {
            matches!(
                event.category.as_str(),
                "assistant" | "reasoning_summary" | "tool" | "usage"
            )
        })
        .collect();

    let mut lines: Vec<Line> = Vec::new();
    let max_events = (inner.height as usize).max(4);
    for event in relevant.iter().rev().take(max_events).rev() {
        append_event_lines(&mut lines, event, app);
    }

    if lines.is_empty() {
        lines.push(Line::from(Span::styled(
            " Waiting for normalized SDD provider output…",
            theme.faint_style,
        )));
    }

    frame.render_widget(
        Paragraph::new(lines)
            .style(theme.base)
            .wrap(Wrap { trim: false }),
        inner,
    );
}

fn append_event_lines(lines: &mut Vec<Line<'static>>, event: &SddEventSummary, app: &App) {
    let theme = &app.theme;
    let provider = if event.provider.is_empty() {
        "agent"
    } else {
        event.provider.as_str()
    };
    let time = event
        .timestamp
        .split('T')
        .nth(1)
        .map(|part| part.chars().take(8).collect::<String>())
        .unwrap_or_default();

    match event.category.as_str() {
        "assistant" => {
            let mut parts = event.message.lines();
            if let Some(first) = parts.next() {
                lines.push(Line::from(vec![
                    Span::styled(format!(" {time} "), theme.faint_style),
                    Span::styled(format!("{provider}  "), theme.accent_bold),
                    Span::styled(first.to_string(), theme.info_style),
                ]));
            }
            for rest in parts {
                lines.push(Line::from(Span::styled(
                    format!("          {rest}"),
                    theme.info_style,
                )));
            }
        }
        "reasoning_summary" => {
            lines.push(Line::from(vec![
                Span::styled(format!(" {time} "), theme.faint_style),
                Span::styled("⋯ ", theme.faint_style),
                Span::styled(
                    if event.message.is_empty() {
                        "reasoning".to_string()
                    } else {
                        event.message.clone()
                    },
                    theme.dim_style,
                ),
            ]));
        }
        "tool" => {
            let status = if event.status.is_empty() {
                String::new()
            } else {
                format!(" · {}", event.status)
            };
            lines.push(Line::from(vec![
                Span::styled(format!(" {time} "), theme.faint_style),
                Span::styled("🔧 ", theme.accent_style),
                Span::styled(
                    format!("{}{}", event.message, status),
                    theme.dim_style,
                ),
            ]));
        }
        "usage" => {
            lines.push(Line::from(vec![
                Span::styled(format!(" {time} "), theme.faint_style),
                Span::styled("usage ", theme.faint_style),
                Span::styled(provider.to_string(), theme.dim_style),
            ]));
        }
        _ => {}
    }
}
