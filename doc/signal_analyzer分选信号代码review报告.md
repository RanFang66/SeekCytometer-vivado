# signal_analyzer IP 分选信号代码 Review 报告

- 日期：2026-10-14
- 范围：`SeekCytometer-vivado/ip_repo/signal_analyzer_1_0/`（PL），并向上核对 PS（`SeekCytometer-vitis`）与桌面端（`SeekCytometer-desktop`）的 gate type 数据链路
- 背景：最近两次改动
  1. commit `1db9f83`（PL）：旁路纯净模式触发判断（`sort_trig = gate_result_out`）；重定义 `gate_judge_pipeline.v` gate type 枚举（新增 `GT_QUADRANT=5`，`GT_ALL` 移到 6）。
  2. commit `9e908c9`（Vitis，本次 review 对象）：修复 gate type 不一致问题。

> **更新记录 v2（2026-10-14）**：Vitis 端 `9e908c9` 提交已修复 gate type 编码链不一致问题（见第 1 节标记 ✅ 已解决）。剩余问题均为 PL 侧未改动项。
>
> **更新记录 v3（2026-10-14）**：应需求，PL 侧纯净模式（高纯度模式）逻辑已**整体删除**（见第 4 节）。涉及 `signal_analyzer_v1_0_S00_AXI.v` 与 `drive_signal_generation.v`。
>
> **更新记录 v4（2026-10-14）**：PS 侧纯净模式残留（`min_event_interval` / `purity_en`）已同步清理完毕（见第 4.1 节）。涉及 `cytometer.h`、`udp_server.c`、`signal_analyzer.c`、`signal_analyzer.h`。

---

## 0. 结论速览

| 级别 | 问题 | 位置 | 状态 |
|---|---|---|---|
| P0 | gate type 编码链三层不一致 | 桌面端 / PS / PL 枚举 | ✅ 已解决（Vitis `9e908c9`） |
| P0 | `GT_QUADRANT` 定义了但 FSM 未实现，象限门永不触发 | `gate_judge_pipeline.v` | ⚠️ 未解决（PL） |
| P1 | 旁路丢掉 `sort_en` 与 `ch_sort_valid_latched` 门控 | `signal_analyzer_v1_0_S00_AXI.v` | ⚠️ 未解决（PL） |
| P1 | 纯净模式旁路不彻底，`sort_abort` 仍活跃 | `signal_analyzer_v1_0_S00_AXI.v` | ✅ 已解决（纯净模式已整体删除） |
| P2 | `sort_trig` 变成电平而非单周期脉冲 | `signal_analyzer_v1_0_S00_AXI.v` | ⚠️ 未解决（PL） |
| P2 | `GATE_ALL = 3'd5` 未同步为 6 | `signal_analyzer_v1_0_S00_AXI.v` | ⚠️ 未解决（PL） |
| P3 | 死代码 / 半死状态机 | PS / PL | ⚠️ 部分残留 |

---

## 1. P0 — gate type 编码链三层不一致 ✅ 已解决

### 1.1 修复内容（Vitis commit `9e908c9`）

1. **`signal_analyzer.h:140-148`** —— `PL_GateType_e` 枚举对齐桌面端：
   ```c
   typedef enum {
       GT_NO_GATE = 0,
       GT_INTERVAL  = 1,
       GT_RECTANGLE = 2,
       GT_POLYGON   = 3,
       GT_ELLIPSE   = 4,
       GT_QUADRANT  = 5,
       GT_ALL       = 6
   } PL_GateType_e;
   ```
   与原 `GT_ALL=5`、无 `GT_QUADRANT` 相比，新增 `GT_QUADRANT=5`、`GT_ALL` 改为 6。

2. **`signal_analyzer.c:101`** —— `write_gates_at` 去掉旧 switch 映射，改为直接透传：
   ```c
   gate_config->gate_config = (data->gate_type & 0xFF);
   // ... 旧的 case 0~4 映射已被注释掉 ...
   gate_config->gate_config |= (data->gate_points_num << 9) | (data->gate_points_num << 16);
   ```

### 1.2 验证结果（逐项核对通过）

- **编码一致性**：桌面端 `GateType { NoGate=0, Interval=1, Rectangle=2, Polygon=3, Ellipse=4, Quadrant=5, AllEvents=6 }`，与 PL `gate_judge_pipeline.v` 枚举（0~6）**完全一致**。直接透传后三层编码统一，原有的 off-by-one 消除。

- **位域布局**：`bram_gate_info.v` 读取 `gate_type = bram_dout[7:0]`（`bram_gate_info.v:163`）、`gate_param = bram_dout[31:16]`（`:164`）、`data_length = bram_dout[15:8]`（`:157`）。PS 写入 `gate_type & 0xFF` 落在 `[7:0]`、`gate_points_num << 16` 落在 `[31:16]`、`gate_points_num << 9` 落在 `[15:9]`（等价于 `[15:8] = gate_points_num*2`），三者与 PL 读取位完全对齐。

