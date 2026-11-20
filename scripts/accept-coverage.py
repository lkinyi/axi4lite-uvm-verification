#!/usr/bin/env python3
"""Run four real UVM tests and reconcile raw-edge CSV, monitor and native bins.
Build the simulator with the evidence directory's bus_audit.sv first.
"""
import argparse
import csv
import importlib.util
import json
import re
import subprocess
import sys
sys.dont_write_bytecode = True
from collections import Counter
from pathlib import Path

TESTS = ["sanity", "regression", "ral", "zero_stall"]
BINS = ["aw_first", "w_first", "same_cycle", "zero", "short", "long_stall"]


def audit(directory, text):
    aw = w = None
    stalls = []
    writes = []
    for row in csv.DictReader((directory / "bus.csv").open()):
        cycle = int(row["cycle"])
        if row["resetn"] == "0":
            aw = w = None
            stalls = []
            continue
        if row["awvalid"] == row["awready"] == "1":
            assert aw is None, "Unexpected second outstanding AW"
            aw = (cycle, row["awaddr"])
        if row["wvalid"] == row["wready"] == "1":
            assert w is None, "Unexpected second outstanding W"
            w = cycle
        if row["bvalid"] == "1" and row["bready"] == "0":
            stalls.append(cycle)
        if row["bvalid"] == row["bready"] == "1":
            assert aw is not None and w is not None, "Unpaired B response"
            order = "aw_first" if aw[0] < w else "w_first" if w < aw[0] else "same_cycle"
            n = len(stalls)
            writes.append(dict(addr=aw[1], aw_cycle=aw[0], w_cycle=w, b_cycle=cycle,
                               order=order, b_stalls=n, stall_cycles=stalls,
                               b_bin="zero" if n == 0 else "short" if n <= 2 else "long_stall"))
            aw = w = None
            stalls = []
    assert aw is None and w is None and not stalls, "Incomplete trailing write"
    observed = re.findall(r"\[COV_WRITE\] addr=([0-9a-f]+) order=(\w+) b_stalls=(\d+)", text)
    assert len(observed) == len(writes) > 0, "Monitor write count differs from bus"
    for expected, (addr, order, count) in zip(writes, observed):
        assert (addr, order.lower(), int(count)) == (expected["addr"], expected["order"], expected["b_stalls"]), (expected, addr, order, count)
    counts = {b: 0 for b in BINS}
    for wr in writes:
        counts[wr["order"]] += 1
        counts[wr["b_bin"]] += 1
    match = re.search(r"\[COV_BINS\] (.*)", text)
    assert match, "Coverage hit summary missing"
    portable = {key: int(value) for key, value in re.findall(r"(\w+)=(\d+)", match[1])}
    assert portable == counts, (portable, counts)
    native = {}
    evidence = {}
    for line_no, line in enumerate((directory / "coverage.dat").read_text().splitlines(), 1):
        if "\x01t\x02covergroup" not in line:
            continue
        for cp, bins in [("cp_aw_w_order", BINS[:3]), ("cp_b_stall", BINS[3:])]:
            for name in bins:
                if f".{cp}.{name}' " in line:
                    native[name] = int(line.rsplit(" ", 1)[1])
                    evidence[name] = dict(file="coverage.dat", line=line_no)
    assert native == counts, ("Native covergroup differs", native, counts)
    scb = re.search(r"\[SCB\] writes=(\d+) reads=(\d+) MATCH=(\d+) MISMATCH=(\d+) RESP_MISMATCH=(\d+)", text)
    assert scb and int(scb[1]) == len(writes) and int(scb[2]) > 0
    (directory / "writes.json").write_text(json.dumps(writes, indent=2) + "\n")
    (directory / "coverage-audit.json").write_text(json.dumps(dict(
        counts=counts, native=native, native_evidence=evidence,
        stall_histogram=dict(Counter(wr["b_stalls"] for wr in writes)),
        all_transactions_match=True), indent=2) + "\n")
    return dict(counts=counts, writes=int(scb[1]), reads=int(scb[2]),
                matches=int(scb[3]), mismatches=int(scb[4]), resp_mismatches=int(scb[5]),
                all_transactions_match=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--seed", type=int, default=20261022)
    args = parser.parse_args()
    binary = args.binary.resolve()
    args.out.mkdir(parents=True, exist_ok=True)
    gate_file = Path(__file__).with_name("check-uvm-result.py")
    spec = importlib.util.spec_from_file_location("gate", gate_file)
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    results = {}
    for name in TESTS:
        d = args.out / name
        d.mkdir()  # Never overwrite previous evidence.
        cmd = [str(binary), "+UVM_TESTNAME=axi4lite_" + name + "_test",
               "+verilator+seed+" + str(args.seed), "+AXI_COV_TRACE"]
        (d / "command.json").write_text(json.dumps(cmd, indent=2) + "\n")
        try:
            with (d / "simulator.log").open("w") as f:
                proc = subprocess.run(cmd, cwd=d, stdout=f, stderr=subprocess.STDOUT, timeout=600)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            code = 124
        text = (d / "simulator.log").read_text(errors="replace")
        result = gate.check(text, code)
        result["seed"] = args.seed
        try:
            result.update(audit(d, text))
            if name == "zero_stall":
                assert result["counts"] == dict(aw_first=1, w_first=0, same_cycle=0, zero=1, short=0, long_stall=0)
        except (AssertionError, OSError, ValueError) as error:
            result.update(status="FAIL", audit_error=str(error))
        results[name] = result
        (args.out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(name + ": " + json.dumps(result), flush=True)
    totals = {b: sum(row.get("counts", {}).get(b, 0) for row in results.values()) for b in BINS}
    covered = all(totals.values())
    (args.out / "coverage-total.json").write_text(json.dumps(totals, indent=2) + "\n")
    passed = covered and all(row["status"] == "PASS" for row in results.values())
    print("ACCEPTANCE=" + ("PASS" if passed else "FAIL"), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
