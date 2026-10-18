# Reliability and transparency implementation plan

Goal: deliver the eight user-approved improvements in the local signed macOS application without losing chats or memory.
Architecture: extend existing split-store transactions, file plans, task receipts and specialist delegation. Keep transcript and memory source files canonical; optional fields preserve backward compatibility. No external dependencies, GitHub or external services.

- [x] Memory revisions: add typed before/after records to split transaction, scoped history/restore UI and tools; test restore and isolation after reload. Files: Core/{Models,SplitStore}, Agent/MemorySystem, Views/MemoryCard.
- [x] Recovery: read-only file receipt checks and interrupted-action report before continuation, preserve image-submission ambiguity, block blind replay; test changed/missing files and restored pending tasks. Files: Agent/{TaskQueue,TaskRecovery}, Tools/ResultVerifier, Views/TaskProgressView.
- [x] Result verification: automatic file digest and generated-image integrity checks, safe syntax verification tool, record verification evidence; test real temporary files and invalid code/image. Files: Tools/{ToolExecutor,ExtendedTools,ResultVerifier}, Agent/AgentEngine.
- [x] Controls and plans: exact stop/pause/skip chat controls, durable skipped next action, native file-plan preview and direct explicit apply with undo; test no mutation before apply and conflict safety. Files: Agent/{QueueControl,AgentEngine}, Tools/FileChangePlan, Views/FilePlanCard.
- [x] Context: capture the actual redacted request, separated instructions/memory/tools/summary/history, inspect in popover; tests prove fitted history and image data handling. Files: Agent/ChatContext, Views/ContextWindowControl.
- [x] Routing: capability/parameter estimate and Mac RAM-aware automatic assignments, explicit configured overrides and visible routing reason; tests vision mismatch and heavy model avoidance. Files: Agent/ModelOrchestrator.
- [x] Doctor: /doctor alias, free-disk report, actionable service/permissions checks; test low disk and loopback restrictions. Files: Agent/{Diagnostics,KnowledgeTools,SlashCommands}.
- [x] Regression, signed isolated native QA, full real-data backup, signed install and restart, independent source preservation audit; document exact results and local commit only.

Risks: filesystem operations cannot be made universally idempotent, external commands cannot be universally rolled back, available memory is an estimate. Unknown execution results are reported rather than replayed. Human file-plan apply is an explicit authorization; terminal/network permissions continue through the existing executor. Revisions never cross scope and deleted memory remains recoverable locally until explicit history removal is separately designed.