- **校验和一致性**：PS 的 `checkbits` 对 `4 + gate_points_num*2` 个 32-bit 字做 XOR；PL `bram_gate_info.v` 从 S_HEAD→S_TYPE→S_CHANNEL→S_CHECK→S_POINTS 逐字 XOR，覆盖同样的字序列。gate_config 的 `[7:0]` 变化对称地进入双方 XOR，校验和仍然匹配。

- **“全部分选”**：`udp_server.c:249` 的 `reset_gates(GT_ALL)` 现在写入 6，PL 读到 `GT_ALL=6` → 恒触发。已修复。

- **其余 `GT_` 用法**：`cytometer.c:109` / `udp_server.c:285` 的 `reset_gates(GT_NO_GATE)` 仍为 0，语义不变。

### 1.3 修复后遗留的小项（非阻断）

- **输入不再做合法性校验**：旧 switch 有 `default → GT_NO_GATE` 兜底，现在任意 `0~255` 都会透传。PL `gate_judge_pipeline` 的 `default` 分支仍会把未知类型判为 `result=0`（永不触发），所以功能上安全，但 PS 层不再拦截/记录非法值。建议在 `write_gates_at` 里加一个 `data->gate_type > GT_ALL` 的边界检查与日志。
- **旧 switch 以注释形式残留**（`signal_analyzer.c:102-121`，约 20 行），属死代码，建议删除。

---

## 2. P0 — `GT_QUADRANT` 未实现 ⚠️ 未解决（PL）

`gate_judge_pipeline.v:51` 定义了 `GT_QUADRANT = 3'd5`，但 `S_CALC` 的 `case(gtype)`（279-363 行）只处理：

```
GT_NO_GATE / GT_INTERVAL / GT_RECTANGLE / GT_POLYGON / GT_ELLIPSE / GT_ALL / default
```

**没有 `GT_QUADRANT` 分支**，落到 `default` → `result_reg <= 1'b0`。现在 PS 已把 `Quadrant=5` 正确透传下来，但 FPGA 内没有任何象限门判定逻辑，**象限门仍将永远不触发**。

> 这是 gate type 修复后暴露出的下一个问题：编码对了，但 PL 功能缺失。

修复建议：补齐象限门判定（按中心点 + 象限方向比较 x/y）；或明确“象限门不用于分选”，在 PS 层拦截并给上层明确错误提示。

---

## 3. P1 — 旁路丢掉 `sort_en` 与 `ch_sort_valid_latched` 门控 ⚠️ 未解决（PL）

`signal_analyzer_v1_0_S00_AXI.v:1369`
```verilog
//	wire sort_trig = sort_trig_reg;
    wire sort_trig = gate_result_out;
```

原 `sort_trig_reg` 仅在 `current_event_is_sort = sort_en && gate_result_out && ch_sort_valid_latched` 成立时才置 1，改为 `gate_result_out` 直接当 `sort_trig` 后丢失两层保护：

1. `ch_sort_valid_latched`（`sort_ch_x`/`sort_ch_y` 两通道都必须有有效脉冲）丢失 → 某通道未触发时 `peak_out` 被清零，门判定可能用 0 值“恰好落入门内”，导致**伪分选**。
2. `sort_en` 门控丢失 → `event_aggregator` 头部 bit20/bit21 反映“是否在门内”而非“是否真的分选”。

修复建议：`sort_trig` 恢复为 `sort_en && gate_result_out && ch_sort_valid_latched` 的单周期脉冲，仅去掉 `purity_suppress`。

---

## 4. P1 — 纯净模式旁路不彻底，`sort_abort` 仍活跃 ✅ 已解决（纯净模式已整体删除）

应需求，纯净模式（高纯度模式）逻辑已在 PL 侧**整体删除**，不再处于“半开”状态。删除内容：

- `signal_analyzer_v1_0_S00_AXI.v`
  - 删除寄存器 `purity_en`、`min_event_interval`（含声明 / 复位 / 赋值）。
  - 删除整个事件历史与纯净判断逻辑：`current_event_time`、`last_event_time`、`last_event_was_sort`、`sort_abort`、`purity_suppress`、`current_event_is_sort`、`ch_sort_valid_latched`、`sort_trig_reg`、`GATE_ALL`、`gate_type`。
  - 保留 `sort_ready`（`event_done` 清 0、`gate_valid_out` 置 1）与 `sort_trig = gate_result_out`。
  - 删除 `drive_signal_generation` 实例的 `.sort_abort(...)` 连接。
  - 删除 AXI 寄存器 `slv_reg55`（min_event_interval 专属）的声明 / 复位 / 写 case `6'h37` / 读 case `6'h37` / hold。
- `drive_signal_generation.v`
  - 删除 `sort_abort` 输入端口。
  - 删除 `S_DRIVE_WAIT` 中的 `if (sort_abort)` 中止分支。

> 注意：`slv_reg48[1]`（原 purity_en 位）保留但已无消费逻辑，`slv_reg48[0]`（drive_type）不受影响。

### 4.1 PS 侧清理（v4）

应同一需求，PS 侧纯净模式残留引用已一并删除，与 PL 侧保持同步：

