# Liquid mobile 0.2 in ordinary Agent mode

The previous integration could run this GGUF only in clean chat: its advertised
4,096-token window could not fit the full Agent system prompt and tool palette.
This change keeps ordinary agent execution enabled and adapts its request context.

## Implementation

- Native text models with a known 1K–8K window receive a compact Russian system
  prompt. It retains the working directory, question policy, result verification,
  tool discovery, untrusted-data rules, protected secret entry and host permissions.
  Catalogs of models, connections, plugins and skills are fetched when needed.
- Relevant memory uses the existing scoped retrieval with a 512-byte budget
  (including record overhead). Whole records are selected; durable memory is not
  truncated, deleted or moved across scopes. Larger records remain available via
  memory tools. Large-window models keep their existing prompt and memory budget.
- Native tools are selected by request and discovery, with exact tool names first.
  Each complete schema must fit alongside discovery and the existing minimum
  history allowance. Schemas are not abbreviated; host executors, validation,
  approvals, receipts and rollback behavior are unchanged.
- Small-window output uses the same reserve as ContextWindow: 819 tokens at 4K,
  rather than asking the native engine for its default 2,048 after budgeting 819.
  Existing history fitting/compaction and full saved history remain in place.
- Small native windows also use a proportional summary limit (768 characters and
  at most 768 estimated tokens at 4K), with a 256-token generation limit. The
  validated summary token bound is reserved once instead of doubling a character
  bound. This leaves room for source chunks and the previous summary. Failure
  still preserves the previous checkpoint and full raw transcript.
- Clean mode still omits the system prompt and tools. No server, context-window
  inflation, model-ID change, new weights or retraining is involved.

## Verification

The new regression first failed against the previous implementation with the
context-too-small error. It now verifies ordinary 4K question/file requests,
the next round after a tool result, output-reserve alignment, complete schemas,
discovery under a large exposed-tool set, memory scope isolation and clean mode.

Final full Swift suite: **312 tests, 29 skipped, zero failures** (19.721 seconds).
The native integration test is opt-in and was run separately, successfully, in
the seven-test compact-context suite. The native test:

1. Imports the full existing mobile 0.2 GGUF into temporary app-owned storage.
2. Runs AppStore.runAgent in ordinary mode with thinking off.
3. Requires an actual write_file call followed by read_file.
4. Checks that the file contains LIQUID-TOOLS-OK and the final response includes it.
5. Reloads StateStorage and checks that the complete tool history persisted.
6. Summarizes the completed turn using the real model, preserves the raw history,
   then answers the apple question with exactly **5** in ordinary mode.

The initial write/read cycle passed twice (13.053 and 12.838 seconds). The expanded
cycle including real compaction and the apple answer passed in 17.667 seconds.
All seven compact-context tests passed with native inference enabled (18.523 seconds).
This exercises the production
registry, embedded inference, JSON tool parsing, executor, receipts and storage;
there are no mocked model replies. Temporary test files are cleaned up.

An additional unit test first reproduced the unsafe minimum summary reservation
at 4K, then verified chunk budget and complete-history preservation after the fix.
A 256-character summary cap was rejected by the real-model check; the final
profile uses the validated 768-token/character bound and a 256-token output budget.

Local logs/backups are in ignored STIX Ai/artifacts/liquid-agent-tools/;
the initial failing and native-only logs are in artifacts/liquid-agent/.

## Installed app

Installed macOS Agent **0.9.10 (31)** with the existing Apple Development identity,
entitlements, helpers and bundled models. Strict deep signature verification and
comparison against the signed package passed. The preceding app and private chat
data were backed up locally. Final release build passed (42.15 seconds).

In an ordinary GUI chat (not clean mode), Liquid created gui-result.txt containing
`Привет, Liquid.` and completed the task. A separate explicit read_file request
then completed with that exact text. The file was also checked independently on
disk. After restarting the final app, model selection, messages and completed
tasks persisted; automatic context compaction completed in the GUI.

After restart, a new ordinary chat read restart-input.txt through read_file and
returned its exact independently generated LIQUID-RESTART marker, which was not
included in the prompt. The same ordinary chat then answered the apple question
with **5**, both tasks completed. This verifies fresh tool execution and answers
after restart, rather than only replaying a previously known result.

## Boundaries

This remains a 4B model with a 4K context window. A request or required schema that
cannot fit is rejected safely. The compact profile does not imply that every
large document, arbitrary tool or long reasoning chain will fit or be solved.
The tests establish ordinary-mode file tools and simple answers, not general
benchmark parity or iPhone performance. No physical iPhone test is claimed.

Observed model-quality limitation: in the earlier, repeatedly compacted GUI chat,
the model skipped a requested read of a new path and replied with a fabricated
file-not-found error without a corresponding tool call. The same fresh-file
request succeeded in a new ordinary chat with an actual read_file call. This is
recorded as a failed model-behavior check, not as an executed filesystem error or
a passing long-conversation reliability test. Existing executor safeguards remain
in force, but arbitrary multi-turn instruction following is not guaranteed.
