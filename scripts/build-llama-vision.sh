#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
cache_dir="${STIX_NATIVE_CACHE:-$HOME/Library/Caches/STIXAgentBuild}"
source_dir="$cache_dir/llama.cpp"
build_dir="$cache_dir/llama-vision-build"
cmake_bin="${STIX_CMAKE:-}"
if [[ -z "$cmake_bin" ]]; then cmake_bin="$(command -v cmake || true)"; fi
if [[ -z "$cmake_bin" && -x "$HOME/Library/Python/3.9/bin/cmake" ]]; then cmake_bin="$HOME/Library/Python/3.9/bin/cmake"; fi
[[ -x "$cmake_bin" && -d "$source_dir/.git" ]] || { print -u2 "Pinned llama.cpp source and CMake are required"; exit 1; }
[[ "$(/usr/bin/git -C "$source_dir" rev-parse HEAD)" == "33d6135cbe20e90e67d9db1c874fbb4a9dc64b19" ]] || { print -u2 "llama.cpp revision mismatch"; exit 1; }
"$cmake_bin" -S "$source_dir" -B "$build_dir" -DBUILD_SHARED_LIBS=ON -DGGML_METAL=ON \
    -DLLAMA_BUILD_COMMON=ON -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DCMAKE_BUILD_TYPE=Release
"$cmake_bin" --build "$build_dir" --target llama-mtmd-cli -j 4
target="$project_dir/dist/native/Vision"
mkdir -p "$target/Frameworks"
cp "$build_dir/bin/llama-mtmd-cli" "$target/stix-mtmd-cli"
for library in "$build_dir"/bin/libllama-common*.dylib(N) "$build_dir"/bin/libmtmd*.dylib(N); do
    cp -a "$library" "$target/Frameworks/"
done
old_rpath="$build_dir/bin"
/usr/bin/install_name_tool -rpath "$old_rpath" @executable_path/../Frameworks "$target/stix-mtmd-cli"
for library in "$target"/Frameworks/lib*.dylib(N); do
    [[ -L "$library" ]] && continue
    /usr/bin/install_name_tool -rpath "$old_rpath" @loader_path "$library"
done
print "Native vision helper staged: $target"
