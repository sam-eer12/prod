//! Explicit per-user login registration; enabling never starts or pairs a session.
#[cfg(target_os = "macos")]
use crate::daemon;
use crate::local;
use serde::{Deserialize, Serialize};
#[cfg(any(target_os = "macos", target_os = "linux", windows))]
use std::process::Command;
#[cfg(any(target_os = "macos", target_os = "linux"))]
use std::process::Stdio;
use std::{
    fs, io,
    path::{Path, PathBuf},
};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Registration {
    schema: u8,
    kind: String,
    path: PathBuf,
}

pub fn enabled(state: &Path) -> io::Result<bool> {
    match fs::read(state.join("autostart.json")) {
        Ok(bytes) => {
            let registration: Registration =
                serde_json::from_slice(&bytes).map_err(io::Error::other)?;
            if registration.schema != 1 {
                return Err(io::Error::other("unsupported autostart configuration"));
            }
            Ok(registration.path.is_file())
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

#[cfg(any(target_os = "macos", windows, test))]
fn xml(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

pub fn enable(state: &Path, executable: &Path) -> io::Result<()> {
    let executable = executable
        .to_str()
        .ok_or_else(|| io::Error::other("startup path must be valid UTF-8"))?;
    let state_text = state
        .to_str()
        .ok_or_else(|| io::Error::other("state path must be valid UTF-8"))?;
    if executable.contains(['\n', '\r']) || state_text.contains(['\n', '\r']) {
        return Err(io::Error::other("startup paths cannot contain line breaks"));
    }
    #[cfg(target_os = "macos")]
    let registration = {
        let path = local::home()?.join("Library/LaunchAgents/com.padlink.daemon.plist");
        local::private_dir(path.parent().unwrap())?;
        let args = daemon::child_args(state)
            .iter()
            .map(|s| format!("<string>{}</string>", xml(&s.to_string_lossy())))
            .collect::<String>();
        let contents = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!-- PadLink managed -->\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>Label</key><string>com.padlink.daemon</string><key>ProgramArguments</key><array><string>{}</string>{args}</array><key>RunAtLoad</key><true/><key>StandardOutPath</key><string>{}</string><key>StandardErrorPath</key><string>{}</string></dict></plist>\n",
            xml(executable),
            xml(&daemon::log_path(state).to_string_lossy()),
            xml(&daemon::log_path(state).to_string_lossy())
        );
        managed_write(&path, contents.as_bytes())?;
        Registration {
            schema: 1,
            kind: "launchagent".into(),
            path,
        }
    };
    #[cfg(target_os = "linux")]
    let registration = {
        let config = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or(local::home()?.join(".config"));
        if !config.is_absolute() {
            return Err(io::Error::other("XDG_CONFIG_HOME must be absolute"));
        }
        let systemd = Command::new("systemctl")
            .args(["--user", "show-environment"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if systemd {
            let path = config.join("systemd/user/padlink.service");
            local::private_dir(path.parent().unwrap())?;
            let executable = systemd_quote(executable);
            let state_text = systemd_quote(state_text);
            let contents = format!(
                "# PadLink managed\n[Unit]\nDescription=PadLink background daemon\n[Service]\nType=simple\nExecStart={executable} --state-dir {state_text} daemon run\nRestart=no\n[Install]\nWantedBy=default.target\n"
            );
            managed_write(&path, contents.as_bytes())?;
            systemctl(&["daemon-reload"])?;
            systemctl(&["enable", "padlink.service"])?;
            Registration {
                schema: 1,
                kind: "systemd".into(),
                path,
            }
        } else {
            if std::env::var_os("DISPLAY").is_none()
                && std::env::var_os("WAYLAND_DISPLAY").is_none()
            {
                return Err(io::Error::other(
                    "no systemd user manager or graphical session; run `padlink daemon run` with your own supervisor",
                ));
            }
            let path = config.join("autostart/padlink.desktop");
            local::private_dir(path.parent().unwrap())?;
            let contents = format!(
                "# PadLink managed\n[Desktop Entry]\nType=Application\nName=PadLink\nExec={} --state-dir {} daemon run\nTerminal=false\n",
                desktop_quote(executable),
                desktop_quote(state_text)
            );
            managed_write(&path, contents.as_bytes())?;
            Registration {
                schema: 1,
                kind: "xdg".into(),
                path,
            }
        }
    };
    #[cfg(windows)]
    let registration = {
        let path = state.join("login-task.xml");
        let sid = local::user_sid()?;
        let arguments = format!("--state-dir {} daemon run", windows_quote(state_text));
        let contents = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\"><RegistrationInfo><Description>PadLink managed background daemon</Description></RegistrationInfo><Triggers><LogonTrigger><Enabled>true</Enabled><UserId>{sid}</UserId></LogonTrigger></Triggers><Principals><Principal id=\"User\"><UserId>{sid}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><ExecutionTimeLimit>PT0S</ExecutionTimeLimit><Enabled>true</Enabled></Settings><Actions Context=\"User\"><Exec><Command>{}</Command><Arguments>{}</Arguments></Exec></Actions></Task>",
            xml(executable),
            xml(&arguments)
        );
        managed_write(&path, contents.as_bytes())?;
        let status = Command::new("schtasks.exe")
            .args(["/Create", "/TN", &task_name()?, "/XML"])
            .arg(&path)
            .arg("/F")
            .status()?;
        if !status.success() {
            return Err(io::Error::other(
                "could not register the per-user login task",
            ));
        }
        Registration {
            schema: 1,
            kind: "task".into(),
            path,
        }
    };
    local::atomic_write(
        &state.join("autostart.json"),
        &serde_json::to_vec(&registration).map_err(io::Error::other)?,
    )?;
    println!("Login startup enabled. It will start idle at your next login.");
    Ok(())
}

fn managed_write(path: &Path, contents: &[u8]) -> io::Result<()> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        local::check_owner(&metadata)?;
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err(io::Error::other("startup entry must be a regular file"));
        }
        let existing = fs::read(path)?;
        if existing.len() > 65536 || !String::from_utf8_lossy(&existing).contains("PadLink managed")
        {
            return Err(io::Error::other(
                "refusing to replace a startup entry not managed by PadLink",
            ));
        }
    }
    local::atomic_write(path, contents)
}

pub fn disable(state: &Path) -> io::Result<()> {
    let bytes = match fs::read(state.join("autostart.json")) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            println!("Login startup is already disabled.");
            return Ok(());
        }
        Err(e) => return Err(e),
    };
    let registration: Registration = serde_json::from_slice(&bytes).map_err(io::Error::other)?;
    if registration.schema != 1 {
        return Err(io::Error::other("unsupported autostart configuration"));
    }
    // A corrupted registry must never turn uninstall into arbitrary file deletion.
    let allowed = match registration.kind.as_str() {
        "launchagent" => local::home()?.join("Library/LaunchAgents/com.padlink.daemon.plist"),
        "systemd" | "xdg" => {
            let config = std::env::var_os("XDG_CONFIG_HOME")
                .map(PathBuf::from)
                .unwrap_or(local::home()?.join(".config"));
            config.join(if registration.kind == "systemd" {
                "systemd/user/padlink.service"
            } else {
                "autostart/padlink.desktop"
            })
        }
        "task" => state.join("login-task.xml"),
        _ => return Err(io::Error::other("unknown startup registration")),
    };
    if registration.path != allowed {
        return Err(io::Error::other(
            "startup registration points outside the managed location",
        ));
    }
    #[cfg(target_os = "linux")]
    if registration.kind == "systemd" {
        systemctl(&["disable", "padlink.service"])?;
    }
    #[cfg(windows)]
    if registration.kind == "task" {
        let status = Command::new("schtasks.exe")
            .args(["/Delete", "/TN", &task_name()?, "/F"])
            .status()?;
        if !status.success() {
            return Err(io::Error::other("could not remove the login task"));
        }
    }
    if let Ok(metadata) = fs::symlink_metadata(&allowed) {
        local::check_owner(&metadata)?;
        if !metadata.is_file()
            || metadata.file_type().is_symlink()
            || !String::from_utf8_lossy(&fs::read(&allowed)?).contains("PadLink managed")
        {
            return Err(io::Error::other(
                "refusing to remove an unmanaged startup entry",
            ));
        }
        fs::remove_file(allowed)?;
    }
    #[cfg(target_os = "linux")]
    if registration.kind == "systemd" {
        systemctl(&["daemon-reload"])?;
    }
    fs::remove_file(state.join("autostart.json"))?;
    println!("Login startup disabled.");
    Ok(())
}

