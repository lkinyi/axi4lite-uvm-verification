#!/usr/bin/env python3
"""Gate completed UVM logs; a simulator exit code of zero alone is insufficient."""
import argparse
import json
import re
from pathlib import Path


def check(text, exit_code):
    errors = [int(x) for x in re.findall(r"^UVM_ERROR\s*:\s*(\d+)\s*$", text, re.M)]
    fatals = [int(x) for x in re.findall(r"^UVM_FATAL\s*:\s*(\d+)\s*$", text, re.M)]
    results = re.findall(r"\[SCB\] RESULT: (PASS|FAIL)", text)
    diagnostic = bool(re.search(r"^(?:UVM_ERROR|UVM_FATAL)\s+(?!:)", text, re.M))
    mismatch = bool(re.search(r"(?:READ|RESP) MISMATCH", text))
    timeout = exit_code == 124 or bool(re.search(r"Global timeout|timeout reached|timed out", text, re.I))
    sva = "[SVA]" in text and bool(re.search(r"%Error|Assertion failed", text))
    passed = (exit_code == 0 and errors == [0] and fatals == [0]
              and results == ["PASS"] and not (diagnostic or mismatch or timeout or sva))
    detected = (not timeout and (mismatch or sva) and not passed)
    return dict(status="PASS" if passed else "FAIL", exit_code=exit_code,
                uvm_error=errors[-1] if errors else None,
                uvm_fatal=fatals[-1] if fatals else None,
                scoreboard=results[-1] if results else "MISSING",
                timeout=timeout, fault_detected=detected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--exit-code", type=int, required=True)
    parser.add_argument("--expect-detected", action="store_true",
                        help="Require an explicit mismatch/SVA detection, never call it a normal PASS")
    args = parser.parse_args()
    result = check(args.log.read_text(errors="replace"), args.exit_code)
    result["mode"] = "expected_fault" if args.expect_detected else "normal"
    accepted = result["fault_detected"] if args.expect_detected else result["status"] == "PASS"
    result["acceptance"] = "DETECTED" if args.expect_detected and accepted else result["status"]
    print(json.dumps(result, sort_keys=True))
    return 0 if accepted else 1


if __name__ == "__main__":
    raise SystemExit(main())
