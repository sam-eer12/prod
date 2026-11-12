# Brok Bot 🤖✨

> **An open-source, local-first, privacy-respecting clone of Grok Bot.**  
> Powered by Bring-Your-Own-Key (BYOK) AI models, a server-side modular connector marketplace, hardware-backed vault security, and client-side notifications.

---

## 📖 Architecture & Specifications

The complete design specifications, requirements, and engineering roadmaps are available in the `docs/` directory:

- 📋 [**Product Requirements Document (PRD)**](file:///Users/sameergupta/Downloads/GitHub/prod/docs/PRD.md): Detailed user personas, competitive analysis vs. Grok Bot, functional requirements, and non-functional specifications.
- 🛠️ [**Implementation Plan & Architecture**](file:///Users/sameergupta/Downloads/GitHub/prod/docs/IMPLEMENTATION_PLAN.md): Technical architecture, dependency stack, Blender socket protocol, Google OAuth PKCE specs, ad-hoc signing strategy, and phased 16-week execution roadmap.

---

## 🌟 Key Highlights

- **Native macOS & Android Apps:** Native Swift/SwiftUI on macOS and Kotlin/Jetpack Compose on Android with a shared **Liquid Glass** aesthetic.
- **BYOK Multi-Model Engine:** Support for OpenRouter, Google Gemini, Anthropic Claude, OpenAI, and NVIDIA NIM with streaming and tool calling.
- **Server-Side Modular Connector Marketplace:** Install and update connectors (Gmail, Google Calendar, Blender 3D, Notion, Slack, etc.) dynamically via remote JSON manifests without requiring app updates.
- **Hardware-Backed Vault:** Local credential encryption using Touch ID / LocalAuthentication + AES-256-GCM on macOS, and Android Keystore with StrongBox on Android.
- **100% Client-Side Notifications:** Scheduled directly by OS background helpers (`UNUserNotificationCenter` / `NotificationManager`) with zero external push servers.
- **Ad-Hoc Signing Support:** Seamless distribution via `codesign -s -` with Homebrew Cask automation.

---

## 🗺️ Implementation Phases

| Phase | Milestone | Key Deliverables |
| :---: | :--- | :--- |
| **Phase 1** | **Core macOS MVP** | SwiftUI Liquid Glass UI, BYOK Multi-Model Engine, LocalAuth Touch ID Vault, Ad-hoc signing |
| **Phase 2** | **Connectors & Marketplace** | Remote Manifest Catalog, Blender 3D Bridge, Google Workspace PKCE, Interactive Approval Cards |
| **Phase 3** | **Android App & Local Notifs** | Jetpack Compose Haze UI, Android Keystore StrongBox, WorkManager background poller |
| **Phase 4** | **Decentralized Sync & Polish** | Automerge LAN P2P Sync (Bonjour/mTLS), WhisperKit local voice mode, v1.0 Release |

---

## 📜 License

Licensed under the [Apache 2.0 / MIT License](LICENSE).
