`timescale 1 ns / 1 ps

module ad_data_filter #
(
    parameter integer C_AD_DATA_DEPTH = 18,
    parameter integer C_AD_CHANNEL_NUM = 8
)
(
    input  wire clk,
    input  wire rst_n,

    input  wire ad_data_updated,

    input  wire signed [C_AD_DATA_DEPTH-1:0] ad_ch1_val,
    input  wire signed [C_AD_DATA_DEPTH-1:0] ad_ch2_val,
    input  wire signed [C_AD_DATA_DEPTH-1:0] ad_ch3_val,
    input  wire signed [C_AD_DATA_DEPTH-1:0] ad_ch4_val,
    input  wire signed [C_AD_DATA_DEPTH-1:0] ad_ch5_val,
    input  wire signed [C_AD_DATA_DEPTH-1:0] ad_ch6_val,
    input  wire signed [C_AD_DATA_DEPTH-1:0] ad_ch7_val,
    input  wire signed [C_AD_DATA_DEPTH-1:0] ad_ch8_val,

    output wire signed [C_AD_DATA_DEPTH-1:0] ad_ch1_val_filt,
    output wire signed [C_AD_DATA_DEPTH-1:0] ad_ch2_val_filt,
    output wire signed [C_AD_DATA_DEPTH-1:0] ad_ch3_val_filt,
    output wire signed [C_AD_DATA_DEPTH-1:0] ad_ch4_val_filt,
    output wire signed [C_AD_DATA_DEPTH-1:0] ad_ch5_val_filt,
    output wire signed [C_AD_DATA_DEPTH-1:0] ad_ch6_val_filt,
    output wire signed [C_AD_DATA_DEPTH-1:0] ad_ch7_val_filt,
    output wire signed [C_AD_DATA_DEPTH-1:0] ad_ch8_val_filt
);

localparam integer FILTER_LEN = 4;
localparam integer SUM_WIDTH  = C_AD_DATA_DEPTH + 2;

wire signed [C_AD_DATA_DEPTH-1:0] ad_ch_val [0:7];
assign ad_ch_val[0] = ad_ch1_val;
assign ad_ch_val[1] = ad_ch2_val;
assign ad_ch_val[2] = ad_ch3_val;
assign ad_ch_val[3] = ad_ch4_val;
assign ad_ch_val[4] = ad_ch5_val;
assign ad_ch_val[5] = ad_ch6_val;
assign ad_ch_val[6] = ad_ch7_val;
assign ad_ch_val[7] = ad_ch8_val;


reg signed [C_AD_DATA_DEPTH-1:0] ad_ch_val_dly0 [0:7];
reg signed [C_AD_DATA_DEPTH-1:0] ad_ch_val_dly1 [0:7];
reg signed [C_AD_DATA_DEPTH-1:0] ad_ch_val_dly2 [0:7];


reg signed [SUM_WIDTH-1:0] sum [0:7];
reg signed [C_AD_DATA_DEPTH-1:0] ad_ch_val_filt_arr [0:7];



integer ch;



always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (ch = 0; ch < 8; ch = ch + 1) begin
            ad_ch_val_dly0[ch]      <= {C_AD_DATA_DEPTH{1'b0}};
            ad_ch_val_dly1[ch]      <= {C_AD_DATA_DEPTH{1'b0}};
            ad_ch_val_dly2[ch]      <= {C_AD_DATA_DEPTH{1'b0}};
            sum[ch]                 <= {SUM_WIDTH{1'b0}};
            ad_ch_val_filt_arr[ch]  <= {C_AD_DATA_DEPTH{1'b0}};
        end
    end else if (ad_data_updated) begin
        for (ch = 0; ch < 8; ch = ch + 1) begin
            ad_ch_val_dly2[ch] <= ad_ch_val_dly1[ch];
            ad_ch_val_dly1[ch] <= ad_ch_val_dly0[ch];
            ad_ch_val_dly0[ch] <= ad_ch_val[ch];

            sum[ch] <= ad_ch_val_dly0[ch]
                     + ad_ch_val_dly1[ch]
                     + ad_ch_val_dly2[ch]
                     + ad_ch_val[ch];

            ad_ch_val_filt_arr[ch] <= (sum[ch]) >>> 2;
        end
    end
end

// Direct output from filter array (no extra register stage)
assign ad_ch1_val_filt = ad_ch_val_filt_arr[0];
assign ad_ch2_val_filt = ad_ch_val_filt_arr[1];
assign ad_ch3_val_filt = ad_ch_val_filt_arr[2];
assign ad_ch4_val_filt = ad_ch_val_filt_arr[3];
assign ad_ch5_val_filt = ad_ch_val_filt_arr[4];
assign ad_ch6_val_filt = ad_ch_val_filt_arr[5];
assign ad_ch7_val_filt = ad_ch_val_filt_arr[6];
assign ad_ch8_val_filt = ad_ch_val_filt_arr[7];

endmodule
