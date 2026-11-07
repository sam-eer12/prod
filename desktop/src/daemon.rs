//! Private, bounded local control; one supervised background worker per user.
use crate::local;
use fs2::FileExt;
use interprocess::local_socket::{
    ConnectOptions, Listener, ListenerNonblockingMode, ListenerOptions, Name, Stream, prelude::*,
};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

const TIMEOUT: Duration = Duration::from_secs(2);
const MAX_FRAME: usize = 4096;
static TERMINATE: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Status {
    pub state: String,
    pub version: String,
    pub protocol_version: u16,
    pub pid: u32,
    pub uptime_seconds: u64,
    pub session_implemented: bool,
    pub rust_heap_bytes: usize,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    op: String,
}

pub fn socket_name(state: &Path) -> io::Result<Name<'static>> {
    #[cfg(unix)]
    {
        state
            .join("control.sock")
            .to_fs_name::<interprocess::local_socket::GenericFilePath>()
            .map(Name::into_owned)
    }
    #[cfg(windows)]
    {
        use sha2::{Digest, Sha256};
        let identity = local::user_sid()?;
        let digest = Sha256::digest(state.to_string_lossy().as_bytes());
        format!("padlink-{identity}-{:x}", digest)
            .to_ns_name::<interprocess::local_socket::GenericNamespaced>()
            .map(Name::into_owned)
    }
}

fn listener(state: &Path) -> io::Result<Listener> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt;
        let path = state.join("control.sock");
        if let Ok(metadata) = fs::symlink_metadata(&path) {
            local::check_owner(&metadata)?;
            if !metadata.file_type().is_socket() {
                return Err(io::Error::other(
                    "refusing to remove a non-socket IPC endpoint",
                ));
            }
            fs::remove_file(path)?;
        }
    }
    let options = ListenerOptions::new()
        .name(socket_name(state)?)
        .nonblocking(ListenerNonblockingMode::Both);
    #[cfg(windows)]
    let options = {
        use interprocess::os::windows::{
            local_socket::ListenerOptionsExt, security_descriptor::SecurityDescriptor,
        };
        let sddl = widestring::U16CString::from_str(format!(
            "D:P(A;;GA;;;{})(A;;GA;;;SY)",
            local::user_sid()?
        ))
        .map_err(io::Error::other)?;
        options.security_descriptor(SecurityDescriptor::deserialize(&sddl)?)
    };
    let listener = options.create_sync().map_err(|e| {
        io::Error::new(
            e.kind(),
            format!("cannot create the private control socket: {e}"),
        )
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        // The 0700 parent excludes other users during bind/chmod on platforms
        // such as macOS that cannot fchmod an unbound socket descriptor.
        fs::set_permissions(
            state.join("control.sock"),
            fs::Permissions::from_mode(0o600),
        )?;
    }
    Ok(listener)
}

pub fn rpc(state: &Path, op: &str) -> io::Result<Vec<u8>> {
    let deadline = Instant::now() + TIMEOUT;
    let stream = ConnectOptions::new()
        .name(socket_name(state)?)
        .wait_mode(interprocess::ConnectWaitMode::Timeout(TIMEOUT))
        .nonblocking_stream(true)
        .connect_sync()?;
    let mut stream = RpcStream(stream);
    authorize_peer(&stream)?;
    stream.set_nonblocking(true)?;
    let request = serde_json::to_vec(&serde_json::json!({"op": op})).map_err(io::Error::other)?;
    let mut sent = 0;
    let mut frame = request;
    frame.push(b'\n');
    while sent < frame.len() {
        match stream.write(&frame[sent..]) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => sent += n,
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => pause(deadline)?,
            Err(e) => return Err(e),
        }
    }
    let mut output = Vec::with_capacity(MAX_FRAME);
    let mut buffer = [0_u8; 512];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => {
                if output.len() + n > MAX_FRAME {
                    return Err(io::Error::other("IPC response is too large"));
                }
                output.extend_from_slice(&buffer[..n]);
                if output.last() == Some(&b'\n') {
                    output.pop();
                    #[cfg(windows)]
                    {
                        let _ = stream.write_all(b"\0");
                    }
                    return Ok(output);
                }
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => pause(deadline)?,
            Err(e) => return Err(e),
        }
    }
}

struct RpcStream(Stream);
impl std::ops::Deref for RpcStream {
    type Target = Stream;
    fn deref(&self) -> &Stream {
        &self.0
    }
}
impl std::ops::DerefMut for RpcStream {
    fn deref_mut(&mut self) -> &mut Stream {
        &mut self.0
    }
}
#[cfg(windows)]
impl Drop for RpcStream {
    fn drop(&mut self) {
        let Stream::NamedPipe(pipe) = &self.0;
        // Every RPC is acknowledged or abandoned by its deadline. A vanished
        // server must not retain an unbounded client-side flush worker.
        pipe.inner().assume_flushed();
    }
}

fn pause(deadline: Instant) -> io::Result<()> {
    if Instant::now() >= deadline {
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            "daemon did not respond before its deadline",
        ));
    }
    std::thread::sleep(Duration::from_millis(5));
    Ok(())
}

