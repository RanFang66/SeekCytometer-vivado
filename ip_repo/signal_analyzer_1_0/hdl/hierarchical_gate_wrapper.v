`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/08 17:40:43
// Design Name: 
// Module Name: hierarchical_gate_wrapper
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module hierarchical_gate_wrapper #(
    parameter integer C_NUM_MAX_POINTS   = 12,
    parameter integer C_POINT_DATA_WIDTH = 32,
    parameter NUM_CH = 8,
    parameter integer C_WIDTH_BITS = 16,
    parameter integer C_AREA_BITS  = 32,
    parameter integer C_PEAK_BITS  = 18
) (
    input wire  clk,
    input wire  rst_n,

    // 存储参数的BRAM接口
    output wire [31:0] bram_din,        // Data to write to BRAM
    output wire [31:0] bram_addr,        // Address in BRAM
    output wire [3:0] bram_we,            // Write enable for BRAM
    output wire bram_en,            // Enable signal for BRAM
    input  wire [31:0] bram_dout,       // Data read from BRAM, not used in this module
    output wire bram_rst,          // Reset signal for BRAM
    output wire bram_clk,          // Clock signal for BRAM
	
	input wire  enable,
		
	// 测试点输入
    input wire  trigger_in,
    input  wire signed [C_PEAK_BITS * NUM_CH-1:0] ch_peak_flat,
    input  wire [C_WIDTH_BITS * NUM_CH-1:0]       ch_width_flat,
    input  wire signed [C_AREA_BITS * NUM_CH-1:0] ch_area_flat,
//    input wire signed [C_POINT_DATA_WIDTH-1:0] point_x_in,
//    input wire signed [C_POINT_DATA_WIDTH-1:0] point_y_in,
    
    // 最终结果输出
    (*MARK_DEBUG="true"*) output wire  bram_error,  // 因读取门信息失败而中止
    (*MARK_DEBUG="true"*) output reg valid,  // 代表计算完成
    (*MARK_DEBUG="true"*) output reg result   // 在没有下一个输入点时代表上一个点的结果
    );
    localparam LENGTH_GATE_INFO    = 4 * 28;
    
    localparam ST_IDLE    = 2'd0;
    localparam ST_READY  = 2'd1;
    localparam ST_CONFIG = 2'd2;
    localparam ST_COMPUTE  = 2'd3;
    (*MARK_DEBUG="true"*)  reg [1:0] state;
    reg trigger_dly;
    reg trigger_bram_read;
    reg [31:0] bram_gate_addr;
    (*MARK_DEBUG="true"*) wire trigger_input = trigger_in & ~trigger_dly;
    (*MARK_DEBUG="true"*) wire bram_read_busy;
    wire [7:0] bram_gate_type;
    wire [15:0] bram_gate_param;
    wire [32 * C_NUM_MAX_POINTS - 1:0] bram_gate_points_x;
    wire [32 * C_NUM_MAX_POINTS - 1:0] bram_gate_points_y;
    
    wire [C_POINT_DATA_WIDTH * C_NUM_MAX_POINTS - 1:0] gate_points_x;
    wire [C_POINT_DATA_WIDTH * C_NUM_MAX_POINTS - 1:0] gate_points_y;
    
    // 测试点
    (*MARK_DEBUG="true"*) reg  trigger_gate_judge;
//    reg [C_POINT_DATA_WIDTH-1:0] point_x;
//    reg [C_POINT_DATA_WIDTH-1:0] point_y;
    (*MARK_DEBUG="true"*) wire signed [31:0] sort_compare_value_x;
	(*MARK_DEBUG="true"*) wire signed [31:0] sort_compare_value_y;
 
    // 门控参数输出
    (*MARK_DEBUG="true"*) reg [2:0]  gate_type;
    (*MARK_DEBUG="true"*) reg [$clog2(C_NUM_MAX_POINTS)-1:0] gate_points_num;
    (*MARK_DEBUG="true"*) reg [C_POINT_DATA_WIDTH * C_NUM_MAX_POINTS - 1:0] gate_points_x_pack;
    (*MARK_DEBUG="true"*) reg [C_POINT_DATA_WIDTH * C_NUM_MAX_POINTS - 1:0] gate_points_y_pack;
    
    // 单门控输出反馈
    (*MARK_DEBUG="true"*) wire gate_valid;
    (*MARK_DEBUG="true"*) wire gate_result;
    
    (*MARK_DEBUG="true"*) wire bram_info_last;
    (*MARK_DEBUG="true"*) reg bram_info_last_reg;
    
    wire [2:0] channelX;
    wire [2:0] channelY;
    wire [1:0] typeX;
    wire [1:0] typeY;
    (*MARK_DEBUG="true"*) reg [2:0] reg_channelX;
    (*MARK_DEBUG="true"*) reg [2:0] reg_channelY;
    (*MARK_DEBUG="true"*) reg [1:0] reg_typeX;
    (*MARK_DEBUG="true"*) reg [1:0] reg_typeY;
    
    (*MARK_DEBUG="true"*) reg signed [C_PEAK_BITS * NUM_CH-1:0] ch_peaks;
    reg [C_WIDTH_BITS * NUM_CH-1:0]       ch_widths;
    reg signed [C_AREA_BITS * NUM_CH-1:0] ch_areas;
    

	assign sort_compare_value_x =
    (reg_typeX == 2'b00) ?  {{(32-C_PEAK_BITS){ch_peaks[reg_channelX* C_PEAK_BITS + C_PEAK_BITS - 1]}},
                        ch_peaks[reg_channelX* C_PEAK_BITS +: C_PEAK_BITS]}:
    (reg_typeX == 2'b01) ? {{16'b0}, ch_widths[reg_channelX* C_WIDTH_BITS +: C_WIDTH_BITS]} :
    (reg_typeX == 2'b10) ? ch_areas[reg_channelX * C_AREA_BITS +: C_AREA_BITS] :
    32'b0;

	assign sort_compare_value_y =
    (reg_typeY == 2'b00) ? {{(32-C_PEAK_BITS){ch_peaks[reg_channelY* C_PEAK_BITS + C_PEAK_BITS - 1]}},
                        ch_peaks[reg_channelY* C_PEAK_BITS +: C_PEAK_BITS]}:
    (reg_typeY == 2'b01) ? {{16'b0}, ch_widths[reg_channelY* C_WIDTH_BITS +: C_WIDTH_BITS]} :
    (reg_typeY == 2'b10) ? ch_areas[reg_channelY * C_AREA_BITS +: C_AREA_BITS] :
    32'b0;
    
    
    always @(posedge clk) begin
        if (!rst_n) begin
            trigger_dly <= 0;
        end else begin
            trigger_dly <= trigger_in;
        end
    end
    
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= ST_IDLE; 
            trigger_bram_read <= 0;
            bram_gate_addr <= 0;
            bram_info_last_reg <= 0;
            ch_peaks <= 0;
            ch_areas <= 0;
            ch_widths <= 0;
            gate_type <= 0;
            gate_points_num <= 0;
            gate_points_x_pack <= 0;
            gate_points_y_pack <= 0;
            trigger_gate_judge <= 0;
            valid <= 0;
            result <= 0;
        end else begin
            case (state)
                ST_IDLE: begin
                    bram_gate_addr <= 0;
                    ch_peaks <= 0;
                    ch_areas <= 0;
                    ch_widths <= 0;
                    gate_type <= 0;
                    gate_points_num <= 0;
                    gate_points_x_pack <= 0;
                    gate_points_y_pack <= 0;
                    trigger_gate_judge <= 0;
                    bram_info_last_reg <= 0;
                    valid <= 0;
                    if (enable) begin
                        state <= ST_READY; 
                        trigger_bram_read <= 1;
                    end else begin
                        trigger_bram_read <= 0;
                    end
                end
                ST_READY: begin
                    trigger_bram_read <= 0;
                    if (enable) begin
                        if (trigger_input) begin
                            state <= ST_CONFIG; 
                            valid <= 0;
                            result <= 0;
                            ch_peaks <= ch_peak_flat;
                            ch_areas <= ch_area_flat;
                            ch_widths <= ch_width_flat;
                        end
                    end else begin 
                        state <= ST_IDLE; 
                    end
                end
                ST_CONFIG: begin
                    if (bram_error) begin
                        state <= ST_IDLE; 
                    end else if (~bram_read_busy) begin
                        state <= ST_COMPUTE;
                        if (bram_info_last) begin
                            trigger_bram_read <= 0;
                        end else begin
                            bram_gate_addr <= bram_gate_addr + LENGTH_GATE_INFO;
                            trigger_bram_read <= 1;
                        end
                        bram_info_last_reg <= bram_info_last;
                        gate_type <= bram_gate_type[2:0];
                        gate_points_num <= bram_gate_param[$clog2(C_NUM_MAX_POINTS)-1:0];
                        gate_points_x_pack <= gate_points_x;
                        gate_points_y_pack <= gate_points_y;
                        reg_channelX <= channelX;
                        reg_channelY <= channelY;
                        reg_typeX <= typeX;
                        reg_typeY <= typeY;
                        trigger_gate_judge <= 1;
                    end
                end
                ST_COMPUTE: begin
                    trigger_bram_read <= 0;
                    trigger_gate_judge <= 0;
                    if (gate_valid) begin
                        if (gate_result) begin
                            if (bram_info_last_reg) begin
                                state <= ST_IDLE;
                                valid <= 1;
                                result <= 1;
                            end else begin
                                state <= ST_CONFIG; 
                            end
                        end else begin
                            valid <= 1;
                            result <= 0;
                            state <= ST_IDLE; 
                        end
                    end
                end
            endcase
        end
    end
    
    gate_judge_pipeline #(
		.C_NUM_MAX_POINTS(12),
		.C_POINT_DATA_WIDTH(32)
	) u_gate_judge (
		.rst_n(rst_n),
		.sys_clk(clk),
		.enable(1'b1),
		.trigger(trigger_gate_judge),
		.point_x(sort_compare_value_x),
		.point_y(sort_compare_value_y),
		.gate_type(gate_type),
		.gate_points_num(gate_points_num),
		.gate_points_x_pack(gate_points_x_pack),
		.gate_points_y_pack(gate_points_y_pack),
		.valid(gate_valid),
		.result(gate_result)
	);
	
    bram_gate_info #(
		.C_NUM_MAX_POINTS(12)
	) gate_info (
        .clk(clk),
        .rst_n(rst_n),
    
        // BRAM interface 
        .bram_clk(bram_clk),
        .bram_rst(bram_rst),
        .bram_addr(bram_addr),
        .bram_din(bram_din),
        .bram_dout(bram_dout),
        .bram_we(bram_we),
        .bram_en(bram_en),
    
        // addr request
        .request(trigger_bram_read),
        .start_native_addr(bram_gate_addr),
        
        .error(bram_error),           // 0=ok 1=error
        .busy(bram_read_busy),            // 0= idle, 1 = busy
        .last(bram_info_last),
        .gate_type(bram_gate_type),
        .gate_param(bram_gate_param),  
        .x_channel(channelX),
        .x_type(typeX),
        .y_channel(channelY),
        .y_type(typeY),        
        .gate_points_x(bram_gate_points_x),
        .gate_points_y(bram_gate_points_y)
    );
    
    genvar i;
    generate
        for (i = 0; i < C_NUM_MAX_POINTS; i = i + 1) begin
            assign gate_points_x[i* C_POINT_DATA_WIDTH +: C_POINT_DATA_WIDTH] = bram_gate_points_x[i* 32 +: C_POINT_DATA_WIDTH];
            assign gate_points_y[i* C_POINT_DATA_WIDTH +: C_POINT_DATA_WIDTH] = bram_gate_points_y[i* 32 +: C_POINT_DATA_WIDTH];
        end
    endgenerate
endmodule
