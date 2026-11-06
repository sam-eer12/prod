"""Build the same Rust core for every packaged Android ABI, with 16 KiB ELF alignment."""
import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
NDK_VERSION = "28.2.13676358"
TARGETS = {
    "arm64-v8a": ("aarch64-linux-android", "aarch64-linux-android"),
    "armeabi-v7a": ("armv7-linux-androideabi", "armv7a-linux-androideabi"),
    "x86": ("i686-linux-android", "i686-linux-android"),
    "x86_64": ("x86_64-linux-android", "x86_64-linux-android"),
}


def sdk_path():
    configured = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if configured:
        return Path(configured)
    properties = ROOT / "android/local.properties"
    if properties.exists():
        for line in properties.read_text().splitlines():
            if line.startswith("sdk.dir="):
                return Path(line.split("=", 1)[1].replace("\\:", ":").replace("\\\\", "\\"))
    raise SystemExit("Set ANDROID_HOME or android/local.properties sdk.dir before building JNI.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--abis", default=",".join(TARGETS))
    parser.add_argument("--sdk", type=Path)
    args = parser.parse_args()
    host = {"Darwin": "darwin-x86_64", "Linux": "linux-x86_64", "Windows": "windows-x86_64"}[platform.system()]
    sdk = args.sdk or sdk_path()
    toolchain = sdk / "ndk" / NDK_VERSION / "toolchains/llvm/prebuilt" / host / "bin"
    if not toolchain.is_dir():
        raise SystemExit(f"Install Android NDK {NDK_VERSION} through SDK Manager.")
    for abi in args.abis.split(","):
        if abi not in TARGETS:
            raise SystemExit(f"Unsupported ABI: {abi}")
        target, compiler_target = TARGETS[abi]
        extension = ".cmd" if platform.system() == "Windows" else ""
        linker = toolchain / f"{compiler_target}28-clang{extension}"
        env = os.environ.copy()
        env["PATH"] = str(toolchain) + os.pathsep + env.get("PATH", "")
        env[f"CARGO_TARGET_{target.upper().replace('-', '_')}_LINKER"] = str(linker)
        env["CARGO_TARGET_DIR"] = str(ROOT / "target/android")
        env["RUSTFLAGS"] = env.get("RUSTFLAGS", "") + " -C link-arg=-Wl,-z,max-page-size=16384"
        subprocess.run(["cargo", "build", "--locked", "--release", "-p", "padlink-android", "--target", target], cwd=ROOT, env=env, check=True)
        source = ROOT / "target/android" / target / "release/libpadlink_core.so"
        destination = args.out / abi / source.name
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists() or destination.read_bytes() != source.read_bytes():
            shutil.copy2(source, destination)


if __name__ == "__main__":
    main()
