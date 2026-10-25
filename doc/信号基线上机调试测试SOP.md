# 信号基线识别与校正 上机调试测试 SOP

> 日期：2026-10-25
> 分支：`refactor/baseline`（Vivado `0c09099`、Vitis `bd02304`、Desktop `develop@b93090b`）
> 关联文档：《信号基线自动识别与基线校正设计方案》《信号基线开发记录小结》
> 验证对象：阶段3 + 阶段4 已实现功能 —— ACQUIRE/TRACK 基线估计、相对阈值、`baseline_en` 门控、运行时参数、寄存器回读、UDP 命令映射（HMI 基线调试台），以及本次的**滤波器求和溢出修复**

---

## 0. 本次修改记录（上机验证前必读）

| # | 修改项 | 位置 | 说明 |
|---|---|---|---|
| 1 | **滤波器求和溢出修复（根因）** | `ad_data_filter.v` | 4 个 18-bit 样本求和未显式符号扩展到 20-bit，当输入 > 32768 码（悬空 ~1.5V）时中间结果回绕为负数 → 滤波输出错误 → 基线跳变。修复：求和前逐操作数 `$signed` 符号扩展 |
| 2 | `alpha_shift` 位宽扩展 | `slv_reg2[6:2]` | 3-bit(0..7) → 5-bit(0..31)，默认 10 |
| 3 | `max_pulse_wid` 位宽扩展 + 迁移 | `slv_reg3[31:24]` → `slv_reg4[15:0]` | 8-bit(0..255) → 16-bit(0..65535)，默认 255 |
| 4 | 监视回读竞态修复 | Vitis `signal_analyzer.c` | `read_baseline_mon` 写 `mon_ch` 后加一次 flush 空读，避免读到上一通道旧值 |
| 5 | 阶段4 UDP 命令映射 | Vitis `udp_server.c` + Desktop `UdpCommClient` | `CMD_BASELINE_SETTINGS(0x0D)` / `CMD_BASELINE_MONITOR(0x0E)`，HMI 新增「Baseline Debug Console」 |
| 6 | HMI 连接状态修复 | Desktop `BaselineDebugDialog` | 打开控制台时按 controller 当前状态刷新，不再显示 stale "Disconnected" |

> **本 SOP 以 HMI 基线调试台为主测入口**（阶段4 已接通 UDP）。ILA 仅作深挖辅助，不再需要 XSCT / 临时改 PS 代码下参。

---

## 1. 测试范围与前提

**本 SOP 覆盖：**
- 双相 EMA 基线估计（ACQUIRE 快收敛 / TRACK 慢跟踪）
- 相对阈值（`detect_ref = baseline_out + threshold`）
- `baseline_en` 门控（关=绝对阈值+原始度量，开=相对阈值+基线校正）
- 运行时参数（`acquire_len` / `guard_len` / `max_pulse_wid`，含扩展后范围）
- 监视回读（`slv_reg42/43`，经 UDP → HMI 控制台）
- **悬空通道基线稳定性**（本次溢出修复的回归验证，见用例 0）

**本 SOP 不覆盖：**
- 逐样本减（`sample_baselined` 未接线，见 §7 坑 3）

**前置条件：**
1. Vivado 综合通过、生成 bitstream、导出 `.xsa`（含本次 `ad_data_filter.v` 修复）
2. Vitis 重新导入 xsa、编译、烧录
3. HMI 启动并连接 SoC（`Baseline Debug Console` 可打开）
4. （可选）ILA 抓取工程，用代码里已加的 `MARK_DEBUG`

---

## 2. 关键默认态与语义（⚠️ 测试前必读）

| 项 | 复位默认 | 含义 |
|---|---|---|
| `baseline_en` (`slv_reg2[0]`) | **0（校正关闭）** | 复位后 = 旧绝对阈值行为；需在控制台打开 Enable 开关置 1 |
| `slv_reg2` | `0x28` | `alpha_shift=10`，`slope_th=0`（斜率二级门控禁用），`acquire_force=0` |
| `slv_reg3` | `0x00080400` | `guard_len=8` / `acquire_len=1024`（约 1 ms @1 MHz） |
| `slv_reg4` | `255` | `max_pulse_wid=255` |
| 阈值 `slv_reg8~15` | — | **语义已变**：从「绝对 ADC 码值」改为「**相对基线的峰高**」（`baseline_valid=1` 时） |

