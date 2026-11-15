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
const SESSION_DIRS: [&str; 2] = ["/usr/share/wayland-sessions", "/usr/share/xsessions"];

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
    switch: String,
    back: String,
    forward: String,
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
            switch: settings.text("iconUser", "\u{f007}"),
            back: settings.text("iconChevron", "\u{f053}"),
            forward: settings.text("iconRight", "\u{f054}"),
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

fn home_of(user: &str) -> String {
    fs::read_to_string("/etc/passwd")
        .ok()
        .and_then(|text| {
            text.lines().find_map(|line| {
                let fields: Vec<&str> = line.split(':').collect();
                (fields.len() >= 7 && fields[0] == user).then(|| fields[5].to_string())
            })
        })
        .unwrap_or_else(|| format!("/home/{user}"))
}

fn quiet_session(user: &str, argv: &[String]) -> Vec<String> {
    let state = format!("{}/.local/state", home_of(user));
    let log = format!("{state}/session.log");
    let _ = fs::create_dir_all(&state);
    let wrapper = env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().and_then(|dir| dir.parent()).map(|dir| dir.join("session")))
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|| "/usr/bin/start-hyprland".into());

    let mut cmd = vec![wrapper, log];
    cmd.extend(argv.iter().cloned());
    cmd
}

fn read_users(default: &str) -> Vec<String> {
    let mut out = vec![default.to_string()];
    if let Ok(text) = fs::read_to_string("/etc/passwd") {
        for line in text.lines() {
            let fields: Vec<&str> = line.split(':').collect();
            if fields.len() < 7 {
                continue;
            }
            let uid: u32 = fields[2].parse().unwrap_or(0);
            if !(1000..65534).contains(&uid) || fields[6].contains("nologin") || fields[6].ends_with("false") {
                continue;
            }
            if !out.iter().any(|known| known == fields[0]) {
                out.push(fields[0].to_string());
            }
        }
    }
    out
}

fn read_sessions() -> Vec<(String, Vec<String>, String)> {
    let mut out = vec![(
        "hyprland".to_string(),
        SESSION.iter().map(|arg| arg.to_string()).collect::<Vec<_>>(),
        "Hyprland".to_string(),
    )];
    for dir in SESSION_DIRS {
        let Ok(entries) = fs::read_dir(dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("desktop") {
                continue;
            }
            let Ok(text) = fs::read_to_string(&path) else { continue };
            let Some(exec) = text.lines().find_map(|line| line.strip_prefix("Exec=")) else { continue };
            let argv: Vec<String> = exec
                .split_whitespace()
                .filter(|part| !part.starts_with('%'))
                .map(str::to_string)
                .collect();
            if argv.is_empty() {
                continue;
            }
            let id = path.file_stem().and_then(|stem| stem.to_str()).unwrap_or("session").to_string();
            let name = text
                .lines()
                .find_map(|line| line.strip_prefix("Name="))
                .map(str::to_string)
                .unwrap_or_else(|| id.clone());
            if out.iter().any(|(_, known, _)| known == &argv) {
                continue;
            }
            out.push((id, argv, name));
        }
    }
    out
}

struct Choice {
    users: Vec<String>,
    sessions: Vec<(String, Vec<String>, String)>,
    user: usize,
    session: usize,
    open: bool,
    row: usize,
}

impl Choice {
    fn value(&self, row: usize) -> String {
        match row {
            0 => self.sessions.get(self.session).map(|(_, _, name)| name.clone()),
            _ => self.users.get(self.user).cloned(),
        }
        .unwrap_or_default()
    }

    fn step(&mut self, delta: i32) {
        let count = if self.row == 0 { self.sessions.len() } else { self.users.len() };
        if count == 0 {
            return;
        }
        let current = if self.row == 0 { self.session } else { self.user };
        let next = (current as i32 + delta).rem_euclid(count as i32) as usize;
        if self.row == 0 {
            self.session = next;
        } else {
            self.user = next;
        }
    }

    fn focus(&mut self, delta: i32) {
        self.row = ((self.row as i32 + delta).rem_euclid(2)) as usize;
    }

    fn panel(&self, area: Rect) -> Rect {
        let width = 30u16.min(area.width.saturating_sub(2));
        Rect::new(center(area.width, width), center(area.height, 5), width, 5)
    }

