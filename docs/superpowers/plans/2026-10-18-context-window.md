# Context window and compaction implementation plan

Goal: expose the selected local model's context budget and maintain a durable summary without deleting chat history.
Architecture: conservative token estimates include system instructions, schemas, images and output reserve. A versioned checkpoint references an immutable history prefix by digest. Manual and automatic tool-free local summarization work on bounded chunks; recent complete tool groups and the current request stay verbatim. Execution receipts continue reading the full original history.

Constraints: native SwiftUI; no GitHub, deploy, remote inference, new dependencies or changes to user model assignments. Existing chats decode with no checkpoint. Summary text is conversation data, never system authority. Failed/cancelled/stale compactions do not replace a checkpoint. Unknown context limits are visibly estimates.

- [x] Add token estimates, checkpoint/digest/group planning and regression tests.
- [x] Implement bounded local summarization with atomic checkpoint publication, automatic threshold and /compact; add tests for persistence, failures, cancellation and concurrent history changes. Persistence success requires unlocked Mac.
- [x] Add accessible context ring/popover with reserve breakdown and compact action.
- [ ] Run full regression and a real local compaction smoke test, build/sign/install and inspect native UI when Mac is unlocked.

Affected files: Core/Models.swift, Agent/ContextBudget.swift, new Agent/ContextCompaction.swift and Agent/ChatContext.swift, Agent/AgentEngine.swift, Agent/SlashCommands.swift, Integrations/LMStudio.swift, App/AppStore.swift, Views/ComposerView.swift, new Views/ContextWindowControl.swift and Tests/STIXAgentTests/ContextCompactionTests.swift.

Current evidence: 41 selected logic checks passed; real local summary/continuation passed in 30.034s; release 0.4.3 signed, atomically installed on disk and verified. Two new protected-state success tests and native UI/restart remain blocked by the locked Mac. See docs/CONTEXT-WINDOW.md.
