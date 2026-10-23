#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cache_dir="${STIX_NATIVE_CACHE:-$HOME/Library/Caches/STIXAgentBuild}"
source_dir="$cache_dir/llama.cpp"
build_dir="$cache_dir/llama-build"
model_cache="$cache_dir/iphone-models"
model_dir="$project_dir/iOS/STIXRemote/Models"
native_dir="$project_dir/Vendor/iOSNative"
revision="33d6135cbe20e90e67d9db1c874fbb4a9dc64b19"
model_revision="90862c4b9d2787eaed51d12237eafdfe7c5f6077"
source_hash="061b54daade076b5d3362dac252678d17da8c68f07560be70818cace6590cb1a"
target_hash="670a3c9f67783b7323c11c51a9ceebfaa1e67273111ce949cf2dee0437de1894"
source_model="$model_cache/Qwen3-1.7B-Q8_0.gguf"
target_model="$model_dir/Qwen3-1.7B-Q4_K_M.gguf"
framework="$native_dir/llama.xcframework"
cmake_bin="${STIX_CMAKE:-$(command -v cmake || true)}"
if [[ -z "$cmake_bin" && -x "$HOME/Library/Python/3.9/bin/cmake" ]]; then
    cmake_bin="$HOME/Library/Python/3.9/bin/cmake"
fi
[[ -x "$cmake_bin" ]] || { print -u2 "CMake is required"; exit 1; }
mkdir -p "$cache_dir" "$model_cache" "$model_dir" "$native_dir"

if [[ ! -d "$source_dir/.git" ]]; then
    /usr/bin/git clone --no-checkout --filter=blob:none https://github.com/ggml-org/llama.cpp.git "$source_dir"
fi
if [[ "$(/usr/bin/git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)" != "$revision" ]]; then
    /usr/bin/git -C "$source_dir" fetch --depth 1 origin "$revision"
    /usr/bin/git -C "$source_dir" checkout --detach "$revision"
fi
[[ "$(/usr/bin/git -C "$source_dir" rev-parse HEAD)" == "$revision" ]] || exit 1

if [[ ! -d "$framework" ]]; then
    (cd "$source_dir" && PATH="${cmake_bin:h}:$PATH" ./build-xcframework.sh ios-device)
    /usr/bin/ditto "$source_dir/build-apple/llama.xcframework" "$framework"
fi
cp "$source_dir/LICENSE" "$native_dir/llama.cpp-LICENSE.txt"

if [[ ! -x "$build_dir/bin/llama-quantize" ]]; then
    "$cmake_bin" -S "$source_dir" -B "$build_dir" -DGGML_METAL=ON \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DCMAKE_BUILD_TYPE=Release
    "$cmake_bin" --build "$build_dir" --target llama-quantize -j 4
fi
if [[ ! -f "$source_model" || "$(shasum -a 256 "$source_model" | awk '{print $1}')" != "$source_hash" ]]; then
    curl -fL --retry 3 --continue-at - --output "$source_model" \
        "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/$model_revision/Qwen3-1.7B-Q8_0.gguf"
fi
[[ "$(shasum -a 256 "$source_model" | awk '{print $1}')" == "$source_hash" ]] || {
    print -u2 "Source model checksum mismatch"; exit 1
}
if [[ ! -f "$target_model" || "$(shasum -a 256 "$target_model" | awk '{print $1}')" != "$target_hash" ]]; then
    "$build_dir/bin/llama-quantize" --allow-requantize "$source_model" "$target_model" Q4_K_M
fi
[[ "$(shasum -a 256 "$target_model" | awk '{print $1}')" == "$target_hash" ]] || {
    print -u2 "iPhone model checksum mismatch"; exit 1
}
curl -fsSL "https://huggingface.co/Qwen/Qwen3-1.7B-GGUF/resolve/$model_revision/LICENSE" \
    -o "$native_dir/Qwen3-LICENSE.txt"
"/usr/bin/python3" "$project_dir/scripts/stage-coreml-image.py" \
    --output "$model_dir/CoreML-SD15-Palettized" --variant palettized --omit-safety
print "Offline iPhone runtime and model are ready. Build iOS/STIXRemote.xcodeproj."
