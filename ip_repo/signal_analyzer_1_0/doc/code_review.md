# Signal Analyzer IP Core - Code Review Report

**Review Date**: 2026-04-06
**Scope**: `hdl/` 目录全部源文件（8个模块）
**基准 Commit**: 5696229 (main)

---

## 1. 架构概览

```
signal_analyzer_v1_0 (Top-level AXI wrapper)
  └── signal_analyzer_v1_0_S00_AXI (AXI-Lite slave + user logic)
        ├── ad_data_filter          8通道4点平均滤波
        ├── pulse_analyzer x8       每通道脉冲检测 (阈值+去抖+peak/width/area)
        ├── gate_judge_pipeline     分选门控判定 (区间/矩形/多边形/椭圆)
        ├── event_aggregator        事件聚合 + BRAM写入 + 速度测量
        └── drive_signal_generation 分选驱动信号生成 (延时+脉宽+冷却)

未实例化:
  - speed_measure.v             独立速度测量状态机 (event_aggregator内有简化实现)
```

---

## 2. 严重问题 (Must Fix)

### 2.1 gate_judge_pipeline `valid` 输出为持续电平而非脉冲

**文件**: `gate_judge_pipeline.v:281-289`

`valid_reg` 在结果计算完成后被置1，但仅在下一次 `trigger_rise` 时才清0（第265行）。导致 `gate_valid_out` 在两次事件之间**持续保持高电平**。

**影响链**: 在 `signal_analyzer_v1_0_S00_AXI.v:1337` 中，`if (gate_valid_out)` 块在 `gate_valid_out` 持续为高期间**每个时钟周期都会执行**，导致：

1. **`sort_abort` 变成持续电平**：当非分选事件间隔过近时，`sort_abort` 应为单周期脉冲触发abort，但实际会持续为高。虽然 `drive_signal_generation` 在 `S_DRIVE_WAIT` 状态下检测到 `sort_abort` 后回到 `IDLE`，此时持续的 `sort_abort` 不再有影响，但信号语义不清晰。

2. **`last_event_time`/`last_event_was_sort` 被重复覆写**：这两个历史记录信号在 `gate_valid_out` 块内更新，持续高电平导致每周期重复赋值，虽然值不变但增加功耗且违背设计意图。

3. **`sort_trig_reg` 依赖正确的间隙**：当前逻辑恰好能工作，因为新事件的 `trigger_rise` 会暂时清除 `valid_reg`，产生 `sort_trig` 的下降沿。但这种正确性依赖于实现细节，非常脆弱。

**建议修复**: 在 `S_IDLE` 状态中自动清零 `valid_reg`：

```verilog
S_IDLE: begin
    valid_reg <= 1'b0;  // 确保valid为单周期脉冲
    if (trigger_rise) begin
        state <= S_CALC;
        // ...existing code
    end
end
```

### 2.2 ad_data_filter 输出延迟与采样时序不匹配

**文件**: `ad_data_filter.v:76-100`, `signal_analyzer_v1_0_S00_AXI.v:1466`

滤波器内部存在 **2个采样周期** 的流水线延迟：

| 周期 | sum (NBA) | ad_ch_val_filt_arr (NBA) | ad_chX_val_filt |
|------|-----------|--------------------------|-----------------|
| N (`ad_data_updated`=1) | 计算新值 (end-of-cycle生效) | ← 读取旧 sum (N-1) | ← 读取旧 filt_arr (N-1) |
| N+1 | 新值生效 | 新值生效 | ← 读取 filt_arr(N) = 旧sum(N-1) |

`pulse_analyzer` 的 `sample_valid` 直接连接 `ad_data_updated`，与 `sample_in`（来自滤波器输出 `ad_chX_val_filt`）在同一个 `ad_data_updated` 脉冲时采样。但此时滤波器输出的是 **2个采样前** 的结果。

