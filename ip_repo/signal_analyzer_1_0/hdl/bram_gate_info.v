`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/06/09 09:51:33
// Design Name: 
// Module Name: bram_gate_info
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


module bram_gate_info #(
    parameter integer C_NUM_MAX_POINTS   = 12
//    parameter integer C_POINT_DATA_WIDTH = 32
//  BRAM读取位宽为32位 若小于32 可直接截取，大于需要重新设计 与写入格式有关 不需要定义参数
) (
    input wire clk,
    input wire rst_n,

    // BRAM interface 
    output wire         bram_clk,           // Clock signal for BRAM
    output wire         bram_rst,           // Reset signal for BRAM
    output reg  [31:0]  bram_addr,          // Address in BRAM
    output wire  [31:0]  bram_din,           // Data to write to BRAM
    input wire  [31:0]  bram_dout,          // Data read from BRAM
    output wire [3:0]   bram_we,            // Write enable for BRAM
    output wire          bram_en,            // Enable signal for BRAM

    // addr request
    input wire request,                     // active on rising edge
    input wire [31:0] start_native_addr,           // native addr for 32bits start from 0
    
    output reg  error,           // 0=ok 1=error
    output wire  busy,            // 0= idle, 1 = busy
    output reg  last,
    output reg [7: 0] gate_type,
    output reg [15: 0] gate_param,
    output reg [3: 0] x_channel,
    output reg [2: 0] x_type,
    output reg [3: 0] y_channel,
    output reg [2: 0] y_type,
    output reg [32 * C_NUM_MAX_POINTS - 1 : 0] gate_points_x,
    output reg [32 * C_NUM_MAX_POINTS - 1 : 0] gate_points_y
    );
    
    
    
    localparam [31:0] HEADER_BODY_CODE    = 32'h424F4459;
    localparam [31:0] HEADER_TAIL_CODE    = 32'h5441494C;
    
    localparam S_IDLE    = 3'd0;
    localparam S_DELAY  = 3'd1;
    localparam S_HEAD = 3'd2;   // check for package first pos 0x48454144
    localparam S_TYPE  = 3'd3;
    localparam S_CHANNEL  = 3'd4;
    localparam S_CHECK = 3'd5;  // check for data integrity
    localparam S_POINTS = 3'd6;
    reg [2:0] state;

    reg [31:0] check_valid;
    reg [31: 0] read_native_addr;
    reg [7:0] read_index;  // 读数据 由于有读延迟
    reg [7:0] write_index; // 写地址 地址会比数据大1
    reg request_dly;
    reg [7:0] data_length; 
    wire trigger_read = request & ~request_dly;
    assign bram_clk = clk;
    assign bram_rst = ~rst_n;
    assign bram_we = 4'd0;
    assign bram_din = 0;
    assign bram_en = (state != S_IDLE);
    assign busy = (state != S_IDLE);
    
    always @(posedge clk) begin
        if (!rst_n) begin
            request_dly <= 0;
        end else begin
            request_dly <= request;
        end
    end
    
    // READ_LATENCY = 1
    always @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            error <= 0;
            gate_type <= 0;
            gate_param <= 0;          
            gate_points_x <= 0;
            gate_points_y <= 0;
            bram_addr <= 0;
            check_valid <= 0;
            read_index <= 0;
            write_index <= 0;
            read_native_addr <= 0;
            data_length <= 0;
            last <= 0;
            x_channel <= 0;
            x_type <= 0;
            y_channel <= 0;
            y_type <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (trigger_read) begin
                        state <= S_DELAY;
                        bram_addr <= start_native_addr;
                        read_native_addr <= start_native_addr;
                        error <= 0;
                        check_valid <= 0;
                        read_index <= 0;
                        write_index <= 0;
                        data_length <= 0;
                        gate_type <= 0;
                        gate_param <= 0;          
                        gate_points_x <= 0;
                        gate_points_y <= 0;
                        x_channel <= 0;
                        x_type <= 0;
                        y_channel <= 0;
                        y_type <= 0;
                        last <= 0;
                    end
                end
                S_DELAY: begin
                    state <= S_HEAD;
                    bram_addr <= read_native_addr + 4;
                    read_native_addr <= read_native_addr + 4;
                end
                S_HEAD: begin
                    if (bram_dout == HEADER_BODY_CODE || 
                        bram_dout == HEADER_TAIL_CODE) begin
                        state <= S_TYPE;
                        last <= (bram_dout == HEADER_TAIL_CODE);
                        bram_addr <= read_native_addr + 4;
                        read_native_addr <= read_native_addr + 4;
                        check_valid <= check_valid ^ bram_dout;
                    end else begin
                        error <= 1;
                        state <= S_IDLE;
                    end
                end
                S_TYPE: begin
                    if (bram_dout[15:8] <= (C_NUM_MAX_POINTS * 2)) begin
                        state <= S_CHANNEL;
                        data_length <= bram_dout[15:8];
                        read_index <= 0;  // S_POINTS中读取的次数
                        write_index <= 2; // 读延迟 地址已经发送1个 正在发送第二个
                        bram_addr <= read_native_addr + 4;
                        read_native_addr <= read_native_addr + 4;
                        check_valid <= check_valid ^ bram_dout;
                        gate_type <= bram_dout[7:0];
                        gate_param <= bram_dout[31:16];
                    end else begin
                        state <= S_IDLE;
                        error <= 1;
                    end
                end
                S_CHANNEL: begin
                    state <= S_CHECK;
                    bram_addr <= read_native_addr + 4;
                    read_native_addr <= read_native_addr + 4;
                    check_valid <= check_valid ^ bram_dout;
                    x_channel <= bram_dout[2:0];
                    x_type <= bram_dout[9:8];
                    y_channel <= bram_dout[18:16];
                    y_type <= bram_dout[25:24];
                end
                S_CHECK: begin
                    check_valid <= check_valid ^ bram_dout;
                    if (data_length == 0) begin
                        state <= S_IDLE;
                        error <= (check_valid ^ bram_dout) != 0;
                    end else begin
                        state <= S_POINTS;
                        bram_addr <= read_native_addr + 4;
                        read_native_addr <= read_native_addr + 4;
                    end
                end
                S_POINTS: begin
                    if (write_index < data_length) begin
                        bram_addr <= read_native_addr + 4;
                        read_native_addr <= read_native_addr + 4;
                        write_index <= write_index + 1;
                    end
                    
                    check_valid <= check_valid ^ bram_dout;
                    if (read_index[0] == 0) begin
                        gate_points_x[32 * (read_index >> 1)+:32] <= bram_dout;
                    end else begin
                        gate_points_y[32 * (read_index >> 1)+:32] <= bram_dout;
                    end
                    
                    if ((read_index + 1) < data_length) begin
                        read_index <= read_index + 1;
                    end else begin
                        state <= S_IDLE;
                        error <= (check_valid ^ bram_dout) != 0;
                    end
                end
                default: begin
                   state <= S_IDLE;
                end
            endcase  
        end
    end

endmodule
