PadLink CLI now includes per-user background daemon management and verified updates.

- Prebuilt binaries for macOS 13+ (Apple Silicon and Intel), Linux kernel 5.4+ (ARM64 and x64, musl), and Windows 10+ (x64).
- Install through the included shell or PowerShell installer, run `padlink`, manage `padlink daemon start|stop|restart`, and opt into `padlink autostart enable`.
- `padlink update` verifies publisher signatures and SHA-256 hashes, coordinates a running daemon, and restores the previous version if replacement startup fails. Use `padlink update --check` to check without installing.
- `padlink uninstall` removes the launcher, payloads and login registration while retaining private user state.

The daemon starts idle. Phone pairing verification is available through `padlink pair`; discovery, live input transport and native virtual gamepad backends remain unfinished. This release does not provide desktop gameplay or macOS Developer ID notarization.

See the repository README and `docs/CLI_DISTRIBUTION.md` for installation commands and release verification details.