**影响**: `peak_time_out` 记录的时间戳对应的是当前时刻，但对应的采样数据实际来自2个采样前，导致 peak_time 偏早约 2×T_sample。对 drive_delay 的绝对定时精度有影响。

**建议修复** (选其一):
- 方案A: 将 `ad_data_updated` 延迟2拍后再作为 `pulse_analyzer` 的 `sample_valid`
- 方案B: 去除 `ad_data_filter` 中多余的输出寄存器级（`ad_ch_val_filt_arr` 直接输出），减少为1级延迟

### 2.3 Polygon 门控 `gnum` 为0或1时下溢

**文件**: `gate_judge_pipeline.v:156,316`

```verilog
wire [CNT_WIDTH-1:0] next_idx = (edge_idx == gnum - 1'b1) ? ...
if (edge_idx == gnum - 1'b1) poly_feeding <= 1'b0;
```

当 `gnum = 0`（软件未配置或配置错误时），`gnum - 1'b1` 在无符号4位运算中下溢为 `4'hF`（15），导致：
- 多边形迭代15+2=17个周期，读取未初始化的顶点数据
- 结果完全不可预测

**建议修复**:

```verilog
GT_POLYGON: begin
    if (gnum < 3) begin  // 多边形至少3个顶点
        result_reg <= 1'b0;
        valid_reg <= 1'b1;
        state <= S_IDLE;
    end else begin
        // ...existing polygon iteration logic
    end
end
```

---

## 3. 中等问题 (Should Fix)

### 3.1 speed_measure.v 未实例化（死代码）

**文件**: `speed_measure.v`（136行）

完整的速度测量模块从未被实例化。速度测量功能由 `event_aggregator.v` 内联实现（第119行 `time_diff = speed_post_time - speed_pre_time`）。

**建议**: 确认不需要后删除，避免维护困惑。如需保留，至少添加注释说明。

### 3.2 事件写入期间新事件静默丢失

**文件**: `event_aggregator.v:200-241`

当 FSM 处于 BRAM 写入状态（S_WAIT_GATE ~ S_DONE）时，新的 `event_done` 被忽略，没有任何标志或计数器记录丢失事件数。

**影响**: 在高事件速率下（例如 >5000 events/s），每次 BRAM 写入约需30+时钟周期（8通道全开），如果写入时间接近事件间隔，会有事件丢失但软件端无法感知。

**建议**: 添加丢失事件计数器，通过AXI寄存器可回读：

```verilog
reg [31:0] dropped_event_count;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n || !analyze_en)
        dropped_event_count <= 32'd0;
    else if (event_done && state != S_IDLE)
        dropped_event_count <= dropped_event_count + 1;
end
```

### 3.3 latched_post_event_time 64位截断为32位

**文件**: `event_aggregator.v:117,218`

```verilog
reg [31:0] latched_post_event_time;
...
latched_post_event_time <= speed_post_time;  // speed_post_time is 64-bit!
```

`speed_post_time` 是64位的 peak_time 切片，赋值给32位寄存器时高位被静默截断。`time_stamp_us` 运行约71分钟（2^32 us ≈ 4295秒）后高位将携带有效信息。

**建议**: 扩展为64位存储并写入BRAM，或在文档中注明运行时间限制。

### 3.4 脉冲分析器去抖期间面积/宽度计算误差

**文件**: `pulse_analyzer.v:83-108,113-128`

上升沿去抖：需要 `C_DEBOUNCE_LEN`（默认3）个连续样本超过阈值才进入脉冲，进入后 `width_reg` 从1开始、`area_reg` 仅包含当前样本。去抖期间的3个超阈值样本**未计入**面积和宽度。

下降沿去抖：需要3个连续样本低于阈值才结束，但此期间仍在累加 `width_reg` 和 `area_reg`（因为 `in_pulse` 仍为1），导致**多计入**了低于阈值的样本。

