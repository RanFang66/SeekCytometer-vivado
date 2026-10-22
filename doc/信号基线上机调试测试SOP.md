# 信号基线识别与校正 上机调试测试 SOP

> 日期：2026-10-22
> 分支：`refactor/baseline`（Vivado `30b00c0` + Vitis `6440069`）
> 关联文档：《信号基线自动识别与基线校正设计方案》《信号基线开发记录小结》
> 验证对象：阶段3 已实现功能 —— ACQUIRE/TRACK 基线估计、相对阈值、`baseline_en` 门控、运行时参数、寄存器回读

---

## 0. 测试范围与前提

**本 SOP 覆盖（阶段 3 已交付）：**
- 双相 EMA 基线估计（ACQUIRE 快收敛 / TRACK 慢跟踪）
- 相对阈值（`detect_ref = baseline_out + threshold`）
- `baseline_en` 门控（关=绝对阈值+原始度量，开=相对阈值+基线校正）
- 运行时参数（`acquire_len` / `guard_len` / `max_pulse_wid`）
- 监视回读（`slv_reg42/43`）

**本 SOP 不覆盖（尚未完成）：**
- 上位机 UDP 命令映射（阶段4）——基线参数需临时用 PS 代码或 XSCT 下发
- 逐样本减（`sample_baselined` 未接线，见 §6 坑 3）

**前置条件：**
1. Vivado 综合通过、生成 bitstream、导出 `.xsa`（阶段5 综合验证的起点）
2. Vitis 重新导入 xsa、编译、烧录
3. 准备好 ILA 抓取工程（用代码里已加的 `MARK_DEBUG` 直接 Set up Debug 即可）

---

## 1. 关键默认态与语义（⚠️ 测试前必读）

| 项 | 复位默认 | 含义 |
|---|---|---|
| `baseline_en` (`slv_reg2[0]`) | **0（校正关闭）** | 复位后 = 旧绝对阈值行为；PS 需显式置 1 才启用基线校正 |
| `slv_reg2` | `0x28` | `alpha_shift=10`，`slope_th=0`（斜率二级门控禁用），`acquire_force=0` |
| `slv_reg3` | `0xFF080400` | `max_pulse_wid=255` / `guard_len=8` / `acquire_len=1024`（约 1 ms @1 MHz） |
| 阈值 `slv_reg8~15` | — | **语义已变**：从「绝对 ADC 码值」改为「**相对基线的峰高**」（`baseline_valid=1` 时） |

> **阈值语义是本次联调第一坑**：上位机沿用旧的绝对码值（如 10100）会被当成峰高，导致**漏触发**。启用基线后，阈值必须按「峰高」重新标定。

---

## 2. 上机前准备

### 2.1 ILA 抓取信号

代码中已加 `MARK_DEBUG`，直接用 Vivado 的 Set up Debug 向导抓取。建议抓：

| 信号 | 位宽 | 含义 | 备注 |
|---|---|---|---|
| `baseline_estimator/state` | 1 | 0=ACQUIRE，1=TRACK | 已 MARK_DEBUG |
| `baseline_estimator/baseline` | 24 | Q18.6 定点基线 | 已 MARK_DEBUG；整数部分 = `baseline >> 6` |
| `baseline_estimator/baseline_valid` | 1 | 基线可信 | 已 MARK_DEBUG |
| `baseline_out[i]` | 18 | 取整后基线（整数码值） | 已 MARK_DEBUG |
| `pulse_active[i]` | 1 | 脉冲中标志 | 单通道 |
| `ad_data_array[i]`（= sample_in） | 18 | 滤波后采样值（有符号） | — |
| `pulse_done[i]` | 1 | 脉冲结束（度量级减时刻） | 可选 |

实例层次（示意，以综合后 netlist 为准）：
`…/signal_analyzer_v1_0_S00_AXI_inst/BASELINE_ESTIMATORS[0].baseline_estimator_inst/*`

**触发条件建议**：
- 观察收敛：触发 `baseline_valid` 上升沿，或 `state` 跳变
- 观察冻结/相对阈值：触发 `pulse_active[i]` 上升沿

### 2.2 PS 侧使能 baseline（临时，UDP 未接）

三种方式任选（测完记得还原/清理）：

- **A（推荐，改 main.c）**：在 `init_cytometer()` 后加一行，临时编译烧录：
  ```c
  write_baseline_settings(1, 10, 0);   // 开基线，alpha_shift=10，slope_th=0
  ```
- **B（XSCT，不改代码）**：用 `xparameters.h` 里的 `XPAR_SIGNAL_ANALYZER_0_S00_AXI_BASEADDR` 作为 `B`：
  ```tcl
  mwr $B+0x08 0x29      ;# baseline_en=1, alpha_shift=10
  mrd $B+0x08           ;# 读回确认
  ```
