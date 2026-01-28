
`timescale 1 ns / 1 ps

	module signal_analyzer_v1_0 #
	(
		// Users to add parameters here
        parameter integer  C_AD_DATA_DEPTH = 18,
        parameter integer  C_AD_CHANNEL_NUM = 8,
		// User parameters ends
		// Do not modify the parameters beyond this line


		// Parameters of Axi Slave Bus Interface S00_AXI
		parameter integer C_S00_AXI_DATA_WIDTH	= 32,
		parameter integer C_S00_AXI_ADDR_WIDTH	= 8
	)
	(
		// Users to add ports here
		input wire ad_data_valid,
        input wire [C_AD_DATA_DEPTH-1:0] ad_ch1_val,
        input wire [C_AD_DATA_DEPTH-1:0] ad_ch2_val,
        input wire [C_AD_DATA_DEPTH-1:0] ad_ch3_val,
        input wire [C_AD_DATA_DEPTH-1:0] ad_ch4_val,
        input wire [C_AD_DATA_DEPTH-1:0] ad_ch5_val,
        input wire [C_AD_DATA_DEPTH-1:0] ad_ch6_val,
        input wire [C_AD_DATA_DEPTH-1:0] ad_ch7_val,
        input wire [C_AD_DATA_DEPTH-1:0] ad_ch8_val,

		output wire event_active,
		output wire event_done, // high for one clock cycle when event is done
		output wire [C_AD_CHANNEL_NUM-1: 0] channel_active,

		output wire [2:0] drive_state_out,
		output wire drive_level_out,


		output wire [31:0] bram_din_a,        // Data to write to BRAM
		output wire [31:0] bram_addr_a, // Address in BRAM
		output wire [3:0] bram_we_a,            // Write enable for BRAM
		output wire bram_en_a,            // Enable signal for BRAM
		input  wire [31:0] bram_dout_a,       // Data read from BRAM, not used in this module
		output wire bram_rst_a,          // Reset signal for BRAM
		output wire bram_clk_a,          // Clock signal for BRAM
		


		// User ports ends
		// Do not modify the ports beyond this line


		// Ports of Axi Slave Bus Interface S00_AXI
		input wire  s00_axi_aclk,
		input wire  s00_axi_aresetn,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_awaddr,
		input wire [2 : 0] s00_axi_awprot,
		input wire  s00_axi_awvalid,
		output wire  s00_axi_awready,
		input wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_wdata,
		input wire [(C_S00_AXI_DATA_WIDTH/8)-1 : 0] s00_axi_wstrb,
		input wire  s00_axi_wvalid,
		output wire  s00_axi_wready,
		output wire [1 : 0] s00_axi_bresp,
		output wire  s00_axi_bvalid,
		input wire  s00_axi_bready,
		input wire [C_S00_AXI_ADDR_WIDTH-1 : 0] s00_axi_araddr,
		input wire [2 : 0] s00_axi_arprot,
		input wire  s00_axi_arvalid,
		output wire  s00_axi_arready,
		output wire [C_S00_AXI_DATA_WIDTH-1 : 0] s00_axi_rdata,
		output wire [1 : 0] s00_axi_rresp,
		output wire  s00_axi_rvalid,
		input wire  s00_axi_rready
	);
	wire bram_we_internal; // Internal write enable signal for BRAM

	assign bram_rst_a = ~s00_axi_aresetn; // Active low reset for BRAM
	assign bram_we_a = {4{bram_we_internal}};  // 1bit write enable for each byte in BRAM
	assign bram_clk_a = s00_axi_aclk; // Use AXI clock for BRAM

// Instantiation of Axi Bus Interface S00_AXI
	signal_analyzer_v1_0_S00_AXI # ( 
		.C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH),
		.C_AD_DATA_DEPTH(C_AD_DATA_DEPTH),
		.C_AD_CHANNEL_NUM(C_AD_CHANNEL_NUM)
	) signal_analyzer_v1_0_S00_AXI_inst (
		// Users to add ports here
		.ad_data_valid(ad_data_valid),
		.ad_ch1_val(ad_ch1_val),
		.ad_ch2_val(ad_ch2_val),
		.ad_ch3_val(ad_ch3_val),
		.ad_ch4_val(ad_ch4_val),
		.ad_ch5_val(ad_ch5_val),
		.ad_ch6_val(ad_ch6_val),
		.ad_ch7_val(ad_ch7_val),
		.ad_ch8_val(ad_ch8_val),

		.event_active(event_active),
		.channel_active(channel_active),
		.event_done(event_done), // high for one clock cycle when event is done
		.drive_state_out(drive_state_out),
		.drive_level_out(drive_level_out),

		.bram_din_a(bram_din_a),        		// Data to write to BRAM
		.bram_addr_a(bram_addr_a), 				// Address in BRAM
		.bram_we_a(bram_we_internal),            // Write enable for BRAM
		.bram_en_a(bram_en_a),            		// Enable signal for BRAM


		.S_AXI_ACLK(s00_axi_aclk),
		.S_AXI_ARESETN(s00_axi_aresetn),
		.S_AXI_AWADDR(s00_axi_awaddr),
		.S_AXI_AWPROT(s00_axi_awprot),
		.S_AXI_AWVALID(s00_axi_awvalid),
		.S_AXI_AWREADY(s00_axi_awready),
		.S_AXI_WDATA(s00_axi_wdata),
		.S_AXI_WSTRB(s00_axi_wstrb),
		.S_AXI_WVALID(s00_axi_wvalid),
		.S_AXI_WREADY(s00_axi_wready),
		.S_AXI_BRESP(s00_axi_bresp),
		.S_AXI_BVALID(s00_axi_bvalid),
		.S_AXI_BREADY(s00_axi_bready),
		.S_AXI_ARADDR(s00_axi_araddr),
		.S_AXI_ARPROT(s00_axi_arprot),
		.S_AXI_ARVALID(s00_axi_arvalid),
		.S_AXI_ARREADY(s00_axi_arready),
		.S_AXI_RDATA(s00_axi_rdata),
		.S_AXI_RRESP(s00_axi_rresp),
		.S_AXI_RVALID(s00_axi_rvalid),
		.S_AXI_RREADY(s00_axi_rready)
	);

	// Add user logic here

	// User logic ends

	endmodule
