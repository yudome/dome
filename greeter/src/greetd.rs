use serde_json::{Value, json};
use std::io::{self, Read, Write};

pub enum Fail {
    Wrong,
    Broken(String),
}

impl From<io::Error> for Fail {
    fn from(error: io::Error) -> Self {
        Fail::Broken(error.to_string())
    }
}

pub fn send<S: Write>(sock: &mut S, message: &Value) -> io::Result<()> {
    let body = serde_json::to_vec(message)?;
    sock.write_all(&(body.len() as u32).to_ne_bytes())?;
    sock.write_all(&body)?;
    sock.flush()
}

pub fn recv<S: Read>(sock: &mut S) -> io::Result<Value> {
    let mut head = [0u8; 4];
    sock.read_exact(&mut head)?;
    let len = u32::from_ne_bytes(head) as usize;
    if len > 1 << 20 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "greetd message too large"));
    }
    let mut body = vec![0u8; len];
    sock.read_exact(&mut body)?;
    serde_json::from_slice(&body).map_err(io::Error::from)
}

fn ask<S: Read + Write>(sock: &mut S, message: Value) -> Result<Value, Fail> {
    send(sock, &message)?;
    Ok(recv(sock)?)
}

pub fn login<S: Read + Write>(sock: &mut S, user: &str, password: &str, cmd: &[&str], env: &[&str]) -> Result<(), Fail> {
    let mut reply = ask(sock, json!({ "type": "create_session", "username": user }))?;
    let mut answered = false;

    loop {
        match reply["type"].as_str() {
            Some("auth_message") => {
                let secret = matches!(reply["auth_message_type"].as_str(), Some("secret" | "visible"));
                let response = if secret && !answered { Value::from(password) } else { Value::Null };
                answered |= secret;
                reply = ask(sock, json!({ "type": "post_auth_message_response", "response": response }))?;
            }
            Some("success") => break,
            _ => {
                let wrong = reply["error_type"].as_str() == Some("auth_error");
                let text = reply["description"].as_str().unwrap_or("greetd error").to_string();
                let _ = ask(sock, json!({ "type": "cancel_session" }));
                return Err(if wrong { Fail::Wrong } else { Fail::Broken(text) });
            }
        }
    }

    let reply = ask(sock, json!({ "type": "start_session", "cmd": cmd, "env": env }))?;
    match reply["type"].as_str() {
        Some("success") => Ok(()),
        _ => Err(Fail::Broken(reply["description"].as_str().unwrap_or("session failed").to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixStream;
    use std::thread;

    fn fake(mut sock: UnixStream) -> Vec<Value> {
        let mut seen = Vec::new();
        while let Ok(message) = recv(&mut sock) {
            let reply = match message["type"].as_str().unwrap() {
                "create_session" => json!({ "type": "auth_message", "auth_message_type": "secret", "auth_message": "Password: " }),
                "post_auth_message_response" if message["response"] == "hunter2" => json!({ "type": "success" }),
                "post_auth_message_response" => json!({ "type": "error", "error_type": "auth_error", "description": "nope" }),
                _ => json!({ "type": "success" }),
            };
            seen.push(message);
            send(&mut sock, &reply).unwrap();
        }
        seen
    }

    fn run(password: &str) -> (Result<(), Fail>, Vec<Value>) {
        let (mut client, server) = UnixStream::pair().unwrap();
        let worker = thread::spawn(move || fake(server));
        let result = login(&mut client, "gabriel", password, &["start-hyprland"], &["XDG_SESSION_TYPE=wayland"]);
        drop(client);
        (result, worker.join().unwrap())
    }

    #[test]
    fn framing_round_trips() {
        let (mut a, mut b) = UnixStream::pair().unwrap();
        send(&mut a, &json!({ "type": "x", "n": 1 })).unwrap();
        let mut head = [0u8; 4];
        b.read_exact(&mut head).unwrap();
        assert_eq!(u32::from_ne_bytes(head) as usize, br#"{"n":1,"type":"x"}"#.len());
        send(&mut a, &json!({ "type": "y" })).unwrap();
        let mut rest = vec![0u8; u32::from_ne_bytes(head) as usize];
        b.read_exact(&mut rest).unwrap();
        assert_eq!(recv(&mut b).unwrap()["type"], "y");
    }

    #[test]
    fn right_password_starts_the_session() {
        let (result, seen) = run("hunter2");
        assert!(result.is_ok());
        let kinds: Vec<_> = seen.iter().map(|m| m["type"].as_str().unwrap().to_string()).collect();
        assert_eq!(kinds, ["create_session", "post_auth_message_response", "start_session"]);
        assert_eq!(seen[0]["username"], "gabriel");
        assert_eq!(seen[2]["cmd"][0], "start-hyprland");
    }

    #[test]
    fn wrong_password_cancels() {
        let (result, seen) = run("guess");
        assert!(matches!(result, Err(Fail::Wrong)));
        assert_eq!(seen.last().unwrap()["type"], "cancel_session");
    }
}
