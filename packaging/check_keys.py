"""Check that every installer pins the same public release signing key."""
import base64
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent
public = (ROOT / "release-public.pem").read_text().strip()
shell = (ROOT / "install.sh").read_text()
assert public in shell, "Shell installer publisher key differs from the Rust key"
details = subprocess.run(["openssl", "rsa", "-pubin", "-in", str(ROOT / "release-public.pem"), "-text", "-noout"],
                         capture_output=True, text=True, check=True).stdout
modulus_text = details.split("Modulus:")[1].split("Exponent:")[0]
modulus = bytes.fromhex(re.sub(r"[^0-9a-fA-F]", "", modulus_text)).lstrip(b"\0")
exponent = int(re.search(r"Exponent: ([0-9]+)", details)[1])
exponent_bytes = exponent.to_bytes((exponent.bit_length() + 7) // 8, "big")
powershell = (ROOT / "install.ps1").read_text()
for name, value in (("Modulus", modulus), ("Exponent", exponent_bytes)):
    pinned = re.search(rf'\$parameters\.{name} = \[Convert\]::FromBase64String\("([^"]+)"\)', powershell)
    assert pinned and base64.b64decode(pinned[1]) == value, f"PowerShell {name} differs from the Rust key"
print("All installers pin the same publisher public key.")
