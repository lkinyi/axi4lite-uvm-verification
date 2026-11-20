# GTKWave memory debug

From the project root in Ubuntu/WSLg:

```bash
bash debug/trace-memory.sh
```

This runs the existing UVM regression with seed 20261022 in a new
`build/uvm-mem-debug/run.*` directory and opens GTKWave with the grouped preset.
The first invocation compiles a separate binary. Identical sources, tool version
and probe selection reuse that binary; every simulation still gets a new run
folder, VCD, coverage file and log. Previous regression evidence is preserved.

Useful variants:

```bash
MEM_WORDS=4,5 bash debug/trace-memory.sh   # also observe debug_mem5
bash debug/trace-memory.sh --no-gui      # simulate and check without opening GUI
bash debug/trace-memory.sh --view        # reopen latest successful run
```

`MEM_WORDS` accepts 1 to 16 unique decimal word indices in 0..255. It changes
only the generated continuous read probes and the Memory section of the preset.
The byte address of a selected word is its index times four.

`tb/tb_top.sv` includes the generated `axi4lite_debug_probes.svh` only when
`AXI4LITE_DEBUG_PROBES` is defined by this script. A probe such as
`wire [31:0] debug_mem4 = dut.mem[4];` reads actual DUT storage and drives nothing
in the DUT. Ordinary builds have no probe enabled. There are no changes to DUT,
scoreboard, driver or sequences.

The script deliberately omits `--trace-max-array 256` and
`--trace-max-width 8192`. The bundled Verilator defaults (32 array elements,
4096 total bits) exclude the 256 x 32-bit unpacked memory. Selected 32-bit
probes, AXI signals and DUT controls remain traceable. This reduces actual VCD
contents; it does not merely hide memory words using GTKWave. It avoids relying
on `$dumpvars` to select individual unpacked memory elements in Verilator.

The reusable preset is `debug/axi4lite-memory.gtkw`. Each run gets its own copy,
with selected probes substituted, so GUI saves do not overwrite the template.
Groups: Clock/Reset, Write, Read, DUT Internal, Memory. Buses use hexadecimal.
`build/uvm-mem-debug/latest` points to the latest successful run.

Inspect `trace-check.json`, `result.txt`, `run/simulator.log` and
`compile-command.txt` inside a run folder for validation and build provenance.
The checker requires zero direct memory array entries, valid preset signal
names, changing debug_mem4 when selected, matching address 0x10 write commits,
and unchanged scoreboard statistics versus the original trace regression.
A different selected word can legitimately remain constant in the existing test.
No Day 4 timing or protocol analysis is performed by this tool.
