# Brok Bot Brand Assets

Canonical brand imagery and platform-specific icon exports for **Brok Bot** across documentation, macOS, and Android.

<img src="logo-256.png" width="128" height="128" alt="Brok Bot Logo" />

---

## Directory Layout

```text
assets/
├── README.md
├── logo.jpg
├── logo.png
├── logo-512.png
├── logo-256.png
└── icons/
    ├── macos/
    │   ├── AppIcon.icns
    │   └── AppIcon.iconset/
    │       ├── icon_16x16.png
    │       ├── icon_16x16@2x.png
    │       ├── icon_32x32.png
    │       ├── icon_32x32@2x.png
    │       ├── icon_128x128.png
    │       ├── icon_128x128@2x.png
    │       ├── icon_256x256.png
    │       ├── icon_256x256@2x.png
    │       ├── icon_512x512.png
    │       └── icon_512x512@2x.png
    └── android/
        ├── drawable/
        │   └── brok_logo.png
        ├── mipmap-mdpi/
        │   └── ic_launcher.png
        ├── mipmap-hdpi/
        │   └── ic_launcher.png
        ├── mipmap-xhdpi/
        │   └── ic_launcher.png
        ├── mipmap-xxhdpi/
        │   └── ic_launcher.png
        └── mipmap-xxxhdpi/
            └── ic_launcher.png
    └── svg/
        ├── brok-mark.svg
        ├── brok-menubar-template.svg
        ├── chief-of-staff.svg
        ├── specialist-bot.svg
        ├── working-context.svg
        ├── permanent-memory.svg
        ├── vault-enclave.svg
        ├── auto-compactor.svg
        ├── byok-model.svg
        ├── compute-accel.svg
        ├── headless-daemon.svg
        ├── marketplace.svg
        ├── blender-bridge.svg
        ├── google-workspace.svg
        ├── approval-gate.svg
        ├── sync-p2p.svg
        └── voice-mode.svg
```

---

## Core Brand Logos

| File | Format | Dimensions | Platform / Usage |
| :--- | :--- | :---: | :--- |
| [logo.jpg](logo.jpg) | JPEG | 1024 × 1024 | Canonical master source asset used to derive all PNG and icon exports. |
| [logo.png](logo.png) | PNG | 1024 × 1024 | Lossless full-resolution PNG master for distribution, marketing, and high-DPI rendering. |
| [logo-512.png](logo-512.png) | PNG | 512 × 512 | High-DPI in-app header/sidebar artwork (e.g., macOS app bundle `Resources/logo.png`) and marketplace cards. |
| [logo-256.png](logo-256.png) | PNG | 256 × 256 | Repository documentation (`README.md`), lightweight web previews, and compact UI badges. |

---

## macOS Application Icons

Compiled icon bundle and source iconset under [icons/macos/](icons/macos/):

- **Compiled Bundle Icon:** [icons/macos/AppIcon.icns](icons/macos/AppIcon.icns) — packaged into `BrokBot.app/Contents/Resources/AppIcon.icns` (`CFBundleIconFile`).
- **Source Iconset:** [icons/macos/AppIcon.iconset/](icons/macos/AppIcon.iconset/) — all 10 standard macOS AppIcon resolutions:

| File | Point Size | Scale | Pixel Dimensions |
| :--- | :---: | :---: | :---: |
| [icon_16x16.png](icons/macos/AppIcon.iconset/icon_16x16.png) | 16 × 16 | 1x | 16 × 16 |
| [icon_16x16@2x.png](icons/macos/AppIcon.iconset/icon_16x16@2x.png) | 16 × 16 | 2x | 32 × 32 |
| [icon_32x32.png](icons/macos/AppIcon.iconset/icon_32x32.png) | 32 × 32 | 1x | 32 × 32 |
| [icon_32x32@2x.png](icons/macos/AppIcon.iconset/icon_32x32@2x.png) | 32 × 32 | 2x | 64 × 64 |
| [icon_128x128.png](icons/macos/AppIcon.iconset/icon_128x128.png) | 128 × 128 | 1x | 128 × 128 |
| [icon_128x128@2x.png](icons/macos/AppIcon.iconset/icon_128x128@2x.png) | 128 × 128 | 2x | 256 × 256 |
| [icon_256x256.png](icons/macos/AppIcon.iconset/icon_256x256.png) | 256 × 256 | 1x | 256 × 256 |
| [icon_256x256@2x.png](icons/macos/AppIcon.iconset/icon_256x256@2x.png) | 256 × 256 | 2x | 512 × 512 |
| [icon_512x512.png](icons/macos/AppIcon.iconset/icon_512x512.png) | 512 × 512 | 1x | 512 × 512 |
| [icon_512x512@2x.png](icons/macos/AppIcon.iconset/icon_512x512@2x.png) | 512 × 512 | 2x | 1024 × 1024 |

