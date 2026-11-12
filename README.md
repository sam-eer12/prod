# Brok Bot 🤖✨

> **An open-source, local-first, privacy-respecting clone of Grok Bot.**  
> Powered by Bring-Your-Own-Key (BYOK) AI models, a server-side modular connector marketplace, dual-space context management, hardware-backed vault security, and client-side notifications.

---

## 📖 Architecture & Specifications

The complete design specifications, requirements, and engineering roadmaps are available in the `docs/` directory:

- 📋 [**Product Requirements Document (PRD)**](file:///Users/sameergupta/Downloads/GitHub/prod/docs/PRD.md): Detailed user personas, competitive analysis vs. Grok Bot, dual-space context management, functional requirements, and non-functional specifications.
- 🛠️ [**Implementation Plan & Architecture**](file:///Users/sameergupta/Downloads/GitHub/prod/docs/IMPLEMENTATION_PLAN.md): Technical architecture, dependency stack, Blender socket protocol, Google OAuth PKCE specs, headless "Open at Login" daemon mode, ad-hoc signing strategy, and phased 16-week execution roadmap.

---

## 🌟 Key Highlights

- **Dual-Space Context Management:**
  - **Working Context:** Ephemeral task-specific scratchpad and conversation history.
  - **Permanent Context (Secure Enclave):** Auto-compacting personal memory shielded by hardware encryption. Updateable or pruned in real-time via natural language commands (*"store this in your memory"*, *"update my memory"*, *"forget/delete from your memory"*).
- **Clean Minimal Liquid Glass UI:** Ultra-thin frosted glass materials, specular border gradients, and ambient persona glows across native macOS (SwiftUI) and Android (Jetpack Compose).
- **Silent Background Wakeup ("Open at Login"):** On macOS, launches silently in the background at login without opening the main window, keeping routines, polling, and local notifications active.
- **Compute & Performance Settings:** Configurable multithreading (`1`, `2`, `4` threads) and hardware acceleration toggles (Apple Neural Engine/Metal on Mac, NNAPI/Vulkan on Android).
- **BYOK Multi-Model Engine:** Support for OpenRouter, Google Gemini, Anthropic Claude, OpenAI, and NVIDIA NIM with streaming and tool calling.
- **Server-Side Modular Connector Marketplace:** Install and update connectors (Gmail, Google Calendar, Blender 3D, Notion, Slack, etc.) dynamically via remote JSON manifests without requiring app updates.
- **Hardware-Backed Vault:** Local credential encryption using Touch ID / LocalAuthentication + AES-256-GCM on macOS, and Android Keystore with StrongBox on Android.
- **100% Client-Side Notifications:** Scheduled directly by OS background helpers (`UNUserNotificationCenter` / `NotificationManager`) with zero external push servers.

---

## 🗺️ Implementation Phases

| Phase | Milestone | Key Deliverables |
| :---: | :--- | :--- |
| **Phase 1** | **Core macOS & Context** | SwiftUI Liquid Glass UI, Dual-Space Context, Auto-Compactor, BYOK Multi-Model Engine, Headless Login Daemon, LocalAuth Vault |
| **Phase 2** | **Connectors & Marketplace** | Remote Manifest Catalog, Blender 3D Bridge, Google Workspace PKCE, Interactive Approval Cards |
| **Phase 3** | **Android App & Local Notifs** | Jetpack Compose Haze UI, Android Keystore StrongBox, BootReceiver & WorkManager background poller |
| **Phase 4** | **Decentralized Sync & Polish** | Automerge LAN P2P Sync (Bonjour/mTLS), WhisperKit local voice mode, v1.0 Release |

---

## 📜 License

Licensed under the [Apache 2.0 / MIT License](LICENSE).
