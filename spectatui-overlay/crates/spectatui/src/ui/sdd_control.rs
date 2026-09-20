use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Borders, Clear, Paragraph};
use ratatui::Frame;

use crate::app::App;

fn centered_rect(w: u16, h: u16, outer: Rect) -> Rect {
    let width = w.min(outer.width.saturating_sub(2)).max(1);
    let height = h.min(outer.height.saturating_sub(2)).max(1);
    let x = outer.x + outer.width.saturating_sub(width) / 2;
    let y = outer.y + outer.height.saturating_sub(height) / 2;
    Rect::new(x, y, width, height)
}

pub fn draw(frame: &mut Frame, app: &App) {
    let theme = &app.theme;
    let area = centered_rect(86, 25, frame.area());
    frame.render_widget(Clear, area);

    let title_text = if app.sdd_route_editing {
        "SDD Route"
    } else {
        "SDD Control"
    };
    let title = Line::from(vec![
        Span::styled("─┤ ", theme.border_focused),
        Span::styled(title_text, theme.title_focused),
        Span::styled(" ├", theme.border_focused),
    ]);
    let block = Block::default()
        .borders(Borders::ALL)
        .border_type(BorderType::Rounded)
        .border_style(theme.border_focused)
        .title(title)
        .padding(super::PANEL_PADDING);
    let inner = block.inner(area);
    frame.render_widget(block, area);

    if app.sdd_route_editing {
        draw_editor(frame, app, inner);
    } else {
        draw_control(frame, app, inner);
    }
}

fn draw_control(frame: &mut Frame, app: &App, area: Rect) {
    let theme = &app.theme;
    let mut lines = Vec::new();
    let protected_state = app
        .project
        .sdd_status
        .as_ref()
        .map(|status| {
            matches!(status.status.as_str(), "running" | "interrupted")
                && matches!(status.stage.as_str(), "implement" | "converge")
        })
        .unwrap_or(false);
    lines.push(Line::from(vec![
        Span::styled(" Full workflow ", theme.dim_style),
        if protected_state {
            Span::styled("[f] new run locked  ", theme.faint_style)
        } else {
            Span::styled("[f] new run  ", theme.accent_bold)
        },
        Span::styled("[R] resume", theme.accent_bold),
    ]));
    if protected_state {
        lines.push(Line::from(Span::styled(
            "  Active implementation is protected from accidental restart.",
            theme.warn_style,
        )));
    }
    lines.push(Line::default());
    lines.push(Line::from(vec![
        Span::styled("  Stage       ", theme.faint_style),
        Span::styled("Agent      ", theme.faint_style),
        Span::styled("Model                         ", theme.faint_style),
        Span::styled("Effort", theme.faint_style),
    ]));

    let Some(config) = &app.project.sdd_config else {
        lines.push(Line::from(Span::styled(
            "  No SDD routing projection. Run sdd upgrade or any SDD command.",
            theme.warn_style,
        )));
        frame.render_widget(Paragraph::new(lines).style(theme.base), area);
        return;
    };

    for (i, route) in config.routes.iter().enumerate() {
        let selected = i == app.sdd_control_index;
        let style = if selected {
            Style::default().fg(theme.sel_fg).bg(theme.sel).add_modifier(Modifier::BOLD)
        } else {
            theme.dim_style
        };
        let prefix = if selected { "❯ " } else { "  " };
        let model = if route.model.chars().count() > 28 {
            let short: String = route.model.chars().take(27).collect();
            format!("{short}…")
        } else {
            route.model.clone()
        };
        lines.push(Line::from(Span::styled(
            format!(
                "{prefix}{:<11} {:<10} {:<29} {}",
                route.stage, route.agent, model, route.effort
            ),
            style,
        )));
    }

    lines.push(Line::default());
    lines.push(Line::from(vec![
        Span::styled("[↑/↓] stage  ", theme.faint_style),
        Span::styled("[r] run stage  ", theme.accent_bold),
        Span::styled("[e] edit route  ", theme.accent_bold),
        Span::styled("[esc] close", theme.faint_style),
    ]));
    frame.render_widget(Paragraph::new(lines).style(theme.base), area);
}

fn draw_editor(frame: &mut Frame, app: &App, area: Rect) {
    let theme = &app.theme;
    let stage = app
        .selected_sdd_route()
        .map(|r| r.stage.as_str())
        .unwrap_or("unknown");

    let row = |idx: usize, label: &str, value: String| {
        let selected = app.sdd_route_field == idx;
        Line::from(vec![
            Span::styled(
                if selected { " ❯ " } else { "   " },
                if selected { theme.accent_bold } else { theme.faint_style },
            ),
            Span::styled(format!("{label:<8}"), theme.dim_style),
            Span::styled(
                value,
                if selected {
                    Style::default()
                        .fg(theme.sel_fg)
                        .bg(theme.sel)
                        .add_modifier(Modifier::BOLD)
                } else {
                    theme.info_style
                },
            ),
        ])
    };

    let model_options = app.sdd_provider_models(&app.sdd_edit_agent);
    let model_index = model_options
        .iter()
        .position(|model| model == &app.sdd_edit_model)
        .map(|idx| idx + 1)
        .unwrap_or(0);

    let mut lines = vec![
        Line::from(vec![
            Span::styled(" Stage  ", theme.dim_style),
            Span::styled(stage.to_string(), theme.accent_bold),
        ]),
        Line::default(),
        row(0, "Agent", app.sdd_edit_agent.clone()),
        row(
            1,
            "Model",
            if model_options.is_empty() {
                app.sdd_edit_model.clone()
            } else {
                format!(
                    "{}  [{}/{}]",
                    app.sdd_edit_model,
                    model_index,
                    model_options.len()
                )
            },
        ),
        row(2, "Effort", app.sdd_edit_effort.clone()),
        Line::default(),
    ];

    if app.sdd_route_field == 1 && !model_options.is_empty() {
        let preview = model_options
            .iter()
            .enumerate()
            .map(|(idx, model)| {
                if model == &app.sdd_edit_model {
                    format!("❯{model}")
                } else {
                    format!(" {model}")
                }
            })
            .collect::<Vec<_>>()
            .join("  ");
        lines.push(Line::from(vec![
            Span::styled(" Models  ", theme.faint_style),
            Span::styled(preview, theme.dim_style),
        ]));
    }

    if app.sdd_edit_agent == "cursor" {
        lines.push(Line::from(Span::styled(
            " Cursor CLI has no effort flag; effort is fixed to medium metadata.",
            theme.faint_style,
        )));
    }
    lines.push(Line::from(Span::styled(
        " ↑/↓ field · ←/→ choose value · Enter next value",
        theme.faint_style,
    )));
    lines.push(Line::from(vec![
        Span::styled(" Ctrl+S ", theme.accent_bold),
        Span::styled("save   ", theme.dim_style),
        Span::styled("Esc ", theme.faint_style),
        Span::styled("cancel", theme.dim_style),
    ]));
    frame.render_widget(Paragraph::new(lines).style(theme.base), area);
}