- **C（改复位默认）**：把 `S00_AXI.v` 里 `slv_reg2 <= 32'h00000028` 临时改为 `0x29`，重综合。

---

## 3. 测试用例

### 用例 1：ACQUIRE 收敛 + `baseline_valid` 按时置位

**目的**：确认开环快速收敛、`baseline_valid` 在 ~1024 拍（约 1 ms）内置位。

**步骤**：
1. 上电 / 复位，确保有 ADC 采样时钟（`sample_valid` 在跑）。
2. ILA 触发 `baseline_valid` 上升沿。
3. 抓 `baseline`、`state`、`baseline_valid`。

**预期**：
- `state` 从 0 起，`baseline` 快速逼近真实基线（首样本作初值，然后 ACQUIRE 快 EMA）
- 计数到 `acquire_len`（默认 1024）后 `state` 切 1、`baseline_valid` 置 1
- `baseline_out` ≈ 真实基线（数千~10000 码）

**判定**：`baseline_valid` 在 1024 拍内置位，`baseline_out` 稳定在合理量级。

---

### 用例 2：TRACK 慢跟踪 + 脉冲期间冻结

**目的**：确认 TRACK 阶段基线跟踪慢漂移、脉冲期间冻结。

**步骤**：
1. 进 TRACK 后，抓 `baseline_out`、`pulse_active[i]`、`ad_data_array[i]`。
2. 让真实样本流过（触发脉冲），观察脉冲期间基线是否不变。
3. 脉冲间隙观察基线是否缓慢跟踪漂移。

**预期**：
- 脉冲期间（`pulse_active=1`）`baseline_out` **完全不变**（冻结）
- 脉冲下降沿后守门 `guard_len`（8 拍）内不更新
- 非脉冲间隙，基线以慢 EMA（α=2^-10，τ≈1024 拍）跟踪漂移，几乎看不出单拍抖动

**判定**：脉冲期间基线无扰动；间隙基线平滑、无被单次噪声带动的抖动。

---

### 用例 3：相对阈值触发（基线阶跃）

**目的**：确认基线变化后，相对阈值触发无误触/漏触。

**步骤**：
1. 开启 `baseline_en=1`，把阈值 `slv_reg8` 设为一个小**峰高**（如 500，不是绝对码值）。
2. 稳定无样本流过时，确认**无误触发**（`sample ≈ baseline`，`sample - baseline ≈ 0 < threshold`）。
3. 人为制造基线阶跃（改 PMT 增益或电子学偏置），观察 `baseline_out` 重新跟踪、触发仍正确。

**预期**：
- 无样本时 `detect_ref = baseline + threshold` 高于本底，无误触发
- 阶跃后基线跟踪跟上，脉冲（相对基线高出 threshold 的部分）仍被正确检出

**判定**：漂移全程无漏触/误触；`baseline_out` 能跟上阶跃。

---

### 用例 4：`baseline_en` 门控（0/1 切换）

**目的**：确认门控生效，且切换无毛刺。

**步骤**：
1. 在 TRACK 稳定态下，`mwr $B+0x08 0x28`（关）→ `mrd` 确认 → 观察行为回到**绝对阈值 + 原始度量**。
2. 再 `mwr $B+0x08 0x29`（开）→ 观察立即切回相对阈值 + 基线校正，**无需重收敛**。

**预期**：
- 关：检测用绝对 `threshold_value`，`peak/area` 为原始值（不扣基线）
- 开：立即用相对阈值，估计器无需重新 ACQUIRE（后台一直跑，重开即用）

**判定**：两种模式行为符合预期，开关切换无 1 ms 重收敛等待。

---

### 用例 5：`acquire_force` 重收敛

**目的**：确认主动重收敛生效。

**步骤**：
1. 稳定 TRACK 下，PS 调 `baseline_reacquire()`，或 XSCT：
   ```tcl
   mwr $B+0x08 0x2B   ;# 置 acquire_force=1（baseline_en=1 + bit1）
   mwr $B+0x08 0x29   ;# 清 acquire_force
   ```
2. ILA 触发 `baseline_valid` 下降沿，抓 `state`、`baseline_valid`。

**预期**：
- `baseline_valid` 先拉低、`state` 回 ACQUIRE，重新快速收敛后再置位

**判定**：重收敛完整、`baseline_valid` 翻转一次后恢复。

---

### 用例 6：运行时参数生效（改 `slv_reg3`）

**目的**：确认 `acquire_len`/`guard_len`/`max_pulse_wid` 运行时可变。

**步骤**：
1. PS 调 `write_baseline_params(2048, 8, 255)`，或 XSCT `mwr $B+0x0C 0xFF080800`（acquire_len=2048）。
2. 触发一次重收敛（用例5），ILA 数 `baseline_valid` 置位前的拍数。

