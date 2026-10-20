#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
revision="33d6135cbe20e90e67d9db1c874fbb4a9dc64b19"
cache_dir="${STIX_NATIVE_CACHE:-$HOME/Library/Caches/STIXAgentBuild}"
source_dir="$cache_dir/llama.cpp"
build_dir="$cache_dir/llama-build"
frameworks_dir="$project_dir/dist/native/Frameworks"
cmake_bin="${STIX_CMAKE:-}"
if [[ -z "$cmake_bin" ]]; then
    cmake_bin="$(command -v cmake || true)"
fi
if [[ -z "$cmake_bin" && -x "$HOME/Library/Python/3.9/bin/cmake" ]]; then
    cmake_bin="$HOME/Library/Python/3.9/bin/cmake"
fi
[[ -n "$cmake_bin" && -x "$cmake_bin" ]] || { print -u2 "CMake is required to build the embedded llama.cpp runtime"; exit 1; }
mkdir -p "$cache_dir" "$frameworks_dir"
if [[ ! -d "$source_dir/.git" ]]; then
    /usr/bin/git clone --no-checkout --filter=blob:none https://github.com/ggml-org/llama.cpp.git "$source_dir"
fi
if [[ "$(/usr/bin/git -C "$source_dir" rev-parse HEAD 2>/dev/null || true)" != "$revision" ]]; then
    /usr/bin/git -C "$source_dir" fetch --depth 1 origin "$revision"
    /usr/bin/git -C "$source_dir" checkout --detach "$revision"
fi
[[ "$(/usr/bin/git -C "$source_dir" rev-parse HEAD)" == "$revision" ]] || { print -u2 "llama.cpp revision mismatch"; exit 1; }

"$cmake_bin" -S "$source_dir" -B "$build_dir" -DBUILD_SHARED_LIBS=ON -DGGML_METAL=ON \
    -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release
"$cmake_bin" --build "$build_dir" --target llama -j 4

rm -f "$frameworks_dir"/lib*.dylib(N)
cp -a "$build_dir"/bin/lib*.dylib "$frameworks_dir/"
/usr/bin/xcrun clang++ -std=c++17 -O2 -dynamiclib \
    -I "$source_dir/include" -I "$source_dir/ggml/include" -I "$source_dir/vendor/nlohmann" \
    -L "$frameworks_dir" -lllama -Wl,-rpath,@loader_path \
    -Wl,-install_name,@rpath/libSTIXLlama.dylib \
    -o "$frameworks_dir/libSTIXLlama.dylib" \
    "$project_dir/Vendor/LlamaBridge/stix_llama_bridge.cpp"

for library in "$frameworks_dir"/lib*.dylib(N); do
    [[ -L "$library" ]] && continue
    if ! /usr/bin/otool -l "$library" | /usr/bin/grep -q 'path @loader_path '; then
        /usr/bin/install_name_tool -add_rpath @loader_path "$library"
    fi
done
cp "$source_dir/LICENSE" "$project_dir/dist/native/llama.cpp-LICENSE.txt"
print "Native runtime staged: $frameworks_dir"
