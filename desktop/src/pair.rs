//! Short-lived pairing verification. Live input/session ownership belongs to
//! the future daemon, so this command closes after an authenticated round trip.
use crossterm::{
    event::{self, Event, KeyCode, KeyEventKind, KeyModifiers},
    terminal,
};
use padlink_protocol::{
    PAIRING_CODE_ALPHABET,
    clock::ClockSync,
    frame::Frame,
    pairing::net::{DesktopEvent, DesktopPairingClient},
};
use std::{
    io::{self, IsTerminal, Write},
    net::SocketAddr,
    time::{Duration, Instant},
};
use zeroize::Zeroizing;

struct HiddenInput;
impl HiddenInput {
    fn begin() -> io::Result<Self> {
        terminal::enable_raw_mode()?;
        Ok(Self)
    }
}
impl Drop for HiddenInput {
    fn drop(&mut self) {
        let _ = terminal::disable_raw_mode();
    }
}

pub fn run(endpoint: SocketAddr, label: &str) -> Result<(), String> {
    if !io::stdin().is_terminal() {
        return Err("pair requires an interactive terminal for hidden code entry".into());
    }
    let clock = Instant::now();
    let mut client =
        DesktopPairingClient::connect(endpoint, label, 0).map_err(|e| e.to_string())?;
    println!("Waiting for Allow on the phone at {endpoint}.");
    let mut hidden: Option<HiddenInput> = None;
    let mut code = Zeroizing::new([0_u8; 6]);
    let mut length = 0;
    let mut pong_deadline = None;
    let mut clocks = ClockSync::new();
    loop {
        let now = clock.elapsed().as_millis() as u64;
        if pong_deadline.is_some_and(|deadline| now >= deadline) {
            return Err("encrypted round-trip timed out".into());
        }
        match client.poll(now).map_err(|e| e.to_string())? {
            DesktopEvent::Pending => {}
            DesktopEvent::EnterCode => {
                print!("Code (hidden, six characters): ");
                io::stdout().flush().map_err(|e| e.to_string())?;
                hidden = Some(HiddenInput::begin().map_err(|e| e.to_string())?);
            }
            DesktopEvent::WrongCode => {
                println!("Code was not accepted. Try again before it expires.")
            }
            DesktopEvent::Paired => {
                let ping = clocks
                    .ping(now.checked_mul(1000).ok_or("clock overflow")?)
                    .map_err(|e| e.to_string())?;
                client
                    .send(&Frame::Ping(ping), now)
                    .map_err(|e| e.to_string())?;
                pong_deadline = Some(now + 3000);
            }
            DesktopEvent::Frame(Frame::Pong(pong)) => {
                clocks
                    .accept_pong(&pong, now.checked_mul(1000).ok_or("clock overflow")?)
                    .map_err(|e| e.to_string())?;
                client.close();
                println!("Pairing and encrypted round trip verified. Connection closed.");
                return Ok(());
            }
            DesktopEvent::Frame(_) => {
                return Err("unexpected frame during pairing verification".into());
            }
        }
        if hidden.is_some() {
            if event::poll(Duration::from_millis(20)).map_err(|e| e.to_string())?
                && let Event::Key(key) = event::read().map_err(|e| e.to_string())?
            {
                if key.kind != KeyEventKind::Press {
                    continue;
                }
                match key.code {
                    KeyCode::Esc => return Err("pairing cancelled".into()),
                    KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                        return Err("pairing cancelled".into());
                    }
                    KeyCode::Backspace if length > 0 => {
                        length -= 1;
                        code[length] = 0;
                    }
                    KeyCode::Enter if length == 6 => {
                        let input =
                            std::str::from_utf8(code.as_ref()).map_err(|_| "invalid code")?;
                        client.enter_code(input, now).map_err(|e| e.to_string())?;
                        code.fill(0);
                        length = 0;
                        hidden = None;
                        println!();
                    }
                    KeyCode::Char(character) => {
                        let candidate = character.to_ascii_uppercase();
                        if candidate.is_ascii()
                            && PAIRING_CODE_ALPHABET.contains(&(candidate as u8))
                            && length < 6
                        {
                            code[length] = candidate as u8;
                            length += 1;
                        }
                    }
                    _ => {}
                }
            }
        } else {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
