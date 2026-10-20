#!/bin/zsh
set -euo pipefail

source_root="${0:A:h:h}"
checkout="${STIX_SDCPP_SOURCE:-$HOME/Library/Caches/STIXAgentBuild/stable-diffusion.cpp}"
revision="b13a48219d5cdf408edcb93da6cd69b612ed03d3"
if [[ ! -d "$checkout/.git" ]]; then
    mkdir -p "${checkout:h}"
    /usr/bin/git clone --recurse-submodules https://github.com/leejet/stable-diffusion.cpp.git "$checkout"
fi
if [[ "$(/usr/bin/git -C "$checkout" rev-parse HEAD)" != "$revision" ]]; then
    /usr/bin/git -C "$checkout" fetch origin "$revision"
    /usr/bin/git -C "$checkout" checkout --detach "$revision"
fi
/usr/bin/git -C "$checkout" submodule update --init --recursive

if command -v cmake >/dev/null 2>&1; then
    cmake_cmd=(cmake)
elif command -v uv >/dev/null 2>&1; then
    cmake_cmd=(uv tool run --from cmake cmake)
else
    print -u2 "CMake or uv is required to build the bundled SDXL engine"
    exit 1
fi
build="$checkout/build-stix-metal"
"${cmake_cmd[@]}" -S "$checkout" -B "$build" -DSD_METAL=ON -DSD_WEBP=OFF -DSD_WEBM=OFF -DCMAKE_BUILD_TYPE=Release
"${cmake_cmd[@]}" --build "$build" --target sd-cli -j 6
binary="$build/bin/sd-cli"
[[ -x "$binary" ]] || { print -u2 "sd-cli build failed"; exit 1; }
mkdir -p "$source_root/dist/native/SDCPP/Licenses"
cp "$binary" "$source_root/dist/native/SDCPP/stix-sd-cli"
cp "$checkout/LICENSE" "$source_root/dist/native/SDCPP/Licenses/stable-diffusion.cpp-LICENSE.txt"
cp "$checkout/ggml/LICENSE" "$source_root/dist/native/SDCPP/Licenses/ggml-LICENSE.txt"
cp "$checkout/thirdparty/utf8proc/LICENSE.md" "$source_root/dist/native/SDCPP/Licenses/utf8proc-LICENSE.md"
cp "$checkout/thirdparty/oniguruma/COPYING" "$source_root/dist/native/SDCPP/Licenses/oniguruma-COPYING.txt"
cp "$checkout/thirdparty/LICENSE.darts_clone.txt" "$source_root/dist/native/SDCPP/Licenses/darts_clone-LICENSE.txt"
