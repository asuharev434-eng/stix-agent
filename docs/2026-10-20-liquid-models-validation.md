# Liquid model integration — 2026-10-20

Follow-up: ordinary Agent mode is now supported by the compact-context change.
See [the tool-mode validation](2026-10-20-liquid-agent-tools.md). The observations
below describe the preceding 0.9.9 integration, before that fix.

Installed macOS STIX Agent 0.9.9 (30) displays pre-1.0 STIX text models as
`STIX Liquid <version>-self/other`, including mobile variants. Stable model IDs,
raw GGUF names, hashes and historical messages remain unchanged. The iOS local
model picker uses the same naming helper.

## Ordinary local model

Imported the full existing `STIX-Ai-0.2-mobile-other-Q4_K_M.gguf` using
`LocalModelLibrary.importFile`, the same importer called by the normal menu.
The opt-in installed import test selected it through typed StateStorage while
Agent was closed. GUI file-picker attempts did not complete; the import itself
was performed through this native test harness. No separate API/server was added.

- Display: `STIX Liquid 0.2-mobile-other · импортирована`.
- ID: `builtin-text:imported-24c4b1a61061c97e`.
- Size: 2,497,280,672 bytes; Qwen3-4B Q4_K_M, external weights unchanged.
- SHA-256: `24c4b1a61061c97e1119b8c9525da493dfdf962c0bfc2cf2ed85193138a7668c`.
- Advertised context: 4,096 tokens.

The previous broken entry was only the first GGUF shard (1,794,859,584 bytes,
SHA prefix `182818670209e4bd`). It was backed up locally, then removed only after
the full model was installed and no saved chat, role or default referenced it.
New imports reject `split.count > 1` and roll back without changing the manifest.
The installed app, settings, chats and old partial payload were backed up locally;
private app data and weight payloads are excluded from this source change.

## Runtime acceptance

Observed in the installed native GUI, with completed tasks:

1. In the standard **Чистый чат** mode, asked:
   `У меня 2 яблока, у тебя 3 яблока. Сколько всего у нас яблок? Ответь только числом.`
   Final answer: **5**.
2. Quit Agent and reopened it. The selected Liquid model and answer **5** persisted.
3. Asked in that reopened chat: `Вычти 8 из 27. Ответь только числом.`
   A fresh generation completed with final answer **19**.

**Limitation:** the full Agent system instructions and tools exceed this mobile
build's 4,096-token context. A normal agent-mode prompt was safely rejected by
ContextBudget before inference. Use **Чистый чат** (Command–Option–N) for this
build. Full tool-agent mode has not been made compatible or claimed as passing.
These two arithmetic checks are integration checks, not a general quality benchmark.
Thinking was off for both checks. No physical iPhone runtime test was performed.

## Verification

- Baseline: 301 tests, 28 skipped, zero failures.
- Final Swift suite: 305 tests, 28 skipped, zero failures (23.125 seconds).
- Real full-GGUF import/hash/dedup/restart test: passed (4.374 seconds).
- Explicit installed library import/select/repair test: passed (2.167 seconds).
- macOS release build: passed.
- iOS generic-device build with CODE_SIGNING_ALLOWED=NO: passed. Existing llama
  framework is device-only, so simulator build is not supported by that artifact.
- Installed macOS app retained its existing helpers, bundled resources, signing
  identity and entitlements. Strict deep code-signature verification passed.

Local evidence logs are under `STIX Ai/artifacts/liquid-agent/` (ignored), including
`final-tests.log`, `installed-import.log` and `ios-device-build.log`.
