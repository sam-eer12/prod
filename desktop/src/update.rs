//! Signed release downloads and transactional, versioned per-user installs.
use crate::{autostart, daemon, local};
use fs2::FileExt;
use rsa::{
    RsaPublicKey,
    pkcs1v15::{Signature, VerifyingKey},
    pkcs8::DecodePublicKey,
    signature::Verifier,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

pub const REPOSITORY: &str = "sam-eer12/prod";
const PUBLIC_KEY: &str = include_str!("../../packaging/release-public.pem");
const MAX_METADATA: u64 = 65536;
const MAX_ARCHIVE: u64 = 32_000_000;
const MAX_BINARY: u64 = 24_000_000;

#[derive(Debug, Clone)]
struct Artifact {
    target: String,
    file: String,
    bytes: u64,
    sha256: String,
    binary_bytes: u64,
    binary_sha256: String,
    minimum_os: String,
    url: String,
}
#[derive(Debug)]
struct Release {
    version: String,
    protocol: u16,
    artifacts: Vec<Artifact>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Installation {
    schema: u8,
    pub channel: String,
    pub prefix: PathBuf,
    pub current_version: String,
    pub previous_version: Option<String>,
    target: String,
    state_dir: PathBuf,
    binary_sha256: String,
}

pub fn platform() -> io::Result<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Ok("aarch64-apple-darwin"),
        ("macos", "x86_64") => Ok("x86_64-apple-darwin"),
        ("linux", "aarch64") => Ok("aarch64-unknown-linux-musl"),
        ("linux", "x86_64") => Ok("x86_64-unknown-linux-musl"),
        ("windows", "x86_64") => Ok("x86_64-pc-windows-msvc"),
        _ => Err(io::Error::other(
            "no published PadLink binary supports this OS/CPU",
        )),
    }
}

pub fn binary_name() -> &'static str {
    if cfg!(windows) {
        "padlink.exe"
    } else {
        "padlink"
    }
}
fn root(prefix: &Path) -> PathBuf {
    prefix.join("share/padlink")
}
fn binary(prefix: &Path, version: &str) -> PathBuf {
    root(prefix)
        .join("versions")
        .join(version)
        .join(binary_name())
}
pub fn launcher(prefix: &Path) -> PathBuf {
    prefix.join("bin").join(binary_name())
}

fn valid_version(text: &str) -> io::Result<semver::Version> {
    if text.len() > 64
        || !text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".+-".contains(&b))
    {
        return Err(io::Error::other("invalid release version"));
    }
    semver::Version::parse(text).map_err(io::Error::other)
}

fn valid_hash(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

fn read_bounded(path: &Path, limit: u64) -> io::Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > limit {
        return Err(io::Error::other(format!(
            "{} is not a bounded regular file",
            path.display()
        )));
    }
    let mut bytes = Vec::new();
    fs::File::open(path)?
        .take(limit + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(io::Error::other("file grew beyond its size limit"));
    }
    Ok(bytes)
}

fn verify_signature(data: &[u8], signature: &[u8], public_key: &str) -> io::Result<()> {
    let key = RsaPublicKey::from_public_key_pem(public_key).map_err(io::Error::other)?;
    let verifier = VerifyingKey::<Sha256>::new(key);
    let signature = Signature::try_from(signature).map_err(io::Error::other)?;
    verifier.verify(data, &signature).map_err(|_| {
        io::Error::other("release signature is invalid; the installation was preserved")
    })
}