> **阈值语义是第一坑**：启用基线后阈值是峰高（相对基线），不是绝对码值。旧绝对码值（如 10100）会被当成峰高 → **漏触发**。必须按峰高重标定。

---

## 3. 上机前准备

### 3.1 HMI 基线调试台（主入口）

打开 `Baseline Debug Console`，界面分两块：

- **Settings**：Enable 开关、Alpha Shift(0..31)、Slope Threshold(0..63)、Acquire Length、Guard Length、Max Pulse Width、Apply / Re-acquire 按钮。
- **Monitor**：8 通道表格（Channel / Valid / Baseline(code)），`Refresh` 单次读取，`Auto refresh` 定时轮询（默认 500 ms）。

推荐测试流程：先 `Apply` 下发参数 → 打开 `Auto refresh` 观察 8 通道基线。

### 3.2 ILA 抓取信号（深挖辅助）

代码已加 `MARK_DEBUG`，Set up Debug 向导直接抓：

| 信号 | 位宽 | 含义 | 备注 |
|---|---|---|---|
| `baseline_estimator/state` | 1 | 0=ACQUIRE，1=TRACK | 已 MARK_DEBUG |
| `baseline_estimator/baseline` | 24 | Q18.6 定点基线 | 整数部分 = `baseline >> 6` |
| `baseline_estimator/baseline_valid` | 1 | 基线可信 | 已 MARK_DEBUG |
| `baseline_out[i]` | 18 | 取整后基线 | 已 MARK_DEBUG |
| `pulse_active[i]` | 1 | 脉冲中标志 | 单通道 |
| `ad_data_array[i]`（= sample_in） | 18 | **滤波后**采样值 | **溢出修复验证关键点** |

实例层次（示意，以综合后 netlist 为准）：
`…/signal_analyzer_v1_0_S00_AXI_inst/BASELINE_ESTIMATORS[0].baseline_estimator_inst/*`

---

## 4. 测试用例

### 用例 0（回归 · 本次根因）：悬空通道基线稳定

**目的**：确认滤波器求和溢出已修复，悬空通道基线稳定在真实电平，不再大范围跳变。

**背景**：修复前，悬空 8 通道（~1.5V ≈ +39300 码，> 32768）经滤波器 `4×39300` 溢出回绕为负数，基线跳变。修复后滤波输出应稳定 ≈ +39300。

**步骤**：
1. 8 个采样通道全部悬空（不接信号发生器）。
2. 控制台 `Apply`（开 Enable，alpha=10，其余默认），打开 `Auto refresh`。
3. 观察 Monitor 表 8 通道 `Baseline` 与 `Valid`。

**预期**：
- 8 通道 `Valid` 均 = Yes（约 1 ms 内收敛）
- `Baseline` 稳定在 **~+39000 ~ +40000**（= 1.5V），抖动极小（慢 EMA 下应仅 ±个位数码）
- **不再**出现大范围跳变 / 负数 / 偶然才对的 40000

**判定**：8 通道基线稳定在 +39000 附近、无大范围跳变，即为修复生效。

---

### 用例 1：ACQUIRE 收敛 + `baseline_valid` 按时置位

**目的**：确认开环快速收敛、`baseline_valid` 在 ~1024 拍（约 1 ms）内置位。

**步骤**：
1. 控制台 `Apply` 开 Enable，`Auto refresh` 观察。
2. （可选）ILA 触发 `baseline_valid` 上升沿，抓 `baseline`、`state`。

**预期**：
- `state` 从 0 起，`baseline` 快速逼近真实基线（首样本作初值，ACQUIRE 快 EMA）
- 计数到 `acquire_len`（默认 1024）后 `state` 切 1、`baseline_valid` 置 1

**判定**：`Valid` 在 ~1 ms 内变 Yes，`Baseline` 稳定在合理量级。

---

### 用例 2：TRACK 慢跟踪 + 脉冲期间冻结

**目的**：确认 TRACK 阶段基线跟踪慢漂移、脉冲期间冻结。

**步骤**：
1. 进 TRACK 后，接入真实样本流，用 ILA 抓 `baseline_out`、`pulse_active[i]`、`ad_data_array[i]`。
2. 观察脉冲期间基线是否不变，间隙是否缓慢跟踪。

