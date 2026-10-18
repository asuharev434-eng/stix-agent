# Native Agent Implementation Plan

> **For agentic workers:** Use subagent-driven-development for independent integration tasks and inline integration for shared app code.

**Goal:** Deliver and install a minimal functional local SwiftUI agent on this Mac.
**Architecture:** SwiftPM executable packaged as a native app. Core codable domain, actor-based integrations, main-actor observable app state, cancellable tool loop and SwiftUI surfaces.
**Tech Stack:** Swift 6 compiler in Swift 5 compatibility mode, SwiftUI, AppKit, Foundation, Security, WebKit. macOS 14+.

## Global Constraints
- No login or settings screen; model picker inside composer lower left.
- Keys only in Keychain and secure request forms; redact outputs before persistence and LLM.
- No mock model/image results; first launch permissions must respect macOS TCC.
- Install locally with no GitHub, deploy or external servers.

### Task 1: Core storage and security
- [x] Create Core/Models.swift, Core/Storage.swift, Core/Secrets.swift and Core/Approval.swift.
- [x] Define JSONValue, Chat, Message, Attachment, ToolCall, PendingInteraction, preferences and API/plugin metadata shared contracts.
- [x] Atomic local persistence, owner-only directories, Keychain, secret redactor and exact-action approval keys.
- [x] Test Codable roundtrips, redaction and approval scoping via swift test.

### Task 2: Local service integrations
- [x] Integrations/LMStudio.swift: list models, streamed completions and tool assembly, error propagation.
- [x] Integrations/ComfyClient.swift: standard SDXL workflow, discovery, submit/progress/download, owned-task cancellation.
- [x] Integrations/MCPClient.swift: JSON-RPC initialize, tool listing/calling, stdio and HTTP transport.
- [x] Tests in Tests/STIXAgentTests for protocol parsing and workflow shape, live endpoint probes.

### Task 3: Tools and agent
- [x] Tools/FileTools.swift and Tools/ProcessRunner.swift implement validated operations, backups and timeout/cancellation.
- [x] Tools/ToolExecutor.swift validates schema arguments, approvals, preferences, HTTP injection and metadata.
- [x] Agent/AgentEngine.swift executes persistent streamed tool loop, questions and secure forms, bounded context and cancellation.
- [x] Test actual temporary-file write/move/undo and command exit/cancel.

### Task 4: SwiftUI application
- [x] App/AppStore.swift controls chats, persistence, integrations and interactions.
- [x] App/STIXAgentApp.swift entrypoint; Views/ChatView.swift, ComposerView.swift, MessageView.swift, InteractionView.swift and ArtifactView.swift.
- [x] Native sidebar, composer model picker, drag/drop, Markdown/code/media/diagram/dashboard display, plugin cards, secure input and permissions onboarding.
- [x] Render and inspect running native app; verify questions and permission responses resume correct task.

### Task 5: Delivery and local setup
- [x] scripts/build-app.sh bundles, signs and installs executable/resources with Info.plist and app icon.
- [x] README documents use, service startup, plugin/API access and limitations.
- [x] swift test and release build, live model tool call, real Comfy image, installed .app launch.
- [x] Review entire source for key leaks, path and subprocess hazards. Keep source and app local; no GitHub or deployment.

## Delivery evidence

See docs/validation.md for tests, native UI findings and local Developer ID signing. No GitHub remote, push or deployment was performed. The .app is installed locally; system privacy grants remain controlled by macOS.
