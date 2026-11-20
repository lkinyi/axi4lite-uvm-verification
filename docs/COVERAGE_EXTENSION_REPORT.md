# AXI4-Lite Coverage 扩展与自动验收报告

最终状态：**PASS**。2026-11-20（Asia/Shanghai），四个 UVM 测试通过，六个新增 Bin 全部命中；363 笔真实写事务的总线采样、Monitor 观测和原生 Covergroup 计数一致。

## 一、修改摘要

项目：`/home/icverify/ic-verification/axi4lite-uvm-verification`  
分支：`work/axi4lite-verification`。起始 HEAD 见本次证据目录 `head.txt`。

| 文件 | 本次修改 |
| --- | --- |
| tb/axi4lite_seq_item.sv | 新增非随机观测字段 aw_w_order、b_stall_cycles；UNKNOWN 为未观测初值，不是覆盖 Bin |
| tb/axi4lite_monitor.sv | 用真实 AW/W 握手识别顺序；逐周期统计 BVALID && !BREADY；仍在 B 握手时通过原 analysis port 发布同一事务 |
| tb/axi4lite_coverage.sv | 新增两个仅对写事务采样的 Coverpoint，共六个 Bin；增加便于日志审阅的精确命中计数 |
| tb/axi4lite_test.sv | 新增一个 passive 的 axi4lite_zero_stall_test，提前置 BREADY=1，完成一笔 AW-first 写入并读回 |
| scripts/check-uvm-result.py | 新增统一正常/预期故障判定入口，检查进程状态、UVM 摘要、错误消息、Scoreboard、超时 |
| scripts/accept-coverage.py | 新增四测试自动验收，对独立总线 CSV、Monitor 每笔结果、日志计数、coverage.dat 原生 Bin 逐一核对 |
| scripts/local-dev.sh | 在已有用户脚本中小范围替换结果判定，保留超时进程返回码，调用统一判定器 |

原有 RAL、Scoreboard、timing sequence、16 种 WSTRB 激励、Interface SVA、INJECT_BRESP_ERR 均为已有功能。本次未改 DUT、Driver、Interface、Sequences、Env、Scoreboard、RAL，也未改原有 analysis 连接。

开始时已有的 `tb/tb_top.sv` debug probe 修改原样保留。原有 `debug/`、`.vscode/` 和 `docs/LOCAL_WORKFLOW.md` 未修改。用户原 `local-dev.sh` 完整备份在本次证据目录 `local-dev-before.sh`，其哈希与开始前快照一致；改动见 `local-dev-gate.patch`。

## 二、测试结果

所有 UVM 测试 Seed 均为 **20261022**，均启用 `--assert --coverage`。

| 测试 | 状态 | 进程退出码 | UVM_ERROR / FATAL | 写 / 读 | MATCH | 数据 / 响应 MISMATCH | Scoreboard |
| --- | --- | ---: | --- | --- | ---: | --- | --- |
| Sanity | PASS | 0 | 0 / 0 | 10 / 10 | 10 | 0 / 0 | PASS |
| Regression | PASS | 0 | 0 / 0 | 344 / 108 | 97 | 0 / 0 | PASS |
| RAL | PASS | 0 | 0 / 0 | 8 / 8 | 8 | 0 / 0 | PASS |
| Zero-stall 定向 | PASS | 0 | 0 / 0 | 1 / 1 | 1 | 0 / 0 | PASS |

Regression 有 11 笔越界读，按既有 Scoreboard 逻辑检查 DECERR、忽略数据，因此 MATCH=97 小于 reads=108。无新增错误或超时。

本次证据目录：

`build/coverage-final-20261120-200829/`

其中 `runs/results.json` 为机器可读判定；四个测试各有 `simulator.log`、`command.json`、`bus.csv`、`writes.json`、`coverage.dat`、`coverage-audit.json`。日志全部来自本次新编译二进制，没有用旧日志代替正常回归。

## 三、Coverage 结果

下表均为原生 Covergroup Bin 的实际次数，并与独立总线重建及日志计数一致。合计是四次运行命中次数之和，并非单次运行覆盖率。

