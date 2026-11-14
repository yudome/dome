mod greetd;

use ratatui::{
    DefaultTerminal,
    buffer::Buffer,
    crossterm::{
        event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers, MouseButton, MouseEventKind},
        execute,
    },
    layout::Rect,
    style::{Color, Style},
    widgets::{Block, BorderType, Widget},
};
use serde_json::Value;
use std::{
    env, fs,
    io::{self, Write},
    os::unix::net::UnixStream,
    path::Path,
    process::Command,
    time::{Duration, Instant},
};

const SESSION: &[&str] = &["/usr/bin/start-hyprland"];
const SESSION_ENV: &[&str] = &["XDG_SESSION_TYPE=wayland", "XDG_CURRENT_DESKTOP=Hyprland", "XDG_SESSION_DESKTOP=Hyprland"];

struct Settings(Value);

impl Settings {
    fn load(config: &Path) -> Self {
        let cache = config.with_file_name("cache").join("settings.json");
        if let Some(live) = fs::read_to_string(cache).ok().and_then(|text| serde_json::from_str::<Value>(&text).ok()) {
            if live.as_object().is_some_and(|map| !map.is_empty()) {
                return Settings(live);
            }
        }
        let mut flat = serde_json::Map::new();
        if let Some(table) = fs::read_to_string(config).ok().and_then(|text| text.parse::<toml::Table>().ok()) {
            for (key, value) in table {
                match value {
                    toml::Value::Table(section) => flat.extend(section.into_iter().map(|(k, v)| (k, serde_json::to_value(v).unwrap_or(Value::Null)))),
                    other => {
                        flat.insert(key, serde_json::to_value(other).unwrap_or(Value::Null));
                    }
                }
            }
        }
        Settings(Value::Object(flat))
    }

    fn text(&self, key: &str, fallback: &str) -> String {
        self.0[key].as_str().unwrap_or(fallback).to_string()
    }

    fn color(&self, key: &str, fallback: &str) -> Color {
        let text = self.text(key, fallback);
        let hex = text.trim_start_matches('#');
        let hex = if hex.len() == 8 { &hex[2..] } else { hex };
        u32::from_str_radix(hex, 16).map(|rgb| Color::Rgb((rgb >> 16) as u8, (rgb >> 8) as u8, rgb as u8)).unwrap_or(Color::Reset)
    }
}

struct Theme {
    surface: Color,
    foreground: Color,
    dim: Color,
    red: Color,
    lock: String,
    eye: String,
    eye_off: String,
    power: [String; 2],
    wrong: String,
    format: String,
    digits: Vec<(char, Vec<String>)>,
    cooldown: Duration,
}

impl Theme {
    fn new(settings: &Settings) -> Self {
        let digits = settings.0["lockDigits"]
            .as_array()
            .map(|glyphs| {
                glyphs
                    .iter()
                    .filter_map(|glyph| {
                        let parts: Vec<String> = glyph.as_array()?.iter().filter_map(|row| row.as_str().map(str::to_string)).collect();
                        let key = parts.first()?.chars().next()?;
                        (parts.len() == 6).then(|| (key, parts[1..].to_vec()))
                    })
                    .collect()
            })
            .unwrap_or_default();
        Theme {
            surface: settings.color("surface", "#101010"),
            foreground: settings.color("foreground", "#ffffff"),
            dim: settings.color("dim", "#3f3f3f"),
            red: settings.color("red", "#e05252"),
            lock: settings.text("iconLock", "\u{f023}"),
            eye: settings.text("iconEye", "\u{f06e}"),
            eye_off: settings.text("iconEyeOff", "\u{f070}"),
            power: [settings.text("iconPowerOff", "\u{f011}"), settings.text("iconReboot", "\u{ead2}")],
            wrong: settings.text("lockWrongText", "Wrong password"),
            format: settings.text("lockClockFormat", "HH:mm"),
            digits,
            cooldown: Duration::from_millis(settings.0["lockCooldownMs"].as_u64().unwrap_or(3000)),
        }
    }
}

fn now() -> libc::tm {
    unsafe {
        let stamp = libc::time(std::ptr::null_mut());
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&stamp, &mut tm);
        tm
    }
}

fn format_time(format: &str, tm: &libc::tm) -> String {
    let hour12 = if tm.tm_hour % 12 == 0 { 12 } else { tm.tm_hour % 12 };
    let tokens: [(&str, String); 10] = [
        ("AP", if tm.tm_hour < 12 { "AM" } else { "PM" }.into()),
        ("ap", if tm.tm_hour < 12 { "am" } else { "pm" }.into()),
        ("HH", format!("{:02}", tm.tm_hour)),
        ("hh", format!("{:02}", hour12)),
        ("mm", format!("{:02}", tm.tm_min)),
        ("ss", format!("{:02}", tm.tm_sec)),
        ("H", tm.tm_hour.to_string()),
        ("h", hour12.to_string()),
        ("m", tm.tm_min.to_string()),
        ("s", tm.tm_sec.to_string()),
    ];
    let mut out = String::new();
    let mut rest = format;
    'scan: while let Some(first) = rest.chars().next() {
        for (token, value) in &tokens {
            if let Some(tail) = rest.strip_prefix(token) {
                out.push_str(value);
                rest = tail;
                continue 'scan;
            }
        }
        out.push(first);
        rest = &rest[first.len_utf8()..];
    }
    out
}

