//! What fits in one FIPS fragment, and what it costs when it doesn't.
//!
//! docs/fips/FIPS_INTEGRATION_ROADMAP.md §2.2 budgeted 1242 usable bytes at a 1280-byte
//! underlay MTU and concluded that ~42 bytes of margin over quinn's 1200 floor
//! was too thin to ship. The arithmetic omitted the FMP layer. The real budget
//! is 1170 — *below* the floor — so QUIC has been fragmenting into two FIPS
//! fragments the entire time, including in every green result the roadmap cites.
//!
//! Two things kept that invisible:
//!
//!   1. `quic_e2e` runs in-process, where nothing enforces a path MTU.
//!   2. The loss injector in `transport/udp_socket.rs` drops whole QUIC packets
//!      *above* FIPS, so it cannot observe a lost fragment by construction.
//!
//! This binary reports the budget from fips-core's own constants, then runs the
//! §5 loss table under both models so the difference is a measured number rather
//! than an argument.
//!
//! Usage:  cargo run --release --bin mtu_budget
//!         FIPS_E2E_BYTES=4194304 cargo run --release --bin mtu_budget

use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use fips_bridge_core::transport::mtu::{
    fragments_for, min_underlay_for_unfragmented_quic, quic_fits_single_fragment,
    single_fragment_budget, DEFAULT_UNDERLAY_UDP_MTU, LAN_UNDERLAY_UDP_MTU, QUIC_MIN_MTU,
    SERVICE_DATAGRAM_OVERHEAD,
};

/// The §5 loss table, in parts per thousand.
const LOSS_LADDER: &[u32] = &[0, 10, 30, 50, 100];

fn main() -> Result<()> {
    report_budget();
    run_loss_table()?;
    Ok(())
}

fn report_budget() {
    println!("=== single-fragment budget ===\n");
    println!("  FIPS service-datagram overhead : {SERVICE_DATAGRAM_OVERHEAD} bytes");
    println!("    FIPS_OVERHEAD (fips-core upper/icmp.rs:91)  106");
    println!("    FSP_PORT_HEADER_SIZE                          4");
    println!("  quinn min_mtu floor            : {QUIC_MIN_MTU} bytes\n");

    for mtu in [DEFAULT_UNDERLAY_UDP_MTU, LAN_UNDERLAY_UDP_MTU] {
        let budget = single_fragment_budget(mtu);
        let fits = quic_fits_single_fragment(mtu);
        let frags = fragments_for(QUIC_MIN_MTU as usize, mtu);
        let label = if mtu == DEFAULT_UNDERLAY_UDP_MTU {
            "default (NAT-safe)"
        } else {
            "lan profile"
        };
        println!("  underlay {mtu}  [{label}]");
        println!("    usable payload        : {budget} bytes");
        println!("    floor-sized QUIC pkt  : {frags} fragment(s)");
        println!(
            "    verdict               : {}\n",
            if fits {
                "fits in one fragment"
            } else {
                "DOES NOT FIT — every QUIC packet fragments"
            }
        );
    }

    println!(
        "  minimum underlay for unfragmented QUIC: {} bytes",
        min_underlay_for_unfragmented_quic()
    );
    println!("  (above the 1280 that nostr-vpn reverted to, twice)\n");

    println!("  roadmap §2.2 claimed 1242 usable; it omitted the FMP layer:");
    println!("    FMP outer header                16");
    println!("    FMP inner header                 5");
    println!("    SessionDatagram body            35");
    println!("    FMP Poly1305 tag                16");
    println!("                                   ───");
    println!("                                    72   = 1242 - 1170\n");
}

/// Re-runs `quic_e2e` per loss level under each model.
///
/// A subprocess rather than an in-process loop because the loss knobs are read
/// from the environment once per socket, and because it keeps this binary
/// honest: it measures the same code path the roadmap measured.
fn run_loss_table() -> Result<()> {
    println!("=== loss table: packet-level vs fragment-level ===\n");
    println!("  Same transfer, same loss rate, two models of where loss lands.");
    println!("  'packet' is what the roadmap measured. 'fragment' is the wire.\n");

    // The first subprocess pays for cargo's release build of quic_e2e, which
    // lands entirely in whichever cell runs first and reads as a 90-second
    // outlier. Burn it before timing anything.
    print!("  warming up...");
    use std::io::Write;
    let _ = std::io::stdout().flush();
    let _ = timed_run(0, "packet")?;
    println!(" done\n");
    println!(
        "  {:>6}  {:>12}  {:>12}  {:>10}",
        "loss", "packet mode", "fragment mode", "delta"
    );
    println!("  {:->6}  {:->12}  {:->12}  {:->10}", "", "", "", "");

    for &permille in LOSS_LADDER {
        let packet = timed_run(permille, "packet")?;
        let fragment = timed_run(permille, "fragment")?;

        let cell = |r: &RunOutcome| match r {
            RunOutcome::Ok(d) => format!("{:.2}s", d.as_secs_f64()),
            RunOutcome::Failed => "FAIL".to_string(),
        };
        let delta = match (&packet, &fragment) {
            (RunOutcome::Ok(p), RunOutcome::Ok(f)) if p.as_secs_f64() > 0.0 => {
                format!("{:.2}x", f.as_secs_f64() / p.as_secs_f64())
            }
            (RunOutcome::Ok(_), RunOutcome::Failed) => "broke".to_string(),
            _ => "-".to_string(),
        };

        println!(
            "  {:>5}%  {:>12}  {:>12}  {:>10}",
            permille as f64 / 10.0,
            cell(&packet),
            cell(&fragment),
            delta
        );
    }

    println!("\n  Fragment mode rolls once per fragment, so a packet survives only");
    println!("  if every fragment does — which is what FIPS reassembly requires.");
    println!("  At the default MTU that is 2 rolls, so 3% link loss lands as ~5.9%.");
    println!("\n  NOTE: still one host. This corrects the *model*, not the venue.");
    println!("  Real RTT, real NAT traversal and real bursty loss still need two");
    println!("  machines before any of these numbers describe a shipping path.");

    Ok(())
}

enum RunOutcome {
    Ok(Duration),
    Failed,
}

fn timed_run(permille: u32, mode: &str) -> Result<RunOutcome> {
    let started = Instant::now();
    let status = Command::new(env!("CARGO"))
        .args(["run", "--release", "--quiet", "--bin", "quic_e2e"])
        .env("FIPS_BRIDGE_LOSS_PERMILLE", permille.to_string())
        .env("FIPS_BRIDGE_LOSS_MODE", mode)
        .env("FIPS_E2E_BYTES", bytes())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .context("spawn quic_e2e")?;

    Ok(if status.success() {
        RunOutcome::Ok(started.elapsed())
    } else {
        RunOutcome::Failed
    })
}

fn bytes() -> String {
    std::env::var("FIPS_E2E_BYTES").unwrap_or_else(|_| (4 * 1024 * 1024).to_string())
}