- `signal_analyzer.h`：删除 `SIGNAL_ANALYZER_MIN_EVENT_INTERVAL`（REG55）、`HIGH_PURITY_EN_MASK`（0x2）、`SIGNAL_ANALYZER_S00_AXI_SLV_REG55_OFFSET`。
- `signal_analyzer.c`：`write_drive_settings` 删除对 REG55（min_event_interval）的写，其余 drive 寄存器写保持不变。
- `cytometer.h`：`struct DriveParas` 删除 `min_event_interval` 字段。
- `udp_server.c`：`CMD_DRIVE_SETTINGS` 解析删除 `min_event_interval` 读取（原 `data_start + 17`）及日志参数（日志由 6 参改为 5 参）。

> 遗留：`DRIVE_TYPE_MASK`（0x1）现无消费点，属死代码，可择机删除。

---

## 5. P2 — `sort_trig` 变成电平而非脉冲 ⚠️ 未解决（PL）

`gate_result_out` 是 `hierarchical_gate_wrapper` 的 `result`，在门判定完成后保持高电平直到下一事件（仅 `ST_READY` 复位，`hierarchical_gate_wrapper.v:178`）。因此 `sort_trig` 是电平。

当前 `drive_signal_generation` 用边沿检测 `sort_start = !sort_trig_d1 && sort_trig_d0` 仍能触发一次（这是旁路后能输出的原因），但信号名为 `trig`、语义为脉冲，后续模块直接采电平会出错；跨事件边界保持高电平也使 bit20/bit21 采集依赖精确时序对齐。

修复建议：在触发路径显式产生单周期脉冲，而非直接暴露 `result` 电平。

---

## 6. P2 — `GATE_ALL = 3'd5` 未同步 ⚠️ 未解决（PL）

`signal_analyzer_v1_0_S00_AXI.v:1322`
```verilog
localparam [2:0] GATE_ALL = 3'd5;
```
`GT_ALL` 已移到 6，此处仍写死 5。该常量被 `ch_sort_valid_latched`（1339 行 `gate_type == GATE_ALL`）使用，进而喂给 `current_event_is_sort → sort_abort`（仍活跃）。经查 PS 端无任何代码写 `slv_reg17`，故该比较目前不可达、暂不触发，但一旦启用即为隐患。

修复建议：同步为 6，或连同整个 `slv_reg17` 通道一起删除。

---

## 7. P3 — 死代码 / 半死代码 ⚠️ 部分残留

- **PL** `signal_analyzer_v1_0_S00_AXI.v`：`sort_trig_reg`、`ch_sort_valid_latched`、纯净模式状态机等半死逻辑已随纯净模式整体删除（见第 4 节）。✅
- **PS** `signal_analyzer.c:102-121`：旧 switch 映射被注释残留，属死代码，仍待删除。

建议删除 PS 端注释残留的旧 switch。

---

## 8. 其它观察（非缺陷）

- 本次 Vitis 提交同时**重新生成了硬件平台**：`xparameters.h` / `xbram_g.c` / `system.mss` 等新增了第二个 BRAM 控制器 `AXI_BRAM_CTRL_1`（`0x84000000`），`signal_analyzer.h:137` 的 `GATE_CONFIG_ADDR` 已指向它。这属于门控 BRAM 的硬件改动，与 gate type 修复一并合入，`xsa`/`bit`/BSP 已同步，未见不一致。

---

## 9. 建议修复顺序（更新后）

1. ~~修 PS 三层编码（根因）~~ —— **已完成**（Vitis `9e908c9`）。
2. ~~整体删除纯净模式~~ —— **已完成**（见第 4 节，v3）。
3. **PL 补齐 `GT_QUADRANT` 判定逻辑**，或明确象限门不用于分选并在 PS 层拦截（当前象限门仍永不触发）。
4. **决定并处理 `sort_trig` 语义**：当前 `sort_trig = gate_result_out` 为电平、且已不再有 `sort_en` / 通道有效脉冲门控。若需恢复门控，应重新引入单周期脉冲触发；否则明确该简化行为并同步上层对头部 bit20/bit21 的解读。
5. **清理**：删除 PS 端注释残留的旧 switch；`write_gates_at` 加 `gate_type > GT_ALL` 边界校验。

---

## 附：涉及文件清单

- `SeekCytometer-desktop/database/DbEnums.h`（桌面端枚举，只读参考）
- `SeekCytometer-desktop/network/UdpCommClient.cpp`（`sendGateData` / `sendGatePath`，只读参考）
- `SeekCytometer-vitis/seek_cytometer/src/signal_analyzer/signal_analyzer.h`（已改 ✅）
- `SeekCytometer-vitis/seek_cytometer/src/signal_analyzer/signal_analyzer.c`（已改 ✅）
- `SeekCytometer-vitis/seek_cytometer/src/udp_server.c`
- `SeekCytometer-vivado/ip_repo/signal_analyzer_1_0/hdl/gate_judge_pipeline.v`（待改：补 GT_QUADRANT）
- `SeekCytometer-vivado/ip_repo/signal_analyzer_1_0/hdl/signal_analyzer_v1_0_S00_AXI.v`（待改：收窄旁路、GATE_ALL、死代码）