fn block_rows(text: &str, digits: &[(char, Vec<String>)]) -> Vec<String> {
    let mut lines = vec![String::new(); 5];
    let mut first = true;
    for ch in text.chars() {
        let Some((_, rows)) = digits.iter().find(|(key, _)| *key == ch) else { continue };
        for (line, row) in lines.iter_mut().zip(rows) {
            if !first {
                line.push_str("  ");
            }
            line.push_str(&row.replace('#', "██").replace(' ', "  "));
        }
        first = false;
    }
    lines
}

struct Greeter {
    user: String,
    theme: Theme,
    password: String,
    message: String,
    focus: usize,
    hover: Option<usize>,
    reveal: bool,
    checking: bool,
    failed_at: Option<Instant>,
}

struct Layout {
    top: u16,
    box_width: u16,
    box_col: u16,
    power_col: u16,
    power_row: u16,
}

impl Layout {
    fn new(area: Rect, clock: &[String]) -> Self {
        let box_width = clock.first().map_or(0, |line| line.chars().count() as u16).max(14);
        Layout {
            top: area.height.saturating_sub(11) / 2,
            box_width,
            box_col: center(area.width, box_width),
            power_col: center(area.width, 5),
            power_row: area.height.saturating_sub(2),
        }
    }

    fn slots(&self) -> [(usize, u16, u16, u16); 3] {
        [
            (1, self.box_col + self.box_width - 4, self.top + 7, 3),
            (2, self.power_col.saturating_sub(1), self.power_row, 3),
            (3, self.power_col + 3, self.power_row, 3),
        ]
    }

    fn hit(&self, col: u16, row: u16) -> Option<usize> {
        self.slots().into_iter().find(|&(_, x, y, w)| row == y && col >= x && col < x + w).map(|(slot, ..)| slot)
    }
}

fn center(total: u16, length: u16) -> u16 {
    total.saturating_sub(length) / 2
}

impl Greeter {
    fn clock(&self) -> Vec<String> {
        block_rows(&format_time(&self.theme.format, &now()), &self.theme.digits)
    }

    fn render(&self, area: Rect, buf: &mut Buffer) {
        let theme = &self.theme;
        let plain = Style::new().fg(theme.foreground).bg(theme.surface);
        buf.set_style(area, plain);
        let clock = self.clock();
        let layout = Layout::new(area, &clock);

        for (index, line) in clock.iter().enumerate() {
            let width = line.chars().count() as u16;
            buf.set_string(center(area.width, width), layout.top + index as u16, line, plain);
        }

        let wrong = self.failed_at.is_some() && !self.message.is_empty();
        let ink = if self.checking { plain.fg(theme.dim) } else { plain };
        Block::bordered()
            .border_type(BorderType::Rounded)
            .border_style(if wrong { plain.fg(theme.red) } else { plain })
            .render(Rect::new(layout.box_col, layout.top + 6, layout.box_width, 3).intersection(area), buf);
        buf.set_string(layout.box_col + 2, layout.top + 7, &theme.lock, ink);

        let field: String = if self.reveal { self.password.clone() } else { "●".repeat(self.password.chars().count()) };
        let skip = field.chars().count().saturating_sub(layout.box_width as usize - 8);
        buf.set_string(layout.box_col + 4, layout.top + 7, field.chars().skip(skip).collect::<String>(), ink);

        let message: String = self.message.chars().take(area.width as usize).collect();
        buf.set_string(center(area.width, message.chars().count() as u16), layout.top + 10, &message, plain.fg(theme.red));

        for (slot, x, y, width) in layout.slots() {
            let lit = self.focus == slot || self.hover == Some(slot);
            let style = if lit { Style::new().fg(theme.surface).bg(theme.foreground) } else { plain };
            let glyph = match slot {
                1 if self.reveal => &theme.eye_off,
                1 => &theme.eye,
                _ => &theme.power[slot - 2],
            };
            buf.set_string(x, y, " ".repeat(width as usize), style);
            buf.set_string(x + 1, y, glyph, style);
        }
    }

    fn activate(&mut self, slot: usize, terminal: &mut DefaultTerminal) {
        match slot {
            0 => self.submit(terminal),
            1 => self.reveal = !self.reveal,
            _ => {
                let _ = Command::new("systemctl").arg(if slot == 2 { "poweroff" } else { "reboot" }).spawn();
            }
        }
    }