| Bin（完整 Coverpoint 前缀） | Sanity | Regression | RAL | Zero-stall | 合计 | 命中 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| cp_aw_w_order.aw_first | 3 | 32 | 0 | 1 | 36 | 是 |
| cp_aw_w_order.w_first | 3 | 35 | 0 | 0 | 38 | 是 |
| cp_aw_w_order.same_cycle | 4 | 277 | 8 | 0 | 289 | 是 |
| cp_b_stall.zero | 0 | 0 | 0 | 1 | 1 | 是 |
| cp_b_stall.short（1～2） | 1 | 263 | 8 | 0 | 272 | 是 |
| cp_b_stall.long_stall（>=3） | 9 | 81 | 0 | 0 | 90 | 是 |

每个测试的 `coverage.dat` 原生 Bin 行号依次为：31855（AW-first）、31856（W-first）、31857（Same-cycle）、31858（zero）、31859（short）、31860（long_stall）。`coverage-audit.json` 记录了这些行号及原生次数。顺序三 Bin 合计与反压三 Bin 合计均为 363，等于四个 Scoreboard 的总写事务数；读事务未计入。

### 可追溯的总线证据

`bus.csv` 的 cycle 为时钟上升沿编号，第一行为表头，因此 cycle N 对应文件第 N+1 行。`writes.json` 保留每笔 AW/W/B 握手周期与所有反压周期。下表写事务编号从 1 开始。

| Bin | 测试 / 写事务 | 真实信号证据 |
| --- | --- | --- |
| AW-first | Regression / 第 279 笔（原 timing_seq） | AW 握手 cycle 2019，W 握手 cycle 2024，2019 < 2024 |
| W-first | Regression / 第 295 笔（原 timing_seq） | W 握手 cycle 2467，AW 握手 cycle 2472，2467 < 2472 |
| Same-cycle | Regression / 第 263 笔（原 timing_seq） | AWVALID&&AWREADY 与 WVALID&&WREADY 同在 cycle 1651 |
| zero | Zero-stall / 第 1 笔 | AW=7、W=15、B 握手=17；无 BVALID=1、BREADY=0 的采样 |
| short | Regression / 第 1 笔 | cycle 10 为 BVALID=1、BREADY=0；cycle 11 为 B 握手，仅计 1 |
| long_stall | Regression / 第 279 笔 | cycle 2026～2032 连续 7 次 BVALID=1、BREADY=0；2033 握手不计入 |

边界也有真实命中：Regression 第 326 笔仅在 cycle 3266、3267 反压（2 次，short），3268 握手；第 260 笔在 cycle 1603～1605 反压（3 次，long_stall），1606 握手。统计器未把等待响应期间 BVALID=0 的周期加进去。

零反压测试只发出一笔 AW-first 写事务，得到 aw_first=1、w_first=0、same_cycle=0、zero=1、short=0、long_stall=0；随后读回通过。这也检查了顺序及反压统计不会误命中其他 Bin。

原 Driver 会先看到 BVALID，再拉高 BREADY，因此 b_delay=0 的真实反压为 1，b_delay=6 的 timing_seq 真实反压为 7。原三项测试的 zero=0 是真实结果；新增 passive 定向测试才命中 zero。未改 Driver，也没有修改统计值来填覆盖率。

## 四、协议检查

- 原有 `A_B_STABLE` 位于 `tb/axi4lite_if.sv`。本次 UVM 编译启用 `--assert`，没有传入关闭断言的运行参数；生成的 C++ 中保留了该断言的条件与失败处理，证据见 `assertion-enabled.txt`。正常测试确实产生了 362 笔非零 B 反压事务，断言未失败。
- 在 build 内另建一次性接口负向 harness：保持 BVALID=1、BREADY=0，将 BRESP 从合法 0 改成合法 3。原断言在 35ns 触发 `A_B_STABLE`，仿真异常退出。这是调用原检查的负向验证，没有复制或新增同类 SVA，没有修改 DUT。见 `sva-negative.log`。
- 原有 `INJECT_BRESP_ERR` 已存在于 DUT；会把正常地址的 B 响应置为 SLVERR，也影响正常地址的 R 响应。原有 `A_BRESP_LEGAL/A_RRESP_LEGAL` 与 Scoreboard 可检测该错误。
- 可复用入口已在 `.github/workflows/regression.yml`：用 Icarus 编译 `-DINJECT_BRESP_ERR` 并运行既有 `tb_protocol`。本次在独立目录复跑该入口，首次 B response/stability 检查检测故障，退出码 1，判为 **DETECTED**。见 `bresp-build-command.json`、`bresp-run.log`。这次故障注入运行是协议测试，不冒充 UVM 正常 PASS，也未声称本次运行了 BRESP 注入的 UVM 版本。

## 五、风险与遗留问题

