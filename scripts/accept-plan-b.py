#!/usr/bin/env python3
"""Build isolated Plan B variants; preserve original coverage and Plan A proofs.
Acceptance requires the specific TXN_INTEGRITY error for each Monitor mutation.
No existing evidence directory may be overwritten. No commit or push is made.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
FAULTS = {
    "drop": ("INJECT_MON_DROP_READ", "MISSING_MON_READ", 9),
    "duplicate": ("INJECT_MON_DUP_READ", "EXTRA_MON_READ", 11),
    "corrupt": ("INJECT_MON_CORRUPT_READ", "FIELD_MISMATCH_READ", 10),
}


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


A = load("plan_a", "accept-plan-a.py")
require, save, execute = A.require, A.save, A.execute
COUNTS = re.compile(r"\[TXN_INTEGRITY\] COUNTS active=(\d+) driver_writes=(\d+) driver_reads=(\d+) monitor_writes=(\d+) monitor_reads=(\d+) scoreboard_writes=(\d+) scoreboard_reads=(\d+)")


def counts(text):
    rows = COUNTS.findall(text)
    require(len(rows) == 1, "Exactly one integrity counter summary required")
    keys = ["active", "driver_writes", "driver_reads", "monitor_writes", "monitor_reads",
            "scoreboard_writes", "scoreboard_reads"]
    return dict(zip(keys, map(int, rows[0])))


def normal_integrity(text, passive=False):
    c = counts(text)
    require(c["monitor_writes"] == c["scoreboard_writes"] and
            c["monitor_reads"] == c["scoreboard_reads"], "Monitor/Scoreboard counts differ")
    if passive:
        require(c["active"] == 0 and c["driver_writes"] == c["driver_reads"] == 0
                and "[TXN_INTEGRITY] RESULT: SKIP_ACTIVE" in text
                and "[TXN_INTEGRITY] RESULT: PASS" not in text, "Passive check must explicitly skip active reconciliation")
    else:
        require(c["active"] == 1 and c["driver_writes"] == c["monitor_writes"]
                and c["driver_reads"] == c["monitor_reads"]
                and "[TXN_INTEGRITY] RESULT: PASS completed-record consistency only" in text,
                "Active integrity did not pass")
    return c


def fault_integrity(text, code, kind):
    macro, target, observed_reads = FAULTS[kind]
    gate = A.load_gate().check(text, code)
    c = counts(text)
    require(c == dict(active=1, driver_writes=10, driver_reads=10, monitor_writes=10,
                      monitor_reads=observed_reads, scoreboard_writes=10,
                      scoreboard_reads=observed_reads), "Unexpected fault counts: " + repr(c))
    diagnostics = re.findall(r"^UVM_ERROR\s+(?!:).*$", text, re.M)
    target_lines = [line for line in diagnostics if "[TXN_INTEGRITY] " + target in line]
    require(target_lines, "Missing specific TXN_INTEGRITY target " + target)
    require(text.count("[MON_INJECT] " + macro) == 1, "Fault must be injected exactly once")
    require("[TXN_INTEGRITY] RESULT: FAIL" in text, "Checker did not report failure")
    require(code == 0 and gate["uvm_fatal"] == 0 and not gate["timeout"]
            and gate["uvm_error"] == len(diagnostics) > 0 and "[SVA]" not in text,
            "Fault must finish with a complete UVM summary, no timeout/fatal/SVA")
    allowed_integrity = ("MISSING_MON_READ", "SCB_DRIVER_COUNT", "FIELD_MISMATCH_READ") if kind == "drop" else (
        ("EXTRA_MON_READ", "SCB_DRIVER_COUNT", "FIELD_MISMATCH_READ") if kind == "duplicate" else ("FIELD_MISMATCH_READ",))
    for line in diagnostics:
        allowed = any("[TXN_INTEGRITY] " + label in line for label in allowed_integrity)
        if kind == "corrupt":
            allowed = allowed or "[SCB] READ MISMATCH" in line or "[SCB] RESULT: FAIL" in line
        require(allowed, "Unrelated error is not fault detection: " + line)
    if kind == "corrupt":
        require(len(target_lines) == 1 and "index=0 fields= data " in target_lines[0], "Wrong corrupted field/index")
        require(sum("[SCB] READ MISMATCH" in line for line in diagnostics) == 1
                and gate["scoreboard"] == "FAIL" and len(diagnostics) == 3, "Unexpected corruption errors")
    else:
        require(gate["scoreboard"] == "PASS", "Drop/duplicate must expose original scoreboard blind spot")
        require(any("[TXN_INTEGRITY] SCB_DRIVER_COUNT" in line for line in diagnostics), "Scoreboard/Driver count detection missing")
    return dict(acceptance="DETECTED", target=target, target_errors=target_lines,
                counters=c, diagnostics=diagnostics, gate=gate)


def build(out, name, verilator, macro=None):
    d = out / name
    d.mkdir()
    cmd = [str(verilator), "--binary", "--timing", "--assert", "--coverage", "-Wno-fatal",
           "-j", "1", "--output-groups", "32", "-CFLAGS", "-O0", "+define+UVM_NO_DPI"]
    if macro:
        cmd.append("+define+" + macro)
    cmd += ["+incdir+" + str(ROOT / ".tools/uvm/src"), "+incdir+" + str(ROOT / "tb")]
    cmd += [str(ROOT / f) for f in [".tools/uvm/src/uvm_pkg.sv", "tb/axi4lite_if.sv",
            "tb/axi4lite_pkg.sv", "rtl/axi4lite_slave.sv", "tb/tb_top.sv", "tb/axi4lite_plan_a_audit.sv"]]
    cmd += ["--top-module", "tb_top", "--Mdir", str(d / "obj"), "-o", "uvm_sim"]
    save(d / "source-sha256.json", {str(p.relative_to(ROOT)): A.digest(p)
         for folder in ["tb", "rtl"] for p in (ROOT / folder).glob("*.sv")})
    print("BUILD " + name, flush=True)
    code, _ = execute(cmd, d, "compile", timeout=1800)
    require(code == 0, name + " build failed: " + str(code))
    binary = d / "obj/uvm_sim"
    save(d / "binary-sha256.json", {"sha256": A.digest(binary)})
    print("BUILD " + name + " PASS", flush=True)
    return binary


def verify_fault_gate(out, real_logs):
    """Real faulty logs must be rejected if their target is removed/relabelled."""
    results = {}
    for kind, (text, code) in real_logs.items():
        target = FAULTS[kind][1]
        for name, changed, status in [("unrelated_error", text.replace("[TXN_INTEGRITY] " + target, "[OTHER] unrelated"), code),
                                      ("wrong_target", text.replace(target, "WRONG_TARGET"), code),
                                      ("timeout", text, 124), ("nonzero_exit", text, 1)]:
            rejected = False
            try:
                fault_integrity(changed, status, kind)
            except ValueError:
                rejected = True
            require(rejected, kind + " gate incorrectly accepted " + name)
            results[kind + "/" + name] = "REJECTED"
    save(out / "fault-gate-selfcheck.json", results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--verilator", type=Path, default=ROOT / ".tools/verilator-src/bin/verilator")
    parser.add_argument("--seed", type=int, default=20261022)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True)  # Refuse to replace historical evidence.
    results = dict(status="RUNNING", seed=args.seed)
    try:
        require(subprocess.check_output(["git", "-C", str(ROOT), "branch", "--show-current"], text=True).strip()
                == "work/axi4lite-v2-integrity", "Wrong development branch")
        baseline = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "axi4lite-decerr-protection-v1^{}"], text=True).strip()
        require(baseline.startswith("9357e68"), "Plan A tag does not match frozen commit")
        subprocess.run(["git", "-C", str(ROOT), "merge-base", "--is-ancestor", baseline, "HEAD"], check=True)
        version = subprocess.check_output([str(args.verilator), "--version"], text=True)
        require("Verilator 5.052" in version, "Use approved Verilator 5.052")
        (out / "verilator-version.txt").write_text(version)
        (out / "git-status-before.txt").write_bytes(subprocess.check_output(["git", "-C", str(ROOT), "status", "--short", "--branch"]))
        (out / "head.txt").write_bytes(subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"]))
        for folder in ["rtl", "tb", "scripts"]:
            shutil.copytree(ROOT / folder, out / "sources" / folder, ignore=shutil.ignore_patterns("__pycache__"))
        for path in ["rtl/axi4lite_slave.sv", "tb/axi4lite_scoreboard.sv", "tb/axi4lite_test.sv",
                     "tb/axi4lite_sequences.sv", "tb/axi4lite_coverage.sv", "scripts/accept-coverage.py",
                     "scripts/accept-plan-a.py", "scripts/check-uvm-result.py"]:
            require((ROOT / path).read_bytes() == subprocess.check_output(["git", "-C", str(ROOT), "show", baseline + ":" + path]), "Unexpected change in " + path)
        normal = build(out, "normal", args.verilator)
        cmd = [sys.executable, str(ROOT / "scripts/accept-coverage.py"), "--binary", str(normal),
               "--out", str(out / "coverage"), "--seed", str(args.seed)]
        code, _ = execute(cmd, out, "coverage-acceptance", timeout=1200)
        require(code == 0, "Original four-test and six-bin acceptance failed")
        results["coverage"] = json.loads((out / "coverage/results.json").read_text())
        results["normal_integrity"] = {name: normal_integrity((out / "coverage" / name / "simulator.log").read_text(), name == "zero_stall")
                                       for name in results["coverage"]}
        gate = A.load_gate()
        results["plan_a_normal"] = {name: A.run_case(out / "plan-a-normal", normal, name, args.seed, gate) for name in A.CASES}
        for name in A.CASES:
            normal_integrity((out / "plan-a-normal" / name / "simulator.log").read_text())
        print("Normal Sanity/Regression/RAL/zero-stall + six bins + Plan A: PASS", flush=True)
        results["faults"] = {}
        real_logs = {}
        for kind, (macro, _, _) in FAULTS.items():
            binary = build(out, kind, args.verilator, macro)
            d = out / kind / "sanity"
            d.mkdir()
            code, text = execute([str(binary), "+UVM_TESTNAME=axi4lite_sanity_test",
                                  "+verilator+seed+" + str(args.seed)], d, "simulator")
            results["faults"][kind] = fault_integrity(text, code, kind)
            # Raw bus matches normal Sanity; only Monitor publication was changed.
            require((d / "bus.csv").read_bytes() == (out / "coverage/sanity/bus.csv").read_bytes(), "Monitor injection changed bus traffic")
            save(d / "proof.json", results["faults"][kind])
            real_logs[kind] = (text, code)
            print(macro + ": DETECTED [TXN_INTEGRITY] " + FAULTS[kind][1], flush=True)
        verify_fault_gate(out, real_logs)
        # Retain the original Plan A negative proofs under the new environment.
        alias = build(out, "plan-a-injected", args.verilator, "INJECT_DECERR_ALIAS_BUG")
        results["plan_a_injected"] = {name: A.run_case(out / "plan-a-fault", alias, name, args.seed, gate, True) for name in A.CASES}
        for name in A.CASES:
            normal_integrity((out / "plan-a-fault" / name / "simulator.log").read_text())
        d = out / "plan-a-control-sanity"
        d.mkdir()
        code, text = execute([str(alias), "+UVM_TESTNAME=axi4lite_sanity_test",
                              "+verilator+seed+" + str(args.seed)], d, "simulator")
        require(gate.check(text, code)["status"] == "PASS", "Plan A mutation broke in-range control")
        normal_integrity(text)
        fingerprints = [json.loads((out / name / "source-sha256.json").read_text())
                        for name in ["normal", *FAULTS, "plan-a-injected"]]
        require(all(x == fingerprints[0] for x in fingerprints), "Sources changed between builds")
        save(out / "source-consistency.json", {"all_five_builds_same_source": True})
        results["status"] = "PASS"
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        results.update(status="FAIL", error=str(error))
    save(out / "acceptance.json", results)
    print("PLAN_B_ACCEPTANCE=" + results["status"], flush=True)
    if results["status"] != "PASS":
        print(results.get("error", "unknown failure"), flush=True)
    return 0 if results["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
