#!/usr/bin/env python3
"""Run the pinned local quality fixtures against the embedded C bridge.

This script never executes model-requested tools; it records their proposed JSON
for review. Pass only a verified local GGUF and the staged bridge library.
"""

import argparse
import ctypes
import hashlib
import json
import resource
import time
from pathlib import Path


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--context", type=int, default=8192)
    parser.add_argument("--case", dest="case_id", default=None)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fixtures = Path(__file__).resolve().parents[1] / "Tests/STIXAgentTests/Fixtures/inference-quality.json"
    cases = json.loads(fixtures.read_text(encoding="utf-8"))["textCases"]
    if args.case_id:
        cases = [case for case in cases if case["id"] == args.case_id]
        if not cases:
            parser.error("unknown case")
    library = ctypes.CDLL(str(args.bridge.resolve()))
    library.stix_llama_load.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t]
    library.stix_llama_load.restype = ctypes.c_void_p
    callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p)
    library.stix_llama_generate.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32, ctypes.c_float,
                                           callback_type, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    library.stix_llama_generate.restype = ctypes.c_int
    library.stix_llama_unload.argtypes = [ctypes.c_void_p]
    error = ctypes.create_string_buffer(1024)
    started = time.monotonic()
    handle = library.stix_llama_load(str(args.model.resolve()).encode(), args.context, error, len(error))
    if not handle:
        raise RuntimeError(error.value.decode(errors="replace"))
    load_seconds = time.monotonic() - started
    results = []
    try:
        for case in cases:
            system = case["system"]
            if case.get("expectedTool"):
                tools = [
                    {"name": "list_files", "description": "List files in a directory.",
                     "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}},
                    {"name": "write_file", "description": "Create or replace a UTF-8 file.",
                     "parameters": {"type": "object", "properties": {"path": {"type": "string"},
                                                                    "content": {"type": "string"}},
                                    "required": ["path", "content"]}},
                ]
                system += ("\nДоступные инструменты (JSON Schema):\n" +
                           "\n".join(json.dumps(tool, ensure_ascii=False) for tool in tools) +
                           '\nЕсли нужен инструмент, верни только JSON: {"tool_calls":[{"name":"имя", "arguments":{...}}]}. '
                           "Не утверждай о выполнении до результата инструмента. Если инструмент не нужен, отвечай обычным текстом.")
            messages = [{"role": "system", "content": system},
                        {"role": "user", "content": case["user"] + "\n/no_think"}]
            wire = json.dumps(messages, ensure_ascii=False).encode("utf-8")
            chunks = []
            first = None
            started = time.monotonic()

            def receive(data, length, user):
                nonlocal first
                if data and length:
                    if first is None:
                        first = time.monotonic() - started
                    chunks.append(ctypes.string_at(data, length))
                return 1

            error.value = b""
            generated = library.stix_llama_generate(handle, wire, args.max_tokens, 0.1 if case.get("expectedTool") else 0.7, callback_type(receive),
                                                     None, error, len(error))
            text = b"".join(chunks).decode("utf-8", errors="replace")
            results.append({"id": case["id"], "seconds": round(time.monotonic() - started, 3),
                            "firstTokenSeconds": round(first, 3) if first is not None else None,
                            "tokens": generated, "error": error.value.decode(errors="replace"),
                            "output": text})
    finally:
        library.stix_llama_unload(handle)
    report = {"model": args.model.name, "sha256": digest(args.model),
              "loadSeconds": round(load_seconds, 3),
              "peakRSSBytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
              "results": results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"model": report["model"], "loadSeconds": report["loadSeconds"],
                      "peakRSSBytes": report["peakRSSBytes"],
                      "cases": [{"id": item["id"], "tokens": item["tokens"],
                                 "seconds": item["seconds"]} for item in results]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
