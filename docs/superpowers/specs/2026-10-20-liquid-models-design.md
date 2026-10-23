# Liquid names and ordinary mobile0.2 import

User goal: show Liquid family names in STIX Agent and add STIX Liquid0.2-mobile-other
as a normal locally imported model, without a separate API. Use the existing
LocalModelLibrary importer, app-owned storage, picker and embedded inference engine.

Shared STIXModelNaming display helper maps known STIX0.x identifiers and imported
GGUF filenames to Liquid labels. Keep technical IDs, model hashes, chats, explicit
self/other provenance and third-party upstream names. Version1.0 is out of scope.
Mac descriptors, import notices and deletion menus use the helper; the iOS local
picker shares the rule. Preserve existing recorded message text as history.

A first GGUF shard is already in the installed library and has failed to load:
182818670209e4bd... is only1.79GB of the2.50GB model. Import the canonical full
24c4b1a61061c97e... GGUF through the standard LocalModelLibrary importer. Reject future incomplete shard
imports in the metadata inspector with a clear merge/full-file instruction.
Remove the unusable entry only after the full import works and no chats use it.

Changes: Shared/RemoteChatCore naming, model descriptor/import presentation,
GGUFInspector split metadata validation, iOS local display and regression tests.
Keep native inference implementation and model payloads unchanged. Existing
thinking switch remains a standard Agent control. No iPhone hardware test requested.

Validation: naming boundaries/IDs, rollback of shard import, all Swift tests,
release build, same-identity signed installed app with existing helpers/resources,
ordinary library import, GUI answer and generation after relaunch. Back up the app
and model settings before installation. Push a focused PR on the current Agent line.