fn parse_release(bytes: &[u8]) -> io::Result<Release> {
    let text = std::str::from_utf8(bytes).map_err(io::Error::other)?;
    let mut lines = text.lines();
    if lines.next() != Some("PADLINK_RELEASE 1") {
        return Err(io::Error::other("unsupported release manifest"));
    }
    let version = lines
        .next()
        .and_then(|s| s.strip_prefix("version "))
        .ok_or_else(|| io::Error::other("manifest has no version"))?
        .to_owned();
    valid_version(&version)?;
    let protocol = lines
        .next()
        .and_then(|s| s.strip_prefix("protocol "))
        .ok_or_else(|| io::Error::other("manifest has no protocol version"))?
        .parse()
        .map_err(io::Error::other)?;
    let mut artifacts = Vec::new();
    for line in lines {
        let fields: Vec<_> = line.split_ascii_whitespace().collect();
        if fields.len() != 10 || fields[0] != "artifact" || artifacts.len() >= 8 {
            return Err(io::Error::other("invalid artifact record"));
        }
        let target = fields[1];
        if ![
            "aarch64-apple-darwin",
            "x86_64-apple-darwin",
            "aarch64-unknown-linux-musl",
            "x86_64-unknown-linux-musl",
            "x86_64-pc-windows-msvc",
        ]
        .contains(&target)
            || artifacts.iter().any(|a: &Artifact| a.target == target)
        {
            return Err(io::Error::other("unsupported or duplicate artifact target"));
        }
        let file = format!("padlink-{version}-{target}.tar.gz");
        let url = format!("https://github.com/{REPOSITORY}/releases/download/v{version}/{file}");
        if fields[2] != file || fields[9] != url || !valid_hash(fields[4]) || !valid_hash(fields[6])
        {
            return Err(io::Error::other("artifact identity or checksum is invalid"));
        }
        let bytes = fields[3].parse::<u64>().map_err(io::Error::other)?;
        let binary_bytes = fields[5].parse::<u64>().map_err(io::Error::other)?;
        if bytes == 0 || bytes > MAX_ARCHIVE || binary_bytes == 0 || binary_bytes > MAX_BINARY {
            return Err(io::Error::other("artifact exceeds release size limits"));
        }
        artifacts.push(Artifact {
            target: target.into(),
            file,
            bytes,
            sha256: fields[4].into(),
            binary_bytes,
            binary_sha256: fields[6].into(),
            minimum_os: fields[7].into(),
            url,
        });
        // Field 8 records the archive layout; it cannot authorize arbitrary extraction paths.
        if fields[8]
            != if target.contains("windows") {
                "padlink.exe"
            } else {
                "padlink"
            }
        {
            return Err(io::Error::other("unexpected archive layout"));
        }
    }
    if artifacts.is_empty() {
        return Err(io::Error::other("release has no artifacts"));
    }
    Ok(Release {
        version,
        protocol,
        artifacts,
    })
}

fn release(folder: &Path) -> io::Result<Release> {
    let bytes = read_bounded(&folder.join("release-manifest.txt"), MAX_METADATA)?;
    let signature = read_bounded(&folder.join("release-manifest.sig"), 512)?;
    verify_signature(&bytes, &signature, PUBLIC_KEY)?;
    let release = parse_release(&bytes)?;
    if release.protocol != padlink_protocol::PROTOCOL_VERSION {
        return Err(io::Error::other(
            "release uses a different phone protocol; update both sides together",
        ));
    }
    Ok(release)
}

