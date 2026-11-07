use std::time::Instant;
use std::{
    fs,
    path::PathBuf,
    process::{Command, Output, Stdio},
    time::Duration,
};

struct Sandbox {
    root: PathBuf,
    state: PathBuf,
}
impl Sandbox {
    fn new() -> Self {
        let mut nonce = [0; 8];
        getrandom::fill(&mut nonce).unwrap();
        let suffix: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
        let temporary = if cfg!(unix) {
            PathBuf::from("/tmp")
        } else {
            std::env::temp_dir()
        };
        let root = temporary.join(format!("pdl-{suffix}"));
        fs::create_dir(&root).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        }
        Self {
            state: root.join("s"),
            root,
        }
    }
    fn run(&self, args: &[&str]) -> Output {
        // Background Windows children may inherit a pipe handle. Regular files
        // let us inspect output without waiting for an unrelated daemon's EOF.
        let stdout = self.root.join("command.stdout");
        let stderr = self.root.join("command.stderr");
        let mut child = Command::new(env!("CARGO_BIN_EXE_padlink"))
            .arg("--state-dir")
            .arg(&self.state)
            .args(args)
            .stdin(Stdio::null())
            .stdout(fs::File::create(&stdout).unwrap())
            .stderr(fs::File::create(&stderr).unwrap())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                return Output {
                    status,
                    stdout: fs::read(&stdout).unwrap(),
                    stderr: fs::read(&stderr).unwrap(),
                };
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let mut output = Output {
                    status: child.wait().unwrap(),
                    stdout: fs::read(&stdout).unwrap(),
                    stderr: fs::read(&stderr).unwrap(),
                };
                output
                    .stderr
                    .extend_from_slice(b"\nCLI exceeded the 15-second test deadline\n");
                return output;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn ok(&self, args: &[&str]) -> Output {
        let output = self.run(args);
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        output
    }
    fn status(&self) -> serde_json::Value {
        serde_json::from_slice(&self.ok(&["status", "--json"]).stdout).unwrap()
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = self.run(&["daemon", "stop"]);
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn daemon_is_single_instance_and_intentional_stop_stays_stopped() {
    let sandbox = Sandbox::new();
    assert_eq!(sandbox.status()["state"], "stopped");
    sandbox.ok(&["daemon", "start"]);
    let first = sandbox.status();
    assert_eq!(first["state"], "idle");
    assert_eq!(first["session_implemented"], false);
    sandbox.ok(&["daemon", "start"]);
    assert_eq!(first["pid"], sandbox.status()["pid"]);
    assert!(!sandbox.run(&["daemon", "worker"]).status.success());
    sandbox.ok(&["disconnect"]);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&sandbox.state).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(sandbox.state.join("control.sock"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    sandbox.ok(&["daemon", "stop"]);
    std::thread::sleep(Duration::from_millis(1200));
    assert_eq!(sandbox.status()["state"], "stopped");
    sandbox.ok(&["daemon", "stop"]);
    sandbox.ok(&["daemon", "start"]);
    assert_ne!(first["pid"], sandbox.status()["pid"]);
}

#[cfg(unix)]
#[test]
fn malformed_slow_and_oversized_clients_do_not_break_control() {
    use std::{
        io::{Read, Write},
        os::unix::net::UnixStream,
    };
    let sandbox = Sandbox::new();
    sandbox.ok(&["daemon", "start"]);
    let socket = sandbox.state.join("control.sock");
    let mut malformed = UnixStream::connect(&socket).unwrap();
    malformed
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    malformed
        .write_all(b"{\"op\":\"stop\",\"unexpected\":true}\n")
        .unwrap();
    let mut response = String::new();
    malformed.read_to_string(&mut response).unwrap();
    assert!(response.contains("invalid control request"));
    let mut oversized = UnixStream::connect(&socket).unwrap();
    let _ = oversized.write_all(&[b'x'; 8192]);
    drop(oversized);
    let clients: Vec<_> = (0..4)
        .map(|_| UnixStream::connect(&socket).unwrap())
        .collect();
    std::thread::sleep(Duration::from_millis(100));
    // The request budget expires idle clients; no unbounded queue/thread is spawned.
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let output = sandbox.run(&["status", "--json"]);
        if output.status.success() {
            break;
        }
        assert!(Instant::now() < deadline);
    }
    drop(clients);
    sandbox.ok(&["daemon", "stop"]);
}

#[cfg(unix)]
#[test]
fn crash_restarts_idle_and_stale_sockets_are_recovered() {
    use std::os::unix::net::UnixListener;
    let sandbox = Sandbox::new();
    sandbox.ok(&["status"]);
    drop(UnixListener::bind(sandbox.state.join("control.sock")).unwrap());
    sandbox.ok(&["daemon", "start"]);
    let original = sandbox.status()["pid"].as_u64().unwrap() as i32;
    // SAFETY: the PID belongs to this test's authenticated, private daemon endpoint.
    assert_eq!(unsafe { libc::kill(original, libc::SIGKILL) }, 0);
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let output = sandbox.run(&["status", "--json"]);
        if output.status.success() {
            let status: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
            if status["pid"]
                .as_u64()
                .is_some_and(|pid| pid != original as u64)
            {
                break;
            }
        }
        assert!(Instant::now() < deadline, "daemon did not restart");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(sandbox.status()["state"], "idle");
}

#[cfg(unix)]
#[test]
fn intentional_stop_during_crash_backoff_prevents_restart() {
    let sandbox = Sandbox::new();
    sandbox.ok(&["daemon", "start"]);
    let pid = sandbox.status()["pid"].as_u64().unwrap() as i32;
    // SAFETY: this PID belongs to the worker in the test's private state directory.
    assert_eq!(unsafe { libc::kill(pid, libc::SIGKILL) }, 0);
    std::thread::sleep(Duration::from_millis(100));
    sandbox.ok(&["daemon", "stop"]);
    std::thread::sleep(Duration::from_millis(1200));
    assert_eq!(sandbox.status()["state"], "stopped");
}

#[cfg(unix)]
#[test]
fn symlink_state_and_non_socket_endpoints_are_rejected() {
    use std::os::unix::fs::symlink;
    let sandbox = Sandbox::new();
    let real = sandbox.root.join("real");
    fs::create_dir(&real).unwrap();
    symlink(&real, &sandbox.state).unwrap();
    assert!(!sandbox.run(&["status"]).status.success());
    fs::remove_file(&sandbox.state).unwrap();
    sandbox.ok(&["status"]);
    fs::write(sandbox.state.join("control.sock"), b"do not remove").unwrap();
    assert!(!sandbox.run(&["daemon", "worker"]).status.success());
    assert_eq!(
        fs::read(sandbox.state.join("control.sock")).unwrap(),
        b"do not remove"
    );
}