- 六个新增 Bin 无未覆盖项。原三测试单独运行仍不会命中 zero；请在覆盖闭环中保留新增 zero-stall 测试。
- 复用本机 Verilator 5.052 / UVM 库；Verilator 为二态仿真，不能据此宣称已验证四态 X/Z 场景。本次未运行 Questa/VCS/Xcelium。
- 正常验收要求：进程正常退出、唯一完整 UVM_ERROR/FATAL 零错误摘要、唯一 Scoreboard PASS、无实际错误/不匹配/超时/SVA 失败。超时、信号退出、缺摘要、矛盾的 PASS/FAIL 均拒绝。
- Day 4 的真实故障日志原退出码为 0，UVM_ERROR=38、UVM_FATAL=0、Scoreboard FAIL；新 gate 正确判 FAIL，预期故障模式判 DETECTED。该项明确使用历史失败日志检验 gate，未当成本次正常测试。
- gate 的干净日志、超时、信号退出、缺摘要、实际错误行、矛盾结果、非零 FATAL 共七种边界均通过，详见 `auxiliary-results.json`。
- 原 `scripts/local-dev.sh` 默认仍指向 Day 1 二进制和旧指纹。源码已经改变，它会按原有机制拒绝陈旧缓存；本次使用下面的新验收入口。为保留历史结果，没有覆盖旧二进制或重写它的指纹。
- 原 `sim/Makefile` 和远程 CI 没有全面改造；需要相同严格判定时可复用新增 gate。本次本地入口已执行完毕，没有未完成的正常测试。
- 未生成新的 VCD，没有追踪存储器数组。文件保留检查见 `preservation-check.json`。

### 复现入口

在项目根目录执行（本次已经执行完成）：

```bash
python3 scripts/accept-coverage.py \
  --binary build/coverage-final-20261120-200829/obj/uvm_sim \
  --out build/coverage-final-20261120-200829/rerun-$(date +%Y%m%d-%H%M%S) \
  --seed 20261022
```

必须使用包含独立 `bus_audit.sv` 采样器的本次二进制。源码或工具变化后，应先显式重新编译；完整编译命令在 `compile-command.txt`，复用工具的构建脚本为证据目录中的 `compile.py`。新的运行目录若已有同名测试子目录，验收脚本拒绝覆盖。

单日志判定示例：

```bash
python3 scripts/check-uvm-result.py path/to/simulator.log --exit-code 0
python3 scripts/check-uvm-result.py path/to/injected.log --exit-code 0 --expect-detected
```

第二个命令仅接受明确 mismatch/SVA 检出，输出 DETECTED，不能用来标注正常 DUT PASS。

## 六、供初学者理解的源码说明

1. **顺序判断**：Monitor 在每个 mon_cb 采样点同时计算 AWVALID&&AWREADY、WVALID&&WREADY。首次握手时，两者都真是 Same-cycle；只有 AW 真是 AW-first；只有 W 真是 W-first。先判断，再更新已接收标志，因此不会因程序里 AW 写在前面而把同周期误判成 AW-first。完全不读取 aw_delay/w_delay。
2. **反压计数**：每笔写开始时清零，每个采样点只有 BVALID=1 且 BREADY=0 才加一。BVALID=0 时不加；BVALID=1 且 BREADY=1 时发布事务，不加。Monitor 使用已有 #1step 时钟块，与真正握手所在时钟边沿对应；没有额外跳过首次 BVALID 的等待。
3. **Bin 划分**：Coverage 接收 Monitor 事务，写事务的 aw_w_order 进入三个顺序 Bin，b_stall_cycles 按 0、1～2、3 及以上进入三个反压 Bin；两处都有写方向 iff 门控。日志计数只供审阅，自动验收还核对仿真器真正写出的原生 Bin。
4. **实际新增内容**：原项目已经能发乱序 AW/W、制造响应等待并检查数据/协议。本次补上了这些行为的真实总线观测字段、独立覆盖统计、零反压最小激励，以及能识别“仿真退出码为零但验证失败”的自动判定。没有把已有 RAL、SVA 或故障注入算成本次新增功能。

## 七、最终状态

**PASS**：正常三项回归及必要的零反压测试均通过，六个 Bin 有真实命中证据，原断言启用并经负向验证，故障注入可检测，自动化能拒绝退出码为零的验证失败。

未 Commit、未 Push。原有 memory-debug 探针、调试脚本和独立波形功能均保留。
