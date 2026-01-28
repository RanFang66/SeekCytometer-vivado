//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/29/2025 06:05:11 PM
// Design Name: 
// Module Name: pulse_analyzer
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

`timescale 1ns/1ps
module pulse_analyzer #(
  parameter integer C_AD_DATA_DEPTH = 18,
  parameter integer C_AREA_WIDTH    = 32,
  parameter integer C_DEBOUNCE_LEN  = 3
)(
  input  wire                          clk,
  input  wire                          rst_n,
  input  wire [63:0]                   time_stamp_in, // in clock cycles
  input  wire                          sample_valid,   // new sample available
  input  wire signed [C_AD_DATA_DEPTH-1:0] sample_in,
  input  wire                          enabled,
  input  wire signed [C_AD_DATA_DEPTH-1:0] threshold_value,
  output reg                           pulse_active,   // high while in pulse
  output reg                           event_done,     // one clock pulse at pulse end
  output reg signed [C_AD_DATA_DEPTH-1:0] peak_out,
  output reg [31:0]                    peak_time_out, // in clock cycles
  output reg [15:0]                    width_out,      // in samples
  output reg signed [C_AREA_WIDTH-1:0] area_out
);



  // Internal regs
  reg signed [C_AD_DATA_DEPTH-1:0] peak_reg;
  reg [15:0] width_reg;
  reg signed [C_AREA_WIDTH-1:0] area_reg;
  reg [31:0] peak_time_reg;
  reg in_pulse;

  // Debounce counters
  reg [$clog2(C_DEBOUNCE_LEN+1)-1:0] rise_count;
  reg [$clog2(C_DEBOUNCE_LEN+1)-1:0] fall_count;

  always @(posedge clk) begin
    if (!rst_n) begin
      in_pulse     <= 1'b0;
      pulse_active <= 1'b0;
      event_done   <= 1'b0;
      peak_reg     <= {C_AD_DATA_DEPTH{1'b0}};
      width_reg    <= 16'd0;
      area_reg     <= {C_AREA_WIDTH{1'b0}};
      peak_time_reg <= 32'd0;
      peak_out     <= {C_AD_DATA_DEPTH{1'b0}};
      width_out    <= 16'd0;
      area_out     <= {C_AREA_WIDTH{1'b0}};
      peak_time_out <= 32'd0;
      rise_count   <= 0;
      fall_count   <= 0;
    end else begin
      event_done <= 1'b0; // default

      if (sample_valid && enabled) begin
        if (!in_pulse) begin
          // Not in pulse check for rising above threshold with debounce
          if (sample_in > threshold_value) begin
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
            peak_time_reg <= time_stamp_in[31:0];
            rise_count   <= 0;
            fall_count   <= 0;
          end

        end else begin
          // In pulse update peak, width, area
          width_reg <= width_reg + 1;
          if (sample_in > peak_reg) begin
            peak_time_reg <= time_stamp_in[31:0];
            peak_reg <= sample_in;
          end
          area_reg <= area_reg + $signed({{(C_AREA_WIDTH-C_AD_DATA_DEPTH){sample_in[C_AD_DATA_DEPTH-1]}}, sample_in});

          // Falling below/equal threshold
          if (sample_in <= threshold_value) begin
            if (fall_count < C_DEBOUNCE_LEN)
              fall_count <= fall_count + 1;
          end else begin
            fall_count <= 0;
          end

          // If below threshold for debounce length �? end pulse
          if (fall_count >= C_DEBOUNCE_LEN) begin
            in_pulse     <= 1'b0;
            pulse_active <= 1'b0;
            event_done   <= 1'b1;
            peak_out     <= peak_reg;
            width_out    <= width_reg;
            area_out     <= area_reg;
            peak_time_out <= peak_time_reg;
            // Reset working regs
            peak_reg     <= {C_AD_DATA_DEPTH{1'b0}};
            width_reg    <= 16'd0;
            area_reg     <= {C_AREA_WIDTH{1'b0}};
            peak_time_reg <= 32'd0;
            rise_count   <= 0;
            fall_count   <= 0;
          end
        end

      end else if (sample_valid && !enabled) begin
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
