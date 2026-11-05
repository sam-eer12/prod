//! PadLink desktop CLI.
//!
//! This is the baseline command surface only. Discovery, pairing, the daemon,
//! and gamepad backends are intentionally not implemented yet. Commands that
//! have no implementation exit with status 2 instead of pretending to succeed.

use std::process::ExitCode;

use clap::{Args, CommandFactory, Parser, Subcommand, ValueEnum};
use padlink_protocol::PROTOCOL_VERSION;

#[derive(Debug, Parser)]
#[command(
    name = "padlink",
    version,
    about = "PadLink desktop CLI and daemon (baseline scaffold)"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Debug, Subcommand)]
enum Command {
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
}

#[derive(Debug, Subcommand)]
enum AutostartAction {
    Enable,
    Disable,
    Status,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    match cli.command {
        None => {
            let mut command = Cli::command();
            let _ = command.print_help();
            println!();
            ExitCode::SUCCESS
        }
        Some(Command::Status(args)) => {
            if args.json {
                println!(
                    "{{\"state\":\"scaffold\",\"protocol_version\":{PROTOCOL_VERSION},\"implemented\":false}}"
                );
            } else {
                println!("PadLink {}", env!("CARGO_PKG_VERSION"));
                println!("State: scaffold (no daemon or session implemented)");
                println!("Protocol revision: {PROTOCOL_VERSION}");
            }
            ExitCode::SUCCESS
        }
        Some(command) => {
            eprintln!(
                "padlink: `{}` is not implemented in this baseline scaffold.",
                command.name()
            );
            ExitCode::from(2)
        }
    }
}

impl Command {
    fn name(&self) -> &'static str {
        match self {
            Self::Scan(_) => "scan",
            Self::Connect(_) => "connect",
            Self::Disconnect => "disconnect",
            Self::Status(_) => "status",
            Self::Doctor => "doctor",
            Self::Daemon { .. } => "daemon",
            Self::Autostart { .. } => "autostart",
        }
    }
}
