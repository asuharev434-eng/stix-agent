# Liquid Agent Implementation Plan

**Goal:** Liquid labels and a normal working import of mobile0.2.
**Architecture:** Shared display mapping, preserved IDs, existing LocalModelLibrary.
**Execution:** Inline in an isolated checkout based on the current Agent source.

- [x] Baseline Swift tests; backup installed app/settings.
- [x] Failing tests for display mapping, stable IDs and shard rejection.
- [x] Implement shared labels and reject incomplete GGUF imports.
- [x] Full Swift tests, release build and same-certificate installation.
- [x] Standard LocalModelLibrary import, real GUI answers and relaunch persistence.
- [ ] Push source/validation to GitHub and attach PR.