---

## Android Launcher & Drawable Assets

Android density buckets and in-app drawable exports under [icons/android/](icons/android/), matching `android/app/src/main/res/`:

| File | Resource Bucket | Density | Pixel Dimensions | Usage |
| :--- | :--- | :---: | :---: | :--- |
| [mipmap-mdpi/ic_launcher.png](icons/android/mipmap-mdpi/ic_launcher.png) | `mipmap-mdpi` | ~160 dpi (1x) | 48 × 48 | Standard-density Android launcher icon |
| [mipmap-hdpi/ic_launcher.png](icons/android/mipmap-hdpi/ic_launcher.png) | `mipmap-hdpi` | ~240 dpi (1.5x) | 72 × 72 | High-density Android launcher icon |
| [mipmap-xhdpi/ic_launcher.png](icons/android/mipmap-xhdpi/ic_launcher.png) | `mipmap-xhdpi` | ~320 dpi (2x) | 96 × 96 | Extra-high-density Android launcher icon |
| [mipmap-xxhdpi/ic_launcher.png](icons/android/mipmap-xxhdpi/ic_launcher.png) | `mipmap-xxhdpi` | ~480 dpi (3x) | 144 × 144 | Extra-extra-high-density Android launcher icon |
| [mipmap-xxxhdpi/ic_launcher.png](icons/android/mipmap-xxxhdpi/ic_launcher.png) | `mipmap-xxxhdpi` | ~640 dpi (4x) | 192 × 192 | Extra-extra-extra-high-density Android launcher icon |
| [drawable/brok_logo.png](icons/android/drawable/brok_logo.png) | `drawable` | nodpi / master | 512 × 512 | Jetpack Compose UI (`R.drawable.brok_logo`) |
| [ic_brok_notification.xml](../android/app/src/main/res/drawable/ic_brok_notification.xml) | `drawable` | `24dp` vector | `24 × 24` viewport | Monochrome `#FFFFFF` Android status-bar notification silhouette matching `brok-menubar-template.svg` |

---

## SVG Vector Icon Suite (`icons/svg/`)

Minimalist **Liquid Glass** vector icon suite under [icons/svg/](icons/svg/) built as valid standalone SVGs (`xmlns="http://www.w3.org/2000/svg"`, `stroke-width="1.75"`, `stroke-linecap="round"`, `stroke-linejoin="round"`). All 15 UI/feature icons and the menu bar template use `viewBox="0 0 24 24"` with `currentColor` for seamless adaptive light/dark tinting, while `brok-mark.svg` provides a full-color `128 × 128` vector companion mark.

> **Master Raster Preservation:** The canonical raster master files ([logo.jpg](logo.jpg), [logo.png](logo.png), [logo-512.png](logo-512.png), [logo-256.png](logo-256.png)) and all derived macOS/Android PNG/ICNS assets remain untouched; `brok-mark.svg` is strictly a vector companion asset.

