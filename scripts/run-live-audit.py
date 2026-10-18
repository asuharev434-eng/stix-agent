#!/usr/bin/env python3
"""Run the twelve previously gated checks serially against this Mac's local APIs."""
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time

TESTS = [
    "DiagnosticsTests.testUnbundledVoiceFailsBeforeRequestingPermissions",
    "LiveIntegrationTests.testLocalModelCreatesFileThroughAgentLoop",
    "LiveFeatureTests.testLocalPromptAdaptationAndThinkingTransport",
    "LiveFeatureTests.testLocalSpecialistLeavesMainModelSelected",
    "LiveCapabilityTests.testMainDelegatesTextCodeAndAnalysisThenUsesTerminalAndQueue",
    "LiveCapabilityTests.testMainDelegatesActualImageToVision",
    "LiveCapabilityTests.testMainPausesItsOwnDurableTask",
    "LiveCapabilityTests.testMainSearchesDuckDuckGoAndReadsSource",
    "LiveIntegrationTests.testLocalComfyProducesPNG",
    "LiveFeatureTests.testLocalComfyResizeAndEditOwnFixture",
    "LiveCapabilityTests.testMainEditsOwnExistingImageWithoutReplacingOriginal",
    "LiveCapabilityTests.testMainGeneratesThenEditsLastImage",
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--start", type=int, default=1, help="First check, 1..12; keeps earlier evidence")
    parser.add_argument("--stop", type=int, default=12, help="Last check, inclusive")
    args = parser.parse_args()
    if not 1 <= args.start <= args.stop <= len(TESTS):
        parser.error("Expected 1 <= start <= stop <= 12")
    project = Path(__file__).resolve().parent.parent
    output = project / "dist" / "remaining-tests"
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / "report.json"
    report = json.loads(report_path.read_text()) if report_path.exists() else {"attempts": []}
    env = dict(os.environ, STIX_AGENT_LIVE="1", STIX_AGENT_LIVE_FEATURES="1", STIX_AGENT_CAPABILITY_AUDIT="1")
    for index in range(args.start - 1, args.stop):
        test = TESTS[index]
        number = len(report["attempts"]) + 1
        log = output / f"{number:02d}-{test}.log"
        record = {"index": index + 1, "test": test, "started": datetime.datetime.now(datetime.timezone.utc).isoformat(), "status": "running", "log": str(log)}
        report["attempts"].append(record)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(f"[{index + 1}/12] {test}", flush=True)
        started = time.monotonic()
        with log.open("w") as stream:
            result = subprocess.run(["swift", "test", "--skip-build", "--filter", test], cwd=project, env=env, stdout=stream, stderr=subprocess.STDOUT)
        text = log.read_text()
        passed = result.returncode == 0 and "Executed 1 test, with 0 failures" in text and "skipped" not in text.lower()
        record.update(status="passed" if passed else "failed", seconds=round(time.monotonic() - started, 3), exitCode=result.returncode)
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(f"    {record['status']} ({record['seconds']} s)", flush=True)
        if not passed:
            print(f"Stopped for investigation: {log}", flush=True)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
