`timescale 1ns / 1ps
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


module pulse_analyzer # 
(
    parameter integer C_AD_DATA_DEPTH = 18 // Width of the ad_data signal
)
(
    input wire clk,
    input wire rst_n,

    input wire enabled,
    input wire ad_data_updated,
    input wire [C_AD_DATA_DEPTH-1:0] ad_data,
    input wire [C_AD_DATA_DEPTH-1:0] threshold_value,

    output reg [C_AD_DATA_DEPTH-1:0] pulse_peak,
    output reg [15:0]                pulse_width,
    output reg [31:0]                pulse_area,
    
    output wire                      pulse_active
);

    reg in_pulse;
    reg [15:0] width_counter;
    reg [31:0] area_accumulator;
    reg [17:0] peak_value;

    assign pulse_active = in_pulse;
    reg ad_data_d0;
    reg ad_data_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ad_data_d0 <= 0;
            ad_data_d1 <= 0;
        end else begin
            if (ad_data_updated) begin
                ad_data_d0 <= ad_data;
                ad_data_d1 <= ad_data_d0;
            end else begin
                ad_data_d0 <= ad_data_d0; // Maintain previous value if not updated
                ad_data_d1 <= ad_data_d1; // Maintain previous value if not updated
            end
        end
    end

    // Detect pulse start condition
    // A pulse starts when the current ad_data and the previous two ad_datas are above the threshold_value
    wire pulse_start = (ad_data_d0 > threshold_value) && (ad_data_d1 > threshold_value) && (ad_data > threshold_value);
    // Detect pulse end condition
    // A pulse ends when the current ad_data and the previous two ad_datas are below the threshold_value
    wire pulse_end = (ad_data_d0 <= threshold_value) && (ad_data_d1 <= threshold_value) && (ad_data <= threshold_value);



    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_pulse         <= 0;
            width_counter    <= 0;
            area_accumulator <= 0;
            peak_value       <= 0;

            pulse_width <= 0;
            pulse_area  <= 0;
            pulse_peak  <= 0;
        end else begin
            if (enabled) begin
                if (ad_data_updated) begin
                    if (pulse_start && !in_pulse) begin
                        // Pulse start
                        in_pulse         <= 1;
                        width_counter    <= 16'd1;
                        area_accumulator <= ad_data;
                        peak_value       <= ad_data;
                    end else if (in_pulse && ad_data > threshold_value) begin
                        // Pulse continues
                        width_counter    <= width_counter + 1;
                        area_accumulator <= area_accumulator + ad_data;
                        if (ad_data > peak_value)
                            peak_value <= ad_data;
                    end else if (in_pulse && pulse_end) begin
                        // Pulse end
                        in_pulse     <= 0;
                        pulse_width  <= width_counter;
                        pulse_area   <= area_accumulator;
                        pulse_peak   <= peak_value;

                        // Reset pulse state
                        width_counter    <= 0;
                        area_accumulator <= 0;
                        peak_value       <= 0;
                    end
                end
            end else begin
                // Reset pulse state if not active
                in_pulse         <= 0;
                width_counter    <= 0;
                area_accumulator <= 0;
                peak_value       <= 0;
            end
        end
    end

endmodule
