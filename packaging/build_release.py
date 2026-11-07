"""Package native binaries and sign a bounded, flat release manifest."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "sam-eer12/prod"
TARGETS = {
    "aarch64-apple-darwin": ("padlink", "13.0"),
    "x86_64-apple-darwin": ("padlink", "13.0"),
    "aarch64-unknown-linux-musl": ("padlink", "5.4"),
    "x86_64-unknown-linux-musl": ("padlink", "5.4"),
    "x86_64-pc-windows-msvc": ("padlink.exe", "10"),
}


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--target", choices=TARGETS)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--key-file", type=Path)
    parser.add_argument("--key-env")
    parser.add_argument("--targets", nargs="+", choices=TARGETS,
                        help="Explicit subset for isolated local tests; production signs every target by default")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?", args.version):
        parser.error("version must be a release semantic version")
    args.out.mkdir(parents=True, exist_ok=True)
    if args.binary:
        if not args.target:
            parser.error("--binary needs --target")
        name = TARGETS[args.target][0]
        archive = args.out / f"padlink-{args.version}-{args.target}.tar.gz"
        with tarfile.open(archive, "w:gz") as package:
            information = package.gettarinfo(str(args.binary), arcname=name)
            information.uid = information.gid = 0
            information.uname = information.gname = ""
            information.mode = 0o755
            with args.binary.open("rb") as stream:
                package.addfile(information, stream)
        print(f"Packaged {archive.name}")
        return
    if not args.artifacts or bool(args.key_file) == bool(args.key_env):
        parser.error("manifest signing needs --artifacts and exactly one of --key-file/--key-env")
    protocol_source = (ROOT / "protocol/src/lib.rs").read_text()
    protocol = re.search(r"pub const PROTOCOL_VERSION: u16 = ([0-9]+);", protocol_source)
    if not protocol:
        parser.error("cannot determine the source protocol version")
    records = ["PADLINK_RELEASE 1", f"version {args.version}", f"protocol {protocol[1]}"]
    targets = args.targets or list(TARGETS)
    for target in targets:
        name, minimum = TARGETS[target]
        filename = f"padlink-{args.version}-{target}.tar.gz"
        archive = args.artifacts / filename
        if not archive.is_file() or archive.stat().st_size > 32_000_000:
            parser.error(f"missing or oversized archive: {filename}")
        with tarfile.open(archive, "r:gz") as package:
            entries = package.getmembers()
            if len(entries) != 1 or entries[0].name != name or not entries[0].isfile() or entries[0].size > 24_000_000:
                parser.error(f"unsafe archive layout: {filename}")
            with package.extractfile(entries[0]) as stream:
                binary_hash = hashlib.file_digest(stream, "sha256").hexdigest()
            binary_size = entries[0].size
        url = f"https://github.com/{REPOSITORY}/releases/download/v{args.version}/{filename}"
        records.append(f"artifact {target} {filename} {archive.stat().st_size} {sha256(archive)} {binary_size} {binary_hash} {minimum} {name} {url}")
        if archive.resolve() != (args.out / filename).resolve():
            shutil.copy2(archive, args.out / filename)
    manifest = args.out / "release-manifest.txt"
    manifest.write_bytes(("\n".join(records) + "\n").encode())
    with tempfile.TemporaryDirectory(prefix="padlink-sign-") as temporary:
        if args.key_env:
            key_file = Path(temporary) / "release-key.pem"
            value = os.environ.get(args.key_env)
            if not value:
                parser.error("the release signing secret is not configured")
            key_file.write_text(value)
            key_file.chmod(0o600)
        else:
            key_file = args.key_file
        public = subprocess.run(["openssl", "pkey", "-in", str(key_file), "-pubout"], check=True, capture_output=True).stdout
        if public.strip() != (ROOT / "packaging/release-public.pem").read_bytes().strip():
            parser.error("signing key does not match the pinned publisher public key")
        subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_file), "-out", str(args.out / "release-manifest.sig"), str(manifest)], check=True)
    for filename in ("install.sh", "install.ps1", "release-public.pem"):
        shutil.copy2(ROOT / "packaging" / filename, args.out / filename)
    subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(ROOT / "packaging/release-public.pem"), "-signature", str(args.out / "release-manifest.sig"), str(manifest)], check=True)
    print(f"Signed release {args.version} for {len(targets)} targets")


if __name__ == "__main__":
    main()