**预期**：
- 脉冲期间（`pulse_active=1`）`baseline_out` **完全不变**（冻结）
- 脉冲下降沿后守门 `guard_len`（8 拍）内不更新
- 非脉冲间隙，基线以慢 EMA（α=2^-10，τ≈1024 拍）跟踪漂移，单拍几乎无抖动

**判定**：脉冲期间基线无扰动；间隙基线平滑。

---

### 用例 3：相对阈值触发（基线阶跃）

**目的**：确认基线变化后，相对阈值触发无误触/漏触。

**步骤**：
1. 开 `baseline_en`，把阈值设为一个小的**峰高**（如 500，不是绝对码值）。
2. 稳定无样本时确认**无误触发**（`sample ≈ baseline`）。
3. 人为制造基线阶跃（改 PMT 增益/电子学偏置），观察 `baseline_out` 重新跟踪、触发仍正确。

**预期**：
- 无样本时 `detect_ref = baseline + threshold` 高于本底，无误触发
- 阶跃后基线跟踪跟上，脉冲仍被正确检出

**判定**：漂移全程无漏触/误触，`baseline_out` 能跟上阶跃。

---

### 用例 4：`baseline_en` 门控（0/1 切换）

**目的**：确认门控生效，且切换无毛刺。

**步骤**：
1. TRACK 稳定态下，控制台关 Enable → 行为回到**绝对阈值 + 原始度量**。
2. 再开 Enable → 立即切回相对阈值 + 基线校正，**无需重收敛**。

**预期**：
- 关：检测用绝对 `threshold_value`，`peak/area` 为原始值（不扣基线）
- 开：立即用相对阈值，后台一直跑，重开即用

**判定**：两种模式行为符合预期，开关切换无 1 ms 重收敛等待。

---

### 用例 5：`acquire_force` 重收敛

**目的**：确认主动重收敛生效。

**步骤**：
1. 稳定 TRACK 下点 `Re-acquire`（发送 `acquireForce=true`，固件置位后自清）。
2. ILA 触发 `baseline_valid` 下降沿，抓 `state`、`baseline_valid`。

**预期**：
- `baseline_valid` 先拉低、`state` 回 ACQUIRE，重新快速收敛后再置位

**判定**：重收敛完整、`baseline_valid` 翻转一次后恢复。

---

### 用例 6：运行时参数生效（扩展范围）

**目的**：确认 `acquire_len`/`guard_len`/`max_pulse_wid` 运行时可变，且扩展范围可用。

**步骤**：
1. 改 `Acquire Length`（如 2048）→ `Apply` → `Re-acquire`，ILA 数 `baseline_valid` 置位前拍数。
2. 改 `Max Pulse Width` 到 >255（如 1000）→ `Apply`，确认写入并被看门狗使用。
3. 改 `Alpha Shift` 到 >7（如 20）→ `Apply`，确认慢跟踪更慢。

**预期**：
- `acquire_len=2048` 时 ACQUIRE 时长翻倍（约 2 ms）
- `max_pulse_wid` 可写入 >255（16-bit）
- `alpha_shift` 可写入 >7（5-bit），EMA 更慢

**判定**：扩展范围参数均能写入并在波形上体现对应变化。

---

### 用例 7：寄存器回读（`slv_reg42/43`，经 UDP）

**目的**：确认 HMI 读到的基线监视值与 ILA 一致（含回读竞态已修复）。

**步骤**：
1. 控制台 `Auto refresh` 轮询，记录 8 通道 `Baseline`。
2. 对比 ILA 里对应通道 `baseline_out[i]`。
3. 切换监控通道多次，确认**每次读到的都是当前通道**（无跨通道串扰）。

**预期**：
- `Baseline` = 当前基线整数码值，`Valid` = `baseline_valid`
- 与 ILA 波形一致，无通道串扰

**判定**：回读值正确、与 ILA 吻合、无串扰。

---

## 5. 寄存器速查

