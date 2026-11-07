//! PadLink desktop CLI.
//!
//! Pairing verification uses the shared core. Installation, local daemon
//! lifecycle and signed updates are implemented. Commands that have
//! no implementation exit with status 2 instead of pretending to succeed.

use std::process::ExitCode;

use clap::{Args, CommandFactory, Parser, Subcommand, ValueEnum};
use padlink_protocol::PROTOCOL_VERSION;
mod autostart;
mod daemon;
mod local;
mod pair;
mod update;
#[global_allocator]
static HEAP: padlink_protocol::memory::BudgetedAllocator<std::alloc::System> =
    padlink_protocol::memory::BudgetedAllocator::new(std::alloc::System, 4_000_000);

#[derive(Debug, Parser)]
#[command(
    name = "padlink",
    version,
    about = "PadLink desktop CLI, background daemon and updates"
)]
struct Cli {
    /// Override the private per-user state directory.
    #[arg(long, global = true, hide = true)]
    state_dir: Option<std::path::PathBuf>,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Verify phone pairing and encrypted TCP, then close the connection.
    Pair(PairArgs),
    /// Discover phones advertising the PadLink pairing service.
    Scan(ScanArgs),
    /// Pair with a phone and open a controller session.
    Connect(ConnectArgs),
    /// Release input and close the active session.
    Disconnect,
    /// Show local session and daemon status.
    Status(StatusArgs),
    /// Check platform, network, and permission prerequisites.
    Doctor,
    /// Check for and install a verified CLI update.
    Update(UpdateArgs),
    /// Remove this managed CLI installation and its login registration.
    Uninstall,
    #[command(name = "_install", hide = true)]
    Install(InstallArgs),
    /// Manage the per-user background daemon.
    Daemon {
        #[command(subcommand)]
        action: DaemonAction,
    },
    /// Manage open-at-login behavior.
    Autostart {
        #[command(subcommand)]
        action: AutostartAction,
    },
}

#[derive(Debug, Args)]
struct PairArgs {
    /// Phone address shown by the app, for example 192.168.1.20:41337.
    endpoint: std::net::SocketAddr,
    /// Unverified desktop name displayed in the phone's Allow/Deny prompt.
    #[arg(long, default_value = "PadLink desktop")]
    name: String,
}

#[derive(Debug, Args)]
#[allow(dead_code)] // Consumed by clap; handlers arrive in Phase 2.
struct ScanArgs {
    /// Restrict discovery to one network interface.
    #[arg(long, value_name = "NAME")]
    interface: Option<String>,
    /// Explicitly probe the local subnet after bounded discovery fails.
    #[arg(long)]
    probe_subnet: bool,
}

#[derive(Debug, Args)]
#[allow(dead_code)] // Consumed by clap; handlers arrive in Phase 2.
struct ConnectArgs {
    /// Device name or endpoint, for example 192.0.2.10:47600.
    #[arg(value_name = "DEVICE_OR_ENDPOINT")]
    target: Option<String>,
    /// Address to connect to.
    #[arg(long, value_name = "ADDR")]
    ip: Option<String>,
    /// Port to connect to.
    #[arg(long, value_name = "PORT")]
    port: Option<u16>,
    /// Preferred transport. USB remains unavailable until its gate passes.
    #[arg(long, value_enum, default_value_t = Transport::Auto)]
    transport: Transport,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
enum Transport {
    Auto,
    Udp,
    Tcp,
    Usb,
}

#[derive(Debug, Args)]
struct StatusArgs {
    /// Emit machine-readable output.
    #[arg(long)]
    json: bool,
}

#[derive(Debug, Subcommand)]
enum DaemonAction {
    Start,
    Stop,
    Restart,
    Status,
    Run,
    #[command(hide = true)]
    Worker,
}

#[derive(Debug, Args)]
struct UpdateArgs {
    /// Report the latest published version without changing the installation.
    #[arg(long)]
    check: bool,
    /// Install a specific version, including an explicit rollback.
    #[arg(long)]
    version: Option<String>,
    /// Use an offline release folder; signatures and checksums remain required.
    #[arg(long)]
    from: Option<std::path::PathBuf>,
}

#[derive(Debug, Args)]
struct InstallArgs {
    #[arg(long)]
    prefix: std::path::PathBuf,
    #[arg(long)]
    from: std::path::PathBuf,
    #[arg(long, default_value = "curl")]
    channel: String,
}

#[derive(Debug, Subcommand)]
enum AutostartAction {
    Enable,
    Disable,
    Status,
}

fn main() -> ExitCode {
    #[cfg(windows)]
    match update::forward_launcher() {
        Ok(Some(code)) => return code,
        Err(error) => {
            eprintln!("padlink: {error}");
            return ExitCode::from(2);
        }
        Ok(None) => {}
    }
    let cli = Cli::parse();
    let Some(command) = cli.command else {
        let mut command = Cli::command();
        let _ = command.print_help();
        println!();
        return ExitCode::SUCCESS;
    };
    let result = local::state_dir(cli.state_dir)
        .map_err(|e| e.to_string())
        .and_then(|state| run(command, &state));
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("padlink: {error}");
            ExitCode::from(2)
        }
    }
}