fn hash_file(path: &Path, expected_bytes: u64) -> io::Result<String> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() != expected_bytes
    {
        return Err(io::Error::other(
            "download is incomplete or has an unexpected size/type",
        ));
    }
    let mut file = fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 8192];
    let mut read = 0;
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        read += count as u64;
        if read > expected_bytes {
            return Err(io::Error::other("download changed while being verified"));
        }
        hasher.update(&buffer[..count]);
    }
    if read != expected_bytes {
        return Err(io::Error::other("download changed while being verified"));
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn check_hash(path: &Path, size: u64, hash: &str) -> io::Result<()> {
    if hash_file(path, size)? != hash {
        return Err(io::Error::other(
            "download checksum is invalid; the installation was preserved",
        ));
    }
    Ok(())
}

pub fn installed() -> io::Result<Option<Installation>> {
    let executable = std::env::current_exe()?;
    for parent in executable.ancestors().skip(1).take(6) {
        let candidates = [
            parent.join("install.json"),
            parent.join("share/padlink/install.json"),
        ];
        for path in candidates {
            if path.exists() {
                return read_installation(&path).map(Some);
            }
        }
    }
    Ok(None)
}

fn read_installation(path: &Path) -> io::Result<Installation> {
    let installation: Installation =
        serde_json::from_slice(&read_bounded(path, MAX_METADATA)?).map_err(io::Error::other)?;
    valid_version(&installation.current_version)?;
    if let Some(version) = &installation.previous_version {
        valid_version(version)?;
    }
    if installation.schema != 1
        || !["curl", "manual"].contains(&installation.channel.as_str())
        || !installation.prefix.is_absolute()
        || fs::canonicalize(root(&installation.prefix).join("install.json"))?
            != fs::canonicalize(path)?
        || installation.target != platform()?
        || !valid_hash(&installation.binary_sha256)
        || !installation.state_dir.is_absolute()
    {
        return Err(io::Error::other(
            "installation record is invalid; no files were changed",
        ));
    }
    Ok(installation)
}

pub fn stable_executable() -> io::Result<PathBuf> {
    Ok(match installed()? {
        Some(installation) => launcher(&installation.prefix),
        None => std::env::current_exe()?,
    })
}

/// A Windows launcher is immutable while running. It dispatches to the versioned payload.
#[cfg(windows)]
pub fn forward_launcher() -> io::Result<Option<std::process::ExitCode>> {
    let executable = std::env::current_exe()?;
    if executable
        .parent()
        .is_none_or(|p| p.file_name() != Some(std::ffi::OsStr::new("bin")))
    {
        return Ok(None);
    }
    let prefix = executable
        .parent()
        .and_then(Path::parent)
        .ok_or_else(|| io::Error::other("invalid launcher location"))?;
    let installation = read_installation(&root(prefix).join("install.json"))?;
    let target = binary(prefix, &installation.current_version);
    let status = Command::new(target)
        .args(std::env::args_os().skip(1))
        .status()?;
    Ok(Some(std::process::ExitCode::from(
        status.code().unwrap_or(2) as u8,
    )))
}

struct Stage(PathBuf);
impl Stage {
    fn new(parent: &Path) -> io::Result<Self> {
        let path = parent.join(format!(".padlink-stage-{}", local::random_suffix()?));
        local::private_dir(&path)?;
        Ok(Self(path))
    }
}
impl Drop for Stage {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn download(url: &str, destination: &Path, limit: u64) -> io::Result<()> {
    let program = if cfg!(windows) { "curl.exe" } else { "curl" };
    let status = Command::new(program)
        .args([
            "--fail",
            "--silent",
            "--show-error",
            "--location",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--tlsv1.2",
            "--connect-timeout",
            "15",
            "--max-time",
            "120",
            "--retry",
            "2",
            "--max-filesize",
            &limit.to_string(),
            "--output",
        ])
        .arg(destination)
        .arg(url)
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::other(
            "release download failed; the installation was preserved",
        ))
    }
}

fn extract(folder: &Path, artifact: &Artifact, parent: &Path) -> io::Result<(Stage, PathBuf)> {
    let archive = folder.join(&artifact.file);
    check_hash(&archive, artifact.bytes, &artifact.sha256)?;
    let stage = Stage::new(parent)?;
    let tar = if cfg!(windows) { "tar.exe" } else { "tar" };
    // Limit extraction to the signed, flat filename, even if a release packager regresses.
    let status = Command::new(tar)
        .arg("-xzf")
        .arg(&archive)
        .arg("-C")
        .arg(&stage.0)
        .arg("--")
        .arg(binary_name())
        .status()?;
    if !status.success() {
        return Err(io::Error::other("could not extract the release binary"));
    }
    let path = stage.0.join(binary_name());
    check_hash(&path, artifact.binary_bytes, &artifact.binary_sha256)?;
    Ok((stage, path))
}

