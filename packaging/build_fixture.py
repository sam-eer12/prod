"""Build an older version of the same CLI for real upgrade/rollback tests."""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
VERSION = "0.0.0-fixture"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fail-start", action="store_true",
                        help="Build a signed-test candidate whose daemon fails to start")
    args = parser.parse_args()
    manifest = ROOT / "Cargo.toml"
    lock = ROOT / "Cargo.lock"
    source = ROOT / "desktop/src/main.rs"
    original_source = source.read_bytes()
    version = "0.0.1-fixture" if args.fail_start else VERSION
    original_manifest, original_lock = manifest.read_bytes(), lock.read_bytes()
    try:
        manifest.write_text(re.sub(r'^version = "[^"]+"', f'version = "{version}"', original_manifest.decode(), count=1, flags=re.MULTILINE))
        if args.fail_start:
            source.write_text(original_source.decode().replace(
                'DaemonAction::Start => daemon::start(state),',
                'DaemonAction::Start => Err(std::io::Error::other("fixture startup failure")),',
            ))
        subprocess.run(["cargo", "build", "--offline", "--release", "-p", "padlink-cli", "--target", args.target], cwd=ROOT, check=True)
        binary = ROOT / "target" / args.target / "release" / ("padlink.exe" if "windows" in args.target else "padlink")
        subprocess.run(["python3", str(ROOT / "packaging/build_release.py"), "--binary", str(binary), "--target", args.target, "--version", version, "--out", str(args.out)], check=True)
    finally:
        manifest.write_bytes(original_manifest)
        lock.write_bytes(original_lock)
        source.write_bytes(original_source)


if __name__ == "__main__":
    main()