pub fn status(state: &Path) -> io::Result<Option<Status>> {
    match rpc(state, "status") {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(io::Error::other),
        Err(e)
            if matches!(
                e.kind(),
                io::ErrorKind::NotFound
                    | io::ErrorKind::ConnectionRefused
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::BrokenPipe
                    | io::ErrorKind::UnexpectedEof
            ) =>
        {
            Ok(None)
        }
        #[cfg(windows)]
        Err(e) if e.raw_os_error() == Some(2) => Ok(None),
        Err(e) => Err(e),
    }
}

pub fn start(state: &Path) -> io::Result<()> {
    if let Some(status) = status(state)? {
        println!("Daemon already running (PID {}).", status.pid);
        return Ok(());
    }
    let log = local::open_private(&state.join("daemon.log"), true)?;
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("--state-dir")
        .arg(state)
        .args(["daemon", "run"])
        .stdin(Stdio::null())
        .stdout(log.try_clone()?)
        .stderr(log);
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // SAFETY: setsid is async-signal-safe and the closure touches no shared Rust state.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() == -1 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let mut child = command.spawn()?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = status(state)? {
            println!("Daemon started (PID {}, idle).", status.pid);
            return Ok(());
        }
        if child.try_wait()?.is_some() {
            return Err(io::Error::other(format!(
                "daemon startup failed; see {}",
                state.join("daemon.log").display()
            )));
        }
        if let Err(error) = pause(deadline) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(error);
        }
    }
}

pub fn stop(state: &Path) -> io::Result<bool> {
    let supervisor = local::open_private(&state.join("supervisor.lock"), false)?;
    let standalone = supervisor.try_lock_exclusive().is_ok();
    if standalone && status(state)?.is_none() {
        return Ok(false);
    }
    // A worker can be absent during crash backoff. The private stop intent also
    // reaches its supervisor, so an intentional stop cannot be undone by retry.
    local::atomic_write(&state.join("stop.request"), b"stop\n")?;
    drop(supervisor);
    if standalone {
        let _ = rpc(state, "stop");
    }
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let supervisor = local::open_private(&state.join("supervisor.lock"), false)?;
        let worker = local::open_private(&state.join("daemon.lock"), false)?;
        if supervisor.try_lock_exclusive().is_ok() && worker.try_lock_exclusive().is_ok() {
            return Ok(true);
        }
        pause(deadline)?;
    }
}

fn lock(state: &Path, name: &str) -> io::Result<fs::File> {
    let file = local::open_private(&state.join(name), false)?;
    file.try_lock_exclusive().map_err(|_| {
        io::Error::new(
            io::ErrorKind::AlreadyExists,
            "another daemon instance is running",
        )
    })?;
    Ok(file)
}

#[cfg(unix)]
extern "C" fn terminate(_: libc::c_int) {
    TERMINATE.store(true, Ordering::Relaxed);
}

fn signals() {
    TERMINATE.store(false, Ordering::Relaxed);
    #[cfg(unix)]
    {
        // SAFETY: the handler only writes a lock-free atomic and never allocates.
        unsafe {
            libc::signal(libc::SIGTERM, terminate as *const () as libc::sighandler_t);
            libc::signal(libc::SIGINT, terminate as *const () as libc::sighandler_t);
        }
    }
}

