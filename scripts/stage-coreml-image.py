#!/usr/bin/env python3
"""Stage exact Core ML model resources outside Git for local evaluation.

The build checks these files again before packaging. This script is only a
development-time downloader; the installed app never downloads its base model.
"""

import argparse
import concurrent.futures
import hashlib
import json
import subprocess
import urllib.request
from pathlib import Path


VARIANTS = {
    "palettized": ("apple/coreml-stable-diffusion-v1-5-palettized",
                   "04a6a0bdd66fb8da470c14e56d762343ef579d88"),
    "standard": ("apple/coreml-stable-diffusion-v1-5",
                 "c63580e549bc0ca6c27381d0640c1eb1b68b00b1"),
}
ROOT = "original/compiled/"
COMPONENTS = ("TextEncoder.mlmodelc/", "Unet.mlmodelc/",
              "VAEDecoder.mlmodelc/", "VAEEncoder.mlmodelc/")
TOKENIZER = ("vocab.json", "merges.txt")


def metadata(repository: str, revision: str):
    url = f"https://huggingface.co/api/models/{repository}?blobs=true"
    with urllib.request.urlopen(url, timeout=30) as response:
        document = json.load(response)
    if document.get("sha") != revision:
        raise RuntimeError("Image model revision changed; update and review the manifest")
    return [item for item in document["siblings"]
            if item["rfilename"].startswith(ROOT) and
            (item["rfilename"][len(ROOT):].startswith(COMPONENTS) or
             item["rfilename"][len(ROOT):] in TOKENIZER)]


def valid(path: Path, item: dict) -> bool:
    if not path.is_file() or path.stat().st_size != item["size"]:
        return False
    content = path.read_bytes() if item["size"] < 2_000_000 else None
    if "lfs" in item:
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest() == item["lfs"]["sha256"]
    if content is None:
        return False
    git_blob = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
    return git_blob == item["blobId"]


def stage(item: dict, destination: Path, repository: str, revision: str) -> str:
    relative = item["rfilename"][len(ROOT):]
    target = destination / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    if valid(target, item):
        return f"verified {relative}"
    temporary = target.with_name(target.name + ".partial")
    url = f"https://huggingface.co/{repository}/resolve/{revision}/{item['rfilename']}"
    command = ["/usr/bin/curl", "--fail", "--location", "--retry", "10", "--retry-all-errors", "--retry-delay", "2", "--silent",
               "--show-error", "--continue-at", "-", "--output", str(temporary), url]
    subprocess.run(command, check=True)
    if not valid(temporary, item):
        raise RuntimeError(f"Downloaded image component has a wrong hash: {relative}")
    temporary.replace(target)
    return f"verified {relative}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--variant", choices=VARIANTS, default="palettized")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    repository, revision = VARIANTS[args.variant]
    args.output.mkdir(parents=True, exist_ok=True)
    if args.verify_only:
        manifest = json.loads((args.output / "manifest.json").read_text(encoding="utf-8"))
        if manifest["repository"] != repository or manifest["revision"] != revision or len(manifest["files"]) < 20:
            raise RuntimeError("Wrong Core ML model manifest")
        for relative, values in manifest["files"].items():
            if relative.startswith("/") or ".." in Path(relative).parts:
                raise RuntimeError("Unsafe Core ML model path")
            item = {"size": values["size"], "lfs": {"sha256": values["sha256"]}} if values["sha256"] else {
                "size": values["size"], "blobId": values["gitBlob"]}
            if not valid(args.output / relative, item):
                raise RuntimeError(f"Core ML model hash mismatch: {relative}")
        print(f"Verified: {args.output}")
        return
    items = metadata(repository, revision)
    if len(items) < 20 or not any("VAEEncoder.mlmodelc/weights/" in x["rfilename"] for x in items):
        raise RuntimeError("Incomplete Core ML component list")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        for result in pool.map(lambda item: stage(item, args.output, repository, revision), items):
            print(result, flush=True)
    manifest = {"repository": repository, "revision": revision,
                "files": {item["rfilename"][len(ROOT):]: {"size": item["size"],
                                                               "sha256": item.get("lfs", {}).get("sha256"),
                                                               "gitBlob": item.get("blobId")}
                          for item in items}}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Complete: {args.output}")


if __name__ == "__main__":
    main()
