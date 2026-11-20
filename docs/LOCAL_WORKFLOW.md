# 本机 VS Code 操作

在 Windows VS Code 中使用“文件 → 打开文件夹”，输入：
`\\wsl.localhost\Ubuntu\home\icverify\ic-verification\axi4lite-uvm-verification`。
若当前为 Windows 文件夹窗口，点击左下角远程图标，选择“在 WSL 中重新打开文件夹”。
左下角应显示 **WSL: Ubuntu**。也可双击 Windows 交付目录中的“打开项目一.cmd”。

选择菜单“终端 → 运行任务”，选择以 `IC:` 开头的任务。四个测试均复用 Day 1 编译产物；Icarus 仅在源码变化或产物缺失时快速编译。UVM 任务不会自动编译；缓存指纹变化时会停止并提示。

日志位于 `build/day15/logs`，每次执行保留独立文件；`build/day15/latest.log` 指向最近一次测试。UVM 覆盖率在对应的 `build/day15/runs` 目录，Day 1 的 coverage.dat 不被覆盖。

首次看波形先运行“IC: 生成真实 AXI4-Lite 波形”，等待 `TASK_RESULT=PASS`，再运行“IC: 打开仿真波形（GTKWave）”。波形来自原协议测试驱动的真实 DUT；Sanity、Regression、RAL 的 Day 1 二进制没有开启 trace，不会产生 UVM 波形。

GTKWave 默认已加载 AXI 五个通道信号。左侧 SST 展开 `tb_protocol_wave → protocol`，点选需要的信号后点击 **Append**；按 Ctrl 或 Shift 可多选。用工具栏放大/缩小，在波形上点击设置时间标记。重点看时钟上升沿 `VALID=1` 且 `READY=1` 的握手；AW/W 为写请求，B 为写响应，AR 为读请求，R 为读响应。总线右键可选十六进制显示。选择“File → Write Save File As”将个人布局保存到 build/day15 下。

Git origin 为个人 Fork，upstream 为原作者。当前开发分支是 `work/axi4lite-verification`。任务中不含提交或 Push。验收后如需上传，先审阅并提交新增配置，再单独 Push 当前个人分支。

公开仓库的 fetch 成功只证明读取可用，不能证明上传认证。本仓库已配置 WSL Git 调用现有 Windows Git Credential Manager 2.5.0，未主动读取凭据或发起登录。验收并同意上传后，在 VS Code 源代码管理中审阅并提交这五个新增文件，再对个人开发分支选择“发布分支”，目标选 origin；若弹出 GitHub 登录，选择浏览器登录，由你在浏览器确认 lkinyi 账户并完成双重验证。当前不要点击发布分支。不要把 Token 写入 remote 或交给聊天。写权限和上传认证尚未验证。

项目二地址仅记录：https://github.com/lkinyi/verilog-axi.git ，未安装或执行。