pub fn supervise(state: &Path) -> io::Result<()> {
    let _lock = lock(state, "supervisor.lock")?;
    match fs::remove_file(state.join("stop.request")) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    signals();
    let mut failures = 0;
    let mut window = Instant::now();
    loop {
        let mut child: Child = Command::new(std::env::current_exe()?)
            .arg("--state-dir")
            .arg(state)
            .args(["daemon", "worker"])
            .spawn()?;
        let result = loop {
            if TERMINATE.load(Ordering::Relaxed) || state.join("stop.request").exists() {
                let _ = rpc(state, "stop");
                let deadline = Instant::now() + TIMEOUT;
                while child.try_wait()?.is_none() && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(10));
                }
                if child.try_wait()?.is_none() {
                    child.kill()?;
                }
                child.wait()?;
                return Ok(());
            }
            if let Some(status) = child.try_wait()? {
                break status;
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        if result.success() {
            return Ok(());
        }
        if window.elapsed() > Duration::from_secs(300) {
            failures = 0;
            window = Instant::now();
        }
        if failures >= 3 {
            return Err(io::Error::other(
                "daemon stopped after three restart attempts in five minutes",
            ));
        }
        let wait = [1, 5, 30][failures];
        failures += 1;
        let deadline = Instant::now() + Duration::from_secs(wait);
        while Instant::now() < deadline {
            if TERMINATE.load(Ordering::Relaxed) || state.join("stop.request").exists() {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

struct Client {
    stream: Stream,
    input: [u8; MAX_FRAME],
    used: usize,
    output: Vec<u8>,
    sent: usize,
    deadline: Instant,
    stop: bool,
}

impl Client {
    fn new(stream: Stream) -> Self {
        Self {
            stream,
            input: [0; MAX_FRAME],
            used: 0,
            output: Vec::new(),
            sent: 0,
            deadline: Instant::now() + TIMEOUT,
            stop: false,
        }
    }
    fn poll(&mut self, started: Instant) -> io::Result<bool> {
        if Instant::now() >= self.deadline {
            return Ok(true);
        }
        #[cfg(windows)]
        if !self.output.is_empty() && self.sent == self.output.len() {
            let mut ack = [0_u8; 1];
            return match self.stream.read(&mut ack) {
                Ok(_) => Ok(true),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(false),
                Err(e) => Err(e),
            };
        }
        if self.output.is_empty() {
            if self.used == MAX_FRAME {
                return Ok(true);
            }
            match self.stream.read(&mut self.input[self.used..]) {
                Ok(0) => return Ok(true),
                Ok(n) => self.used += n,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(false),
                Err(e) => return Err(e),
            }
            if let Some(end) = self.input[..self.used].iter().position(|b| *b == b'\n') {
                self.output = match serde_json::from_slice::<Request>(&self.input[..end]) {
                    Ok(Request { op }) if op == "status" => serde_json::to_vec(&Status {
                        state: "idle".into(),
                        version: env!("CARGO_PKG_VERSION").into(),
                        protocol_version: padlink_protocol::PROTOCOL_VERSION,
                        pid: std::process::id(),
                        uptime_seconds: started.elapsed().as_secs(),
                        session_implemented: false,
                        rust_heap_bytes: crate::HEAP.metrics().used,
                    })
                    .map_err(io::Error::other)?,
                    Ok(Request { op }) if op == "stop" => {
                        self.stop = true;
                        b"{\"state\":\"stopping\"}".to_vec()
                    }
                    Ok(Request { op }) if op == "disconnect" => {
                        b"{\"state\":\"idle\",\"session_active\":false}".to_vec()
                    }
                    _ => b"{\"error\":\"invalid control request\"}".to_vec(),
                };
                self.output.push(b'\n');
            } else {
                return Ok(false);
            }
        }
        match self.stream.write(&self.output[self.sent..]) {
            Ok(0) => Ok(true),
            Ok(n) => {
                self.sent += n;
                Ok(!cfg!(windows) && self.sent == self.output.len())
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(false),
            Err(e) => Err(e),
        }
    }
}

#[cfg(windows)]
impl Drop for Client {
    fn drop(&mut self) {
        // A response is either acknowledged or abandoned after the deadline.
        // Never spawn a pipe-flush worker that a non-reading client can retain.
        let Stream::NamedPipe(pipe) = &self.stream;
        pipe.inner().assume_flushed();
    }
}

pub fn worker(state: &Path) -> io::Result<()> {
    let _lock = lock(state, "daemon.lock")?;
    let listener = listener(state)?;
    signals();
    let started = Instant::now();
    let mut clients: [Option<Client>; 4] = std::array::from_fn(|_| None);
    loop {
        if TERMINATE.load(Ordering::Relaxed) {
            return Ok(());
        }
        // Bounded admission and work per turn keep malformed/slow clients from starving stop.
        if let Some(slot) = clients.iter_mut().find(|c| c.is_none()) {
            match listener.accept() {
                Ok(stream) => {
                    if authorize_peer(&stream).is_ok() {
                        *slot = Some(Client::new(stream));
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(e) => return Err(e),
            }
        }
        for slot in &mut clients {
            if let Some(client) = slot {
                match client.poll(started) {
                    Ok(true) => {
                        if client.stop && client.sent == client.output.len() {
                            return Ok(());
                        }
                        *slot = None;
                    }
                    Err(_) => *slot = None,
                    Ok(false) => {}
                }
            }
        }
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn authorize_peer(stream: &Stream) -> io::Result<()> {
    #[cfg(windows)]
    {
        let pid = stream
            .peer_creds()?
            .pid()
            .ok_or_else(|| io::Error::other("pipe peer identity is unavailable"))?;
        if local::process_sid(pid)? != local::user_sid()? {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "pipe peer belongs to another user",
            ));
        }
    }
    #[cfg(unix)]
    {
        let _ = stream;
    } // The owner-only directory and socket restrict Unix peers.
    Ok(())
}

pub fn show(state: &Path, json: bool) -> io::Result<()> {
    match status(state)? {
        Some(status) if json => println!(
            "{}",
            serde_json::to_string(&status).map_err(io::Error::other)?
        ),
        Some(status) => println!(
            "Daemon: running, idle (PID {}, version {})",
            status.pid, status.version
        ),
        None if json => println!("{{\"state\":\"stopped\",\"session_implemented\":false}}"),
        None => println!("Daemon: stopped"),
    }
    Ok(())
}

#[cfg(target_os = "macos")]
pub fn child_args(state: &Path) -> Vec<std::ffi::OsString> {
    vec![
        "--state-dir".into(),
        state.as_os_str().to_owned(),
        "daemon".into(),
        "run".into(),
    ]
}

pub fn log_path(state: &Path) -> PathBuf {
    state.join("daemon.log")
}
