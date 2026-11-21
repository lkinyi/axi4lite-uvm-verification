# AXI4-Lite UVM v2 Plan B: completed transaction integrity

Status: **PASS**, 2026-11-21 (Asia/Shanghai). Uncommitted review only.

Development branch: `work/axi4lite-v2-integrity`.
Frozen Plan A baseline: `9357e68ba14f367f40840828de95db9173115712`,
tag `axi4lite-decerr-protection-v1`.

## Contract and implementation

`axi4lite_integrity_checker` checks consistency of **completed transaction
records**. The Driver reference is not independent bus truth. This work does
not prove that every bus request was accepted or completed and does not add
outstanding tracking, interrupted-reset recovery, or DUT functionality.

The Driver waits until a sampled BVALID/BREADY or RVALID/RREADY handshake.
It captures the accepted response (and accepted read data), copies the sequence
item into a new object, and publishes it through `completed_ap` before
`item_done()`. The sequence may subsequently reuse its own item safely.
Clocking inputs retain the existing `#1step` sampling; output skew is unchanged.

The Monitor still publishes on response handshakes. Env adds two connections:
Driver completion AP -> Checker, Monitor AP -> Checker. Existing Monitor ->
Scoreboard and Monitor -> Coverage connections remain. Agent creation and the
existing active/passive configuration are reused.

Checker callbacks copy each received record into private, per-direction queues.
No comparison takes place in a callback, so which publisher runs first in a
simulation time slot does not affect the result. In `check_phase` it:

- checks Monitor counts against actual Scoreboard `writes` and `reads`;
- for an active agent, checks Driver/Monitor counts and compares corresponding
  per-direction records in completion order;
- explicitly compares write `dir`, `addr`, `data`, `strb`, `resp` and read
  `dir`, `addr`, `data`, `resp`; read strobes, stimulus delays, and coverage
  metadata do not participate;
- checks Scoreboard counts against Driver completions as a separate assertion.

No transaction identity is inferred from a class handle. Queues are retained
until end-of-test, which is sufficient for this bounded serial Driver suite.
A missing or extra record can shift later positional comparisons and produce
additional field mismatch diagnostics; these are not additional injected faults.
`EXTRA_MON_READ` means duplicate/extra publication relative to the Driver stream;
this checker cannot infer the physical cause of an arbitrary extra record.

Passive zero-stall has no normal Driver completion stream. It emits
`RESULT: SKIP_ACTIVE`, checks only Monitor/Scoreboard counts, and makes no claim
of Driver/Monitor reconciliation. It still runs the original coverage audit.

## Change list

- `tb/axi4lite_driver.sv`: completion AP, actual response handshake confirmation,
  accepted response capture, and independent publication copy.
- `tb/axi4lite_monitor.sv`: three separately compiled, one-shot read mutations.
- `tb/axi4lite_integrity_checker.sv`: new independent integrity component.
- `tb/axi4lite_env.sv`: creates Checker and connects both transaction paths;
  provides Scoreboard counters and active/passive state.
- `tb/axi4lite_pkg.sv`: includes Checker in dependency order.
- `scripts/accept-plan-b.py`: independent builds, strict target-specific negative
  gates, unchanged original coverage audit and Plan A proof reuse.
- `docs/PLAN_B_VERIFICATION.md`: contract, reproduction, and measured results.

DUT, Scoreboard, Agent, interface/SVA, sequence item, sequences, tests, RAL,
Coverage and all original acceptance scripts are unchanged from frozen Plan A.
`accept-plan-a.py` intentionally requires its protected sources to match HEAD,
so its standalone preflight rejects uncommitted Plan B changes. The new runner
reuses its unchanged case runner, raw-bus parser and strict normal/negative
proof gates, while enforcing the Plan B preservation boundary instead.

## Reproduction and evidence

Run from `/home/icverify/ic-verification/axi4lite-uvm-verification`:

```bash
python3 scripts/accept-plan-b.py \
  --out "build/axi4lite-v2-plan-b-rerun-$(date +%Y%m%d-%H%M%S-%N)"
```

Every invocation refuses an existing output directory. The real rejection
check is saved in `validation/existing-out-rejection.json` and its log. It uses the existing
Verilator 5.052 installation and UVM 2020.3.1 with
`--binary --timing --assert --coverage -Wno-fatal -j 1 --output-groups 32 -CFLAGS -O0`.
Successful builds use new output directories with no historical binary cache reuse.
There is no reinstall, `clean`, commit or push.

The normal build has only `+define+UVM_NO_DPI`. Each Monitor fault build adds
exactly one of `+define+INJECT_MON_DROP_READ`, `+define+INJECT_MON_DUP_READ`, or
`+define+INJECT_MON_CORRUPT_READ`. A fifth independent build adds only the
original `+define+INJECT_DECERR_ALIAS_BUG` for Plan A negative regression.

