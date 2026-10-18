# Local productivity expansion

Approved scope: global quick capture; local scheduled/folder automations; reusable workflow forms; local PDF/DOCX/text search; isolated code execution; cross-chat result gallery and image recipes; resource policy and inference phases; verified local backup/restore and separate encrypted credentials transfer. Preserve every existing source and keep all processing local. No GitHub or external servers.

Architecture: typed optional feature configuration in split-store transactions; disposable document search index; independent durable automation inbox/cursors with deterministic event IDs; SwiftUI inline feature cards. Scheduled ticks run in a per-user LaunchAgent only after a user enables a rule. Closed app can reopen in the logged-in session; sleeping/logged-out Mac is not woken. Normal execution and approval rules still apply. Restoring uses a verified staged copy and retains the old root for recovery. Keychain secrets are excluded from normal backups and use a separate password-encrypted archive.

- [ ] Tests and compatible feature configuration persistence; no data-loss fallback for missing declared files.
- [ ] Automation schedule/watch detection, deduplication, disable/history, launchd helper and app inbox consumption.
- [ ] Validated workflow definitions, inline parameter forms, deterministic file/image steps and skill-assisted prompts.
- [ ] Incremental local document indexing and bounded cited search, local folder management.
- [ ] Seatbelt-isolated code runs, network/file-denial tests, explicit publication with undo.
- [ ] Gallery derived from real attachments; persisted actual image recipes and repeat/variant actions.
- [ ] Resource policy and actual model request phases; background economy behavior.
- [ ] Verified backup creation, portable referenced files, protected restore, independent encrypted credential transfer.
- [ ] Global hotkey, quick panel, selected-text capture and macOS Services integration.
- [ ] Full regression, signed isolated UI QA, real data backup, signed local install and restart, independent preservation audit, local commit.

Risks/limits: macOS permissions control selection capture. Seatbelt is OS process isolation, not a VM. DOCX has no stable page numbers, so citations identify the document/fragment; PDFs cite real pages. Scheduling is best effort after wake, with at most one catch-up for a daily rule, no wake timer. Runtime/model memory figures are estimates. Arbitrary terminal/API effects cannot be rolled back universally. Background tasks can wait for ordinary approval. Existing chats/memory/receipts remain canonical and are not replaced by indexes.