| File | ViewBox | Coloring | Purpose / Surface |
| :--- | :---: | :--- | :--- |
| [brok-mark.svg](icons/svg/brok-mark.svg) | `0 0 128 128` | Full-color palette (`#0D0E12`, `#D4AF37`, `#00E5FF`) | Companion vector mark inspired by Brok Bot's bowler hat, oval eyes, golden monocle & chain, and handlebar mustache on a Liquid Glass squircle badge |
| [brok-menubar-template.svg](icons/svg/brok-menubar-template.svg) | `0 0 24 24` | Monochrome `currentColor` | macOS Menu Bar template icon & notification badge silhouette (paired with `ic_brok_notification.xml`) |
| [chief-of-staff.svg](icons/svg/chief-of-staff.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Primary Chief of Staff AI orchestrator persona |
| [specialist-bot.svg](icons/svg/specialist-bot.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Specialist sub-agent persona & delegated worker thread |
| [working-context.svg](icons/svg/working-context.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Ephemeral Working Context scratchpad & active prompt turns |
| [permanent-memory.svg](icons/svg/permanent-memory.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Long-term Permanent Memory personal knowledge space |
| [vault-enclave.svg](icons/svg/vault-enclave.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Hardware-backed Secure Enclave / AES-256-GCM biometric vault |
| [auto-compactor.svg](icons/svg/auto-compactor.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Semantic Auto-Compactor & memory deduplication engine |
| [byok-model.svg](icons/svg/byok-model.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Bring Your Own Key (BYOK) multi-provider LLM configuration |
| [compute-accel.svg](icons/svg/compute-accel.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Multithreading (`1`/`2`/`4`) & hardware acceleration (ANE/Metal/NNAPI) |
| [headless-daemon.svg](icons/svg/headless-daemon.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Silent "Open at Login" background daemon & WorkManager worker |
| [marketplace.svg](icons/svg/marketplace.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Modular server-side Connector Marketplace & manifests |
| [blender-bridge.svg](icons/svg/blender-bridge.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Blender 3D local socket bridge (`127.0.0.1:9876` / `bpy`) |
| [google-workspace.svg](icons/svg/google-workspace.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Google Workspace connector (Gmail & Calendar API) |
| [approval-gate.svg](icons/svg/approval-gate.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Explicit user approval gate & action confirmation sheet |
| [sync-p2p.svg](icons/svg/sync-p2p.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | P2P LAN & E2EE Automerge CRDT device synchronization |
| [voice-mode.svg](icons/svg/voice-mode.svg) | `0 0 24 24` | `currentColor` (`1.75` stroke) | Local/cloud hybrid voice mode & speech dictation |

---

## Regenerating Derived Assets (macOS Native Tools)

All PNG exports and the macOS `.icns` bundle are generated directly from `assets/logo.jpg` using macOS built-in `/usr/bin/sips` and `/usr/bin/iconutil` (no external dependencies required):

```bash
# Root PNG masters
sips -s format png assets/logo.jpg --out assets/logo.png
sips -s format png -z 512 512 assets/logo.jpg --out assets/logo-512.png
sips -s format png -z 256 256 assets/logo.jpg --out assets/logo-256.png

# macOS iconset + .icns
sips -s format png -z 16 16     assets/logo.jpg --out assets/icons/macos/AppIcon.iconset/icon_16x16.png
sips -s format png -z 32 32     assets/logo.jpg --out assets/icons/macos/AppIcon.iconset/icon_16x16@2x.png
sips -s format png -z 32 32     assets/logo.jpg --out assets/icons/macos/AppIcon.iconset/icon_32x32.png
sips -s format png -z 64 64     assets/logo.jpg --out assets/icons/macos/AppIcon.iconset/icon_32x32@2x.png
sips -s format png -z 128 128   assets/logo.jpg --out assets/icons/macos/AppIcon.iconset/icon_128x128.png
sips -s format png -z 256 256   assets/logo.jpg --out assets/icons/macos/AppIcon.iconset/icon_128x128@2x.png
sips -s format png -z 256 256   assets/logo.jpg --out assets/icons/macos/AppIcon.iconset/icon_256x256.png
sips -s format png -z 512 512   assets/logo.jpg --out assets/icons/macos/AppIcon.iconset/icon_256x256@2x.png
sips -s format png -z 512 512   assets/logo.jpg --out assets/icons/macos/AppIcon.iconset/icon_512x512.png
sips -s format png -z 1024 1024 assets/logo.jpg --out assets/icons/macos/AppIcon.iconset/icon_512x512@2x.png
iconutil -c icns assets/icons/macos/AppIcon.iconset -o assets/icons/macos/AppIcon.icns

# Android mipmap & drawable PNGs
sips -s format png -z 48 48   assets/logo.jpg --out assets/icons/android/mipmap-mdpi/ic_launcher.png
sips -s format png -z 72 72   assets/logo.jpg --out assets/icons/android/mipmap-hdpi/ic_launcher.png
sips -s format png -z 96 96   assets/logo.jpg --out assets/icons/android/mipmap-xhdpi/ic_launcher.png
sips -s format png -z 144 144 assets/logo.jpg --out assets/icons/android/mipmap-xxhdpi/ic_launcher.png
sips -s format png -z 192 192 assets/logo.jpg --out assets/icons/android/mipmap-xxxhdpi/ic_launcher.png
sips -s format png -z 512 512 assets/logo.jpg --out assets/icons/android/drawable/brok_logo.png
```