Each build directory retains exact `compile-command.txt` / JSON, compiler log,
exit status, SV input hashes, executable hash and generated executable.
Each test retains its simulation command, log, raw bus CSV and native coverage.
The four normal raw bus CSV files are byte-identical to the frozen Plan A
acceptance evidence (`plan-a-bus-equivalence.json`).
The runner saves source snapshots and overall `acceptance.json`.

The three Monitor experiments affect the first completed read of Sanity.
Drop and duplicate must leave the original Scoreboard at PASS while the new
Checker emits the specific `MISSING_MON_READ` or `EXTRA_MON_READ` error.
Corruption flips read data bit 0 and must emit `FIELD_MISMATCH_READ` at index 0
with `fields= data`; its one expected Scoreboard read mismatch is also checked.
Fault gates require normal simulation completion, zero fatals, exact counters,
a single injection marker, only allowed diagnostics and a complete error summary.
Raw bus CSV must be byte-identical to normal Sanity for all three experiments.
Unrelated errors, wrong/missing target IDs, nonzero exits and timeouts are rejected.
These negative tests are reported as DETECTED, never as normal DUT PASS.
The nested `gate` object is the unchanged legacy data/response/SVA gate. Its
`fault_detected` flag does not recognize new integrity-only errors (and is false
for drop/duplicate). Plan B acceptance is the separate target-specific
`acceptance: DETECTED` plus `target_errors`, counters and allowed diagnostics.

## Build interruption and recovery

The original acceptance process was interrupted during duplicate-build C++
compilation when WSL restarted at approximately 12:29 on 2026-11-21.
It did not produce a completed build exit status or an overall acceptance result.
`duplicate/` retains the interrupted artifacts; they are excluded from acceptance.
Windows System Event 2004 at 12:29:44 reports virtual memory exhaustion, including
DWM and WSL allocations (`windows-resource-event.json`). This is supporting
resource-pressure evidence; the complete restart cause is not established.

After restart all SV source hashes and the completed normal/drop binary hashes
were verified unchanged. Completed test gates were re-evaluated. Remaining
builds use the identical Verilator flags, with a task-local systemd user scope
limiting RAM to 2500 MiB and swap to 1 GiB. No persistent WSL/system configuration
or unrelated application was changed. `resume-after-interruption.py` imports the
same unmodified Plan B build/acceptance functions and saves progress per stage.
The successful duplicate retry lives under `recovery/duplicate/`.
`recovery-resources.json` records cgroup limits, peak and OOM events.

The task-local resource limit can also wrap a fresh full run:

```bash
systemd-run --user --scope -p MemoryMax=2500M -p MemorySwapMax=1G \
  python3 scripts/accept-plan-b.py \
  --out "build/axi4lite-v2-plan-b-rerun-$(date +%Y%m%d-%H%M%S-%N)"
```

## Measured acceptance (2026-11-21, Asia/Shanghai)

**PLAN_B_ACCEPTANCE=PASS**. All seeds are `20261022`.

Full evidence directory: `/home/icverify/ic-verification/axi4lite-uvm-verification/build/axi4lite-v2-plan-b-20261121-121449-319352`.

| Original test | Driver W/R | Monitor W/R | Scoreboard W/R | Active integrity | UVM errors/fatals |
| --- | --- | --- | --- | --- | --- |
| sanity | 10/10 | 10/10 | 10/10 | PASS | 0/0 |
| regression | 344/108 | 344/108 | 344/108 | PASS | 0/0 |
| ral | 8/8 | 8/8 | 8/8 | PASS | 0/0 |
| zero_stall | 0/0 | 1/1 | 1/1 | SKIP_ACTIVE | 0/0 |

All four original test gates and the unchanged native-bin/raw-bus/Monitor audit passed.
Six-bin totals: `{"aw_first": 36, "long_stall": 90, "same_cycle": 289, "short": 272, "w_first": 38, "zero": 1}`. All six bins hit.

| Isolated Monitor fault | Driver W/R | Monitor = Scoreboard W/R | Target error | Original Scoreboard | Result |
| --- | --- | --- | --- | --- | --- |
| drop | 10/10 | 10/9 | MISSING_MON_READ | PASS | DETECTED |
| duplicate | 10/10 | 10/11 | EXTRA_MON_READ | PASS | DETECTED |
| corrupt | 10/10 | 10/10 | FIELD_MISMATCH_READ | FAIL | DETECTED |

Target diagnostics below are copied verbatim from real simulator logs, not synthetic examples.