fn run(command: Command, state: &std::path::Path) -> Result<(), String> {
    let result = match command {
        Command::Pair(args) => return pair::run(args.endpoint, &args.name),
        Command::Status(args) => daemon::show(state, args.json),
        Command::Daemon { action } => match action {
            DaemonAction::Start => daemon::start(state),
            DaemonAction::Stop => daemon::stop(state).map(|stopped| {
                println!(
                    "Daemon {}.",
                    if stopped {
                        "stopped"
                    } else {
                        "is already stopped"
                    }
                )
            }),
            DaemonAction::Restart => daemon::stop(state).and_then(|_| daemon::start(state)),
            DaemonAction::Status => daemon::show(state, false),
            DaemonAction::Run => daemon::supervise(state),
            DaemonAction::Worker => daemon::worker(state),
        },
        Command::Disconnect => {
            if daemon::status(state).map_err(|e| e.to_string())?.is_some() {
                daemon::rpc(state, "disconnect").map(|_| println!("No active gameplay session."))
            } else {
                println!("No active gameplay session.");
                Ok(())
            }
        }
        Command::Autostart { action } => match action {
            AutostartAction::Enable => {
                update::stable_executable().and_then(|path| autostart::enable(state, &path))
            }
            AutostartAction::Disable => autostart::disable(state),
            AutostartAction::Status => autostart::enabled(state).map(|enabled| {
                println!(
                    "Login startup: {}",
                    if enabled { "enabled" } else { "disabled" }
                )
            }),
        },
        Command::Update(args) => update::run(
            args.check,
            args.version.as_deref(),
            args.from.as_deref(),
            state,
        ),
        Command::Install(args) => update::install(&args.prefix, &args.from, state, &args.channel),
        Command::Uninstall => update::uninstall(state),
        Command::Doctor => {
            println!(
                "PadLink {} (protocol {PROTOCOL_VERSION})",
                env!("CARGO_PKG_VERSION")
            );
            println!(
                "Platform: {}",
                update::platform().map_err(|e| e.to_string())?
            );
            println!("Private state: {}", state.display());
            println!("Daemon log: {}", daemon::log_path(state).display());
            println!("Memory: bounded Rust heap; aggregate RSS limit remains unvalidated.");
            println!("Gameplay: unavailable in this build.");
            daemon::show(state, false)
        }
        command => {
            return Err(format!(
                "`{}` is not implemented in this build.",
                command.name()
            ));
        }
    };
    result.map_err(|e| e.to_string())
}

impl Command {
    fn name(&self) -> &'static str {
        match self {
            Self::Pair(_) => "pair",
            Self::Scan(_) => "scan",
            Self::Connect(_) => "connect",
            Self::Disconnect => "disconnect",
            Self::Status(_) => "status",
            Self::Doctor => "doctor",
            Self::Update(_) => "update",
            Self::Uninstall => "uninstall",
            Self::Install(_) => "_install",
            Self::Daemon { .. } => "daemon",
            Self::Autostart { .. } => "autostart",
        }
    }
}
