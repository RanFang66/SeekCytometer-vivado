 module drive_signal_generation #(
    parameter integer SAMPLE_DATA_WIDTH = 16,
    parameter integer CHANNEL_NUM = 8
)(
    input wire clk,
    input wire rst_n,
    input wire sort_en,
    input wire sort_trig,
    input wire drive_type,  // 0: Level, 1: Edge
    input wire [31:0] time_us,
    input wire [31:0] drive_delay,
    input wire [31:0] drive_width,
    input wire [31:0] cooling_time,
    input wire [15:0] measured_time_diff,
    input wire [31:0] measured_coe,
    output reg [2:0]  drive_state,
    output wire        drive_level
);

    localparam			integer S_DRIVE_IDLE = 3'd0;
    localparam 			integer S_DRIVE_WAIT = 3'd1;
    localparam 			integer S_DRIVE_HIGH = 3'd2;
    localparam 			integer S_DRIVE_COOLDOWN = 3'd3;

    reg [31:0]          time_drive_start;
    reg [31:0]          time_drive_end;
    reg [31:0]          time_drive_cooling_end;
    reg                 drive_level_edge;
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
            delay_calculated <= measured_time_diff * measured_coe;    
            delay_total <= (delay_calculated >> 14) + drive_delay;
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
            time_drive_start <= 32'd0;
            time_drive_end <= 32'd0;
            time_drive_cooling_end <= 32'd0;
        end else begin
            case (drive_state)
                S_DRIVE_IDLE:
                begin
                    if (sort_start)
                    begin
                        drive_state <= S_DRIVE_WAIT;
                        time_drive_start <= (time_us + delay_total[31:0]);
                    end	
                end
                S_DRIVE_WAIT:
                begin
                    if (time_us >= time_drive_start)
                    begin
                        drive_state <= S_DRIVE_HIGH;
                        time_drive_end <= drive_type ? (time_us + 32'd10) : (time_us + drive_width); 
                        drive_level_edge <= ~drive_level_edge;
                    end 
                end	
                S_DRIVE_HIGH:
                begin
                    if (time_us >= time_drive_end)
                    begin
                        drive_state <= S_DRIVE_COOLDOWN;
                        time_drive_cooling_end <= (time_us + cooling_time);
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
                    time_drive_start <= 32'd0;
                    time_drive_end <= 32'd0;
                    time_drive_cooling_end <= 32'd0;
                end
            endcase
        end
    end
endmodule
