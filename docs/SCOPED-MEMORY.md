# Scoped local memory — 0.5.0 (11)

Canonical data lives in ~/Library/Application Support/STIX Agent.

- Memory/profile.md and preferences.md: personal facts and preferences.
- Projects/<stable folder UUID>/: overview.md, decisions.md, tasks.md and project.json.
- Chats/<UUID>/: chat.json metadata, messages.jsonl visible transcript, history.jsonl model transcript, context.json checkpoint, memory.md private notes, Actions/state.json receipts, Attachments/ outputs.
- Chats/index.md and Projects/index.md map readable titles to IDs.
- settings.json contains preferences and Keychain references, never key values.
- store.json lists active objects; state.json is a small format pointer.
- search.sqlite is disposable and rebuilds from canonical messages.
- Backups/Migrations/<UUID>/ retains exact legacy source bytes.

Use /memory to add, edit, pin or remove records in personal, current-project or current-chat scope. A project is an exact canonical working-folder identity. Other projects and private chat notes never enter retrieval. Memory records include source, source-chat ID, timestamps and category. Legacy records retain an explicitly unknown date.

Prompt retrieval uses relevant/core entries within 12 records and 6000 UTF-8 bytes. It is lexical, requires no embedding model and can omit entries outside its budget. Full transcripts and checkpoints remain separate. Pinning is subject to this budget.

For manual Markdown editing, close the app first and preserve record metadata and delimiters. Concurrent external edits stop autosave instead of being overwritten. Invalid documents fail closed. Unknown legacy fields also stop migration; scalar normalization such as UUID casing is accepted by typed decoding. A staged typed roundtrip verifies each generation before publishing. Process locking, transaction hashes and a pending commit journal recover interrupted writes. Simulated interruption is tested; physical power-cut durability was not tested.

## Verified installation

Installed and Developer ID signed locally on 2026-10-19: 0.5.0 (11). No GitHub or remote service used.

Full pre-upgrade backup: dist/memory-upgrade-backup-19057f708d/Data (27 files compared by SHA-256). Independently compared migrated real data: 4 chats, 44 visible messages, 23 model-history records, checkpoints, metadata, settings, job and undo journals all preserved. The original personal-memory array contained zero records. The /memory UI verification subsequently added its command/card to the existing conversation.

212 tests reported, 12 opt-in tests skipped, zero failures. Tests include lowercase UUID regression, unknown fields, source archival, attachment preservation, interrupted commit recovery, symlink rejection, external edit protection, scoped retrieval and disposable SQLite rebuild. Native QA verified project sharing, private-chat isolation and separate projects with synthetic records. Installed app restarted and /memory rendered correctly without the migration alert.