**对窄脉冲的影响**：
- width 偏差：-3（上升缺失）+3（下降多算）≈ 0（正好抵消）
- area 偏差：上升沿漏掉的面积 ≠ 下降沿多算的面积（因为波形不对称），存在系统性偏差

**评估**: 对于宽脉冲（>50 samples）影响可忽略；窄脉冲（<20 samples）需评估精度要求。

---

## 4. 设计改进建议

### 4.1 AXI 寄存器增加运行状态回读

**文件**: `signal_analyzer_v1_0_S00_AXI.v:1096-1159`

当前仅 `slv_reg56`（write addr）和 `slv_reg57`（event counter）为硬件状态。建议利用空闲寄存器：

| 寄存器 | 建议用途 |
|--------|----------|
| slv_reg58 | `{drive_state, sort_trig, sort_abort, ...}` 调试状态 |
| slv_reg59 | 丢失事件计数器（见3.2） |
| slv_reg60 | `time_stamp_us[31:0]`（供软件校时） |
| slv_reg61 | `ch_pulse_valid` 当前值 |

### 4.2 硬编码常量参数化

| 位置 | 值 | 说明 |
|------|------|------|
| `S00_AXI.v:1184` | `199` | CLK_COUNT_IN_1US，200MHz专用 |
| `event_aggregator.v:50` | `0x00008000` | BRAM大小32KB |
| `drive_signal_generation.v:107` | `64'd10` | Edge模式高电平10us |

**建议**: 提取为 `parameter`，方便不同平台/时钟频率复用。

### 4.3 BRAM 容量保护

**文件**: `event_aggregator.v`

BRAM 32KB 环形缓冲区无满保护。8通道全开时每事件116字节，约可存282个事件。如果 PS 端读取不及时，旧数据被覆盖无任何提示。

**建议**: 添加BRAM半满/满中断信号，或实现读写指针保护（PS写入read_ptr，PL检查 write_ptr 不超过 read_ptr）。

---

## 5. 代码质量

### 5.1 复位风格不一致

| 风格 | 使用位置 |
|------|----------|
| 异步复位 `always @(posedge clk or negedge rst_n)` | pulse_analyzer, event_aggregator, drive_signal_generation, gate_judge_pipeline |
| 同步复位 `always @(posedge S_AXI_ACLK) if (!ARESETN)` | AXI标准接口部分 |

混合风格在功能上可工作（同一复位源），但可能导致综合约束复杂化。

**建议**: Xilinx FPGA 推荐同步复位（有利于综合优化）。统一为一种风格。

### 5.2 被注释的代码

| 文件 | 行号 | 内容 |
|------|------|------|
| `ad_data_filter.v` | 81-98 | 旧的滑动窗口方案 |
| `event_aggregator.v` | 142-148 | 未完成的 ch_pulse_valid 逻辑 |
| `signal_analyzer_v1_0_S00_AXI.v` | 1437-1454 | pulse_analyzer 旧接口模板 |
| `signal_analyzer_v1_0_S00_AXI.v` | 1521-1536 | drive_signal_generation 旧接口模板 |

**建议**: 清理，使用 git history 追溯旧代码即可。

### 5.3 乱码注释

- `pulse_analyzer.v:128`: `// If below threshold for debounce length ⁇? end pulse`
- `speed_measure.v:60`: `// ⁇32位的max_time_diff扩展⁇64位后再相⁇`
- `signal_analyzer_v1_0_S00_AXI.v:1441`: `// ȥ⁇⁇⁇⁇⁇⁇??????`

**建议**: 修复编码或改用英文注释。

### 5.4 `dist` 信号声明但未使用

**文件**: `signal_analyzer_v1_0_S00_AXI.v:304,1417`

```verilog
wire signed [31:0] dist;
assign dist = slv_reg54[31:0];
```

`dist` 被声明和赋值但从未被任何模块消费。

---

## 6. 寄存器映射表

