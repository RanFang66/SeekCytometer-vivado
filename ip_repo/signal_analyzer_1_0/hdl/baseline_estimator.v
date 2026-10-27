`timescale 1ns/1ps
// ----------------------------------------------------------------------------
// baseline_estimator  (minimal form, 2026-10-27)
//
// Single-pole leaky integrator, one always block, no state machine:
//
//   sample below the estimate -> fast correction (alpha = 2^-4)   : tracks the floor
//   sample above the estimate -> slow correction (alpha = 2^-K)   : ignores pulses
//
// Every step is a convex combination of the previous estimate and a sample:
//
//     next = baseline + (sample - baseline) / 2^k        (k >= 4)
//
// so the output is mathematically trapped between the previous estimate and the
// sample. It cannot leave the range spanned by the samples -- which is exactly
// the property the previous revision lost somewhere on the bench: it reported
// 131071 (= +full scale) while the raw samples sat at ~1300.
//
// Removed on purpose (each was a candidate for that failure and none of them is
// needed for the function): the S_ACQUIRE/S_TRACK state machine, the first-sample
// seed, pulse gating, the width watchdog, the rescue path and the divergence
// watchdog. What remains is small enough to reason about in one screen.
//
// Ports are unchanged so signal_analyzer_v1_0_S00_AXI needs no edit, and the
// ILA-probed net names (state / baseline / err_reg / baseline_valid / sample_in /
// pulse_active / baseline_out) are preserved so debug_core.xdc still binds.
//
//   acquire_force / bypass : reload the estimate from the live sample (Re-acquire)
//   alpha_shift            : up-leg shift K (alpha = 2^-K), clamped to [4, 20]
//   acquire_len            : warm-up samples before baseline_valid is asserted
//   state (probed)         : 0 = still warming up, 1 = converged
//   dbg_acq_cnt            : warm-up progress counter
// ----------------------------------------------------------------------------
module baseline_estimator #(
    parameter integer C_AD_DATA_DEPTH = 18,
    parameter integer C_FRAC_BITS     = 6
)(
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              sample_valid,
    (*MARK_DEBUG="true"*) input  wire signed [C_AD_DATA_DEPTH-1:0] sample_in,
    (*MARK_DEBUG="true"*) input  wire                              pulse_active,   // kept for probe binding only
    input  wire                              acquire_force,
    input  wire                              bypass,
    input  wire [4:0]                        alpha_shift,
    input  wire signed [7:0]                 slope_th,       // unused (kept for the register map)
    input  wire [15:0]                       acquire_len,
    input  wire [7:0]                        guard_len,      // unused
    input  wire [15:0]                       max_pulse_wid,  // unused
    (*MARK_DEBUG="true"*) output reg         baseline_valid,
    output reg                               overflow,       // always 0 now
    output wire                              dbg_state,
    output wire [15:0]                       dbg_acq_cnt,
    (*MARK_DEBUG="true"*) output wire signed [C_AD_DATA_DEPTH-1:0] baseline_out,
    output wire signed [C_AD_DATA_DEPTH-1:0] sample_baselined
);

    localparam integer CBW = C_AD_DATA_DEPTH + C_FRAC_BITS;   // 24

    (*MARK_DEBUG="true"*) reg [0:0]                state;     // 0 warming up, 1 converged
    (*MARK_DEBUG="true"*) reg signed [CBW-1:0]     baseline;  // Q18.6
    (*MARK_DEBUG="true"*) reg signed [CBW:0]       err_reg;   // one-cycle pipeline stage
    reg [15:0] warm_cnt;

    wire signed [CBW-1:0] sample_fp = {sample_in, {C_FRAC_BITS{1'b0}}};

    wire signed [CBW:0] err =
        {sample_fp[CBW-1], sample_fp} - {baseline[CBW-1], baseline};

    // Up-leg shift K in [4, 20]; the down-leg is fixed at 2^-4.
    wire [4:0] up_shift = (alpha_shift < 5'd4)  ? 5'd4 :
                          (alpha_shift > 5'd20) ? 5'd20 : alpha_shift;
    wire [4:0] cur_shift = err_reg[CBW] ? 5'd4 : up_shift;

    // ------------------------------------------------------------------------
    // Sign-magnitude correction.
    //
    // `err_reg >>> cur_shift` was synthesised as a LOGICAL shift: the bench ILA
    // showed a clearly negative error (err_reg top bit set, e.g. 0x1E2F15C =
    // -29770 codes) producing an UPWARD baseline step of the same magnitude, so
    // the estimate climbed into the +FS clamp (0x7FFFFF) and stayed there -- or,
    // once the rail-recovery guard was added, sawtoothed between +FS and the
    // sample. Shifting an explicit non-negative magnitude removes any dependence
    // on how a tool treats signedness inside an unsigned expression context.
    // ------------------------------------------------------------------------
    wire [CBW:0] err_mag  = err_reg[CBW] ? (~err_reg + 1'b1) : err_reg;
    wire [CBW:0] corr_mag = err_mag >> cur_shift;
    wire signed [CBW:0] corr_raw = err_reg[CBW] ? -$signed(corr_mag) : $signed(corr_mag);

    // Single-sample step clamp: one outlier sample (an ADC bit slip, a cable bump)
    // could otherwise drag the estimate by |err|/16 = ~8000 codes in one shot and
    // then take 2^14 samples (~80 ms) to recover -- which reads as "the baseline
    // jumps". Limiting one step to 2048 codes leaves normal tracking untouched
    // (|corr| during real pulse edges is far smaller once the estimate is on the
    // floor) and bounds the damage of any single bad sample.
    localparam signed [CBW:0] CORR_LIM = 25'sd131072;   // 2048 codes in Q18.6
    wire signed [CBW:0] corr =
        (corr_raw >  CORR_LIM) ?  CORR_LIM :
        (corr_raw < -CORR_LIM) ? -CORR_LIM : corr_raw;

    // Convex combination: |corr| <= |err| / 16, so the result stays between the
    // previous estimate and the sample. The saturation below is only a guard
    // against gross bit growth.
    wire signed [CBW:0] next_raw =
        {baseline[CBW-1], baseline} + corr;

    wire signed [CBW-1:0] next_baseline =
        (next_raw[CBW:CBW-1] == 2'b01) ? {1'b0, {(CBW-1){1'b1}}} :
        (next_raw[CBW:CBW-1] == 2'b10) ? {1'b1, {(CBW-1){1'b0}}} :
                                         next_raw[CBW-1:0];

    wire [15:0] warm_target = (acquire_len == 16'd0) ? 16'd1 : acquire_len;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            baseline       <= {CBW{1'b0}};
            err_reg        <= {(CBW+1){1'b0}};
            baseline_valid <= 1'b0;
            state          <= 1'b0;
            warm_cnt       <= 16'd0;
            overflow       <= 1'b0;
        end else begin
            overflow <= 1'b0;
            err_reg  <= err;

            if (sample_valid) begin
                if (bypass || acquire_force) begin
                    // Re-acquire / self-test: adopt the live sample immediately.
                    baseline  <= sample_fp;
                    err_reg   <= {(CBW+1){1'b0}};
                    warm_cnt  <= 16'd0;
                    state     <= 1'b0;
                    baseline_valid <= 1'b0;
                end else begin
                    baseline <= next_baseline;
                    if (warm_cnt < warm_target) begin
                        warm_cnt <= warm_cnt + 1'b1;
                    end else begin
                        state          <= 1'b1;
                        baseline_valid <= 1'b1;
                    end
                end
            end
        end
    end

    assign baseline_out     = baseline[CBW-1 : C_FRAC_BITS];
    assign sample_baselined = sample_in - baseline_out;
    assign dbg_state        = state;
    assign dbg_acq_cnt      = warm_cnt;

endmodule
