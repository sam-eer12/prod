"""Exercise the actual installers, active upgrade, tamper rejection and rollback."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def run(command, success=True):
    # A detached Windows child can retain an inherited pipe handle. File-based
    # capture observes the CLI's exit without waiting for that daemon's EOF.
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        result = subprocess.run([str(x) for x in command], stdout=stdout, stderr=stderr, timeout=30)
        stdout.seek(0); stderr.seek(0)
        result.stdout = stdout.read().decode("utf-8", errors="replace")
        result.stderr = stderr.read().decode("utf-8", errors="replace")
    if (result.returncode == 0) != success:
        raise RuntimeError(f"Command failed its expectation: {command}\n{result.stdout}\n{result.stderr}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--failed-release", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--test-autostart", action="store_true",
                        help="Exercise login registration on disposable native CI hosts")
    args = parser.parse_args()
    # A short private Unix path also fits macOS's Unix-socket pathname limit.
    with tempfile.TemporaryDirectory(prefix="pdl-smoke-", dir=None if sys.platform == "win32" else "/tmp") as temporary:
        root = Path(temporary).resolve()
        prefix, state = root / "prefix space", root / "state space"
        executable = prefix / "bin" / ("padlink.exe" if sys.platform == "win32" else "padlink")
        def cli(*arguments, success=True):
            return run([executable, "--state-dir", state, *arguments], success)
        try:
            if sys.platform == "win32":
                install = ["powershell.exe", "-NoProfile", "-File", args.fixture / "install.ps1", "-Prefix", prefix, "-From", args.fixture, "-StateDir", state]
            else:
                install = ["sh", args.fixture / "install.sh", "--prefix", prefix, "--from", args.fixture, "--state-dir", state]
            run(install)
            assert "0.0.0-fixture" in cli("--version").stdout
            cli("daemon", "start")
            original = json.loads(cli("status", "--json").stdout)
            if args.test_autostart:
                # An XDG-only headless CI host can exercise registration without
                # opening a display or starting a second daemon.
                if sys.platform.startswith("linux"):
                    os.environ.setdefault("DISPLAY", ":padlink-ci")
                cli("autostart", "enable")
                assert "enabled" in cli("autostart", "status").stdout
                assert json.loads(cli("status", "--json").stdout)["pid"] == original["pid"]
            cli("update", "--check", "--from", args.release)
            cli("update", "--from", args.release)
            assert args.version in cli("--version").stdout
            updated = json.loads(cli("status", "--json").stdout)
            assert updated["state"] == "idle" and updated["pid"] != original["pid"]
            assert updated["version"] == args.version
            cli("update", "--version", "0.0.0-fixture", "--from", args.fixture)
            assert "0.0.0-fixture" in cli("--version").stdout
            assert json.loads(cli("status", "--json").stdout)["state"] == "idle"
            failed = cli("update", "--version", "0.0.1-fixture", "--from", args.failed_release, success=False)
            assert "update rolled back" in failed.stderr
            assert "0.0.0-fixture" in cli("--version").stdout
            assert json.loads(cli("status", "--json").stdout)["version"] == "0.0.0-fixture"
            if args.test_autostart:
                assert "enabled" in cli("autostart", "status").stdout
                before_disable = json.loads(cli("status", "--json").stdout)["pid"]
                cli("autostart", "disable")
                assert "disabled" in cli("autostart", "status").stdout
                assert json.loads(cli("status", "--json").stdout)["pid"] == before_disable
            damaged = root / "damaged"
            shutil.copytree(args.release, damaged)
            signature = damaged / "release-manifest.sig"
            contents = bytearray(signature.read_bytes()); contents[0] ^= 1; signature.write_bytes(contents)
            cli("update", "--from", damaged, success=False)
            assert "0.0.0-fixture" in cli("--version").stdout
            shutil.copy2(args.release / "release-manifest.sig", signature)
            # Tamper every archive so the platform-selected one is certainly rejected.
            for archive in damaged.glob("*.tar.gz"):
                with archive.open("r+b") as stream:
                    byte = stream.read(1); stream.seek(0); stream.write(bytes([byte[0] ^ 1]))
            cli("update", "--from", damaged, success=False)
            assert "0.0.0-fixture" in cli("--version").stdout
            cli("daemon", "stop")
            cli("update", "--from", args.release)
            assert json.loads(cli("status", "--json").stdout)["state"] == "stopped"
            cli("uninstall")
            deadline = time.monotonic() + 25
            while (executable.exists() or (prefix / "share/padlink/versions").exists()) and time.monotonic() < deadline:
                time.sleep(0.1)
            assert not executable.exists(), "launcher remained after uninstall"
            assert not (prefix / "share/padlink/install.json").exists()
            assert not (prefix / "share/padlink/versions").exists(), "payloads remained after uninstall"
            assert state.is_dir(), "uninstall removed user state"
            print("Installer, active update, rollback, tamper rejection and uninstall passed.")
        finally:
            if executable.exists():
                if args.test_autostart:
                    try: cli("autostart", "disable")
                    except (RuntimeError, subprocess.TimeoutExpired): pass
                try: cli("daemon", "stop")
                except (RuntimeError, subprocess.TimeoutExpired): pass


if __name__ == "__main__":
    main()
