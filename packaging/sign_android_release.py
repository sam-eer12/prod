"""Sign and verify an Android release APK using Actions signing settings."""
import argparse
import base64
import binascii
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


def required(name):
    value = os.environ.get(name, "")
    if not value:
        raise SystemExit(f"Missing signing setting: {name}")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-tools", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
        raise SystemExit("A stable semantic version is required.")
    major, minor, patch = map(int, args.version.split("."))
    version_code = major * 1_000_000 + minor * 1_000 + patch
    if minor >= 1000 or patch >= 1000 or not 1 <= version_code <= 2_100_000_000:
        raise SystemExit("Version cannot be represented as an Android versionCode.")
    alias = required("PADLINK_ANDROID_KEY_ALIAS")
    expected = required("PADLINK_ANDROID_CERT_SHA256").replace(":", "").lower()
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise SystemExit("Invalid signing certificate SHA-256 fingerprint.")
    required("PADLINK_ANDROID_STORE_PASSWORD")
    required("PADLINK_ANDROID_KEY_PASSWORD")
    try:
        keystore = base64.b64decode(required("PADLINK_ANDROID_KEYSTORE_BASE64"), validate=True)
    except (ValueError, binascii.Error):
        raise SystemExit("Invalid base64-encoded keystore.") from None
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    tools = args.build_tools or (Path(sdk) / "build-tools/36.0.0" if sdk else None)
    if tools is None or any(not (tools / tool).is_file() for tool in ("apksigner", "zipalign", "aapt")):
        raise SystemExit("Set ANDROID_HOME or --build-tools to Android build tools 36.0.0.")

    metadata = subprocess.run([str(tools / "aapt"), "dump", "badging", str(args.apk)],
                              check=True, capture_output=True, text=True).stdout
    package = re.search(r"^package: name='([^']+)' versionCode='([0-9]+)' versionName='([^']+)'", metadata, re.MULTILINE)
    if package is None or package.groups() != ("com.padlink.controller", str(version_code), args.version):
        raise SystemExit("APK package or version does not match the requested production release.")
    with zipfile.ZipFile(args.apk) as archive:
        abis = {name.split("/")[1] for name in archive.namelist()
                if re.fullmatch(r"lib/[^/]+/libpadlink_core\.so", name)}
    if abis != {"arm64-v8a", "armeabi-v7a", "x86", "x86_64"}:
        raise SystemExit("Release APK must contain the PadLink JNI library for all four Android ABIs.")

    args.out.mkdir(parents=True, exist_ok=True)
    filename = f"padlink-{args.version}-android.apk"
    # Keep the keystore and unverified output private until every check passes.
    with tempfile.TemporaryDirectory(prefix="padlink-android-", dir=os.environ.get("RUNNER_TEMP")) as stage:
        stage = Path(stage)
        keyfile = stage / "padlink.jks"
        keyfile.write_bytes(keystore)
        keyfile.chmod(0o600)
        apk = stage / filename
        subprocess.run([
            str(tools / "apksigner"), "sign", "--ks", str(keyfile), "--ks-key-alias", alias,
            "--ks-pass", "env:PADLINK_ANDROID_STORE_PASSWORD",
            "--key-pass", "env:PADLINK_ANDROID_KEY_PASSWORD", "--out", str(apk), str(args.apk),
        ], check=True)
        verification = subprocess.run([
            str(tools / "apksigner"), "verify", "--verbose", "--print-certs", str(apk),
        ], check=True, capture_output=True, text=True).stdout
        fingerprints = re.findall(r"^Signer #[0-9]+ certificate SHA-256 digest: ([0-9a-fA-F]+)$", verification, re.MULTILINE)
        if [value.lower() for value in fingerprints] != [expected]:
            raise SystemExit("The APK signing certificate does not match the configured certificate.")
        subprocess.run([str(tools / "zipalign"), "-c", "-P", "16", "4", str(apk)], check=True)
        digest = hashlib.sha256(apk.read_bytes()).hexdigest()
        (args.out / filename).write_bytes(apk.read_bytes())
        (args.out / f"{filename}.sha256").write_text(f"{digest}  {filename}\n")
        print(verification, end="")
        print(f"Signed and verified: {filename}")


if __name__ == "__main__":
    main()
