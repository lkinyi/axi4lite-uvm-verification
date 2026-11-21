# AXI4-Lite UVM v2 Plan A verification

Status: **PASS**, 2026-11-21 (Asia/Shanghai). Plan A is complete; Plan B was not started.

Project: `/home/icverify/ic-verification/axi4lite-uvm-verification`
Branch: `work/axi4lite-v2-improvements`
HEAD and `axi4lite-coverage-v1`: `3ee46abb0260b31d29996e166146385952a3b6a8`
Evidence: `build/axi4lite-v2-plan-a-20261121-103942-azkijzjl/`

## Environment restoration

WSL runs Ubuntu 24.04.1 as `icverify`, with HOME `/home/icverify`.
The login-shell PATH omitted the existing project-local Verilator installation.
`command -v verilator` therefore returned nothing; the executable was not missing.
The restored tool is `.tools/verilator-src/bin/verilator`:

```text
Verilator 5.052 2026-09-05 rev v5.052
```

Historical `build/coverage-final-20261120-200829/compile-command.txt` and
`compile.log` used this exact installation. `scripts/local-dev.sh` only runs a
cached Day 1 UVM executable and checks its fingerprint; it does not rebuild UVM.
`sim/Makefile` provides commercial simulator targets, not this local Verilator build.

No installation, sudo, apt operation, shell startup edit, or WSL configuration edit
was performed. The compiler is called by absolute path. For an interactive shell,
the following affects only that shell:

```bash
export PATH="$PWD/.tools/verilator-src/bin:$PATH"
verilator --version
```

Two initial baseline build attempts were interrupted by WSL restarts: first with
`-j 2`, then with `-j 1` and the default grouping. Neither produced a complete
binary. The root cause of those restarts is not proven. Windows had approximately
1.2 GB free physical memory during diagnosis, and Verilator's installed docs warn
that large grouped C++ units require more memory. The successful local build uses
`-j 1 --output-groups 32 -CFLAGS -O0`, retaining `--timing --assert --coverage`.
All failed attempt logs and commands remain in `baseline/` and `baseline-serial/`.

Before any source change, a fresh `baseline-low-memory/obj/uvm_sim` was compiled
successfully and ran the original Sanity: exit 0, UVM_ERROR/FATAL 0/0, Scoreboard PASS.
Both the final normal and injected versions were then rebuilt separately from source.

## Implementation

- `rtl/axi4lite_slave.sv`: adds only the `INJECT_DECERR_ALIAS_BUG` guarded block
  in the out-of-range write branch. It preserves DECERR and deliberately writes
  the truncated legal alias using WSTRB. No normal write/read behavior changed.
- `tb/axi4lite_sequences.sv`: adds a deterministic sequence with three cases.
  Each writes a legal sentinel, reads it, attempts an OOB write, then reads the
  legal word again. Every case initializes its own memory; no undefined initial
  memory is used as evidence.
- `tb/axi4lite_test.sv`: adds `axi4lite_decerr_alias_test`,
  `axi4lite_decerr_top_test`, and `axi4lite_decerr_partial_test`.
- `tb/axi4lite_plan_a_audit.sv`: optional read-only bound bus CSV sampler,
  explicitly included only by the acceptance build. It never drives the bus or DUT.
- `scripts/accept-plan-a.py`: rebuilds both variants, runs strict normal/mutation
  gates and the unchanged four-test coverage gate, and refuses existing output paths.

Driver, Monitor, Scoreboard, Coverage, Interface/SVA, RAL, Env, Agent, sequence item,
package and top are byte-identical to HEAD. Existing sequences and tests are retained.
Removing the single new mutation block makes the DUT text byte-identical to HEAD;
see `acceptance/normal-dut-equivalence.json`. Normal and injected source hashes
match; their build commands differ by the isolated injection define and output paths.

## Test results

All test seeds: **20261022**. Assertions and coverage were enabled in both builds.

| Case | OOB -> legal | WSTRB | Sentinel / normal final | Injected final | Mutation result |
| --- | --- | --- | --- | --- | --- |
| decerr_alias | 0x420 -> 0x20 | F | 0x13579BDF | 0xECA86420 | DETECTED |
| decerr_top | 0x7FC -> 0x3FC | F | 0x2468ACE0 | 0xFDB97531 | DETECTED |
| decerr_partial | 0x424 -> 0x24 | 1 | 0xA1B2C3D4 | 0xA1B2C3EE | DETECTED |

All three normal cases: exit 0, UVM_ERROR/FATAL 0/0, writes=2, reads=2,
MATCH=2, MISMATCH=0, RESP_MISMATCH=0, Scoreboard PASS.

All three mutation cases: actual bus BRESP=3 (DECERR) on the OOB write;
the preceding legal read matches the sentinel and the following legal read is
corrupted exactly as shown. Each produces one corresponding READ MISMATCH,
writes=2, reads=2, MATCH=1, MISMATCH=1, RESP_MISMATCH=0, Scoreboard FAIL.
Each simulation completes with exit 0, UVM_ERROR=2 (READ MISMATCH plus RESULT: FAIL),
UVM_FATAL=0. These are expected detected faults, never normal DUT PASS results.
No SVA or response mismatch is used as a substitute for alias corruption.
The injected build also passes the original in-range-only Sanity control.

| Original test | Writes / reads | MATCH | Data / response mismatches | Result |
| --- | --- | --- | --- | --- |
| Sanity | 10 / 10 | 10 | 0 / 0 | PASS |
| Regression | 344 / 108 | 97 | 0 / 0 | PASS |
| RAL | 8 / 8 | 8 | 0 / 0 | PASS |
| Zero-stall coverage check | 1 / 1 | 1 | 0 / 0 | PASS |

Regression has 11 OOB reads whose data is ignored by the unchanged Scoreboard;
their DECERR responses are checked. All normal runs have exit 0 and zero UVM
errors/fatals. The unchanged `scripts/accept-coverage.py` reconciles raw bus,
Monitor and native covergroup counts for all four original tests.
Coverage totals: aw_first=36, w_first=38, same_cycle=289, zero=1, short=272,
long_stall=90. All six bins hit; both three-bin totals equal 363 real writes.

## Evidence and reproduction

`acceptance/acceptance.json` is the machine-readable overall result.
Each normal/mutation test has original `simulator.log`, process exit code,
command JSON/text, `bus.csv`, `transactions.json`, `proof.json`, and `coverage.dat`.
`acceptance/acceptance-evidence.txt` gives exact raw-log and CSV line references
for the three negative experiments. Each build retains command JSON/text,
`compile.log`, source hashes, binary hash, and its own rebuilt executable.
`acceptance/sources/` preserves the exact implementation used for compilation.
`acceptance/coverage/` contains the original four-test coverage audit and native bins.

From the project root, using a NEW output directory:

```bash
python3 scripts/accept-plan-a.py \
  --out "build/axi4lite-v2-plan-a-rerun-$(date +%Y%m%d-%H%M%S-%N)"
```

The script intentionally refuses an existing output directory. No old binary,
coverage file, cache fingerprint or latest-log pointer is replaced.
`validation/` records that refusal and six synthetic gate rejection checks;
those synthetic checks are separate from real simulation evidence.
`preservation-check.json` confirms 20,917 original build files retain size and
mtime, with 160 critical log/binary/coverage/text hashes also checked unchanged.

No Commit or Push was performed.