fn smoke(path: &Path, version: &str) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o755))?;
    }
    let output = Command::new(path)
        .arg("--version")
        .stdin(Stdio::null())
        .output()?;
    if !output.status.success() || output.stdout != format!("padlink {version}\n").as_bytes() {
        return Err(io::Error::other(
            "release executable failed its version smoke check",
        ));
    }
    Ok(())
}

fn system_requirements(artifact: &Artifact) -> io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        let output = Command::new("sw_vers").arg("-productVersion").output()?;
        let actual = String::from_utf8_lossy(&output.stdout)
            .trim()
            .split('.')
            .next()
            .unwrap_or("0")
            .parse::<u32>()
            .unwrap_or(0);
        let minimum = artifact
            .minimum_os
            .split('.')
            .next()
            .unwrap_or("99")
            .parse::<u32>()
            .unwrap_or(99);
        if !output.status.success() || actual < minimum {
            return Err(io::Error::other(format!(
                "this release requires macOS {} or later",
                artifact.minimum_os
            )));
        }
    }
    #[cfg(target_os = "linux")]
    {
        let output = Command::new("uname").arg("-r").output()?;
        let actual = String::from_utf8_lossy(&output.stdout);
        let numbers: Vec<_> = actual
            .trim()
            .split(['.', '-'])
            .take(2)
            .map(|s| s.parse::<u32>().unwrap_or(0))
            .collect();
        if !output.status.success()
            || numbers.as_slice() < [5, 4].as_slice()
            || artifact.minimum_os != "5.4"
        {
            return Err(io::Error::other(
                "this release requires Linux kernel 5.4 or later",
            ));
        }
    }
    #[cfg(windows)]
    if artifact.minimum_os != "10" {
        return Err(io::Error::other("unsupported Windows release requirement"));
    }
    Ok(())
}

