# Scoped memory and split storage

Approved scope: personal/project/chat memory, human-readable files, per-chat history and context, derived SQLite search, lossless local migration, signed Mac update. No GitHub or remote services.

Architecture: retain StateStorage's typed interface while persisting settings, chat metadata, JSONL messages/history, checkpoint, per-chat actions and Markdown memory separately. A manifest lists active records; a staged transaction and an exclusive process lock provide crash recovery. Migration archives original state and previous state, verifies the staged roundtrip before publishing, and retains original attachment paths/bytes. Managed legacy attachments are additionally copied into chat folders; new outputs are stored per chat. Search database is rebuildable, never canonical.

Memory records carry UUID, scope, owner, category, source chat, timestamps, order and enable state. Project identity is a stable canonical folder identity, not a parent-path guess. Context selects bounded relevant memory only from global + current project + current chat; summaries and execution receipts never cross chat boundaries. /memory has three scopes and category controls.

Affected files: Core/Storage.swift and Models.swift; new split-store transaction, memory documents/retrieval and SQLite index modules; AppStore persistence/project binding; ChatContext checkpoint commits; KnowledgeTools, ExtendedTools and MemoryCard; artifact/image destination and FileTools allowlist; migration, crash, scope, retrieval, index and UI tests.

- [x] Regression tests for lossless migration, interrupted transaction recovery, corrupt/symlink paths and derived index rebuild.
- [x] Split storage and migration; preserve all source messages/history/checkpoints/jobs/undos/settings and attachment bytes.
- [x] Scoped memory API/retrieval/UI and project binding with source metadata.
- [x] Full tests, backup real store, close old app, migrate/install/restart and inspect real persisted result/native UI.
