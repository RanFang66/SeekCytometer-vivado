
`timescale 1 ns / 1 ps

	module ad_sample_v1_0 #
	(
		// Users to add parameters here
		parameter integer C_AD_DATA_WIDTH = 18, // Width of each channel data
		parameter integer C_AD_CHANNELS = 8,    // Number of channels (1 to 8)
		
		
		// Parameters of Axi Master Bus Interface M00_AXIS
		parameter integer C_M00_AXIS_TDATA_WIDTH	= 32,
		parameter integer C_M00_AXIS_START_COUNT	= 32,
		// User parameters ends
		// Do not modify the parameters beyond this line


		// Parameters of Axi Slave Bus Interface S00_AXI
		parameter integer C_S00_AXI_DATA_WIDTH	= 32,
		parameter integer C_S00_AXI_ADDR_WIDTH	= 6
	)
	(
		// Users to add ports here
		inout [15:0]       	ad_data,        // ad7606 data
		input              	ad_busy,        // ad7606 busy
		input              	ad_first_data,     // ad7606 first data
		output [2:0]       	ad_os,          // ad7606 oversampling ratio
		output wire         ad_cs,          // ad7606 chip select
		output wire         ad_rd,          // ad7606 read data
		output wire     	ad_wr,          // ad7606 write data;
		output wire         ad_reset,       // ad7606 reset
		output wire         ad_convstab,    // ad7606 start conversion
		output wire         ad_data_valid,
		output wire [17:0]  ad_ch1_val,
		output wire [17:0]  ad_ch2_val,
		output wire [17:0]  ad_ch3_val,
		output wire [17:0]  ad_ch4_val,
		output wire [17:0]  ad_ch5_val,
		output wire [17:0]  ad_ch6_val,
		output wire [17:0]  ad_ch7_val,
		output wire [17:0]  ad_ch8_val,
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
		input wire  s00_axi_rready,
		
		// Ports of Axi Master Bus Interface M00_AXIS
		input wire  m00_axis_aclk,
		input wire  m00_axis_aresetn,
		output wire  m00_axis_tvalid,
		output wire [C_M00_AXIS_TDATA_WIDTH-1 : 0] m00_axis_tdata,
		output wire [(C_M00_AXIS_TDATA_WIDTH/8)-1 : 0] m00_axis_tkeep,
		output wire [(C_M00_AXIS_TDATA_WIDTH/8)-1 : 0] m00_axis_tstrb,
		output wire  m00_axis_tlast,
		input wire  m00_axis_tready
		
	);
	
	wire en_streaming; 				// Enable streaming from the AXI slave interface
	wire [1:0] streaming_status; 	// Status of the streaming operation
	wire [31:0] stream_length;   	// Length of the stream in number of samples
	
// Instantiation of Axi Bus Interface S00_AXI
	ad_sample_v1_0_S00_AXI # ( 
		.C_S_AXI_DATA_WIDTH(C_S00_AXI_DATA_WIDTH),
		.C_S_AXI_ADDR_WIDTH(C_S00_AXI_ADDR_WIDTH)
	) ad_sample_v1_0_S00_AXI_inst (
	   	.en_streaming(en_streaming),
		.streaming_status(streaming_status),
	    .stream_length(stream_length),
	
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


// Instantiation of Axi Bus Interface M00_AXIS
	ad_sample_master_stream_v1_0_M00_AXIS # ( 
		.C_M_AXIS_TDATA_WIDTH(C_M00_AXIS_TDATA_WIDTH),
		.C_M_START_COUNT(C_M00_AXIS_START_COUNT)
	) ad_sample_master_stream_v1_0_M00_AXIS_inst (
		.en_streaming(en_streaming),
		.stream_length(stream_length),
		.ad_data_valid(ad_data_valid),
		.ad_ch1_val(ad_ch1_val),
		.ad_ch2_val(ad_ch2_val),
		.ad_ch3_val(ad_ch3_val),
		.ad_ch4_val(ad_ch4_val),
		.ad_ch5_val(ad_ch5_val),
		.ad_ch6_val(ad_ch6_val),
		.ad_ch7_val(ad_ch7_val),
		.ad_ch8_val(ad_ch8_val),
		.streaming_status(streaming_status),

		.M_AXIS_ACLK(m00_axis_aclk),
		.M_AXIS_ARESETN(m00_axis_aresetn),
		.M_AXIS_TVALID(m00_axis_tvalid),
		.M_AXIS_TDATA(m00_axis_tdata),
		.M_AXIS_TSTRB(m00_axis_tstrb),
		.M_AXIS_TKEEP(m00_axis_tkeep),
		.M_AXIS_TLAST(m00_axis_tlast),
		.M_AXIS_TREADY(m00_axis_tready)
	);


	// Add user logic here
    // Instantiation of AD 7606C module	
	ad_7606c_if ad_7606c_inst (
		.ad_clk(s00_axi_aclk), // Use the AXI clock for AD 7606C
		.rst_n(s00_axi_aresetn), // Use the AXI reset for AD 7606C
		.ad_data(ad_data),
		.ad_busy(ad_busy),
		.first_data(ad_first_data),
		.ad_os(ad_os),
		.ad_cs(ad_cs),
		.ad_rd(ad_rd),
		.ad_wr(ad_wr),
		.ad_reset(ad_reset),
		.ad_convstab(ad_convstab),
		.ad_data_valid(ad_data_valid),
		.ad_ch1_val(ad_ch1_val),
		.ad_ch2_val(ad_ch2_val),
		.ad_ch3_val(ad_ch3_val),
		.ad_ch4_val(ad_ch4_val),
		.ad_ch5_val(ad_ch5_val),
		.ad_ch6_val(ad_ch6_val),
		.ad_ch7_val(ad_ch7_val),
		.ad_ch8_val(ad_ch8_val)
	);
	// User logic ends

	endmodule