| 寄存器 | 偏移 | 位域 | 说明 | 典型写值 |
|---|---|---|---|---|
| `slv_reg2` | 0x08 | [0] baseline_en | 基线校正使能 | `0x28`=关 / `0x29`=开 |
| | | [1] acquire_force | 强制重收敛（置1再清0） | `0x2B`→`0x29` |
| | | [6:2] alpha_shift | 慢跟踪 α = 2^-n（0..31） | 默认 10 |
| | | [13:8] slope_th | 斜率二级门控，0=禁用 | 默认 0（第一阶段禁用） |
| `slv_reg3` | 0x0C | [15:0] acquire_len | 开环收敛样本数（0..65535） | 1024 |
| | | [23:16] guard_len | 守门拍数（0..255） | 8 |
| `slv_reg4` | 0x10 | [15:0] max_pulse_wid | 看门狗阈值（0..65535） | 255 |
| `slv_reg42` | 0xA8 | [2:0] mon_ch | 监控通道 0..7 | 0..7 |
| `slv_reg43` | 0xAC | [17:0] baseline_mon | 只读基线 | — |
| | | [18] baseline_valid_mon | 只读 valid | — |

基地址：`XPAR_SIGNAL_ANALYZER_0_S00_AXI_BASEADDR`（见 `xparameters.h`）。

> ⚠️ `max_pulse_wid` 已从旧版 `slv_reg3[31:24]` **迁移到 `slv_reg4[15:0]`**（16-bit），旧文档/旧 XSCT 脚本若仍写 `slv_reg3[31:24]` 会失效。

---

## 6. 通过判定标准（对照设计方案 8.4）

| 指标 | 目标 |
|---|---|
| 峰值校正误差 | 已知漂移下 `peak_corrected` 误差 < ±1%（满幅） |
| 面积校正误差 | 同漂移下 `area_corrected` 误差 < ±2% |
| 漂移抑制 | 基线阶跃前后 peak/area 结果漂移量 < 阈值 |
| 触发正确性 | 基线漂移全程无误触/漏触 |
| **悬空稳定性（本次新增）** | 悬空 8 通道基线稳定 ≈ +39000，无大范围跳变 |
| 资源增量 | 8 通道合计加法/移位器个位数级（DSP 增量见 §7 坑 7） |
| 时序 | 不引入新的时序违例路径 |

---

## 7. 已知坑与排查

1. **阈值语义变化 → 漏触发**：启用基线后 `slv_reg8~15` 是峰高，不是绝对码值。旧阈值（如 10100）会漏触发。按峰高重标定。
2. **`baseline_en` 默认关 → 看起来基线没作用**：复位后是绝对阈值模式。先确认控制台 Enable 已开（`slv_reg2[0]=1`）。
3. **`sample_baselined` 抓不到**：该输出未接线，会被综合优化掉；相对阈值走 `detect_ref` 方案，本就不需要它。别在 ILA 里找它。
4. **`acquire_len` 别写 0**：已加守卫（0→1 强制收敛），但仍是异常配置，勿依赖。
5. **`max_pulse_wid` 须 > 最大真实脉宽**：否则长脉冲被看门狗误判「检测卡死」触发重收敛。默认 255 拍，若真实脉宽接近需上调。
6. **`slope_th` 第一阶段禁用**：默认 0。写非 0 会启用斜率二级门控（拦截亚阈值边沿），需实验标定后再用，否则可能漏掉陡峭脉冲边沿。
7. **面积 DSP 增量**：`area - baseline*width` 每通道新增 1 个 DSP，与设计目标「DSP 增量 0」不符。本 SOP 不测资源，综合时留意 DSP 数量；若不能接受，后续改逐样本减。
8. **（已修复）滤波器求和溢出**：旧 `ad_data_filter` 求和未显式符号扩展，输入 > 32768 码时溢出回绕 → 基线跳变。已修复，但**任何改动滤波器位宽/滤波阶数时必须保持「先扩展后求和」**，否则复发。

---

## 8. 测试记录模板（建议逐用例填写）

| 用例 | 结果(过/不过) | 关键波形/读数观测 | 备注/异常 |
|---|---|---|---|
| 0 悬空稳定性（回归） | | | |
| 1 ACQUIRE 收敛 | | | |
| 2 TRACK 冻结 | | | |
| 3 相对阈值 | | | |
| 4 baseline_en 切换 | | | |
| 5 acquire_force | | | |
| 6 运行时参数（扩展范围） | | | |
| 7 寄存器回读 | | | |
