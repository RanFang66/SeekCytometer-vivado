`timescale 1ns/1ps
module pulse_analyzer #(
  parameter integer C_AD_DATA_DEPTH = 18,
  parameter integer C_AREA_WIDTH    = 32,
  parameter integer C_DEBOUNCE_LEN  = 3
)(
  input  wire                          clk,
  input  wire                          rst_n,
  input  wire [63:0]                   time_stamp_in, // in clock cycles
  (*MARK_DEBUG="true"*)input  wire                          sample_valid,   // new sample available
  input  wire signed [C_AD_DATA_DEPTH-1:0] sample_in,
  input  wire                          enabled,
  input  wire signed [C_AD_DATA_DEPTH-1:0] threshold_value,
  input  wire signed [C_AD_DATA_DEPTH-1:0] baseline_out, // per-channel baseline (integer), metric-level correction
  input  wire                          baseline_valid,  // 1 = baseline trusted, switch to relative threshold
  input  wire [C_AD_DATA_DEPTH-1:0]     peak_margin,     // 峰值须比 detect_ref 再高这么多码才算有效脉冲 (0=关闭)
  input  wire                          event_done,     // event boundary: clear outputs if no pulse in this event
  output reg                           pulse_active,   // high while in pulse
  output reg                           pulse_done,     // one clock pulse at pulse end
  // 本事件内是否已有"通过质量门"的脉冲。event_aggregator 用它判断空事件(噪声)与
  // 速测配对是否成立 —— 这是与 pulse_active 不同的语义: pulse_active 只要越过阈值
  // 就有效, 而这里要求峰值真的比阈值高出一截。
  output wire                          pulse_valid_out,
  output reg  [15:0]                    reject_count,   // 被质量门丢弃的脉冲累计(诊断)
  output reg signed [C_AD_DATA_DEPTH-1:0] peak_out,
  output reg [63:0]                    peak_time_out, // in clock cycles
  output reg [15:0]                    width_out,      // in samples
  output reg signed [C_AREA_WIDTH-1:0] area_out
);



  // Relative detection reference: when baseline is trusted, trigger against
  // (baseline + threshold); otherwise fall back to the absolute threshold.
  //
  // The sum MUST saturate. `baseline_out + threshold_value` is an 18-bit signed
  // add, and when the input clips the baseline settles near +FS (131071), so
  // baseline + threshold (e.g. 130027 + 3000 = 133027) wrapped to -129117. Every
  // sample was then "above threshold", pulse_active stayed high forever, the
  // pulse width watchdog fired no matter how large max_pulse_wid was, and the
  // baseline froze on that channel. Saturating sends the reference to +FS
  // instead, which correctly means "nothing can trigger".
  wire signed [C_AD_DATA_DEPTH:0] detect_sum =
      {baseline_out[C_AD_DATA_DEPTH-1], baseline_out} +
      {threshold_value[C_AD_DATA_DEPTH-1], threshold_value};

  wire signed [C_AD_DATA_DEPTH-1:0] detect_ref_sat =
      (detect_sum[C_AD_DATA_DEPTH:C_AD_DATA_DEPTH-1] == 2'b01) ? {1'b0, {(C_AD_DATA_DEPTH-1){1'b1}}} : // +FS
      (detect_sum[C_AD_DATA_DEPTH:C_AD_DATA_DEPTH-1] == 2'b10) ? {1'b1, {(C_AD_DATA_DEPTH-1){1'b0}}} : // -FS
                                                                detect_sum[C_AD_DATA_DEPTH-1:0];

  // A non-positive threshold carries no information ("peak height > 0" would flag
  // every sample above the baseline), so detection is disabled for that channel.
  // Without this, an un-configured window (threshold still 0) makes pulse_active
  // chatter on noise, which in turn gates the baseline's TRACK updates.
  wire threshold_usable = (threshold_value > 0);

  wire signed [C_AD_DATA_DEPTH-1:0] detect_ref =
      (baseline_valid && threshold_usable) ? detect_ref_sat : threshold_value;

  // Internal regs
  reg signed [C_AD_DATA_DEPTH-1:0] peak_reg;
  reg [15:0] width_reg;
  reg signed [C_AREA_WIDTH-1:0] area_reg;
  reg [63:0] peak_time_reg;
  reg in_pulse;

  // Debounce counters
  reg [$clog2(C_DEBOUNCE_LEN+1)-1:0] rise_count;
  reg [$clog2(C_DEBOUNCE_LEN+1)-1:0] fall_count;

  // Track whether a pulse completed during the current event
  reg pulse_occurred;

  // ---------------------------------------------------------------------------
  // 峰值质量门
  //
  // 现场用信号源测速时发现: 偶发的"测速 bad"几乎都是噪声刚好越过阈值形成的
  // 4 样本、峰值 548 码的假脉冲 —— 它单独开启/结束一个事件, 配对时拿到的是
  // 上一次事件的峰时间, 于是 dt 变成约一个脉冲周期而被判无效。
  //
  // 这里在脉冲结束时再判一次: 峰值必须比检测参考 detect_ref 再高出 peak_margin
  // 码。不满足则丢弃该脉冲 —— 不更新 peak_time_out、不更新指标、不计入
  // pulse_occurred, 于是它既不会污染速测配对, 也会让所属事件成为"空事件"。
  //
  // 判据放在脉冲结束而不是上升沿: 上升沿时刻与去抖完全不变, 所以对峰时间精度
  // (测速的核心)没有影响。peak_margin = 0 表示关闭, 行为与之前完全一致。
  // ---------------------------------------------------------------------------
  wire signed [C_AD_DATA_DEPTH:0] accept_sum =
      {detect_ref[C_AD_DATA_DEPTH-1], detect_ref} + {1'b0, peak_margin};

  wire peak_accept = (peak_margin == {C_AD_DATA_DEPTH{1'b0}})
                     || ({peak_reg[C_AD_DATA_DEPTH-1], peak_reg} >= accept_sum);

  assign pulse_valid_out = pulse_occurred;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_pulse     <= 1'b0;
      pulse_active <= 1'b0;
      pulse_done   <= 1'b0;
      peak_reg     <= {C_AD_DATA_DEPTH{1'b0}};
      width_reg    <= 16'd0;
      area_reg     <= {C_AREA_WIDTH{1'b0}};
      peak_time_reg <= 64'd0;
      peak_out     <= {C_AD_DATA_DEPTH{1'b0}};
      width_out    <= 16'd0;
      area_out     <= {C_AREA_WIDTH{1'b0}};
      peak_time_out <= 64'd0;
      rise_count   <= 0;
      fall_count   <= 0;
      pulse_occurred <= 1'b0;
      reject_count   <= 16'd0;
    end else begin
      pulse_done <= 1'b0; // default

      // On event boundary, clear outputs if no pulse completed during this event
      if (event_done) begin
        if (!pulse_occurred) begin
          peak_out      <= {C_AD_DATA_DEPTH{1'b0}};
          width_out     <= 16'd0;
          area_out      <= {C_AREA_WIDTH{1'b0}};
          peak_time_out <= 64'd0;
        end
        pulse_occurred <= 1'b0; // reset for next event
      end

      // threshold_usable gating: an un-configured channel (threshold <= 0) must not
      // manufacture pulses out of noise -- see the detect_ref comment above.
      if (sample_valid && enabled && threshold_usable) begin
        if (!in_pulse) begin
          // Not in pulse check for rising above threshold with debounce
          if (sample_in > detect_ref) begin
            if (rise_count < C_DEBOUNCE_LEN)
              rise_count <= rise_count + 1;
          end else begin
            rise_count <= 0;
          end

          if (rise_count >= C_DEBOUNCE_LEN) begin
            // Enter pulse
            in_pulse     <= 1'b1;
            pulse_active <= 1'b1;
            peak_reg     <= sample_in;
            width_reg    <= 16'd1;
            area_reg     <= $signed({{(C_AREA_WIDTH-C_AD_DATA_DEPTH){sample_in[C_AD_DATA_DEPTH-1]}}, sample_in});
            peak_time_reg <= time_stamp_in;
            rise_count   <= 0;
            fall_count   <= 0;
          end

        end else begin
          // In pulse update peak, width, area
          width_reg <= width_reg + 1;
          if (sample_in > peak_reg) begin
            peak_time_reg <= time_stamp_in;
            peak_reg <= sample_in;
          end
          area_reg <= area_reg + $signed({{(C_AREA_WIDTH-C_AD_DATA_DEPTH){sample_in[C_AD_DATA_DEPTH-1]}}, sample_in});

          // Falling below/equal threshold
          if (sample_in <= detect_ref) begin
            if (fall_count < C_DEBOUNCE_LEN)
              fall_count <= fall_count + 1;
          end else begin
            fall_count <= 0;
          end

          // Below threshold for debounce length -> end pulse
          if (fall_count >= C_DEBOUNCE_LEN) begin
            in_pulse     <= 1'b0;
            pulse_active <= 1'b0;
            pulse_done   <= 1'b1;
            if (peak_accept) begin
              pulse_occurred <= 1'b1;
              // Metric-level baseline correction at pulse end: subtract baseline
              // from raw peak/area. Detection now uses relative threshold (phase 2).
              peak_out     <= peak_reg - baseline_out;
              width_out    <= width_reg;
              area_out     <= area_reg - baseline_out * $signed({1'b0, width_reg});
              peak_time_out <= peak_time_reg;
            end else begin
              // 峰值只比阈值高一丁点 -> 判为噪声, 整条脉冲作废:
              // 指标清零、不更新峰时间(因此不会污染速测配对)、不计入 pulse_occurred
              // (因此所属事件会被 event_aggregator 当作空事件丢弃)。
              peak_out      <= {C_AD_DATA_DEPTH{1'b0}};
              width_out     <= 16'd0;
              area_out      <= {C_AREA_WIDTH{1'b0}};
              reject_count  <= reject_count + 1'b1;
            end
            // Reset working regs
            peak_reg     <= {C_AD_DATA_DEPTH{1'b0}};
            width_reg    <= 16'd0;
            area_reg     <= {C_AREA_WIDTH{1'b0}};
            peak_time_reg <= 64'd0;
            rise_count   <= 0;
            fall_count   <= 0;
          end
        end

      end else if (sample_valid && (!enabled || !threshold_usable)) begin
        // Disabled reset state
        in_pulse     <= 1'b0;
        pulse_active <= 1'b0;
        peak_reg     <= {C_AD_DATA_DEPTH{1'b0}};
        width_reg    <= 16'd0;
        area_reg     <= {C_AREA_WIDTH{1'b0}};
        rise_count   <= 0;
        fall_count   <= 0;
      end
    end
  end

endmodule