    fn hit(&self, area: Rect, column: u16, row: u16) -> Option<(usize, i32)> {
        let panel = self.panel(area);
        if column < panel.x || column >= panel.x + panel.width || row < panel.y + 1 || row > panel.y + 3 {
            return None;
        }
        let which = if row == panel.y + 1 { 0 } else if row == panel.y + 3 { 1 } else { return None };
        let middle = panel.x + panel.width / 2;
        Some((which, if column < middle { -1 } else { 1 }))
    }
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
    blink: bool,
    failed_at: Option<Instant>,
    choice: Choice,
}

struct Layout {
    top: u16,
    box_width: u16,
    box_col: u16,
    power_col: u16,
    power_row: u16,
}

impl Layout {
    fn new(area: Rect, typed: usize) -> Self {
        let need = (typed as u16).saturating_add(9).max(14);
        let even = need + need % 2;
        let cap = area.width.saturating_sub(2) & !1;
        let box_width = even.min(cap);
        Layout {
            top: area.height.saturating_sub(11) / 2,
            box_width,
            box_col: center(area.width, box_width),
            power_col: center(area.width, 11),
            power_row: area.height.saturating_sub(2),
        }
    }

    fn slots(&self) -> [(usize, u16, u16, u16); 4] {
        [
            (1, self.box_col + self.box_width - 4, self.top + 7, 3),
            (2, self.power_col, self.power_row, 3),
            (3, self.power_col + 4, self.power_row, 3),
            (4, self.power_col + 8, self.power_row, 3),
        ]
    }

    fn hit(&self, col: u16, row: u16) -> Option<usize> {
        self.slots().into_iter().find(|&(_, x, y, w)| row == y && col >= x && col < x + w).map(|(slot, ..)| slot)
    }
}

