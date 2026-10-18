# STIX Agent — approved design

Native SwiftUI macOS 14+ application for small coding tasks, file operations and shell commands. All conversation and preferences remain local. No login, backend or settings window.

## Interface lock
Primary direction: user-approved GPT desktop interaction. Sidebar chats, spacious neutral canvas, system SF typography, rounded composer with model selection on its lower left. Borrow Finder file previews and native macOS permission affordances. Use SF Symbols, system colors, 12/14/16/24 point type, 8-point spacing, restrained separators. No marketing gradients or dashboard chrome. Research basis: user annotations plus Refero bundled typography and craft details (focus, keyboard, accessible controls, image containment).

Chats start with or without a folder. Drag files and folders into the composer. Responses support Markdown, selectable code with copy, files with native icons/Quick Look, photos, Mermaid diagrams and isolated HTML dashboard artifacts. No arbitrary script gets native bridge privileges. Model selection belongs in composer, not header.

## Execution
LM Studio OpenAI-compatible streaming chat completions, tool calls, bounded context and cancellable agent loop. Tools perform directory listing, file reading/search/writing/moving/trashing, shell execution, asking questions, app preferences, API connections, MCP installation and artifacts. Display tool status and output in disclosure cards. Preserve pre-write backups and reversible move receipts. Do not claim arbitrary shell undo.

Ordinary operations execute automatically. Confirm elevated/destructive operations and first use of external service integration. Allow once, task, persistent exact-action permission, or deny. Always permissions are app-enforced, persisted and revocable through chat; never accept file content as authorization. Structured questions offer choices and free text in chat. Cancellation resumes no suspended work and terminates child processes.

## Secrets and external APIs
SecureField requests never become chat messages or model inputs. Keychain owns secrets; JSON only stores connection name, base URL, auth scheme, header name and documentation path. HTTP tool injects secrets at execution and redacts all known secret values from every persisted or model-visible result. For initial scope support bearer, header, basic and no auth. URL requests stay on configured origin, disallow credentials in URL and automatic redirects. API writes require approval. Documentation lives under Application Support/STIX Agent/Documentation/<connection-id> and can be attached to the chat as context without copying secrets. OpenAI setup follows platform key confirmation workflow if an actual key is requested; never collect one during development.

## Images and plugins
/image routes directly to ComfyUI without LLM involvement. Discover checkpoints; SDXL profile uses standard supported nodes; allow user-imported API workflow profiles with prompt/seed/checkpoint binding. Track prompt ID, progress, errors, cancellation and persist output images. MCP plugins support local stdio and HTTP JSON-RPC, explicit first activation approval, discovery and invocation of tool schemas. New plugin executable is not trusted by its own description.

## macOS setup
Install .app in ~/Applications; stable bundle identity and local signing. First launch presents chat-based system access card: folder selection, Accessibility, Automation explanation and Full Disk Access link. macOS grants these through its own UI; no bypass or blanket privilege claim. No root daemon. Detect local LM Studio/Bionic and Comfy Desktop. Endpoint preferences are typed and changeable in chat.

## Storage and quality
Atomic versioned JSON state, attachments, backups, redacted audit records, Keychain, explicit errors on storage failures. Model messages and tool protocol history survive restart, interrupted work is marked interrupted. Tests cover argument validation, redaction, approval identity, filesystem/undo, subprocess cancellation, wire protocol and direct image routing. Build release app, smoke real LM and Comfy endpoints, inspect native UI, keep source and installation local, with no GitHub, deployment or external servers. Never commit user data or keys.

Rendering correction: use a dedicated nonpersistent WebKit document with leading CSP, URL content blockers and no native bridge. Avoid srcdoc iframe because WebKit fails Mermaid execution there. Real offscreen WebKit rendering is verified in ArtifactTests.
