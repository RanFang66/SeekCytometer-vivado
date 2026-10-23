`timescale 1ns/1ps
// ----------------------------------------------------------------------------
// baseline_estimator
//
// Per-channel signal baseline estimator (leaky integrator / EMA).
//
// Two-phase state machine:
//   S_ACQUIRE : open-loop fast EMA (shift = ACQ_SHIFT = 4) for acquire_len
//               samples, then assert baseline_valid and enter S_TRACK.
//   S_TRACK   : closed-loop slow EMA (shift = alpha_shift), gated by
//               (!pulse_active) & settle(guard) & slope secondary gate.
//
// Baseline is kept in Q(C_AD_DATA_DEPTH.C_FRAC_BITS) fixed point to avoid the
// sticky quantization caused by repeated right-shifts. baseline_out is the
// integer part; sample_baselined = sample_in - baseline_out.
//
// Gating is controlled by inputs. In phase 1 tie pulse_active=0, slope_th=0,
// acquire_force=0 so the estimator runs ungated (updates every valid sample).
// ----------------------------------------------------------------------------
module baseline_estimator #(
    parameter integer C_AD_DATA_DEPTH = 18,
    parameter integer C_FRAC_BITS     = 6
)(
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              sample_valid,   // filtered sample update edge
    input  wire signed [C_AD_DATA_DEPTH-1:0] sample_in,      // filtered sample
    input  wire                              pulse_active,   // from pulse_analyzer (registered, 1 clk late)
    input  wire                              acquire_force,  // PS: force re-acquire
    input  wire [4:0]                        alpha_shift,    // slow-track shift K (alpha = 2^-K)
    input  wire signed [7:0]                 slope_th,       // slope secondary gate; <=0 disables
    input  wire [15:0]                       acquire_len,    // runtime: open-loop acquire sample count N
    input  wire [7:0]                        guard_len,      // runtime: settle guard count after falling edge
    input  wire [15:0]                       max_pulse_wid,  // runtime: watchdog threshold (samples)
    (*MARK_DEBUG="true"*) output reg         baseline_valid, // 1 = baseline trusted
    (*MARK_DEBUG="true"*) output wire signed [C_AD_DATA_DEPTH-1:0] baseline_out,    // integer baseline
    output wire signed [C_AD_DATA_DEPTH-1:0] sample_baselined   // sample - baseline
);

    localparam integer C_BASELINE_WIDTH = C_AD_DATA_DEPTH + C_FRAC_BITS; // 24

    localparam [0:0] S_ACQUIRE = 1'b0;
    localparam [0:0] S_TRACK   = 1'b1;

    localparam [4:0] ACQ_SHIFT = 5'd4; // fast EMA shift in ACQUIRE (alpha = 2^-4)

    (*MARK_DEBUG="true"*) reg [0:0] state;
    (*MARK_DEBUG="true"*) reg signed [C_BASELINE_WIDTH-1:0] baseline;      // Q18.6
    reg [15:0] acq_cnt;    // sized to runtime acquire_len (16-bit)
    reg [7:0]  guard_cnt;  // sized to runtime guard_len (8-bit)
    reg [15:0] wid_cnt;    // sized to runtime max_pulse_wid (16-bit)
    reg signed [C_AD_DATA_DEPTH-1:0]    sample_prev;
    reg                                 first_sample;
    reg                                 pulse_active_d1;

    // Fixed-point sample: sample_in << C_FRAC_BITS (sign preserved by concat).
    wire signed [C_BASELINE_WIDTH-1:0] sample_fp = {sample_in, {C_FRAC_BITS{1'b0}}};

    // Signed error with one extra bit to avoid overflow on the subtraction.
    wire signed [C_BASELINE_WIDTH:0] err =
        {sample_fp[C_BASELINE_WIDTH-1], sample_fp} -
        {baseline[C_BASELINE_WIDTH-1], baseline};

    // EMA shift: fast in ACQUIRE, slow (alpha_shift) in TRACK. Clamp to 24 so the
    // shift never exceeds the 25-bit err width (avoids >>> sign-fill for alpha_shift
    // >= 25; alpha >= 24 is already "hold forever" at 1 MHz).
    wire [4:0] ema_shift = (state == S_ACQUIRE) ? ACQ_SHIFT : ((alpha_shift > 5'd24) ? 5'd24 : alpha_shift);

    // Slope secondary gate (disabled when slope_th <= 0).
    wire signed [C_AD_DATA_DEPTH-1:0] sample_delta = sample_in - sample_prev;
    wire slope_ok = (slope_th <= 0) ||
                    ((sample_delta < slope_th) && (sample_delta > -slope_th));

    wire pulse_fall = pulse_active_d1 && !pulse_active;

    // In-baseline condition: not pulsing, settled, and slope within gate.
    wire in_baseline = !pulse_active && (guard_cnt == 0) && slope_ok;

    // Candidate next baseline (kept 25-bit signed to avoid overflow on add).
    wire signed [C_BASELINE_WIDTH:0] next_baseline =
        {baseline[C_BASELINE_WIDTH-1], baseline} + (err >>> ema_shift);

    // Guard acquire_len == 0: acquire_len-1 would wrap (0xFFFF) and the ACQUIRE
    // termination compare would never match, hanging the estimator in ACQUIRE.
    wire [15:0] acquire_len_eff = (acquire_len == 16'd0) ? 16'd1 : acquire_len;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_ACQUIRE;
            baseline       <= {C_BASELINE_WIDTH{1'b0}};
            baseline_valid <= 1'b0;
            acq_cnt        <= 0;
            guard_cnt      <= 0;
            wid_cnt        <= 0;
            sample_prev    <= {C_AD_DATA_DEPTH{1'b0}};
            first_sample   <= 1'b1;
            pulse_active_d1 <= 1'b0;
        end else begin
            pulse_active_d1 <= pulse_active;

            if (sample_valid) begin
                // Watchdog: count consecutive pulse-active samples.
                if (pulse_active) begin
                    if (wid_cnt < max_pulse_wid)
                        wid_cnt <= wid_cnt + 1;
                end else begin
                    wid_cnt <= 0;
                end

                // Settle guard: reload on pulse falling edge, else count down.
                if (pulse_fall)
                    guard_cnt <= guard_len;
                else if (guard_cnt > 0)
                    guard_cnt <= guard_cnt - 1;

                sample_prev <= sample_in;

                if (first_sample) begin
                    // Seed with the first sample to speed up convergence.
                    baseline     <= sample_fp;
                    first_sample <= 1'b0;
                    acq_cnt      <= 0;
                end else begin
                    case (state)
                        S_ACQUIRE: begin
                            baseline <= next_baseline[C_BASELINE_WIDTH-1:0];
                            if (acq_cnt == acquire_len_eff - 1) begin
                                state          <= S_TRACK;
                                baseline_valid <= 1'b1;
                                acq_cnt        <= 0;
                            end else begin
                                acq_cnt <= acq_cnt + 1;
                            end
                        end
                        S_TRACK: begin
                            if (in_baseline)
                                baseline <= next_baseline[C_BASELINE_WIDTH-1:0];
                            if (acquire_force || (wid_cnt >= max_pulse_wid)) begin
                                state          <= S_ACQUIRE;
                                baseline_valid <= 1'b0;
                                acq_cnt        <= 0;
                            end
                        end
                        default: begin
                            state <= S_ACQUIRE;
                        end
                    endcase
                end
            end
        end
    end

    assign baseline_out     = baseline[C_BASELINE_WIDTH-1 : C_FRAC_BITS];
    assign sample_baselined = sample_in - baseline_out;

endmodule
