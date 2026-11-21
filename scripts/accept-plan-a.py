#!/usr/bin/env python3
"""Rebuild normal/mutated UVM, prove DECERR alias protection, run v1 coverage.
Every invocation requires a fresh --out directory and preserves raw evidence.
"""
import argparse
import csv
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
CASES = {
    "decerr_alias": (0x20, 0x420, 0x13579BDF, 0xECA86420, 15),
    "decerr_top": (0x3FC, 0x7FC, 0x2468ACE0, 0xFDB97531, 15),
    "decerr_partial": (0x24, 0x424, 0xA1B2C3D4, 0x556677EE, 1),
}
PROTECTED = ["axi4lite_driver.sv", "axi4lite_monitor.sv", "axi4lite_scoreboard.sv",
             "axi4lite_coverage.sv", "axi4lite_if.sv", "axi4lite_seq_item.sv",
             "axi4lite_agent.sv", "axi4lite_env.sv", "axi4lite_ral.sv",
             "axi4lite_pkg.sv", "tb_top.sv"]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_gate():
    spec = importlib.util.spec_from_file_location("uvm_gate", ROOT / "scripts/check-uvm-result.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def execute(cmd, directory, label, timeout=600):
    save(directory / (label + "-command.json"), cmd)
    (directory / (label + "-command.txt")).write_text(shlex.join(cmd) + "\n")
    try:
        with (directory / (label + ".log")).open("w") as stream:
            code = subprocess.run(cmd, cwd=directory, stdout=stream,
                                  stderr=subprocess.STDOUT, timeout=timeout).returncode
    except subprocess.TimeoutExpired:
        code = 124
    save(directory / (label + "-exit.json"), {"exit_code": code})
    return code, (directory / (label + ".log")).read_text(errors="replace")


def build(out, name, verilator):
    d = out / name
    d.mkdir()
    cmd = [str(verilator), "--binary", "--timing", "--assert", "--coverage",
           "-Wno-fatal", "-j", "1", "--output-groups", "32", "-CFLAGS", "-O0",
           "+define+UVM_NO_DPI"]
    if name == "injected":
        cmd.append("+define+INJECT_DECERR_ALIAS_BUG")
    cmd += ["+incdir+" + str(ROOT / ".tools/uvm/src"), "+incdir+" + str(ROOT / "tb")]
    cmd += [str(ROOT / f) for f in [".tools/uvm/src/uvm_pkg.sv", "tb/axi4lite_if.sv",
            "tb/axi4lite_pkg.sv", "rtl/axi4lite_slave.sv", "tb/tb_top.sv",
            "tb/axi4lite_plan_a_audit.sv"]]
    cmd += ["--top-module", "tb_top", "--Mdir", str(d / "obj"), "-o", "uvm_sim"]
    inputs = {str(p.relative_to(ROOT)): digest(p) for folder in ["tb", "rtl"]
              for p in (ROOT / folder).glob("*.sv")}
    save(d / "source-sha256.json", inputs)
    print("BUILD " + name, flush=True)
    code, _ = execute(cmd, d, "compile", timeout=1200)
    require(code == 0, name + " build failed: " + str(code))
    binary = d / "obj/uvm_sim"
    save(d / "binary-sha256.json", {"sha256": digest(binary)})
    print("BUILD " + name + " PASS", flush=True)
    return binary


def bus_transactions(directory):
    aw = w = ar = None
    events = []
    with (directory / "bus.csv").open() as stream:
        for line, row in enumerate(csv.DictReader(stream), 2):
            if row["resetn"] == "0":
                aw = w = ar = None
                continue
            cycle = int(row["cycle"])
            if row["awvalid"] == row["awready"] == "1":
                require(aw is None, "Duplicate outstanding AW")
                aw = dict(addr=int(row["awaddr"], 16), aw_cycle=cycle, aw_line=line)
            if row["wvalid"] == row["wready"] == "1":
                require(w is None, "Duplicate outstanding W")
                w = dict(data=int(row["wdata"], 16), strb=int(row["wstrb"], 16),
                         w_cycle=cycle, w_line=line)
            if row["bvalid"] == row["bready"] == "1":
                require(aw is not None and w is not None, "Unpaired B")
                events.append(dict(kind="write", **aw, **w, resp=int(row["bresp"]),
                                   cycle=cycle, line=line))
                aw = w = None
            if row["arvalid"] == row["arready"] == "1":
                require(ar is None, "Duplicate outstanding AR")
                ar = dict(addr=int(row["araddr"], 16), ar_cycle=cycle, ar_line=line)
            if row["rvalid"] == row["rready"] == "1":
                require(ar is not None, "Unpaired R")
                events.append(dict(kind="read", **ar, data=int(row["rdata"], 16),
                                   resp=int(row["rresp"]), cycle=cycle, line=line))
                ar = None
    require(aw is None and w is None and ar is None, "Incomplete trailing transaction")
    save(directory / "transactions.json", events)
    return events


def audit_case(directory, name, injected, text, gate):
    legal, alias, sentinel, poison, mask = CASES[name]
    byte_mask = sum(0xff << (8 * b) for b in range(4) if mask & (1 << b))
    corrupt = (sentinel & ~byte_mask) | (poison & byte_mask)
    final_value = corrupt if injected else sentinel
    events = bus_transactions(directory)
    actual = [(e["kind"], e["addr"], e["data"], e.get("strb", 0), e["resp"]) for e in events]
    expected = [("write", legal, sentinel, 15, 0), ("read", legal, sentinel, 0, 0),
                ("write", alias, poison, mask, 3), ("read", legal, final_value, 0, 0)]
    require(actual == expected, "Raw bus transaction mismatch: " + repr(actual))
    summaries = re.findall(r"\[SCB\] writes=(\d+) reads=(\d+) MATCH=(\d+) MISMATCH=(\d+) RESP_MISMATCH=(\d+)", text)
    require(summaries == [("2", "2", "1" if injected else "2", "1" if injected else "0", "0")],
            "Unexpected scoreboard counters: " + repr(summaries))
    mismatches = re.findall(r"READ MISMATCH addr=0x([0-9a-f]+) expected=0x([0-9a-f]+) got=0x([0-9a-f]+)", text)
    if injected:
        require(gate["status"] == "FAIL" and gate["fault_detected"] and gate["exit_code"] == 0
                and gate["uvm_error"] == 2 and gate["uvm_fatal"] == 0
                and gate["scoreboard"] == "FAIL" and not gate["timeout"], "Fault must complete with only the intended errors")
        require(mismatches == [(f"{legal:08x}", f"{sentinel:08x}", f"{corrupt:08x}")], "Wrong READ MISMATCH")
        diagnostics = re.findall(r"^UVM_ERROR\s+(?!:).*$", text, re.M)
        require(len(diagnostics) == 2 and sum("READ MISMATCH" in x for x in diagnostics) == 1
                and sum("RESULT: FAIL" in x for x in diagnostics) == 1, "Unexpected UVM diagnostic")
        require("RESP MISMATCH" not in text and "[SVA]" not in text, "Response/SVA failure is not alias detection")
    else:
        require(gate["status"] == "PASS" and not mismatches, "Normal test did not pass")
    proof = dict(acceptance="DETECTED" if injected else "PASS", legal_address=f"0x{legal:03x}",
                 alias_address=f"0x{alias:03x}", wstrb=mask, bresp=events[2]["resp"],
                 before=f"0x{sentinel:08x}", after=f"0x{final_value:08x}",
                 resp_mismatches=0, data_mismatches=int(injected),
                 bus_file="bus.csv", evidence_lines=[e["line"] for e in events],
                 gate=gate)
    save(directory / "proof.json", proof)
    return proof


def run_case(out, binary, name, seed, gate_module, injected=False):
    d = out / name
    d.mkdir(parents=True)
    cmd = [str(binary), "+UVM_TESTNAME=axi4lite_" + name + "_test",
           "+verilator+seed+" + str(seed), "+UVM_VERBOSITY=UVM_HIGH", "+AXI_COV_TRACE"]
    code, text = execute(cmd, d, "simulator")
    result = audit_case(d, name, injected, text, gate_module.check(text, code))
    print(name + ": " + result["acceptance"] + " BRESP=DECERR after=" + result["after"], flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--verilator", type=Path, default=ROOT / ".tools/verilator-src/bin/verilator")
    parser.add_argument("--seed", type=int, default=20261022)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True)  # Refuse to overwrite ANY existing evidence directory.
    verilator = args.verilator.resolve()
    results = {"status": "RUNNING", "seed": args.seed}
    try:
        require(verilator.is_file() and os.access(verilator, os.X_OK), "Verilator unavailable")
        version = subprocess.check_output([str(verilator), "--version"], text=True)
        require("Verilator 5.052" in version, "This acceptance uses the approved Verilator 5.052")
        (out / "verilator-version.txt").write_text(version)
        (out / "head.txt").write_text(subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True))
        (out / "working-tree.patch").write_bytes(subprocess.check_output(["git", "-C", str(ROOT), "diff", "axi4lite-coverage-v1", "--binary"]))
        preservation = {}
        for name in PROTECTED:
            path = "tb/" + name
            original = subprocess.check_output(["git", "-C", str(ROOT), "show", "HEAD:" + path])
            require(original == (ROOT / path).read_bytes(), "Protected source changed: " + path)
            preservation[path] = digest(ROOT / path)
        original = subprocess.check_output(["git", "-C", str(ROOT), "show", "axi4lite-coverage-v1:rtl/axi4lite_slave.sv"], text=True)
        stripped, count = re.subn(r"^`ifdef INJECT_DECERR_ALIAS_BUG\n.*?^`endif\n", "",
                                 (ROOT / "rtl/axi4lite_slave.sv").read_text(), flags=re.M | re.S)
        require(count == 1 and stripped == original, "Normal DUT must equal HEAD with mutation block omitted")
        save(out / "normal-dut-equivalence.json", {"guarded_blocks": count, "matches_HEAD": True,
                                                   "protected_source_sha256": preservation})
        sources = out / "sources"
        for folder in ["rtl", "tb", "scripts"]:
            shutil.copytree(ROOT / folder, sources / folder, ignore=shutil.ignore_patterns("__pycache__"))
        gate = load_gate()
        normal = build(out, "normal", verilator)
        results["normal"] = {name: run_case(out / "normal-tests", normal, name, args.seed, gate) for name in CASES}
        # Reuse the existing four-test gate and native-bin/bus/monitor reconciliation unchanged.
        cmd = [sys.executable, str(ROOT / "scripts/accept-coverage.py"), "--binary", str(normal),
               "--out", str(out / "coverage"), "--seed", str(args.seed)]
        code, _ = execute(cmd, out, "coverage-acceptance", timeout=1200)
        results["coverage"] = json.loads((out / "coverage/results.json").read_text())
        require(code == 0 and all(r["status"] == "PASS" for r in results["coverage"].values()), "Original coverage acceptance failed")
        print("Sanity/Regression/RAL/zero-stall + native coverage: PASS", flush=True)
        injected = build(out, "injected", verilator)
        require(json.loads((out / "normal/source-sha256.json").read_text()) ==
                json.loads((out / "injected/source-sha256.json").read_text()), "Sources changed between builds")
        results["injected"] = {name: run_case(out / "fault-tests", injected, name, args.seed, gate, True) for name in CASES}
        d = out / "injected-control-sanity"
        d.mkdir()
        code, text = execute([str(injected), "+UVM_TESTNAME=axi4lite_sanity_test",
                              "+verilator+seed+" + str(args.seed)], d, "simulator")
        results["injected_control_sanity"] = gate.check(text, code)
        require(results["injected_control_sanity"]["status"] == "PASS", "Mutation affected in-range Sanity")
        results["status"] = "PASS"
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        results.update(status="FAIL", error=str(error))
    save(out / "acceptance.json", results)
    print("PLAN_A_ACCEPTANCE=" + results["status"], flush=True)
    return 0 if results["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
