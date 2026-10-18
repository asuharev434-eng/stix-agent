# Local Agent expansion

User authorized implementation of all previously listed gaps and installation, no GitHub, deployment, external servers. Native SwiftUI Liquid Glass layout and existing user data preserved. Never exercise external accounts or actual sensitive actions while testing.

1. Local document ingestion: images to vision model content, local OCR/PDF/DOCX extraction with limits, failures visible.
2. File review: diff and batch move plans, state validation at apply, existing reversible operations, task-wide undo with conflicts surfaced.
3. Durable queue: queued/running/paused/interrupted tasks, explicit resume from checkpoints, never blindly replay a side effect, one executor for local RAM.
4. Shared editable memory and bounded conversation summaries preserving tool groups.
5. Comfy editing: image input/masks, variation/resize, generation parameters via chat, local upload, workflows.
6. Chat search, rename/pin/export, edit and retry, preserve original history through branches.
7. OAuth PKCE flow and refresh stored in Keychain, credential references injected only in approved shell/plugin environment.
8. Native Accessibility and screen capture tools; browser tabs/read/open/click/fill via native adapters, action approval and no credentials in model-visible text.
9. Chat-driven font size, spacing and settings. Main selected model orchestrates specialist local models via bounded tool, validates installed IDs and leaves selection unchanged.

Validation: schema migration from existing JSON, focused unit tests, complete swift test, release build, Developer ID signature verification, backup installed app/state, native UI check before and after install. No live external API or OAuth tests. Native automation actions tested only in disposable/local fixtures or read-only.

Ownership: controller owns Models.swift, AppStore.swift, AgentEngine.swift, ToolExecutor.swift, ToolCatalog.swift integration. Independent workers own new domain modules and explicitly assigned existing transport/UI files.

Additional authorized scope during execution: five-level question slider (0/1/3/6/12 max tool questions), transient Thinking streaming, dual /image selectors and local prompt adaptation/translation. /image now invokes a separate bounded prompt-preparation model and then ComfyUI, superseding original direct bypass design. Image edits resolve last image of same chat; source preserved.

Review findings corrected: image payloads withheld from text-only primary; known secrets redacted from extracted input; orphan jobs cancelled/skipped; input checkpoint separate from started; tool-round exhaustion resumable; enriched conversation branches use durable source IDs; event entitlement added for hardened runtime; interrupted file plan rollback has durable recovery.

Validation so far: full 105-test suite 0 failures (5 opt-in live skipped), four live expanded tests passed against local 1235/8188 including img2img, pure resize, prompt adaptation with Thinking, specialist call preserving selection and model-driven file creation. Final suite/release/UI installation still required after recovery refinement.

Completed: final suite 112 tests (107 passed, 5 opt-in live skipped), zero failures. Four separate local live tests passed (resize+img2img, prompt adapter+Thinking transport, specialist delegation, model-driven file write). Release build and Developer ID signature verification passed; Apple Events entitlement included. Version0.2 installed in ~/Applications and launched; native UI verified text/image model menus, clarification slider, Thinking and history search. Existing Timeweb API connection/history preserved. OAuth provider login and sensitive OS/browser actions were not exercised against external services. Full local data backups and previous app kept in dist. No GitHub/push/deployment performed.
