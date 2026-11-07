# PadLink CLI installation and updates

The CLI is a native executable and needs no Rust toolchain to install. Published
targets are macOS 13+ on Intel/Apple Silicon, Linux kernel 5.4+ on x64/ARM64, and
Windows 10+ on x64. Linux binaries use musl; Windows binaries use the static C
runtime. The CLI manages an idle daemon and verifies phone pairing. Live
gameplay, discovery, drivers and native virtual gamepad backends are unfinished.

## macOS and Linux

Download the complete installer before running it:

```sh
curl --fail --location --proto '=https' --proto-redir '=https' \
  https://github.com/sam-eer12/prod/releases/latest/download/install.sh \
  --output /tmp/padlink-install.sh
sh /tmp/padlink-install.sh --add-to-path
```

Run the second command only after curl succeeds. The installer uses `~/.local`
by default and adds `~/.local/bin` to the zsh/bash startup file only when
`--add-to-path` is provided. Open a new terminal, then type `padlink`. Other
shells can add the printed bin directory to PATH manually. Run without sudo.
Use `--prefix /absolute/user/path` for a custom prefix and `--version 0.1.1`
for an immutable release. Rerunning the installer upgrades a managed installation.

macOS CLI builds do not require a paid Apple Developer identity. The release
signature is PadLink's publisher signature, distinct from Apple's Developer ID
signing/notarization. There is no free iOS provisioning profile or seven-day
expiry involved. No macOS virtual-HID entitlement or login-agent LAN permission
behavior is claimed by this idle-daemon release.

## Windows

In PowerShell 5.1 or later, download and run the installer:

```powershell
curl.exe --fail --location --proto '=https' --proto-redir '=https' `
  https://github.com/sam-eer12/prod/releases/latest/download/install.ps1 `
  --output "$env:TEMP\padlink-install.ps1"
if ($LASTEXITCODE -eq 0) { & "$env:TEMP\padlink-install.ps1" -AddToPath }
```

The default prefix is `%LOCALAPPDATA%\PadLink`. `-AddToPath` updates your user
PATH; reopen the terminal for other sessions. If local policy prohibits script
files, follow your administrator's policy; the installer does not change it.
The x64 binary archive is also downloadable from the release page.

The stable `bin\padlink.exe` launcher forwards commands to versioned binaries,
so updates do not overwrite a running Windows executable. Uninstall uses a
short-lived, bounded remover after the CLI and launcher exit.

## Daemon and login startup

```sh
padlink --version
padlink daemon start
padlink status --json
padlink daemon restart
padlink daemon stop
padlink autostart enable
padlink autostart status
padlink autostart disable
padlink doctor
```

Typing `padlink` displays available commands. Installation does not start the
daemon or enable login startup. Starting a daemon leaves it idle and unpaired.
Login startup uses a macOS LaunchAgent, a Windows per-user Scheduled Task, or
a Linux systemd user service. Linux graphical sessions without a user systemd
manager use XDG autostart. Headless hosts without systemd can run
`padlink daemon run` under their own supervisor. Disabling login startup leaves
an already running daemon active; use `daemon stop` to stop it now.

The supervisor retries crashes after 1, 5 and 30 seconds, at most three times
in five minutes. An intentional stop stays stopped, including during crash
recovery. One private worker and supervisor are allowed per state directory.
Control traffic uses a private Unix socket or a current-user Windows pipe,
with at most four clients, 4096-byte frames and two-second request deadlines.

State is retained in `~/.local/state/padlink` on Unix or
`%LOCALAPPDATA%\PadLink\state` on Windows. `padlink doctor` prints the log path
and implementation status. Heap accounting does not establish the product's
aggregate 75 MB memory requirement.

## Updates, rollback and removal

```sh
padlink update --check
padlink update
padlink update --version 0.1.1
padlink uninstall
```

Updates verify the signed release manifest, protocol compatibility, archive
size/hash, extracted binary size/hash and executable version. Downloads use
HTTPS, timeouts and bounded retries. The new payload is staged on the install
filesystem. A running daemon is stopped before switching and restarted only
if it was running before the update. Failure restores the previous launcher,
installation record and running daemon. A stopped daemon stays stopped.

Automatic updates refuse a downgrade. An explicit `--version` can select an
older published version with a compatible phone protocol. The previous payload
is retained; no periodic automatic update service runs in the background.
`--from /absolute/release/folder` supports offline installs/updates and requires
the same signed manifest, detached signature and platform archive.

Uninstall stops the daemon, removes login registration, launcher and owned
versioned payloads. User state and shell PATH entries are retained. No shared
drivers or unrelated OS configuration are removed. A fresh installation does
not regain phone trust automatically.

The curl installer refuses Homebrew/system prefixes and existing unmanaged
launchers. No Homebrew tap is published yet. If installed through a future
Homebrew formula, `padlink update` delegates ownership to `brew upgrade padlink`;
stop/disable login startup before `brew uninstall padlink`.

## Publisher verification and release maintenance

The signed manifest format pins version, phone protocol, target, immutable
GitHub download URL, sizes, SHA-256 hashes, minimum OS and flat binary name.
RSA-3072 PKCS#1 v1.5 SHA-256 signatures use the public key in
`packaging/release-public.pem`, embedded in Rust and both installers.
The installer itself is downloaded through GitHub HTTPS; inspect or pin an
immutable installer version if a mutable latest URL is unsuitable.

`.github/workflows/release.yml` builds all five targets, signs their manifests,
and tests installation, active updates, explicit downgrade, automatic rollback
after startup failure, tamper rejection, stopped updates and removal on native
runners. Test fixture releases are never published. Manual runs validate only;
a `vVERSION` tag publishes production after all jobs pass. `Cargo.toml` must
match that stable version. Normal CI also checks script syntax and pinned keys.

The private publisher key is stored outside tracked source, in the ignored
`.release-keys/release-private.pem` locally and the GitHub Actions secret
`PADLINK_RELEASE_SIGNING_KEY` for release jobs. Keep an encrypted offline backup;
never commit it or confuse it with the Android APK keystore. Replacing this key
requires a trust-root transition because existing installers pin the public key.

For isolated local testing, `packaging/build_release.py --targets TARGET`
can sign a platform subset. Production signing requires all five targets by
default. `packaging/build_fixture.py` restores source/lockfiles after producing
older or startup-failing test binaries; run it sequentially with other builds.