**预期**：
- `acquire_len=2048` 时，ACQUIRE 时长翻倍（约 2 ms）
- `guard_len` / `max_pulse_wid` 改动分别影响守门时长 / 看门狗阈值

**判定**：参数改动在波形上可观测对应变化。

---

### 用例 7：寄存器回读（`slv_reg42/43`）

**目的**：确认 PS 能读到基线监视值。

**步骤**：
1. PS 调 `read_baseline_mon(ch_id)`，或 XSCT：
   ```tcl
   mwr $B+0xA8 0x00     ;# 选通道 0
   mrd $B+0xAC          ;# [18]=valid, [17:0]=baseline
   ```
2. 对比读到的 `baseline` 与 ILA 里 `baseline_out[0]` 是否一致。

**预期**：
- `[17:0]` = 当前基线整数码值，`[18]` = `baseline_valid`
- 与 ILA 波形一致

**判定**：回读值正确、与 ILA 吻合。

---

## 4. 寄存器速查

| 寄存器 | 偏移 | 位域 | 说明 | 典型写值 |
|---|---|---|---|---|
| `slv_reg2` | 0x08 | [0] baseline_en | 基线校正使能 | `0x28`=关 / `0x29`=开 |
| | | [1] acquire_force | 强制重收敛（置1再清0） | `0x2B`→`0x29` |
| | | [5:2] alpha_shift | 慢跟踪 K | 默认 10 |
| | | [13:8] slope_th | 斜率二级门控，0=禁用 | 默认 0（第一阶段禁用） |
| `slv_reg3` | 0x0C | [15:0] acquire_len | 开环收敛样本数 | 1024 |
| | | [23:16] guard_len | 守门拍数 | 8 |
| | | [31:24] max_pulse_wid | 看门狗阈值 | 255 |
| `slv_reg42` | 0xA8 | [2:0] mon_ch | 监控通道 0..7 | 0..7 |
| `slv_reg43` | 0xAC | [17:0] baseline_mon | 只读基线 | — |
| | | [18] baseline_valid_mon | 只读 valid | — |

基地址：`XPAR_SIGNAL_ANALYZER_0_S00_AXI_BASEADDR`（见 `xparameters.h`）。

---

## 5. 通过判定标准（对照设计方案 8.4）

| 指标 | 目标 |
|---|---|
| 峰值校正误差 | 已知漂移下 `peak_corrected` 误差 < ±1%（满幅） |
| 面积校正误差 | 同漂移下 `area_corrected` 误差 < ±2% |
| 漂移抑制 | 基线阶跃前后 peak/area 结果漂移量 < 阈值 |
| 触发正确性 | 基线漂移全程无误触/漏触 |
| 资源增量 | 8 通道合计加法/移位器个位数级（DSP 增量见 §6 坑 5） |
| 时序 | 不引入新的时序违例路径 |

---

## 6. 已知坑与排查

1. **阈值语义变化 → 漏触发**：启用基线后 `slv_reg8~15` 是峰高，不是绝对码值。旧阈值（如 10100）会漏触发。按峰高重标定。
2. **`baseline_en` 默认关 → 看起来基线没作用**：复位后是绝对阈值模式。先确认 `slv_reg2[0]=1`。
3. **`sample_baselined` 抓不到**：该输出未接线，会被综合优化掉；相对阈值走 `detect_ref` 方案，本就不需要它。别在 ILA 里找它。
4. **`acquire_len` 别写 0**：已加守卫（0→1 强制收敛），但仍是异常配置，勿依赖。
5. **`max_pulse_wid` 须 > 最大真实脉宽**：否则长脉冲被看门狗误判「检测卡死」触发重收敛。默认 255 拍，若真实脉宽接近需上调。
6. **`slope_th` 第一阶段禁用**：默认 0。写非 0 会启用斜率二级门控（拦截亚阈值边沿），需实验标定后再用，否则可能漏掉陡峭脉冲边沿。
7. **面积 DSP 增量**：`area - baseline*width` 每通道新增 1 个 DSP，与设计目标「DSP 增量 0」不符。本 SOP 不测资源，综合时留意 DSP 数量；若不能接受，后续改逐样本减。

---

## 7. 测试记录模板（建议逐用例填写）

| 用例 | 结果(过/不过) | 关键波形观测 | 备注/异常 |
|---|---|---|---|
| 1 ACQUIRE 收敛 | | | |
| 2 TRACK 冻结 | | | |
| 3 相对阈值 | | | |
| 4 baseline_en 切换 | | | |
| 5 acquire_force | | | |
| 6 运行时参数 | | | |
| 7 寄存器回读 | | | |