pub fn install(prefix: &Path, folder: &Path, state: &Path, channel: &str) -> io::Result<()> {
    if !prefix.is_absolute() || !["curl", "manual"].contains(&channel) {
        return Err(io::Error::other(
            "installation needs an absolute user prefix and supported channel",
        ));
    }
    if prefix
        .components()
        .any(|c| c.as_os_str() == "Cellar" || c.as_os_str() == "Homebrew")
        || prefix == Path::new("/opt/homebrew")
        || prefix == Path::new("/usr/local")
    {
        return Err(io::Error::other(
            "Homebrew/system locations are not managed by the curl installer; choose a user-owned prefix",
        ));
    }
    fs::create_dir_all(prefix)?;
    let prefix = fs::canonicalize(prefix)?;
    local::check_owner(&fs::metadata(&prefix)?)?;
    let install_root = root(&prefix);
    local::private_dir(&install_root)?;
    let lock = local::open_private(&install_root.join("install.lock"), false)?;
    lock.try_lock_exclusive()
        .map_err(|_| io::Error::other("another installation/update is in progress"))?;
    let release = release(folder)?;
    let artifact = release
        .artifacts
        .iter()
        .find(|a| a.target == platform().unwrap_or(""))
        .ok_or_else(|| io::Error::other("release has no binary for this OS/CPU"))?;
    system_requirements(artifact)?;
    let (_extracted, source) = extract(folder, artifact, &install_root)?;
    smoke(&source, &release.version)?;
    let record = install_root.join("install.json");
    let previous = if record.exists() {
        Some(read_installation(&record)?)
    } else {
        None
    };
    let launch = launcher(&prefix);
    if previous.is_none() && fs::symlink_metadata(&launch).is_ok() {
        return Err(io::Error::other(format!(
            "{} already exists and is not managed by PadLink",
            launch.display()
        )));
    }
    if let Some(installation) = &previous
        && (installation.state_dir != state || installation.channel != channel)
    {
        return Err(io::Error::other(
            "installation channel/state directory differs; use its existing `padlink update` command",
        ));
    }
    local::private_dir(&install_root.join("versions"))?;
    let payload = binary(&prefix, &release.version);
    if payload.exists() {
        check_hash(&payload, artifact.binary_bytes, &artifact.binary_sha256)?;
    } else {
        let stage = Stage::new(&install_root.join("versions"))?;
        fs::copy(&source, stage.0.join(binary_name()))?;
        smoke(&stage.0.join(binary_name()), &release.version)?;
        // FlushFileBuffers on Windows requires a write-capable handle.
        fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(stage.0.join(binary_name()))?
            .sync_all()?;
        fs::rename(&stage.0, payload.parent().unwrap())?;
    }
    if previous
        .as_ref()
        .is_some_and(|p| p.current_version == release.version)
    {
        println!(
            "PadLink {} is already installed at {}.",
            release.version,
            launch.display()
        );
        return Ok(());
    }
    fs::create_dir_all(prefix.join("bin"))?;
    // Stop also detects a supervisor in crash backoff with no listening worker.
    let was_running = daemon::stop(state)?;
    let new = Installation {
        schema: 1,
        channel: channel.into(),
        prefix: prefix.clone(),
        current_version: release.version.clone(),
        previous_version: previous.as_ref().map(|p| p.current_version.clone()),
        target: artifact.target.clone(),
        state_dir: state.into(),
        binary_sha256: artifact.binary_sha256.clone(),
    };
    let transaction = (|| {
        switch_launcher(&launch, &payload, previous.is_some())?;
        local::atomic_write(
            &record,
            &serde_json::to_vec_pretty(&new).map_err(io::Error::other)?,
        )?;
        if was_running {
            start_payload(&payload, state)?;
        }
        Ok(())
    })();
    if let Err(error) = transaction {
        if let Some(old) = &previous {
            let _ = daemon::stop(state);
            switch_launcher(&launch, &binary(&prefix, &old.current_version), true)?;
            local::atomic_write(
                &record,
                &serde_json::to_vec_pretty(old).map_err(io::Error::other)?,
            )?;
            if was_running {
                start_payload(&binary(&prefix, &old.current_version), state)?;
            }
            return Err(io::Error::other(format!("update rolled back: {error}")));
        }
        let _ = fs::remove_file(&launch);
        let _ = fs::remove_file(&record);
        return Err(error);
    }
    println!(
        "Installed PadLink {} ({}, {} channel) at {}",
        release.version,
        artifact.target,
        channel,
        launch.display()
    );
    if !std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
        .any(|p| p == prefix.join("bin"))
    {
        println!(
            "Add {} to your PATH, then run `padlink --version`.",
            prefix.join("bin").display()
        );
    }
    Ok(())
}

fn switch_launcher(launcher: &Path, payload: &Path, exists: bool) -> io::Result<()> {
    #[cfg(unix)]
    {
        let temporary = launcher
            .parent()
            .unwrap()
            .join(format!(".padlink-launch-{}", local::random_suffix()?));
        std::os::unix::fs::symlink(payload, &temporary)?;
        let result = local::replace(&temporary, launcher);
        if temporary.exists() {
            let _ = fs::remove_file(temporary);
        }
        let _ = exists;
        result
    }
    #[cfg(windows)]
    {
        if exists {
            return Ok(());
        }
        fs::copy(payload, launcher)?;
        Ok(())
    }
}

fn start_payload(payload: &Path, state: &Path) -> io::Result<()> {
    let result = Command::new(payload)
        .arg("--state-dir")
        .arg(state)
        .args(["daemon", "start"])
        .status()?;
    if result.success() {
        Ok(())
    } else {
        Err(io::Error::other("new daemon failed to start"))
    }
}

