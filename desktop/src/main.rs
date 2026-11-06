//! PadLink desktop CLI.
//!
//! Pairing verification uses the shared core. Discovery, the daemon, and
//! gamepad backends remain future work. Commands that have
//! no implementation exit with status 2 instead of pretending to succeed.

use std::process::ExitCode;

use clap::{Args, CommandFactory, Parser, Subcommand, ValueEnum};
use padlink_protocol::PROTOCOL_VERSION;
mod pair;
#[global_allocator]
static HEAP: padlink_protocol::memory::BudgetedAllocator<std::alloc::System> =
    padlink_protocol::memory::BudgetedAllocator::new(std::alloc::System, 4_000_000);

#[derive(Debug, Parser)]
#[command(
    name = "padlink",
    version,
    about = "PadLink desktop CLI and daemon (protocol core, no live session yet)"
)]
struct Cli {
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
                let memory = HEAP.metrics();
                println!(
                    "{{\"state\":\"scaffold\",\"protocol_version\":{PROTOCOL_VERSION},\"protocol_core\":true,\"pairing_check_implemented\":true,\"session_implemented\":false,\"rust_heap_bytes\":{},\"rust_heap_peak_bytes\":{},\"rust_heap_limit_bytes\":{}}}",
                    memory.used, memory.peak, memory.limit
                );
            } else {
                println!("PadLink {}", env!("CARGO_PKG_VERSION"));
                println!("State: scaffold (protocol core present; no daemon or live session)");
                println!("Protocol revision: {PROTOCOL_VERSION}");
            }
            ExitCode::SUCCESS
        }
        Some(Command::Pair(args)) => match pair::run(args.endpoint, &args.name) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("padlink: {error}");
                ExitCode::from(2)
            }
        },
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
            Self::Pair(_) => "pair",
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
