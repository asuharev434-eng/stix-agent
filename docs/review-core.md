# Core integration re-review

Source re-review, 2026-10-18. No application code edited or external operations performed.

## Resolved

- Shell regex bypass: arbitrary shell now requests explicit approval; broader task permission is explained and scoped to working directory.
- Cross-chat corruption: runAgent resolves chat UUID again after model discovery.
- Interrupted known-secret prefixes: raw stream is separate and visible stream holds known credential suffixes before persistence.
- Heavy agent filesystem work: list/read/search/write/move/trash now use detached worker tasks.
- Denied actions: ActionDenied stops the task rather than inviting model retries.

## Open [P1] Persistent shell approvals omit the effective working directory

`Sources/STIXAgent/Tools/ToolExecutor.swift:49-50`, `Sources/STIXAgent/App/AppStore.swift:164-172`

The task permission includes `folder`, but `.always` still hashes only `args`, which do not include the effective working directory. Approving `./deploy.sh` permanently in folder A also permits the same arguments in folder B, executing another script without review. Include the canonical effective directory in the persistent exact approval scope. This is distinct from the intentionally broad, clearly explained task permission.

## Open [P2] MainActor blocking remains for state saves and Undo

`Sources/STIXAgent/App/AppStore.swift:55-58`, `Sources/STIXAgent/Tools/ToolExecutor.swift:202-208`

The filesystem worker fix covers normal tool execution, but state JSON serialization/previous-state copying still run synchronously on MainActor for each save. Undo likewise synchronously hashes/copies directory trees through FileTools.undo. Large history or a large folder undo can freeze the UI and Stop control. Move these operations to a serialized worker and publish results on MainActor.

## Open [P2] Detached file cancellation is not observed by the worker

`Sources/STIXAgent/Tools/ToolExecutor.swift:214-217`

fileWork cancels the detached task, but its closure immediately runs `operation()` without checking cancellation; FileTools recursive traversal also has no cancellation checks. Stop therefore waits for the complete search/hash/copy and can still allow a scheduled mutation to begin after cancellation. Check cancellation before starting the operation and between safe recursive steps; allow an already-started atomic mutation to complete while recording its outcome.

## UI and startup source checks

Composer placeholder and decorative border do not cover the editor; buttons have explicit actions. Pending secret input uses SecureField, clears its state on submit/cancel, and request UUID resets view identity. Chat navigation permits returning to the task containing the prompt. No additional concrete click-blocking or Keychain-entry regression found in source; native UI behavior was not exercised in this review. Installed Comfy launcher binds loopback, disables custom nodes, and enables offline flags; no external deployment path is introduced.

## Final corrections

Shell persistent approvals now include canonical working directory. File workers check cancellation before execution and during directory enumeration/hash chunks. Undo runs in a worker task. Small atomic JSON state saves remain synchronous to retain write ordering and immediate audit records.
