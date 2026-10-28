`timescale 1ns/1ps
// ----------------------------------------------------------------------------
// speed_measure — 双光斑峰时间差测速（配对 + 有效性判定）
//
// 物理模型: 一个细胞先后穿过两个固定间距的光斑, 两个通道各产生一个脉冲。
// 用两个脉冲的"峰值时刻"之差 dt 与光斑间距 d 得到流速 v = d / dt, 这个 dt 再用
// 于推算分选延时 (sort_trance / spot_distance * dt)。
//
// 这个模块只负责"配对 + 判定", 不关心阈值、去抖、事件聚合:
//   pre_peak_time  / post_peak_time : 两个通道最近一次【通过质量门】的脉冲峰时间,
//                                     由 pulse_analyzer 给出; 0 表示暂无。
//   event_start                     : 事件开始(post 通道脉冲上升沿), 由 event_aggregator 给出。
//   event_done                      : 事件结束(单拍), 同上。
//
// 为什么配对要"一次性消费"(而不是事件结束时去读 pre 通道的最新值):
//   * 只过 post 光斑的细胞(漏检 pre) 会拿到上一个细胞的 pre 时间 -> dt 偏大;
//   * 两个细胞间距小于两光斑飞行时间时, 下一个细胞的 pre 会覆盖本细胞的 pre -> dt 偏小;
//   * 噪声毛刺单独成事件时, 两路数据根本不同源。
//   所以在事件【开始】那一刻把待配对的 pre 搬进 event_pre_* 并立即消费: post 上升时
//   本细胞的 pre 一定已经过去, 此刻取的才是属于这个细胞的 pre; 之后任何新 pre 只会
//   留给下一个细胞。
//
// 输出在 event_done 当拍组合有效(由已寄存状态 + 当拍 post_peak_time 算出),
// 方便上层在事件结束时直接锁存, 不会有一拍错位。
// ----------------------------------------------------------------------------
module speed_measure (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        analyze_en,          // 采集总使能, 低时清空状态
    input  wire        enable,              // 测速使能 (slv_reg0[2])

    input  wire [63:0] pre_peak_time,       // pre  通道最近一次有效脉冲峰时间 (us)
    input  wire [63:0] post_peak_time,      // post 通道最近一次有效脉冲峰时间 (us)
    input  wire        event_start,         // 事件开始(单拍)
    input  wire        event_done,          // 事件结束(单拍)

    input  wire [31:0] min_time_diff,       // dt 下界 (us), 0 = 不设下界
    input  wire [31:0] max_time_diff,       // dt 上界 (us)

    output wire [63:0] measured_post_time,  // = 当拍 post 峰时间, 供上层记录
    output wire [31:0] measured_time_diff,  // = 当拍 dt
    output wire        measured_valid,      // 1 = 本次配对成立且 dt 在窗口内
    output wire        pair_pending         // 诊断: 有一个 pre 在等待配对
);

    reg        pre_pending;      // 有一个 pre 脉冲等待配对
    reg [63:0] pre_ts;           // 待配对的 pre 峰时间
    reg [63:0] pre_seen;         // 上一次看到的 pre 峰时间(用于识别"新脉冲")
    reg        event_pre_ok;     // 本事件开始时是否成功捕获到 pre
    reg [63:0] event_pre_ts;     // 本事件锁存的 pre 峰时间

    // pre_peak_time 只在"通过质量门的脉冲结束"时变化, 所以"值变了"就等于
    // "来了一个新脉冲"。0 表示该通道当前没有有效峰时间(会被 pulse_analyzer 在
    // 空事件边界清零), 不算新脉冲。
    wire pre_is_new = (pre_peak_time != 64'd0) && (pre_peak_time != pre_seen);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre_pending  <= 1'b0;
            pre_ts       <= 64'd0;
            pre_seen     <= 64'd0;
            event_pre_ok <= 1'b0;
            event_pre_ts <= 64'd0;
        end else if (!analyze_en) begin
            pre_pending  <= 1'b0;
            pre_ts       <= 64'd0;
            pre_seen     <= 64'd0;
            event_pre_ok <= 1'b0;
            event_pre_ts <= 64'd0;
        end else begin
            if (enable && pre_is_new) begin
                pre_pending <= 1'b1;
                pre_ts      <= pre_peak_time;
                pre_seen    <= pre_peak_time;
            end

            // 事件开始: 把待配对的 pre 搬进来并立即消费
            if (event_start) begin
                event_pre_ok <= pre_pending;
                event_pre_ts <= pre_ts;
                pre_pending  <= 1'b0;
            end

            // 事件结束: 本次配对失效, 下一个事件必须重新配对
            if (event_done)
                event_pre_ok <= 1'b0;
        end
    end

    // dt: 64 位无符号相减。post 早于 pre 时会回绕成巨大数, 自然被上界拒绝。
    wire [63:0] time_diff = post_peak_time - event_pre_ts;

    assign measured_post_time = post_peak_time;
    assign measured_time_diff = time_diff[31:0];
    assign pair_pending       = pre_pending;
    assign measured_valid     = enable && event_pre_ok
                                && (time_diff >= {32'd0, min_time_diff})
                                && (time_diff <  {32'd0, max_time_diff});

endmodule
