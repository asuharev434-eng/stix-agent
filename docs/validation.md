# Local validation ledger

All source and artifacts stay on this Mac. GitHub, deployment and external infrastructure are excluded by user instruction.

- [x] macOS/Xcode/Swift environment inspected; project was empty.
- [x] API Bionic discovered at127.0.0.1:1235; installed LLM list read.
- [x] Existing local SDXL installation and checkpoints identified.
- [x] Native chat, composer selection, file/media/code/diagram/dashboard presentation implemented.
- [x] Local API credentials, protected form, Keychain, documentation and exact-action permissions implemented.
- [x] Independent review found shell classifier, stale chat index, stream redaction and blocking file work; fixes implemented.
- [x] Initial automated tests green:35 total,33 passed,2 live tests skipped. Symlink/nonexistent-path regressions corrected. Final post-review run:39 tests,37 passed,2 live tests skipped,0 failures. Includes real WebKit network-rule compilation and offline Mermaid SVG rendering.
- [x] Release bundle built/signed and installed in ~/Applications; native window and theme command verified.
- [x] Live tests passed: SDXL1024x1024 real PNG229.7s; Qwen3.5 9B created file through agent tools33.4s. Initial30B attempt timed out under memory pressure;9B validated. User subsequently selected8B in the native UI; this selection is preserved. Native initial rich rendering exposed a WebKit srcdoc issue; fixed with a dedicated isolated WebKit document and covered by a real rendering regression test. Final signed native app opened successfully and displayed the real three-block Mermaid diagram; screenshot inspected.

Known scope: image attachment preview does not imply VLM vision input. MCP OAuth/legacy SSE transport not included. Signed with Developer ID Application, Team9TB7MZWNXU; certificate fingerprint matches Downloads/developerID_application.cer. codesign --verify --deep --strict passed; notarization is outside this local-only delivery.

Final installed location: /Users/andrei/Applications/STIX Agent.app. Source remains /Users/andrei/Documents/STIX Agent. Local API endpoints are Bionic1235 and app-owned offline ComfyUI8188. macOS privacy grants are user-controlled through the chat permission card.
