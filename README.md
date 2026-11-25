<p align="center">
  <img src="assets/logo-256.png" width="128" alt="Brok Bot Logo" />
</p>

<h1 align="center">Brok Bot</h1>

<p align="center">
  <strong>An open-source, local-first, privacy-respecting clone of Grok Bot.</strong><br />
  Powered by Bring-Your-Own-Key (BYOK) AI models, a server-side modular connector marketplace, dual-space context management, hardware-backed vault security, and client-side notifications.
</p>

---

## 📖 Architecture & Specifications

The complete design specifications, requirements, and engineering roadmaps live in [`docs/`](docs/):

- 📋 [**Product Requirements Document (PRD)**](docs/PRD.md): User personas, competitive positioning vs. Grok Bot, dual-space context management, functional requirements, and non-functional targets.
- 🛠️ [**Implementation Plan & Architecture (v1.3.0)**](docs/IMPLEMENTATION_PLAN.md): Monorepo layout, dependency stack, macOS `NSVisualEffectView` & Android `haze` 1.3.1 Liquid Glass patterns, headless `SMAppService` daemon architecture, and the 5-phase execution roadmap.
- 🎨 [**Brand Assets Guide**](assets/README.md): Untouched original brand logo assets (`logo.jpg` and PNG exports), platform icon exports for macOS (`.icns`) and Android launcher densities + notification drawable, and the 17-icon Liquid Glass SVG vector suite in [`assets/icons/svg/`](assets/icons/svg/).

---

## 🌟 Key Highlights

- **Dual-Space Context Management:**
  - **Working Context:** Ephemeral task-specific scratchpad and sliding-window conversation history.
  - **Permanent Context (Secure Enclave):** Auto-compacting personal memory shielded by hardware encryption, managed directly via natural language commands (*"store this in your memory"*, *"update my memory"*, *"forget/delete from your memory"*).
- **Clean Minimal Liquid Glass UI & Vector Iconography:** Ultra-thin frosted glass materials, specular border gradients, and ambient persona glows across native macOS (SwiftUI + `NSVisualEffectView`) and Android (Jetpack Compose + `haze`), paired with a 17-icon Liquid Glass SVG vector suite in [`assets/icons/svg/`](assets/icons/svg/) (cataloged in [`assets/README.md`](assets/README.md)) and an Android monochrome status-bar vector ([`ic_brok_notification.xml`](android/app/src/main/res/drawable/ic_brok_notification.xml)) alongside the untouched original brand logo assets.
- **Silent Background Wakeup ("Open at Login"):** Launches silently in the background on macOS (`--background` via `SMAppService`) and Android (`BOOT_COMPLETED` + `WorkManager`), keeping routines, polling, and local notifications active without opening the main window.
- **Compute & Performance Settings:** Configurable worker thread pool (`1`, `2`, `4`, or `Auto`) and hardware acceleration toggles (Apple Neural Engine / Metal on macOS, NNAPI / Vulkan on Android).
- **BYOK Multi-Model Engine:** Unified streaming and tool-calling support for OpenRouter, Google Gemini, Anthropic Claude, OpenAI, and NVIDIA NIM.
- **Server-Side Modular Connector Marketplace:** Dynamically discover and install connectors (Blender 3D, Google Workspace, Streamable HTTP & Stdio MCP servers) via signed remote JSON manifests ([`marketplace/catalog.json`](marketplace/catalog.json)).
- **Hardware-Backed Vault & Client-Side Push:** Local encryption via Touch ID / `LocalAuthentication` + AES-256-GCM on macOS and Android Keystore StrongBox + Tink on Android, paired with 100% client-side OS notifications (`UNUserNotificationCenter` / `NotificationManager`).

---

## 📁 Repository Structure

```text
.
├── assets/        # Untouched brand logo assets, macOS AppIcon.icns, Android mipmaps, and 17-icon SVG suite (icons/svg/)
├── docs/          # Product Requirements Document (PRD.md) & Implementation Plan (IMPLEMENTATION_PLAN.md)
├── macos/         # Swift 6 SwiftPM package (BrokBotCore, BrokBotApp, BrokBotCoreTests)
├── android/       # Kotlin 2.2 / Jetpack Compose Gradle project (Min SDK 28, Target 35)
├── marketplace/   # JSON Schema Draft 2020-12 & starter connector catalog/manifests
├── scripts/       # Release & ad-hoc macOS .app bundle signing scripts (build-macos.sh)
├── LICENSE        # Apache License 2.0
└── README.md
```