pub fn run(
    check: bool,
    version: Option<&str>,
    from: Option<&Path>,
    state: &Path,
) -> io::Result<()> {
    let installation = match installed()? {
        Some(installation) => installation,
        None => {
            if std::env::current_exe()?
                .components()
                .any(|c| c.as_os_str() == "Cellar")
            {
                if check {
                    println!("Homebrew installation: run `brew outdated padlink`.");
                    return Ok(());
                }
                if version.is_some() || from.is_some() {
                    return Err(io::Error::other(
                        "Homebrew owns this installation; choose versions through Homebrew",
                    ));
                }
                let running = daemon::status(state)?.is_some();
                if running {
                    daemon::stop(state)?;
                }
                let status = Command::new("brew").args(["upgrade", "padlink"]).status();
                if running {
                    start_payload(&std::env::current_exe()?, state)?;
                }
                return match status {
                    Ok(s) if s.success() => Ok(()),
                    _ => Err(io::Error::other("Homebrew upgrade failed")),
                };
            }
            return Err(io::Error::other(
                "this executable has no managed installation; install it with the PadLink curl installer first",
            ));
        }
    };
    if installation.state_dir != state {
        return Err(io::Error::other(
            "use this installation's original state directory when updating",
        ));
    }
    let parent = root(&installation.prefix);
    let stage = Stage::new(&parent)?;
    let folder = if let Some(from) = from {
        from
    } else {
        let base = if let Some(version) = version {
            valid_version(version)?;
            format!("https://github.com/{REPOSITORY}/releases/download/v{version}")
        } else {
            format!("https://github.com/{REPOSITORY}/releases/latest/download")
        };
        download(
            &format!("{base}/release-manifest.txt"),
            &stage.0.join("release-manifest.txt"),
            MAX_METADATA,
        )?;
        download(
            &format!("{base}/release-manifest.sig"),
            &stage.0.join("release-manifest.sig"),
            512,
        )?;
        &stage.0
    };
    let release = release(folder)?;
    if let Some(version) = version
        && release.version != version
    {
        return Err(io::Error::other(
            "release manifest does not match the requested version",
        ));
    }
    let candidate = valid_version(&release.version)?;
    let current = valid_version(&installation.current_version)?;
    if candidate < current && version.is_none() {
        return Err(io::Error::other(
            "latest release is older than the installed version; use --version for an explicit rollback",
        ));
    }
    if check {
        println!(
            "Installed: {}. Published: {}. {}",
            current,
            candidate,
            if candidate > current {
                "Update available."
            } else {
                "Up to date."
            }
        );
        return Ok(());
    }
    if candidate == current {
        println!("PadLink {current} is up to date.");
        return Ok(());
    }
    let artifact = release
        .artifacts
        .iter()
        .find(|a| a.target == platform().unwrap_or(""))
        .ok_or_else(|| io::Error::other("release has no binary for this OS/CPU"))?;
    system_requirements(artifact)?;
    if from.is_none() {
        download(&artifact.url, &stage.0.join(&artifact.file), artifact.bytes)?;
    }
    install(&installation.prefix, folder, state, &installation.channel)
}