`drop/sanity/simulator.log`:
```text
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_monitor.sv(98) @ 305000: uvm_test_top.env.agent.mon [MON_INJECT] INJECT_MON_DROP_READ first completed read
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_integrity_checker.sv(79) @ 2395000: uvm_test_top.env.integrity [TXN_INTEGRITY] COUNTS active=1 driver_writes=10 driver_reads=10 monitor_writes=10 monitor_reads=9 scoreboard_writes=10 scoreboard_reads=9
UVM_ERROR /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_integrity_checker.sv(42) @ 2395000: uvm_test_top.env.integrity [TXN_INTEGRITY] MISSING_MON_READ driver=10 monitor=9 missing=1
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_integrity_checker.sv(95) @ 2395000: uvm_test_top.env.integrity [TXN_INTEGRITY] RESULT: FAIL errors=11
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_scoreboard.sv(75) @ 2395000: uvm_test_top.env.sb [SCB] RESULT: PASS
[MON_INJECT]     1
```

`recovery/duplicate/sanity/simulator.log`:
```text
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_monitor.sv(115) @ 305000: uvm_test_top.env.agent.mon [MON_INJECT] INJECT_MON_DUP_READ first completed read
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_integrity_checker.sv(79) @ 2395000: uvm_test_top.env.integrity [TXN_INTEGRITY] COUNTS active=1 driver_writes=10 driver_reads=10 monitor_writes=10 monitor_reads=11 scoreboard_writes=10 scoreboard_reads=11
UVM_ERROR /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_integrity_checker.sv(42) @ 2395000: uvm_test_top.env.integrity [TXN_INTEGRITY] EXTRA_MON_READ duplicate/extra publication driver=10 monitor=11 extra=1
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_integrity_checker.sv(95) @ 2395000: uvm_test_top.env.integrity [TXN_INTEGRITY] RESULT: FAIL errors=11
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_scoreboard.sv(75) @ 2395000: uvm_test_top.env.sb [SCB] RESULT: PASS
[MON_INJECT]     1
```

`corrupt/sanity/simulator.log`:
```text
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_monitor.sv(106) @ 305000: uvm_test_top.env.agent.mon [MON_INJECT] INJECT_MON_CORRUPT_READ first read data bit 0
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_integrity_checker.sv(79) @ 2395000: uvm_test_top.env.integrity [TXN_INTEGRITY] COUNTS active=1 driver_writes=10 driver_reads=10 monitor_writes=10 monitor_reads=10 scoreboard_writes=10 scoreboard_reads=10
UVM_ERROR /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_integrity_checker.sv(42) @ 2395000: uvm_test_top.env.integrity [TXN_INTEGRITY] FIELD_MISMATCH_READ index=0 fields= data driver={AXI_READ addr=0x00000068 data=0x79c5ebcf strb=0xf resp=0} monitor={AXI_READ addr=0x00000068 data=0x79c5ebce strb=0x0 resp=0}
UVM_INFO /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_integrity_checker.sv(95) @ 2395000: uvm_test_top.env.integrity [TXN_INTEGRITY] RESULT: FAIL errors=1
UVM_ERROR /home/icverify/ic-verification/axi4lite-uvm-verification/tb/axi4lite_scoreboard.sv(77) @ 2395000: uvm_test_top.env.sb [SCB] RESULT: FAIL
[MON_INJECT]     1
```

All three Monitor mutations preserve byte-identical raw bus traffic to normal Sanity.
The negative-gate selfcheck rejected all 12 altered-log/exit cases (target relabelled, wrong target, timeout, nonzero exit).

All three normal Plan A cases passed with Driver=Monitor=Scoreboard=2 writes/2 reads.
All three original Plan A DUT mutation cases were DETECTED by the original strict alias-proof gate,
with zero integrity errors: the Driver and Monitor agree on the same genuinely corrupted bus data.
The Plan A injected in-range Sanity control passed with 10 writes/10 reads.
This separates completed-record consistency from the independent memory-model data check.

Historical build preservation: 39,436 files retained identical size/mtime; 306 critical/text/coverage hashes also unchanged.
All five builds used identical SV source hashes; only the isolated fault define and output paths differ.
No historical evidence was removed or replaced. HEAD and frozen tag remain at `9357e68`.
No Commit, Push or staging was performed.

For exact normal and fault build commands, see `normal/compile-command.txt`,
`drop/compile-command.txt`, `recovery/duplicate/compile-command.txt`, `corrupt/compile-command.txt`,
and `plan-a-injected/compile-command.txt` in the evidence directory.
`review.diff` includes the four tracked edits and all three new files, including this report.
`fault-gate-selfcheck.json`, `source-consistency.json`, `preservation-check.json` and
`acceptance.json` provide machine-readable verification.