---

## 🚀 Quick Start

### macOS (Swift 6 / macOS 14.0+)

Run the core unit tests and build the SwiftPM package:

```bash
cd macos && swift test && swift build
```

Assemble and ad-hoc sign `macos/dist/BrokBot.app`:

```bash
bash scripts/build-macos.sh
codesign --verify --deep --strict macos/dist/BrokBot.app
```

### Android (Kotlin / Jetpack Compose, Min SDK 28)

> **Prerequisite:** Android Gradle builds require **JDK 17** (Gradle 8.14.6 is incompatible with JDK 25+) and an Android SDK configured via `ANDROID_HOME`.

```bash
cd android && JAVA_HOME=/path/to/jdk-17 ./gradlew testDebugUnitTest assembleDebug
```

If JDK 17 is already your active `JAVA_HOME`:

```bash
cd android && ./gradlew testDebugUnitTest assembleDebug
```

---

## 🗺️ Implementation Phases

| Phase | Milestone | Key Deliverables |
| :---: | :--- | :--- |
| **Phase 0** | **Foundation, Branding & Setup** *(Completed)* | Brand assets & icons (`assets/`), `.gitignore`, `LICENSE`, `marketplace/` Draft 2020-12 schema & starter catalog, macOS SwiftPM & Android Compose `haze` shells, automated build/test baseline |
| **Phase 1** | **Core macOS Client & BYOK Engine** *(Completed)* | Liquid Glass multi-bot workspace (`PersonaEditorSheet`, `ConversationThread`), `BrokVaultManager` (Touch ID + HKDF + AES-256-GCM `vault.enc`), Dual-Space Context (`DualSpacePromptAssembler`, `SemanticCompactor` & Memory Inspector), 5-provider `BYOKModelClient` SSE streaming, `GlobalHotkeyManager` (`Cmd+Shift+B`), `MenuBarPopoverView`, `UNUserNotificationCenter`, and 17-icon SVG suite (`assets/icons/svg/`) + `ic_brok_notification.xml` |
| **Phase 2** | **MCP Client, Modular Marketplace & Bridges** *(Completed)* | `MarketplaceRegistry` + CryptoKit Ed25519 signature verification + Dynamic Setup UI, Streamable HTTP & Local Stdio MCP clients (`OAuth 2.1 PKCE` / DCR / vaulted Bearer tokens), hosted presets (**Gmail, Google Drive, Docs, Slides, Sheets & Calendar Personal Mode**, **Stripe**, **Vercel**, **Railway**, **Cloudflare**, **Netlify**, **Render**, **Supabase**, **Neon**, **GitHub**, **Sentry**, **PostHog**, **Linear**, **Notion**, **Atlassian**, **Slack**, **Figma**), Blender 3D TCP JSON-RPC bridge (`127.0.0.1:9876`) + addon + inline PNG previews, unified Write Approval Gate & MCP Elicitation UI, and GitHub Actions CI |
| **Phase 3** | **Native Android App & Post-Beta Google Sign-In** *(Next)* | Adaptive Compose Liquid Glass UI (`haze` 1.3.1), Android Keystore StrongBox + Tink vault & context parity, BYOK + Android OAuth flow & Remote MCP parity, silent `BootReceiver` + `WorkManager` + `AlarmManager` + actionable notifications, Coroutines pool & NNAPI/Vulkan accel, production Google OAuth client verification |
| **Phase 4** | **Decentralized Sync, Voice & v1.0 Release** | Automerge CRDT E2EE state convergence, Bonjour/NSD mDNS + mTLS WebSockets + QR pairing, WhisperKit + CoreML/ANE (`Cmd+D`) & Android on-device voice, security audit & NFR profiling, ad-hoc Universal `.dmg`/`.zip`, Homebrew Cask, Universal `.apk` & F-Droid |

---

## 📜 License

Licensed under the [Apache 2.0 / MIT License](LICENSE).
