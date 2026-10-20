#!/usr/bin/env python3
"""Verify every imported model byte before migrating or removing source runtimes."""

import argparse
import hashlib
import json
from pathlib import Path


def safe_child(root: Path, name: str) -> Path:
    if not name or name in (".", "..") or Path(name).name != name or "/" in name or "\\" in name:
        raise ValueError(f"unsafe model path: {name!r}")
    path = root / name
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"missing or non-regular model file: {path}")
    return path


def digest(path: Path) -> str:
    hashed = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            hashed.update(chunk)
    return hashed.hexdigest()


def verify(path: Path, expected: str) -> None:
    if len(expected) != 64 or digest(path) != expected:
        raise ValueError(f"SHA-256 mismatch: {path}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.home() / "Library/Application Support/STIX Agent/Models")
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    counts = {"gguf": 0, "visionProjectors": 0, "mlx": 0, "checkpoints": 0}

    for record in json.loads((root / "manifest.json").read_text()):
        path = safe_child(root, record["fileName"])
        verify(path, record["sha256"])
        if path.stat().st_size != record["bytes"]:
            raise ValueError(f"size mismatch: {path}")
        counts["gguf"] += 1
        if record.get("projectorFileName"):
            verify(safe_child(root, record["projectorFileName"]), record["projectorSHA256"])
            counts["visionProjectors"] += 1

    mlx_root = root / "MLX"
    for record in json.loads((mlx_root / "manifest.json").read_text()):
        name = record["directoryName"]
        if Path(name).name != name or name in ("", ".", ".."):
            raise ValueError(f"unsafe MLX directory: {name!r}")
        folder = mlx_root / name
        if folder.is_symlink() or not folder.is_dir():
            raise ValueError(f"missing MLX directory: {folder}")
        actual = {item.name for item in folder.iterdir()}
        if actual != set(record["files"]):
            raise ValueError(f"MLX file set mismatch: {folder}")
        for file_name, expected in record["files"].items():
            verify(safe_child(folder, file_name), expected)
        counts["mlx"] += 1

    image_root = root / "ImageCheckpoints"
    for record in json.loads((image_root / "manifest.json").read_text()):
        path = safe_child(image_root, record["fileName"])
        verify(path, record["sha256"])
        if path.stat().st_size != record["bytes"]:
            raise ValueError(f"size mismatch: {path}")
        counts["checkpoints"] += 1
    print(json.dumps({"verified": counts}, ensure_ascii=False))


if __name__ == "__main__":
    main()
