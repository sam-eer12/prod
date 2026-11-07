"""Validate an Android keystore and upload signing settings to GitHub Actions."""
import argparse
import base64
import getpass
import os
from pathlib import Path
import re
import subprocess


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, **kwargs)
    if result.returncode:
        raise SystemExit(f"{command[0]} failed: {result.stderr.decode().strip()}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keystore", type=Path, required=True)
    parser.add_argument("--repo", default="sam-eer12/prod")
    parser.add_argument("--alias", default="padlink")
    args = parser.parse_args()
    keystore = args.keystore.read_bytes()
    encoded = base64.b64encode(keystore)
    if len(encoded) > 48 * 1024:
        raise SystemExit("The encoded keystore exceeds GitHub's 48 KiB secret limit.")

    store_password = getpass.getpass("Keystore password: ")
    key_password = getpass.getpass("Key password (Enter to use keystore password): ") or store_password
    if not store_password:
        raise SystemExit("A keystore password is required.")
    environment = os.environ | {
        "PADLINK_ANDROID_STORE_PASSWORD": store_password,
        "PADLINK_ANDROID_KEY_PASSWORD": key_password,
    }
    keytool = ["keytool", "-keystore", str(args.keystore), "-alias", args.alias,
               "-storepass:env", "PADLINK_ANDROID_STORE_PASSWORD"]
    # A CSR proves that the key password unlocks the private key; discard the CSR.
    run([*keytool, "-certreq", "-keypass:env", "PADLINK_ANDROID_KEY_PASSWORD"], env=environment)
    certificate = run([*keytool, "-exportcert"], env=environment)
    fingerprint = run(["openssl", "x509", "-inform", "DER", "-noout", "-fingerprint", "-sha256"], input=certificate)
    fingerprint = fingerprint.decode().strip().split("=", 1)[1].replace(":", "").lower()
    if not re.fullmatch(r"[0-9a-f]{64}", fingerprint):
        raise SystemExit("Could not read the certificate's SHA-256 fingerprint.")

    settings = {
        "PADLINK_ANDROID_KEYSTORE_BASE64": encoded,
        "PADLINK_ANDROID_STORE_PASSWORD": store_password.encode(),
        "PADLINK_ANDROID_KEY_PASSWORD": key_password.encode(),
    }
    for name, value in settings.items():
        run(["gh", "secret", "set", name, "--repo", args.repo], input=value)
        print(f"Configured secret: {name}", flush=True)
    for name, value in {
        "PADLINK_ANDROID_KEY_ALIAS": args.alias,
        "PADLINK_ANDROID_CERT_SHA256": fingerprint,
    }.items():
        run(["gh", "variable", "set", name, "--repo", args.repo, "--body", value])
        print(f"Configured variable: {name}", flush=True)


if __name__ == "__main__":
    main()