fn fill(buf: &mut Buffer, area: Rect, style: Style) {
    let blank = " ".repeat(area.width as usize);

    for y in area.y..area.y + area.height {
        buf.set_string(area.x, y, &blank, style);
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
        let layout = Layout::new(area, self.password.chars().count());

        let pixel = Style::new().bg(theme.foreground).fg(theme.foreground);

        for (index, line) in clock.iter().enumerate() {
            let width = line.chars().count() as u16;
            let left = center(area.width, width);

            for (offset, symbol) in line.chars().enumerate() {
                if symbol != '█' {
                    continue;
                }
                buf[(left + offset as u16, layout.top + index as u16)].set_symbol(" ").set_style(pixel);
            }
        }

        let wrong = self.failed_at.is_some() && !self.message.is_empty();
        let ink = if self.checking { plain.fg(theme.dim) } else { plain };
        Block::bordered()
            .border_type(BorderType::Plain)
            .border_style(if wrong { plain.fg(theme.red) } else { plain })
            .render(Rect::new(layout.box_col, layout.top + 6, layout.box_width, 3).intersection(area), buf);
        buf.set_string(layout.box_col + 2, layout.top + 7, &theme.lock, ink);

        let dots = "●".repeat(self.password.chars().count());
        let shown: String = if self.reveal { self.password.clone() } else { dots };
        let field = layout.box_width.saturating_sub(8);
        let shown: String = shown.chars().skip(shown.chars().count().saturating_sub(field as usize)).collect();
        let offset = field.saturating_sub(shown.chars().count() as u16) / 2;
        buf.set_string(layout.box_col + 4 + offset, layout.top + 7, &shown, ink);

        if self.focus == 0 && self.blink {
            let at = layout.box_col + 4 + offset + shown.chars().count() as u16;
            if at < layout.box_col + layout.box_width - 2 {
                buf[(at, layout.top + 7)].set_symbol(" ").set_style(plain.bg(theme.foreground));
            }
        }

        let message: String = self.message.chars().take(area.width as usize).collect();
        buf.set_string(center(area.width, message.chars().count() as u16), layout.top + 10, &message, plain.fg(theme.red));

        for (slot, x, y, width) in layout.slots() {
            let lit = self.focus == slot || self.hover == Some(slot);
            let style = if lit { Style::new().fg(theme.surface).bg(theme.foreground) } else { plain };
            let glyph = match slot {
                1 if self.reveal => &theme.eye_off,
                1 => &theme.eye,
                4 => &theme.switch,
                _ => &theme.power[slot - 2],
            };
            buf.set_string(x, y, " ".repeat(width as usize), style);
            buf.set_string(x + 1, y, glyph, style);
        }

        if self.choice.open {
            self.render_choice(area, buf);
        }
    }

    fn render_choice(&self, area: Rect, buf: &mut Buffer) {
        let theme = &self.theme;
        let choice = &self.choice;
        let panel = choice.panel(area);

        buf.set_style(area, Style::new().fg(theme.dim).bg(theme.surface));
        fill(buf, panel, Style::new().fg(theme.foreground).bg(theme.surface));

        for row in 0..2 {
            let picked = choice.row == row;
            let name = choice.value(row);
            let name: String = name.chars().take(panel.width.saturating_sub(8) as usize).collect();
            let y = panel.y + 1 + row as u16 * 2;
            let ink = if picked { Style::new().fg(theme.foreground).bg(theme.surface) } else { Style::new().fg(theme.dim).bg(theme.surface) };

            buf.set_string(panel.x + 2, y, &theme.back, ink);
            buf.set_string(panel.x + panel.width - 3, y, &theme.forward, ink);
            buf.set_string(panel.x + (panel.width - name.chars().count() as u16) / 2, y, &name, ink);
        }
    }

    fn activate(&mut self, slot: usize, terminal: &mut DefaultTerminal) {
        match slot {
            0 => self.submit(terminal),
            1 => self.reveal = !self.reveal,
            4 => self.choice.open = !self.choice.open,
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
            Ok(path) => {
                let user = self.choice.users.get(self.choice.user).cloned().unwrap_or_else(|| self.user.clone());
                let (_id, argv, _) = self.choice.sessions.get(self.choice.session).cloned().unwrap_or_else(|| read_sessions()[0].clone());
                let quiet = quiet_session(&user, &argv);
                let cmd: Vec<&str> = quiet.iter().map(String::as_str).collect();
                let envs = ["XDG_SESSION_TYPE=wayland".to_string()];
                let env: Vec<&str> = envs.iter().map(String::as_str).collect();

                UnixStream::connect(path)
                    .map_err(greetd::Fail::from)
                    .and_then(|mut sock| greetd::login(&mut sock, &user, &self.password, &cmd, &env))
            }
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
                self.blink = !self.blink;
                continue;
            }
            match event::read()? {
                Event::Key(key) if key.kind != KeyEventKind::Release => match key.code {
                    KeyCode::Tab if self.choice.open => self.choice.focus(1),
                    KeyCode::BackTab if self.choice.open => self.choice.focus(-1),
                    KeyCode::Tab => self.focus = (self.focus + 1) % 5,
                    KeyCode::BackTab => self.focus = (self.focus + 4) % 5,
                    KeyCode::Left if self.choice.open => self.choice.step(-1),
                    KeyCode::Right if self.choice.open => self.choice.step(1),
                    KeyCode::Up if self.choice.open => self.choice.focus(-1),
                    KeyCode::Down if self.choice.open => self.choice.focus(1),
                    KeyCode::Enter if self.choice.open => self.choice.open = false,
                    KeyCode::Esc if self.choice.open => self.choice.open = false,
                    KeyCode::Left if self.focus > 0 => self.focus = (self.focus - 1).max(1),
                    KeyCode::Right if self.focus > 0 => self.focus = (self.focus + 1).min(4),
                    KeyCode::Char(_) if self.choice.open => {}
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
                    self.hover = if self.choice.open { None } else { Layout::new(area, self.password.chars().count()).hit(mouse.column, mouse.row) };
                    if self.choice.open {
                        if let Some((row, delta)) = self.choice.hit(area, mouse.column, mouse.row) {
                            self.choice.row = row;
                            if matches!(mouse.kind, MouseEventKind::Down(MouseButton::Left)) {
                                self.choice.step(delta);
                            }
                        }
                    }
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

    let choice = Choice { users: read_users(&user), sessions: read_sessions(), user: 0, session: 0, open: false, row: 0 };
    let mut greeter = Greeter { choice, user, theme, password: String::new(), message: String::new(), focus: 0, hover: None, reveal: false, checking: false, blink: true, failed_at: None };
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
    fn choice_switches_the_session_and_the_user() {
        let area = Rect::new(0, 0, 40, 10);
        let mut choice = Choice {
            users: vec!["a".into(), "b".into()],
            sessions: (0..3).map(|i| (format!("s{i}"), vec![], format!("Session {i}"))).collect(),
            user: 0,
            session: 0,
            open: true,
            row: 0,
        };

        assert_eq!(choice.value(0), "Session 0");
        choice.step(1);
        assert_eq!(choice.value(0), "Session 1");
        choice.step(-1);
        choice.step(-1);
        assert_eq!(choice.value(0), "Session 2", "steps wrap backwards");
        choice.focus(1);
        assert_eq!(choice.value(1), "a");
        choice.step(1);
        assert_eq!(choice.value(1), "b", "the user row changes instead");

        let panel = choice.panel(area);
        assert_eq!(panel, Rect::new(5, 2, 30, 5));
        assert_eq!(choice.hit(area, panel.x + 1, panel.y + 1), Some((0, -1)));
        assert_eq!(choice.hit(area, panel.x + 20, panel.y + 1), Some((0, 1)));
        assert_eq!(choice.hit(area, panel.x + 20, panel.y + 3), Some((1, 1)));
        assert_eq!(choice.hit(area, panel.x + 20, panel.y + 2), None);
        assert_eq!(choice.hit(area, 0, panel.y + 1), None);
    }

    #[test]
    fn the_session_writes_to_a_log_instead_of_the_console() {
        let cmd = quiet_session("gabriel", &["/usr/bin/start-hyprland".into()]);

        assert_eq!(cmd.len(), 3);
        assert!(cmd[0].ends_with("/session"), "shared wrapper first: {}", cmd[0]);
        assert_eq!(cmd[1], "/home/gabriel/.local/state/session.log");
        assert_eq!(cmd[2], "/usr/bin/start-hyprland");
    }

    fn greeter_with(password: &str, blink: bool) -> Greeter {
        let settings = Settings(Value::Object(Default::default()));
        let mut greeter = Greeter {
            choice: Choice { users: vec!["u".into()], sessions: vec![], user: 0, session: 0, open: false, row: 0 },
            user: "u".into(),
            theme: Theme::new(&settings),
            password: password.into(),
            message: String::new(),
            focus: 0,
            hover: None,
            reveal: false,
            checking: false,
            blink,
            failed_at: None,
        };
        greeter.message.clear();
        greeter
    }

    #[test]
    fn the_cursor_blinks_after_the_dots() {
        let area = Rect::new(0, 0, 80, 30);
        let layout = Layout::new(area, 2);
        let row = layout.top + 7;

        for (blink, lit) in [(true, true), (false, false)] {
            let greeter = greeter_with("ab", blink);
            let mut buf = Buffer::empty(area);
            greeter.render(area, &mut buf);

            assert_eq!(buf[(layout.box_col + 6, row)].symbol(), "●");
            assert_eq!(buf[(layout.box_col + 7, row)].symbol(), "●");
            assert_eq!(buf[(layout.box_col + 8, row)].bg, if lit { greeter.theme.foreground } else { greeter.theme.surface });
        }
    }

    #[test]
    fn the_clock_is_filled_cells_not_block_glyphs() {
        let area = Rect::new(0, 0, 80, 30);
        let greeter = greeter_with("", true);
        let mut buf = Buffer::empty(area);
        greeter.render(area, &mut buf);
        let layout = Layout::new(area, 0);

        let filled: Vec<&str> = (0..layout.top + 5)
            .flat_map(|y| (0..area.width).map(move |x| (x, y)))
            .map(|(x, y)| buf[(x, y)].symbol())
            .filter(|symbol| *symbol == " ")
            .collect();

        assert!(!filled.is_empty(), "the clock paints with filled cells");
        assert!(
            (0..area.width).all(|x| (0..layout.top + 5).all(|y| buf[(x, y)].symbol() != "█")),
            "no block glyphs are drawn"
        );
    }

    #[test]
    fn the_box_grows_with_the_typed_digits() {
        let area = Rect::new(0, 0, 80, 30);

        assert_eq!(Layout::new(area, 0).box_width, 14);
        assert_eq!(Layout::new(area, 5).box_width, 14);
        assert_eq!(Layout::new(area, 6).box_width, 16, "grows a cell on each side");
        assert_eq!(Layout::new(area, 7).box_width, 16);
        assert_eq!(Layout::new(area, 40).box_width, 50);
        assert_eq!(Layout::new(Rect::new(0, 0, 20, 30), 90).box_width, 18, "never wider than the screen");

        for typed in 0..40 {
            let width = Layout::new(area, typed).box_width;
            assert_eq!(width % 2, 0, "even widths keep the box centred");
            assert_eq!(Layout::new(area, typed).box_col, (area.width - width) / 2);
        }
    }

    #[test]
    fn clock_follows_the_config_font() {
        let tm = libc::tm { tm_hour: 13, tm_min: 5, tm_sec: 9, ..unsafe { std::mem::zeroed() } };
        assert_eq!(format_time("HH:mm", &tm), "13:05");
        assert_eq!(format_time("h:mm:ss AP", &tm), "1:05:09 PM");
        let digits = vec![('1', vec!["  #".into(); 5]), (':', vec![" ".into(), "#".into(), " ".into(), "#".into(), " ".into()])];
        assert_eq!(block_rows("1:1", &digits)[1], "    ██  ██      ██");
    }
}