/// Unload a login-owned macOS supervisor after the daemon has been stopped.
/// Ordinary disable only removes future login registration and leaves it running.
pub fn remove_for_uninstall(state: &Path) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        let service = format!("gui/{}/com.padlink.daemon", unsafe { libc::geteuid() });
        if Command::new("launchctl")
            .args(["print", &service])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()?
            .success()
            && !Command::new("launchctl")
                .args(["bootout", &service])
                .status()?
                .success()
        {
            return Err(io::Error::other("could not unload the PadLink login agent"));
        }
    }
    disable(state)
}

#[cfg(target_os = "linux")]
fn systemctl(args: &[&str]) -> io::Result<()> {
    let status = Command::new("systemctl")
        .arg("--user")
        .args(args)
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other("systemd user registration failed"))
    }
}

#[cfg(target_os = "linux")]
fn systemd_quote(text: &str) -> String {
    format!(
        "\"{}\"",
        text.replace('\\', "\\\\")
            .replace('"', "\\\"")
            .replace('%', "%%")
            .replace('$', "$$")
    )
}
#[cfg(target_os = "linux")]
fn desktop_quote(text: &str) -> String {
    format!(
        "\"{}\"",
        text.replace('\\', "\\\\\\\\")
            .replace('"', "\\\\\\\"")
            .replace('$', "\\\\$")
            .replace('`', "\\\\`")
            .replace('%', "%%")
    )
}
#[cfg(windows)]
fn windows_quote(text: &str) -> String {
    format!("\"{}\"", text.replace('"', "\\\""))
}
#[cfg(windows)]
fn task_name() -> io::Result<String> {
    Ok(format!("PadLink-{}", local::user_sid()?))
}

#[cfg(test)]
mod tests {
    #[test]
    fn xml_cannot_inject_extra_arguments() {
        assert_eq!(super::xml("a&<\"'"), "a&amp;&lt;&quot;&apos;");
    }
}
