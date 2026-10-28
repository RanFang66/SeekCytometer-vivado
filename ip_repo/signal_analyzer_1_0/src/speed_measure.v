`timescale 1ns/1ps
// ----------------------------------------------------------------------------
// speed_measure — 双光斑峰时间差测速（配对 + 有效性判定）
//
// 物理模型: 一个细胞先后穿过两个固定间距的光斑, 两个通道各产生一个脉冲。
// 用两个脉冲"峰值时刻"之差 dt 与光斑间距 d 得到流速 v = d / dt, 这个 dt 再用于
// 推算分选延时 (sort_distance / spot_distance * dt)。
//
// 本模块只负责"配对 + 判定", 不关心阈值/去抖/事件聚合:
//   pre_peak_time  / post_peak_time : 两通道最近一次【通过质量门】的脉冲峰时间,
//                                     由 pulse_analyzer 给出; 0 表示暂无。
//   measured_*                       : 组合输出, 上层在 event_done 当拍采样即可。
//
// 配对算法 —— "取最近的不晚于 post 的 pre"
// ---------------------------------------------------------------------------
// 维护最近两次完成的 pre 峰时间(pre_h0 最新, pre_h1 次新)。事件结束时:
//     候选 = 最近的、且 pre_ts <= post_ts 的那个 pre
//     dt   = post_ts - 候选
//     valid= 有候选 且 min_time_diff <= dt < max_time_diff
//
// 为什么不是"事件开始时锁存待配对的 pre"(上一版的做法):
//   脉冲宽度并不总小于两光斑飞行时间。实测(信号源输入)脉冲宽约 374 个采样点,
//   而两光斑间隔对应的 dt 只有几十 us —— post 脉冲上升时 pre 脉冲往往还没结束,
//   peak_time_out 尚未更新, 于是"待配对"是空的, 全部事件被判无效。
//   改成事件结束(两个脉冲都已完成)后再挑选, 与脉冲宽度无关。
//
// 为什么需要两个候选而不是只取最新:
//   高浓度时下一个细胞的 pre 可能在本事件结束之前就完成, 那时 pre_h0 属于下一个
//   细胞(它的峰时间晚于本细胞的 post) -> 用 pre_h0 <= post_h0 判断即可自动回退到
//   pre_h1(本细胞)。既不会 dt 偏小, 也不会像"只取最新"那样把好的测量丢掉。
//
// 漏检 pre / 久远的残留 pre: 前者没有候选, 后者被 max_time_diff 挡住, 都判无效。
// ----------------------------------------------------------------------------
module speed_measure (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        analyze_en,          // 采集总使能, 低时清空历史
    input  wire        enable,              // 测速使能 (slv_reg0[2])

    input  wire [63:0] pre_peak_time,       // pre  通道最近一次有效脉冲峰时间 (us)
    input  wire [63:0] post_peak_time,      // post 通道最近一次有效脉冲峰时间 (us)

    input  wire [31:0] min_time_diff,       // dt 下界 (us), 0 = 不设下界
    input  wire [31:0] max_time_diff,       // dt 上界 (us)

    output wire [63:0] measured_post_time,  // = 当拍 post 峰时间, 供上层记录
    output wire [31:0] measured_time_diff,  // = 当拍 dt
    output wire        measured_valid,      // 1 = 配对成立且 dt 在窗口内
    output wire [1:0]  pre_hist_count       // 诊断: 已记录几个 pre 候选
);

    // 最近两次完成的 pre 峰时间
    reg [63:0] pre_h0;     // 最新
    reg [63:0] pre_h1;     // 次新
    reg [1:0]  pre_n;      // 已记录个数 (0..2)

    // pre_peak_time 只在"通过质量门的脉冲结束"时变化, 所以"值变了"就等于
    // "来了一个新脉冲"。0 表示该通道当前没有有效峰时间(空事件边界会被清零),
    // 不算新脉冲。
    wire pre_is_new = (pre_peak_time != 64'd0) && (pre_peak_time != pre_h0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_h0 <= 64'd0;
            pre_h1 <= 64'd0;
            pre_n  <= 2'd0;
        end else if (!analyze_en) begin
            pre_h0 <= 64'd0;
            pre_h1 <= 64'd0;
            pre_n  <= 2'd0;
        end else if (enable && pre_is_new) begin
            pre_h1 <= pre_h0;
            pre_h0 <= pre_peak_time;
            if (pre_n < 2'd2)
                pre_n <= pre_n + 2'd1;
        end
    end

    wire [63:0] post_ts = post_peak_time;

    // 候选: 最近的、且不晚于 post 的 pre
    wire have_h0 = (pre_n >= 2'd1) && (pre_h0 != 64'd0) && (pre_h0 <= post_ts);
    wire have_h1 = (pre_n >= 2'd2) && (pre_h1 != 64'd0) && (pre_h1 <= post_ts);
    wire have_pre = have_h0 || have_h1;

    wire [63:0] sel_pre_ts = have_h0 ? pre_h0 : pre_h1;

    // dt: 64 位无符号相减。post 早于 pre 时回绕成巨大数, 自然被上界拒绝。
    wire [63:0] time_diff = post_ts - sel_pre_ts;

    assign measured_post_time = post_ts;
    assign measured_time_diff = time_diff[31:0];
    assign pre_hist_count     = pre_n;
    assign measured_valid     = enable && have_pre
                                && (time_diff >= {32'd0, min_time_diff})
                                && (time_diff <  {32'd0, max_time_diff});

endmodule
