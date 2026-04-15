 module drive_signal_generation #(
    parameter integer SAMPLE_DATA_WIDTH = 16,
    parameter integer CHANNEL_NUM = 8
)(
    input wire clk,
    input wire rst_n,
    input wire sort_en,
    (*MARK_DEBUG="true"*)
    input wire sort_trig,
    (*MARK_DEBUG="true"*)
    input wire sort_abort,  // High-purity mode: abort pending sort in S_DRIVE_WAIT
    input wire drive_type,  // 0: Level, 1: Edge
    (*MARK_DEBUG="true"*)
    input wire [63:0] time_us,
    (*MARK_DEBUG="true"*)
    input wire [63:0] event_peak_time, 
    input wire [31:0] drive_delay,
    input wire [31:0] drive_width,
    input wire [31:0] cooling_time,
    input wire        speed_measure_en,
    input wire [15:0] measured_time_diff,
    input wire [31:0] measured_coe,
    (*MARK_DEBUG="true"*)
    input wire        delay_refer_en,

    (*MARK_DEBUG="true"*)
    output reg [2:0]  drive_state,
    (*MARK_DEBUG="true"*)
    output wire        drive_level
);

    localparam			integer S_DRIVE_IDLE = 3'd0;
    localparam 			integer S_DRIVE_WAIT = 3'd1;
    localparam 			integer S_DRIVE_HIGH = 3'd2;
    localparam 			integer S_DRIVE_COOLDOWN = 3'd3;


    (*MARK_DEBUG="true"*)
    reg [63:0]          time_drive_start;
    (*MARK_DEBUG="true"*)
    reg [63:0]          time_drive_end;
    (*MARK_DEBUG="true"*)
    reg [63:0]          time_drive_cooling_end;
    (*MARK_DEBUG="true"*)
    reg                 drive_level_edge;
    (*MARK_DEBUG="true"*)
    reg [47:0]          delay_calculated;           // 32 + 16
    // delay_total is signed: drive_delay may be negative (sign-extended from 32 bits).
    reg signed [47:0]   delay_total;


    assign drive_level = (drive_type) ? drive_level_edge : (drive_state == S_DRIVE_HIGH);
    
    reg sort_trig_d0;
    reg sort_trig_d1;
    wire sort_start;


    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            delay_calculated <= 48'b0;
            delay_total <= 48'b0;
        end else begin
            if (speed_measure_en) begin
                // Speed-based delay: scale measured time difference by coefficient.
                // (delay_calculated >> 14) is unsigned; drive_delay is sign-extended.
                delay_calculated <= measured_time_diff * measured_coe;
                delay_total <= $signed({2'b00, delay_calculated[47:14]}) + $signed({{16{drive_delay[31]}}, drive_delay});
            end else begin
                // Fixed delay when speed measurement is disabled (sign-extend drive_delay).
                delay_calculated <= 48'b0;
                delay_total <= {{16{drive_delay[31]}}, drive_delay};
            end
        end
    end


    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            sort_trig_d0 <= 1'b0;
            sort_trig_d1 <= 1'b0;
        end else begin
            sort_trig_d1 <= sort_trig_d0;
            sort_trig_d0 <= sort_trig;
        end
    end
    assign sort_start = (!sort_trig_d1 && sort_trig_d0); // rising edge detect

    // Compute the candidate drive start time using signed arithmetic so a
    // negative delay_total (negative drive_delay) brings the start time
    // earlier instead of wrapping past 64 bits and stalling in S_DRIVE_WAIT.
    wire signed [64:0] base_signed   = delay_refer_en ? $signed({1'b0, event_peak_time})
                                                      : $signed({1'b0, time_us});
    wire signed [64:0] delay_signed  = $signed({{17{delay_total[47]}}, delay_total});
    wire signed [64:0] start_calc    = base_signed + delay_signed;
    wire signed [64:0] time_us_signed= $signed({1'b0, time_us});
    // If the requested start is already in the past, fire on the next cycle.
    wire [63:0]        start_clamped = (start_calc <= time_us_signed) ? time_us
                                                                      : start_calc[63:0];

    always @ (posedge clk or negedge rst_n)
    begin
        if (rst_n == 1'b0 || !sort_en)
        begin
            drive_state <= 3'd0;
            drive_level_edge <= 1'b0;
            time_drive_start <= 64'd0;
            time_drive_end <= 64'd0;
            time_drive_cooling_end <= 64'd0;
        end else begin
            case (drive_state)
                S_DRIVE_IDLE:
                begin
                    if (sort_start)
                    begin
                        drive_state <= S_DRIVE_WAIT;
                        time_drive_start <= start_clamped;
                    end
                end
                S_DRIVE_WAIT:
                begin
                    if (sort_abort) begin
                        // High-purity mode: abort sort if non-sort event too close
                        drive_state <= S_DRIVE_IDLE;
                    end else if (time_us >= time_drive_start) begin
                        drive_state <= S_DRIVE_HIGH;
                        time_drive_end <= drive_type ? (time_us + 64'd10) : (time_us + {32'd0, drive_width});
                        drive_level_edge <= ~drive_level_edge;
                    end
                end
                S_DRIVE_HIGH:
                begin
                    if (time_us >= time_drive_end)
                    begin
                        drive_state <= S_DRIVE_COOLDOWN;
                        time_drive_cooling_end <= time_us + {32'd0, cooling_time};
                    end 
                end
                S_DRIVE_COOLDOWN:
                begin
                    if (time_us >= time_drive_cooling_end)
                    begin
                        drive_state <= S_DRIVE_IDLE;
                    end 
                end
                default:
                begin
                    drive_state <= S_DRIVE_IDLE;
                    time_drive_start <= 64'd0;
                    time_drive_end <= 64'd0;
                    time_drive_cooling_end <= 64'd0;
                end
            endcase
        end
    end
endmodule
