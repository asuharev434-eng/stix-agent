# Автономная сборка STIX Agent

Этот вариант работает без LM Studio и ComfyUI. Встроенная Qwen3 4B обрабатывает текст и инструменты через llama.cpp/Metal; Core ML Stable Diffusion 1.5 с SafetyChecker создаёт и правит изображения. Импортированные GGUF, MLX и SDXL работают через включённые в сборку локальные движки. Старые выборы моделей в чатах переводятся на идентификаторы импортированных копий; история сообщений сохраняется.

Точные ревизии, контрольные суммы, лицензии и результаты испытаний — в [матрице инференса](INFERENCE-MATRIX.md). Веса не хранятся в Git. На компьютере сборки разместите проверенный `Qwen3-4B-Q4_K_M.gguf` по пути `~/Library/Caches/STIXAgentBuild/Models/` и подготовьте Core ML комплект через:

```sh
python3 scripts/stage-coreml-image.py --output "$HOME/Library/Caches/STIXAgentBuild/CoreML-SD15-Palettized"
STIX_BUNDLE_TEXT=1 STIX_BUNDLE_IMAGE=1 STIX_BUNDLE_SDCPP=1 \
STIX_BUNDLE_MLX=1 STIX_BUNDLE_VISION=1 ./scripts/build-app.sh
./scripts/package-dmg.sh
```

`build-app.sh` сверяет SHA-256 текста и каждую запись Core ML manifest, затем копирует веса в `.app` и подписывает нативные библиотеки. Для подписанного DMG укажите `STIX_SIGN_IDENTITY` с установленным сертификатом Developer ID Application. Если настроен профиль `notarytool`, передайте `STIX_NOTARY_PROFILE` **и при сборке, и при упаковке**: сборка поставит secure timestamp, упаковка отправит DMG на нотариальное заверение и прикрепит ticket. Без профиля DMG остаётся только локально подписанным — не объявляйте его публичным релизом без проверки Gatekeeper.

Проверки:

```sh
swift test
STIX_TEST_GGUF="$HOME/Library/Caches/STIXAgentBuild/Models/Qwen3-4B-Q4_K_M.gguf" \
STIX_TEST_GGUF_SHA256=ab27b9bfa375a178d6cba48f3ad892b94b7739659dcc7aae8058ce0ffed6b328 \
STIX_TEST_LLAMA_BRIDGE=dist/native/Frameworks/libSTIXLlama.dylib \
swift test --filter LlamaNativeTests
STIX_TEST_OFFLINE_MODEL="$HOME/Library/Caches/STIXAgentBuild/Models/Qwen3-4B-Q4_K_M.gguf" \
STIX_TEST_LLAMA_BRIDGE="$PWD/dist/native/Frameworks/libSTIXLlama.dylib" \
STIX_TEST_TOOL_MATRIX=1 swift test --filter OfflineParityTests.testImportedGGUFLocalToolMatrix
STIX_TEST_OFFLINE_MODEL="$HOME/Library/Caches/STIXAgentBuild/Models/Qwen3-4B-Q4_K_M.gguf" \
STIX_TEST_LLAMA_BRIDGE="$PWD/dist/native/Frameworks/libSTIXLlama.dylib" \
STIX_TEST_COREML_RESOURCES="$HOME/Library/Caches/STIXAgentBuild/CoreML-SD15-Palettized" \
swift test --filter OfflineParityTests.testImportedGGUFAgentAndImageCycle
```

В меню модели в поле ввода можно выбрать «Добавить модель GGUF…». Приложение проверяет заголовок, архитектуру, токенизатор и размер, копирует файл в `Application Support/STIX Agent/Models`, вычисляет SHA-256 и записывает manifest атомарно. Выбор в чате сохраняется; исходный файл не меняется. Удаление импортированной копии доступно в том же меню после переключения всех использующих её чатов и назначений.

Встроенная Core ML модель изображений работает только с 512×512. При сборке с `STIX_BUNDLE_SDCPP=1` приложение также содержит закреплённую ревизию `stable-diffusion.cpp` с Metal. В меню `/image` выберите «Добавить модель safetensors…» и импортируйте SDXL checkpoint-файлы: проверенные копии лежат в `Application Support/STIX Agent/Models/ImageCheckpoints`, а генерация и img2img выполняются без ComfyUI. Сборка отключает пакетный CFG из-за проверенного дефекта белых изображений на Metal. Для точной правки области используйте маску: живой тест изменил красную кружку на синюю при `denoise=0.95`, тогда как запрос без маски не сменил цвет. Если Metal сообщит о нехватке памяти и всё же сохранит серый PNG с кодом выхода 0, приложение теперь считает задачу ошибочной. Пользовательские workflow ComfyUI не переносятся автоматически.

`STIX_BUNDLE_MLX=1` включает подписанный `stix-mlx-runner` для локально импортированных Qwen3.5 и GPT-OSS MLX. Сборка 0.9.8 передаёт схемы инструментов через нативные `ToolSpec`; обе импортированные MLX-модели дали проверенный вызов `write_file`. GPT-OSS получает достаточный бюджет токенов для внутреннего рассуждения, чтобы не возвращать пустой ответ при коротком пользовательском лимите. `STIX_BUNDLE_VISION=1` включает `llama-mtmd-cli` для GGUF-моделей с projector-файлом (проверена Gemma 4). Проверенные пользовательские модели живут вне `.app` в `~/Library/Application Support/STIX Agent/Models`. Для переноса без прежних программ выполните `./scripts/package-offline-kit.sh`: команда проверит хеши, подпись и создаст `dist/STIX Agent Offline Kit` с приложением, импортированными моделями и `install.sh`. Перенесите каталог на новый Mac и запустите `install.sh` на нём. Установщик проверяет файлы до и после копирования и отказывается перезаписывать существующее приложение или хранилище моделей; старые данные нужно сохранять и переносить отдельно. При объёме моделей около 64 ГБ потребуется достаточно свободного места; максимум 20 ГБ RAM принят как целевой предел для текущего Mac, но точный пик нужно измерять для каждой модели.

Живой тест движка с пользовательским checkpoint:

```sh
STIX_SDCPP_MODEL="$HOME/ComfyUI-Shared/models/checkpoints/LUSTIFY_v9_ZENITH.safetensors" \
STIX_SDCPP_BIN="$HOME/Library/Caches/STIXAgentBuild/stable-diffusion.cpp/build-stix-metal/bin/sd-cli" \
swift test --filter LocalCheckpointImageEngineTests.testLiveStandaloneSDXLGeneration
```

Перед установкой поверх пользовательской версии создайте локальную резервную копию данных и проверьте восстановление на копии. Путь данных: `~/Library/Application Support/STIX Agent/`. Установка приложения не удаляет этот каталог или Keychain-записи.
