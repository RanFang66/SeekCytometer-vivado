`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// AD7606C-18 Parallel Interface (Final Optimized Pipeline Version)
// 
// 基于原始代码架构，保持双状态机流水线设计
// 
// 修复内容:
// 1. 修复配置写入数据格式 {1'b0, addr[6:0], data[7:0]}
// 2. 修复WR低脉冲宽度 >= 35ns
// 3. 修复18位数据LSB读取位映射
// 4. 修复数据采样延迟 >= 25ns
// 5. 添加复位后等待时间
//////////////////////////////////////////////////////////////////////////////////

module ad_7606c_if #(
    // ================= Timing parameters =================
    // All values are in clock cycles (200MHz clock, 5ns per cycle)
    parameter integer CONVST_LOW_CYCLES     = 8,    // 40ns (spec: >=10ns)
    parameter integer CONVST_PERIOD_CYCLES  = 71,  // 355us + 575us(busy)
    parameter integer CONVST_POST_CYCLES    = 12,   // 60ns

    parameter integer RD_LOW_CYCLES         = 6,    // 30ns (spec: >=10ns)
    parameter integer RD_CYCLE_CYCLES       = 10,   // 50ns full RD cycle
    parameter integer RD_DATA_SAMPLE        = 5,    // 25ns后采样数据
    
    // Configuration write timing
    parameter integer CFG_SETUP_CYCLES      = 6,    // 30ns
    parameter integer CFG_WR_CYCLES         = 10,    // 50ns (spec: >=35ns) ***FIXED***
    parameter integer CFG_HOLD_CYCLES       = 6     // 30ns
)(
    input              ad_clk,         // 200MHz clk
    input              rst_n,
     
    (* MARK_DEBUG = "true" *)
    inout  [15:0]      ad_data,
    (* MARK_DEBUG = "true" *)
    input              ad_busy,
    (* MARK_DEBUG = "true" *)
    input              first_data,

    output [2:0]       ad_os,
    (* MARK_DEBUG = "true" *)
    output reg         ad_cs,
    (* MARK_DEBUG = "true" *)
    output reg         ad_rd,
    (* MARK_DEBUG = "true" *)
    output reg         ad_wr,
    (* MARK_DEBUG = "true" *)
    output reg         ad_reset,
    (* MARK_DEBUG = "true" *)
    output reg         ad_convstab,
    (* MARK_DEBUG = "true" *)
    output reg         ad_data_valid,

    (* MARK_DEBUG = "true" *)
    output reg [17:0]  ad_ch1_val,
    output reg [17:0]  ad_ch2_val,
    output reg [17:0]  ad_ch3_val,
    output reg [17:0]  ad_ch4_val,
    output reg [17:0]  ad_ch5_val,
    output reg [17:0]  ad_ch6_val,
    output reg [17:0]  ad_ch7_val,
    output reg [17:0]  ad_ch8_val
);

assign ad_os = 3'b111;   // Software mode

(* MARK_DEBUG = "true" *)
wire [15:0] db_in;
(* MARK_DEBUG = "true" *)
reg  [15:0] db_out;
(* MARK_DEBUG = "true" *)
reg         db_oe; 

// ========================================================
// Read FSM states
// ========================================================
localparam S_IDLE     = 2'd0;
localparam S_READ_MSB = 2'd1;
localparam S_READ_LSB = 2'd2;
localparam S_DONE     = 2'd3;

(* MARK_DEBUG = "true" *)
reg [1:0]  ad_rd_state;
(* MARK_DEBUG = "true" *)
reg [4:0]  rd_cnt;
(* MARK_DEBUG = "true" *)
reg [2:0]  channel_idx;
reg [17:0] channel_buffer [0:7];
reg [2:0]  valid_hold_cnt;

// ========================================================
// Configuration WRITE FSM states
// ========================================================
localparam CFGW_IDLE  = 3'd0,
           CFGW_SETUP = 3'd1,
           CFGW_WRLOW = 3'd2,
           CFGW_HOLD  = 3'd3,
           CFGW_NEXT  = 3'd4,
           CFGW_DONE  = 3'd5;

(* MARK_DEBUG = "true" *)
reg [2:0] cfgw_state;
(* MARK_DEBUG = "true" *)
reg [5:0] cfgw_cnt;
(* MARK_DEBUG = "true" *)
reg [2:0] cfgw_idx;
(* MARK_DEBUG = "true" *)
reg       cfgw_done;

// ========================================================
// Conversion FSM states
// ========================================================
localparam S_CONV_WAIT_CONFIG = 3'd0;
localparam S_CONV_IDLE        = 3'd1;
localparam S_CONV_ASSERT      = 3'd2;
localparam S_CONV_RELEASE     = 3'd3;
localparam S_CONV_WAIT_FIRST  = 3'd4;
localparam S_CONV_WAIT_BUSY   = 3'd5;

(* MARK_DEBUG = "true" *)
reg [2:0]  conv_state;
(* MARK_DEBUG = "true" *)
reg [7:0]  conv_cnt;
(* MARK_DEBUG = "true" *)
reg        start_read;

// ========================================================
// IOBUF instantiation
// ========================================================
genvar i;
generate
    for (i = 0; i < 16; i = i + 1) begin : GEN_DB_IOBUF
        IOBUF u_iobuf (.I(db_out[i]), .O(db_in[i]), .T(~db_oe), .IO(ad_data[i]));
    end
endgenerate

// ========================================================
// Reset generation (5us pulse + 300us wait)
// ========================================================
reg [17:0] rst_cnt;
reg        reset_done;

always @(posedge ad_clk or negedge rst_n) begin
    if (!rst_n) begin
        rst_cnt    <= 18'd0;
        ad_reset   <= 1'b1;
        reset_done <= 1'b0;
    end else if (rst_cnt < 18'd1000) begin          // 5us reset pulse
        rst_cnt    <= rst_cnt + 1'b1;
        ad_reset   <= 1'b1;
        reset_done <= 1'b0;
    end else if (rst_cnt < 18'd61000) begin         // 300us wait (tDEVICE_SETUP=274us)
        rst_cnt    <= rst_cnt + 1'b1;
        ad_reset   <= 1'b0;
        reset_done <= 1'b0;
    end else begin
        ad_reset   <= 1'b0;
        reset_done <= 1'b1;
    end
end

// ========================================================
// Configuration data function
// Format: {R/W=0, Address[6:0], Data[7:0]} for DB17-DB2
// ========================================================
function [15:0] cfgw_word(input [2:0] idx);
    begin
        case (idx)
            // Register addr | data
            // 0x03: CH1_CH2 Range, 0x33 = both ±10V single-ended
            3'd0: cfgw_word = {1'b0, 7'h03, 8'h11};
            // 0x04: CH3_CH4 Range  
            3'd1: cfgw_word = {1'b0, 7'h04, 8'h11};
            // 0x05: CH5_CH6 Range
            3'd2: cfgw_word = {1'b0, 7'h05, 8'h11};
            // 0x06: CH7_CH8 Range
            3'd3: cfgw_word = {1'b0, 7'h06, 8'h11};
            // 0x07: Bandwidth = 0xFF (all channels high bandwidth)
            3'd4: cfgw_word = {1'b0, 7'h07, 8'h55};
            default: cfgw_word = 16'h0000;
        endcase
    end
endfunction

// ========================================================
// Configuration WRITE + ADC Read FSM
// ========================================================
always @(posedge ad_clk) begin
    if (!rst_n || !reset_done) begin
        cfgw_state     <= CFGW_IDLE;
        cfgw_idx       <= 3'd0;
        cfgw_cnt       <= 6'd0;
        cfgw_done      <= 1'b0;
        ad_cs          <= 1'b1;
        ad_wr          <= 1'b1;
        db_oe          <= 1'b0;
        ad_rd          <= 1'b1;

        ad_rd_state    <= S_IDLE;
        ad_data_valid  <= 1'b0;
        rd_cnt         <= 5'd0;
        channel_idx    <= 3'd0;
        valid_hold_cnt <= 3'd0;

        ad_ch1_val     <= 18'd0;
        ad_ch2_val     <= 18'd0;
        ad_ch3_val     <= 18'd0;
        ad_ch4_val     <= 18'd0;
        ad_ch5_val     <= 18'd0;
        ad_ch6_val     <= 18'd0;
        ad_ch7_val     <= 18'd0;
        ad_ch8_val     <= 18'd0;

    end else if (!cfgw_done) begin
        // ============================================
        // Configuration Write FSM
        // ============================================
        case (cfgw_state)
            CFGW_IDLE: begin
                ad_cs      <= 1'b0;
                cfgw_state <= CFGW_SETUP;
            end

            CFGW_SETUP: begin
                db_oe  <= 1'b1;
                db_out <= cfgw_word(cfgw_idx);
                ad_wr  <= 1'b1;
                if (cfgw_cnt == CFG_SETUP_CYCLES - 1) begin
                    cfgw_cnt   <= 6'd0;
                    cfgw_state <= CFGW_WRLOW;
                end else begin
                    cfgw_cnt <= cfgw_cnt + 1'b1;
                end
            end

            CFGW_WRLOW: begin
                ad_wr <= 1'b0;
                if (cfgw_cnt == CFG_WR_CYCLES - 1) begin
                    cfgw_cnt   <= 6'd0;
                    cfgw_state <= CFGW_HOLD;
                end else begin
                    cfgw_cnt <= cfgw_cnt + 1'b1;
                end
            end

            CFGW_HOLD: begin
                ad_wr <= 1'b1;
                if (cfgw_cnt == CFG_HOLD_CYCLES - 1) begin
                    cfgw_cnt   <= 6'd0;
                    cfgw_state <= CFGW_NEXT;
                end else begin
                    cfgw_cnt <= cfgw_cnt + 1'b1;
                end
            end

            CFGW_NEXT: begin
                if (cfgw_idx == 3'd4)
                    cfgw_state <= CFGW_DONE;
                else begin
                    cfgw_idx   <= cfgw_idx + 1'b1;
                    cfgw_state <= CFGW_SETUP;
                end
            end

            CFGW_DONE: begin
                ad_cs     <= 1'b1;
                db_oe     <= 1'b0;
                cfgw_done <= 1'b1;
            end
        endcase
        
    end else begin
        // ============================================
        // ADC Read FSM (after config done)
        // ============================================
        case (ad_rd_state)
            S_IDLE: begin
                ad_data_valid <= 1'b0;
                if (start_read) begin
                    ad_cs          <= 1'b0;
                    ad_rd          <= 1'b0;
                    rd_cnt         <= 5'd0;
                    channel_idx    <= 3'd0;
                    valid_hold_cnt <= 3'd0;
                    ad_rd_state    <= S_READ_MSB;
                end 
            end

            S_READ_MSB: begin
                case (rd_cnt)
                    5'd0: begin
                        ad_rd  <= 1'b0;
                        rd_cnt <= rd_cnt + 1'b1;
                    end
                    RD_DATA_SAMPLE: begin
                        // Sample high 16 bits (DB17-DB2 = ADC[17:2])
                        channel_buffer[channel_idx][17:2] <= db_in;
                        rd_cnt <= rd_cnt + 1'b1;
                    end
                    RD_LOW_CYCLES: begin
                        ad_rd  <= 1'b1;
                        rd_cnt <= rd_cnt + 1'b1;
                    end
                    RD_CYCLE_CYCLES: begin
                        rd_cnt      <= 5'd0;
                        ad_rd_state <= S_READ_LSB;
                    end
                    default: begin
                        rd_cnt <= rd_cnt + 1'b1;
                    end
                endcase
            end
            
            S_READ_LSB: begin
                case (rd_cnt)
                    5'd0: begin
                        ad_rd  <= 1'b0;
                        rd_cnt <= rd_cnt + 1'b1;
                    end
                    RD_DATA_SAMPLE: begin
                        // Sample low 2 bits
                        // DB17/DB1 pin -> ad_data[15] -> ADC Bit 1
                        // DB16/DB0 pin -> ad_data[14] -> ADC Bit 0
                        channel_buffer[channel_idx][1] <= db_in[15];
                        channel_buffer[channel_idx][0] <= db_in[14];
                        rd_cnt <= rd_cnt + 1'b1;
                    end
                    RD_LOW_CYCLES: begin
                        ad_rd  <= 1'b1;
                        rd_cnt <= rd_cnt + 1'b1;
                    end
                    RD_CYCLE_CYCLES: begin
                        if (channel_idx == 3'd7) begin
                            ad_rd_state <= S_DONE;
                            rd_cnt      <= 5'd0;
                        end else begin
                            channel_idx <= channel_idx + 1'b1;
                            rd_cnt      <= 5'd0;
                            ad_rd_state <= S_READ_MSB;
                        end
                    end
                    default: begin
                        rd_cnt <= rd_cnt + 1'b1;
                    end
                endcase
            end

            S_DONE: begin
                if (valid_hold_cnt == 3'd0) begin
                    ad_cs <= 1'b1;
                    ad_rd <= 1'b1;

                    ad_ch1_val <= channel_buffer[0];
                    ad_ch2_val <= channel_buffer[1];
                    ad_ch3_val <= channel_buffer[2];
                    ad_ch4_val <= channel_buffer[3];
                    ad_ch5_val <= channel_buffer[4];
                    ad_ch6_val <= channel_buffer[5];
                    ad_ch7_val <= channel_buffer[6];
                    ad_ch8_val <= channel_buffer[7];

                    ad_data_valid  <= 1'b1;
                    valid_hold_cnt <= 3'd1;
                end
                else if (valid_hold_cnt == 3'd4) begin
                    ad_data_valid <= 1'b0;
                    ad_rd_state   <= S_IDLE;
                end
                else begin
                    valid_hold_cnt <= valid_hold_cnt + 1'b1;
                end
            end

            default: ad_rd_state <= S_IDLE;
        endcase
    end
end

// ========================================================
// Conversion FSM (Independent - Pipeline with Read FSM)
// ========================================================
always @(posedge ad_clk) begin
    if (!rst_n || !reset_done) begin
        ad_convstab <= 1'b1;
        conv_state  <= S_CONV_WAIT_CONFIG;
        conv_cnt    <= 8'd0;
        start_read  <= 1'b0;
    end else begin
        case (conv_state)
            S_CONV_WAIT_CONFIG: begin
                ad_convstab <= 1'b1;
                start_read  <= 1'b0;
                if (cfgw_done) begin
                    conv_state <= S_CONV_IDLE;
                    conv_cnt   <= 8'd0;
                end
            end

            S_CONV_IDLE: begin
                ad_convstab <= 1'b1;
                start_read  <= 1'b0;
                if (conv_cnt == CONVST_PERIOD_CYCLES - 1) begin
                    conv_cnt   <= 8'd0;
                    conv_state <= S_CONV_ASSERT;
                end else begin
                    conv_cnt <= conv_cnt + 1'b1;
                end
            end

            S_CONV_ASSERT: begin
                ad_convstab <= 1'b0;
                if (conv_cnt == CONVST_LOW_CYCLES - 1) begin
                    conv_cnt   <= 8'd0;
                    conv_state <= S_CONV_RELEASE;
                end else begin
                    conv_cnt <= conv_cnt + 1'b1;
                end
            end

            S_CONV_RELEASE: begin
                ad_convstab <= 1'b1;
                if (conv_cnt == CONVST_POST_CYCLES - 1) begin
                    conv_cnt   <= 8'd0;
                    conv_state <= S_CONV_WAIT_FIRST;
                end else begin
                    conv_cnt <= conv_cnt + 1'b1;
                end
            end

            S_CONV_WAIT_FIRST: begin
                // Brief wait to ensure BUSY has risen
                if (conv_cnt == 8'd20) begin
                    conv_state <= S_CONV_WAIT_BUSY;
                    conv_cnt   <= 8'd0;
                end else begin
                    conv_cnt <= conv_cnt + 1'b1;
                end
            end

            S_CONV_WAIT_BUSY: begin
                if (!ad_busy) begin
                    start_read <= 1'b1;
                    conv_cnt   <= 8'd0;
                    conv_state <= S_CONV_IDLE;
                end else begin
                    start_read <= 1'b0;
                end
            end
            
            default: conv_state <= S_CONV_WAIT_CONFIG;
        endcase
    end
end

endmodule