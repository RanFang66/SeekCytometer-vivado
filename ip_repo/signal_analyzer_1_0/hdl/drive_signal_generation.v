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
    reg [47:0]          delay_total;


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
                // Speed-based delay: scale measured time difference by coefficient
                delay_calculated <= measured_time_diff * measured_coe;
                delay_total <= (delay_calculated >> 14) + drive_delay;
            end else begin
                // Fixed delay when speed measurement is disabled
                delay_calculated <= 48'b0;
                delay_total <= {16'b0, drive_delay};
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
                        if (event_peak_time < time_us) begin
                            time_drive_start <= event_peak_time + {16'd0, delay_total};
                        end else begin
                            time_drive_start <= time_us + {16'd0, delay_total};
                        end
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
