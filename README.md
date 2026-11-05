# PadLink

PadLink turns an Android phone into a low-latency gamepad for a desktop on the
same local network. This repository is at the **initial project setup** stage:
the Android app builds and runs, and the desktop CLI has its baseline command
surface. Discovery, pairing, controller input, and gamepad backends are not
implemented yet.

The product requirements and engineering plan live in
[PRD.md](PRD.md) and [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md). The
original product prompt is preserved at the top of the PRD.

## What is in this setup

| Area | Status |
| :--- | :--- |
| Android app (native Kotlin) | Buildable debug/release APKs, Material 3 Compose shell, dark controller-inspired theme, settings and build-info screens |
| Android tests | JVM unit tests for the pairing-code shape rules; one Compose launch test (requires a device/emulator) |
| Desktop CLI | Rust 2024 / Cargo workspace, `clap` command surface, honest `not implemented` exits for unfinished commands |
| Shared protocol crate | Version/code-alphabet constants and tests; no PAKE, framing, or replay protection yet |
| Documentation | PRD, implementation plan, controller layout reference, protocol draft |

Android Studio is the build/debug IDE. The installed app runs on Android's ART
runtime; the desktop tool is a separate native Rust binary.

## Repository layout

```text
.
├── android/                        # Standalone Gradle project (open this in Android Studio)
│   ├── app/
│   │   ├── build.gradle.kts
│   │   └── src/
│   │       ├── main/
│   │       │   ├── AndroidManifest.xml
│   │       │   ├── java/com/padlink/controller/
│   │       │   │   ├── PadLinkApplication.kt
│   │       │   │   ├── MainActivity.kt
│   │       │   │   ├── domain/       # Pure Kotlin models and rules
│   │       │   │   └── ui/           # Compose app shell, screens, theme, navigation
│   │       │   └── res/              # Strings, theme, adaptive icon
│   │       ├── test/                 # JVM unit tests
│   │       └── androidTest/          # Instrumented Compose test
│   ├── gradle/
│   │   ├── libs.versions.toml        # Single source of dependency/plugin versions
│   │   └── wrapper/
│   ├── build.gradle.kts
│   ├── settings.gradle.kts
│   └── gradlew
├── desktop/                        # Rust CLI crate (`padlink` binary)
│   ├── Cargo.toml
│   └── src/main.rs
├── protocol/                       # Shared protocol crate + draft specification
│   ├── Cargo.toml
│   ├── SPEC.md
│   └── src/lib.rs
├── docs/references/                # Supplied controller layout reference
├── Cargo.toml                      # Rust workspace root
├── rust-toolchain.toml
├── PRD.md
└── IMPLEMENTATION_PLAN.md
```

## Toolchain

| Tool | Version used by this baseline |
| :--- | :--- |
| Android Gradle Plugin | 9.4.1 (built-in Kotlin enabled) |
| Gradle | 9.6.0 (wrapper) |
| Kotlin / Compose compiler | 2.2.10 (AGP's built-in Kotlin default) |
| Compose BOM | 2025.09.00 |
| Android compile / target SDK | 37 |
| Android min SDK | 28 |
| Java for Gradle | 17+ |
| Rust | stable, edition 2024 (1.85+) |

Versions are pinned in [android/gradle/libs.versions.toml](android/gradle/libs.versions.toml)
and [Cargo.toml](Cargo.toml). Update them together and re-run the builds.

## Build and run the Android app

1. Install Android SDK Platform 37 and Build Tools 36.x through Android Studio's
   SDK Manager.
2. Open the `android/` directory in Android Studio. Do not open the repository
   root; the Gradle project root is `android/`.
3. Let Gradle sync finish, select the `app` run configuration, pick a device or
   emulator running API 28+, and press Run.

Command-line builds:

```sh
cd android
./gradlew :app:assembleDebug
```

The debug APK is written to:

```text
android/app/build/outputs/apk/debug/app-debug.apk
```

Other useful tasks:

```sh
./gradlew :app:testDebugUnitTest     # JVM tests
./gradlew :app:lintDebug             # Android lint
./gradlew :app:assembleRelease       # unsigned release APK
./gradlew :app:compileDebugAndroidTestKotlin
```

Android Studio creates `android/local.properties` with your SDK path. That file
is intentionally ignored by Git. Release signing is not configured yet; the
release task produces an unsigned APK.

### Current app behavior

- Home screen: product scaffold state, connection status card, and settings.
- Settings: app version, build type, package name, and the current controller
  status. Nothing sends gamepad input.
- Debug builds use the application ID `com.padlink.controller.debug` so they can
  coexist with a release install later.

## Build and run the CLI

```sh
cargo build --workspace
cargo run -p padlink-cli -- --help
cargo run -p padlink-cli -- status
cargo run -p padlink-cli -- status --json
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

`status` reports the scaffold state and protocol revision. Commands such as
`scan`, `connect`, `disconnect`, `doctor`, `daemon`, and `autostart` parse their
arguments but exit with status `2` and an explicit "not implemented" message.
They do not print success or fake session data.

## Continuous integration

[.github/workflows/ci.yml](.github/workflows/ci.yml) runs on pushes to `main`,
pull requests targeting `main`, and manual runs from GitHub's Actions tab.

- **Rust:** formatting on Linux, plus Clippy and workspace/documentation tests
  on Linux, macOS, and Windows. Dependency resolution uses `Cargo.lock`.
- **Android:** Java 17, the checked-in Gradle wrapper, Android SDK 37, unit
  tests, lint, debug and unsigned release builds, and instrumentation-test
  compilation.
- **Android emulator:** executes the Compose launch test on an API 35 emulator.
  This is a UI smoke test; Wi-Fi, Bluetooth, touch latency, and gamepad backend
  compatibility still require the physical-device tests in the plan.

The pipeline uploads test/lint reports and the debug APK as seven-day workflow
artifacts. It uses read-only repository permissions, dependency caches, pinned
action revisions, and cancels superseded runs. It does not publish releases or
require release-signing secrets.

## Scope note

This scaffold deliberately contains **no pairing or cryptography fallback**.
Do not use this build to transmit real input. The next milestones from the
implementation plan are:

1. Protocol/session core and native binding boundary.
2. Android LAN permissions, discovery, consent, and six-character PAKE pairing.
3. Custom multi-touch controller View/Canvas and the Compose layout editor.

See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for the full P0/P1 gates and
acceptance criteria.