| 寄存器 | 偏移 | 用途 | R/W |
|--------|------|------|-----|
| slv_reg0 | 0x00 | [0]=analyze_en, [1]=sort_en | R/W |
| slv_reg1 | 0x04 | [7:0]=enabled_channels | R/W |
| slv_reg2~7 | 0x08~0x1C | 保留 | R/W |
| slv_reg8~15 | 0x20~0x3C | Ch0~Ch7 阈值 [17:0] | R/W |
| slv_reg16 | 0x40 | X: [2:0]=sort_ch, [9:8]=sort_type; Y: [18:16]=sort_ch, [25:24]=sort_type | R/W |
| slv_reg17 | 0x44 | [2:0]=gate_type, [7:4]=gate_points_num | R/W |
| slv_reg18~29 | 0x48~0x74 | gate_points_x[0..11] | R/W |
| slv_reg30~41 | 0x78~0xA4 | gate_points_y[0..11] | R/W |
| slv_reg42~46 | 0xA8~0xB8 | 保留 | R/W |
| slv_reg47 | 0xBC | delay_calcu_coe (速度补偿系数) | R/W |
| slv_reg48 | 0xC0 | [0]=drive_type(0:Level,1:Edge), [1]=purity_en | R/W |
| slv_reg49 | 0xC4 | drive_delay (us) | R/W |
| slv_reg50 | 0xC8 | drive_width (us, Level模式) | R/W |
| slv_reg51 | 0xCC | cooling_time (us) | R/W |
| slv_reg52 | 0xD0 | [2:0]=speed_pre_channel, [10:8]=speed_post_channel | R/W |
| slv_reg53 | 0xD4 | max_time_diff (us, 速度测量超时) | R/W |
| slv_reg54 | 0xD8 | dist (未使用) | R/W |
| slv_reg55 | 0xDC | min_event_interval (us, 高纯度模式) | R/W |
| slv_reg56 | 0xE0 | **只读**: [23:0]=last_written_addr, [24]=wrap_around | R |
| slv_reg57 | 0xE4 | **只读**: event_counter | R |
| slv_reg58~63 | 0xE8~0xFC | 保留 | R/W |

---

## 7. 本次会话已修复的问题

### 7.1 sort_trig 持续高电平导致分选驱动无法再次触发

**文件**: `signal_analyzer_v1_0_S00_AXI.v:1329`

**原因**: `sort_trig_reg` 仅在 `gate_valid_out` 为高时更新，两次事件之间保持旧值。连续分选事件导致信号持续为高，`drive_signal_generation` 中的上升沿检测器无法产生新的 `sort_start`。

**修复**: 添加 `sort_trig_reg <= 1'b0` 每周期默认清零，使其成为单周期脉冲。

### 7.2 通道无有效脉冲时分析结果保留旧值

**文件**: `pulse_analyzer.v:34,57,79-87,133`

**原因**: pulse_analyzer 输出（peak/width/area/peak_time）仅在 `pulse_done` 时更新，无脉冲时保留上次旧值，导致 gate_judge 使用陈旧数据做判断。

**修复**: 新增 `event_done` 输入端口和 `pulse_occurred` 追踪寄存器。事件结束时，如果该通道在整个事件期间没有产生过有效脉冲，则将输出清零。

---

## 8. 修改历史

| 日期 | 内容 |
|------|------|
| 2026-04-01 | 初始 code review |
| 2026-04-02 | 修复 speed_post 使能、64位时间戳、BRAM端口声明、复位风格统一、接入 gate_judge_pipeline、新增高纯度模式 |
| 2026-04-03 | 修复椭圆门控时序违例：增加 Stage 4 流水线寄存器，椭圆延迟从4周期增至5周期 |
| 2026-04-06 | 修复 sort_trig 持续高电平 bug；修复无效通道脉冲结果未清零问题；全面 code review 更新 |