    fn submit(&mut self, terminal: &mut DefaultTerminal) {
        if self.password.is_empty() || self.failed_at.is_some_and(|at| at.elapsed() < self.theme.cooldown) {
            return;
        }
        self.checking = true;
        self.reveal = false;
        let _ = terminal.draw(|frame| self.render(frame.area(), frame.buffer_mut()));

        let result = match env::var("GREETD_SOCK") {
            Ok(path) => UnixStream::connect(path).map_err(greetd::Fail::from).and_then(|mut sock| greetd::login(&mut sock, &self.user, &self.password, SESSION, SESSION_ENV)),
            Err(_) => Err(greetd::Fail::Broken("GREETD_SOCK is not set".into())),
        };
        self.checking = false;
        self.password.clear();

        match result {
            Ok(()) => {
                ratatui::restore();
                std::process::exit(0);
            }
            Err(greetd::Fail::Wrong) => self.message = self.theme.wrong.clone(),
            Err(greetd::Fail::Broken(text)) => self.message = text,
        }
        self.failed_at = Some(Instant::now());
    }

    fn run(&mut self, terminal: &mut DefaultTerminal) -> io::Result<()> {
        loop {
            if self.failed_at.is_some_and(|at| at.elapsed() >= self.theme.cooldown) {
                self.failed_at = None;
                self.message.clear();
            }
            terminal.draw(|frame| self.render(frame.area(), frame.buffer_mut()))?;
            if !event::poll(Duration::from_millis(500))? {
                continue;
            }
            match event::read()? {
                Event::Key(key) if key.kind != KeyEventKind::Release => match key.code {
                    KeyCode::Tab => self.focus = (self.focus + 1) % 4,
                    KeyCode::BackTab => self.focus = (self.focus + 3) % 4,
                    KeyCode::Left if self.focus > 0 => self.focus = (self.focus - 1).max(1),
                    KeyCode::Right if self.focus > 0 => self.focus = (self.focus + 1).min(3),
                    KeyCode::Esc if self.focus > 0 => self.focus = 0,
                    KeyCode::Esc if env::var_os("GREETD_SOCK").is_none() => return Ok(()),
                    KeyCode::Esc => {
                        self.password.clear();
                        self.message.clear();
                    }
                    KeyCode::Enter => self.activate(self.focus, terminal),
                    KeyCode::Backspace => {
                        self.focus = 0;
                        self.password.pop();
                    }
                    KeyCode::Char(ch) if !key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER) => {
                        self.focus = 0;
                        if self.password.len() < 256 {
                            self.password.push(ch);
                            self.message.clear();
                        }
                    }
                    _ => {}
                },
                Event::Mouse(mouse) => {
                    let area = terminal.get_frame().area();
                    self.hover = Layout::new(area, &self.clock()).hit(mouse.column, mouse.row);
                    if let (MouseEventKind::Down(MouseButton::Left), Some(slot)) = (mouse.kind, self.hover) {
                        self.activate(slot, terminal);
                    }
                }
                _ => {}
            }
        }
    }
}

fn hex(color: Color) -> String {
    match color {
        Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
        _ => "#000000".into(),
    }
}

fn main() -> io::Result<()> {
    let mut args = env::args().skip(1);
    let (Some(user), Some(config)) = (args.next(), args.next()) else {
        eprintln!("usage: greeter <user> <shell/config.toml>");
        std::process::exit(2);
    };
    let theme = Theme::new(&Settings::load(Path::new(&config)));

    let mut out = io::stdout();
    write!(out, "\x1b]11;{}\x1b\\\x1b]10;{}\x1b\\", hex(theme.surface), hex(theme.foreground))?;
    let mut terminal = ratatui::init();
    execute!(io::stdout(), EnableMouseCapture)?;

    let mut greeter = Greeter { user, theme, password: String::new(), message: String::new(), focus: 0, hover: None, reveal: false, checking: false, failed_at: None };
    let result = greeter.run(&mut terminal);

    execute!(io::stdout(), DisableMouseCapture)?;
    ratatui::restore();
    write!(io::stdout(), "\x1b]110\x1b\\\x1b]111\x1b\\")?;
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clock_follows_the_config_font() {
        let tm = libc::tm { tm_hour: 13, tm_min: 5, tm_sec: 9, ..unsafe { std::mem::zeroed() } };
        assert_eq!(format_time("HH:mm", &tm), "13:05");
        assert_eq!(format_time("h:mm:ss AP", &tm), "1:05:09 PM");
        let digits = vec![('1', vec!["  #".into(); 5]), (':', vec![" ".into(), "#".into(), " ".into(), "#".into(), " ".into()])];
        assert_eq!(block_rows("1:1", &digits)[1], "    ██  ██      ██");
    }
}