pub fn uninstall(state: &Path) -> io::Result<()> {
    let installation = installed()?
        .ok_or_else(|| io::Error::other("this executable has no managed installation"))?;
    if installation.state_dir != state {
        return Err(io::Error::other(
            "use this installation's original state directory",
        ));
    }
    let install_root = root(&installation.prefix);
    let lock = local::open_private(&install_root.join("install.lock"), false)?;
    lock.try_lock_exclusive()
        .map_err(|_| io::Error::other("another update is in progress"))?;
    daemon::stop(state)?;
    autostart::remove_for_uninstall(state)?;
    let versions = install_root.join("versions");
    local::private_dir(&versions)?;
    #[cfg(unix)]
    {
        fs::remove_file(launcher(&installation.prefix))?;
        fs::remove_dir_all(&versions)?;
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // Running Windows images cannot be deleted. A bounded remover retries after
        // both this payload and its forwarding launcher exit. No policy override.
        let launch = launcher(&installation.prefix);
        let quote = |p: &Path| p.to_string_lossy().replace('\'', "''");
        let script = format!(
            "$ErrorActionPreference='Stop'; for ($attempt=0; $attempt -lt 80; $attempt++) {{ Start-Sleep -Milliseconds 250; try {{ if (Test-Path -LiteralPath '{}') {{ Remove-Item -LiteralPath '{}' -Force }}; if (Test-Path -LiteralPath '{}') {{ Remove-Item -LiteralPath '{}' -Recurse -Force }}; Remove-Item -LiteralPath '{}' -Force -ErrorAction SilentlyContinue; exit 0 }} catch {{ }} }}; exit 1",
            quote(&launch),
            quote(&launch),
            quote(&versions),
            quote(&versions),
            quote(&install_root.join("install.lock"))
        );
        Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command"])
            .arg(script)
            .creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
    }
    fs::remove_file(install_root.join("install.json"))?;
    println!(
        "PadLink uninstalled. User state is retained at {}.",
        state.display()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn signed_metadata_accepts_its_key_and_rejects_tampering_or_wrong_key() {
        use rsa::{
            RsaPrivateKey,
            pkcs1v15::SigningKey,
            pkcs8::{EncodePublicKey, LineEnding},
            signature::{SignatureEncoding, Signer},
        };
        let private = RsaPrivateKey::new(&mut rand::rngs::OsRng, 2048).unwrap();
        let public = RsaPublicKey::from(&private)
            .to_public_key_pem(LineEnding::LF)
            .unwrap();
        let mut data = manifest("aarch64-apple-darwin", "0.1.1");
        let signature = SigningKey::<Sha256>::new(private).sign(&data).to_vec();
        assert!(verify_signature(&data, &signature, &public).is_ok());
        assert!(verify_signature(&data, &signature, PUBLIC_KEY).is_err());
        data[0] ^= 1;
        assert!(verify_signature(&data, &signature, &public).is_err());
    }
    fn manifest(target: &str, version: &str) -> Vec<u8> {
        let hash = "0".repeat(64);
        format!("PADLINK_RELEASE 1\nversion {version}\nprotocol 1\nartifact {target} padlink-{version}-{target}.tar.gz 100 {hash} 100 {hash} 13.0 padlink https://github.com/{REPOSITORY}/releases/download/v{version}/padlink-{version}-{target}.tar.gz\n").into_bytes()
    }
    #[test]
    fn traversal_versions_and_artifacts_are_rejected() {
        assert!(valid_version("../evil").is_err());
        assert!(parse_release(&manifest("../../evil", "0.1.1")).is_err());
        assert!(parse_release(&manifest("aarch64-apple-darwin", "0.1.1")).is_ok());
        let bytes = manifest("aarch64-apple-darwin", "0.1.1");
        let bad = String::from_utf8(bytes)
            .unwrap()
            .replace(".tar.gz", "/../../evil");
        assert!(parse_release(bad.as_bytes()).is_err());
    }
    #[test]
    fn duplicate_targets_and_bad_download_origins_are_rejected() {
        let bytes = manifest("aarch64-apple-darwin", "0.1.1");
        let text = String::from_utf8(bytes).unwrap();
        let duplicate = format!("{}{}\n", text, text.lines().last().unwrap());
        assert!(parse_release(duplicate.as_bytes()).is_err());
        assert!(
            parse_release(
                text.replace("https://github.com/", "https://evil.example/")
                    .as_bytes()
            )
            .is_err()
        );
    }
    #[test]
    fn missing_signature_never_accepts_release_metadata() {
        assert!(
            verify_signature(
                &manifest("aarch64-apple-darwin", "0.1.1"),
                &[0; 384],
                PUBLIC_KEY
            )
            .is_err()
        );
    }
}
