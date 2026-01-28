`timescale 1 ns / 1 ps

module ad_sample_master_stream_v1_0_M00_AXIS #
(
    parameter integer C_M_AXIS_TDATA_WIDTH = 32,
    parameter integer C_M_START_COUNT = 32
)
(
    input wire                          M_AXIS_ACLK,
    input wire                          M_AXIS_ARESETN,

    // AXIS Master Interface
    output wire                         M_AXIS_TVALID,
    output wire [C_M_AXIS_TDATA_WIDTH-1:0] M_AXIS_TDATA,
    output wire [(C_M_AXIS_TDATA_WIDTH/8)-1:0]               M_AXIS_TKEEP,
    output wire [(C_M_AXIS_TDATA_WIDTH/8)-1:0]               M_AXIS_TSTRB,
    output wire                         M_AXIS_TLAST,
    input  wire                         M_AXIS_TREADY,

    // User I/O  
    
    input wire                          en_streaming,
    input wire [31:0]                   stream_length,
    input wire                          ad_data_valid,
    input wire [17:0]                   ad_ch1_val,
    input wire [17:0]                   ad_ch2_val,
    input wire [17:0]                   ad_ch3_val,
    input wire [17:0]                   ad_ch4_val,
    input wire [17:0]                   ad_ch5_val,
    input wire [17:0]                   ad_ch6_val,
    input wire [17:0]                   ad_ch7_val,
    input wire [17:0]                   ad_ch8_val,
    output wire [1:0]                   streaming_status
);

    // FSM
    localparam [1:0] IDLE = 2'b00,
                     INIT_COUNTER = 2'b01,
                     SEND_STREAM = 2'b10;
                     
    reg [1:0] mst_exec_state;
    assign streaming_status = mst_exec_state;

    // Start delay counter
    reg [$clog2(C_M_START_COUNT)-1:0] wait_count;

    // streaming control
    reg en_streaming_d1, en_streaming_d2;
    // AD rising edge detection
    reg ad_data_valid_d1;

    // FIFO for data stream
    reg  [31:0] fifo_din;
    wire [31:0] fifo_dout;
    reg         fifo_wr_en;
    wire        fifo_full;
    wire        fifo_empty;
    wire        fifo_rd_en = M_AXIS_TREADY && !fifo_empty;
        





    // Channel buffer for writing to FIFO
    reg [17:0] ch_data [0:7];
    reg [2:0]  wr_channel_cnt;
    reg        write_8ch_active;


    reg [31:0] stream_send_cnt;
    reg is_last_word;


    wire start_stream =  en_streaming_d1 && !en_streaming_d2;
    wire ad_data_updated = ad_data_valid && !ad_data_valid_d1;

   

    always @(posedge M_AXIS_ACLK) begin
        if (!M_AXIS_ARESETN) begin
            ad_data_valid_d1 <= 0;
        end else begin
            ad_data_valid_d1 <= ad_data_valid;
        end
    end


    always @(posedge M_AXIS_ACLK) begin
        if (!M_AXIS_ARESETN) begin
            en_streaming_d1 <= 0;
            en_streaming_d2 <= 0;
        end else begin
            en_streaming_d1 <= en_streaming;
            en_streaming_d2 <= en_streaming_d1;
        end
    end

    // FSM transition
    always @(posedge M_AXIS_ACLK) begin
        if (!M_AXIS_ARESETN) begin
            mst_exec_state <= IDLE;
            wait_count <= 0;
        end else begin
            case (mst_exec_state)
            IDLE: begin
                if (start_stream) begin
                    mst_exec_state <= INIT_COUNTER;
                    wait_count <= 0;
                end
            end

            INIT_COUNTER: begin
                if (wait_count == C_M_START_COUNT - 1) begin
                    mst_exec_state <= SEND_STREAM;
                    wait_count <= 0;
                end else begin
                    wait_count <= wait_count + 1;
                end
            end

            SEND_STREAM: begin
                if (stream_send_cnt >= stream_length * 8) begin
                    mst_exec_state <= IDLE;
                end else begin
                    mst_exec_state <= SEND_STREAM;
                end 
            end

            default: begin
                mst_exec_state <= IDLE;
            end
        endcase
        end
    end




    // FIFO write controller
    always @(posedge M_AXIS_ACLK) begin
        if (!M_AXIS_ARESETN || mst_exec_state != SEND_STREAM) begin
            wr_channel_cnt <= 0;
            write_8ch_active <= 0;
            fifo_wr_en <= 0;
            fifo_din <= 0;

        end else begin
            fifo_wr_en <= 0;
            if (ad_data_updated && !fifo_full) begin
                // Latch 8 channels
                ch_data[0] <= ad_ch1_val;
                ch_data[1] <= ad_ch2_val;
                ch_data[2] <= ad_ch3_val;
                ch_data[3] <= ad_ch4_val;
                ch_data[4] <= ad_ch5_val;
                ch_data[5] <= ad_ch6_val;
                ch_data[6] <= ad_ch7_val;
                ch_data[7] <= ad_ch8_val;
                write_8ch_active <= 1;
                wr_channel_cnt <= 0;
            end else if (write_8ch_active && !fifo_full) begin
                fifo_din <= {5'b0, wr_channel_cnt[2:0], 6'b0, ch_data[wr_channel_cnt]};
                fifo_wr_en <= 1;
                if (wr_channel_cnt == 7) begin
                    write_8ch_active <= 0;
                    wr_channel_cnt <= 0;
                end else begin
                    wr_channel_cnt <= wr_channel_cnt + 1;
                end
            end
        end
    end

    // Stream send counter and last word detection
    always @(posedge M_AXIS_ACLK) begin
        if (!M_AXIS_ARESETN || mst_exec_state != SEND_STREAM) begin
            stream_send_cnt <= 0;
            is_last_word <= 0;
        end else if (M_AXIS_TVALID && M_AXIS_TREADY) begin
            if (stream_send_cnt == (stream_length * 8 - 2)) begin
                is_last_word <= 1'b1;
            end else begin
                is_last_word <= 1'b0;
            end
            stream_send_cnt <= stream_send_cnt + 1;
        end else begin
            is_last_word <= 0;
        end
    end
    
    // AXIS output
    assign M_AXIS_TVALID = !fifo_empty && (mst_exec_state == SEND_STREAM);
    assign M_AXIS_TDATA  = fifo_dout;
    assign M_AXIS_TSTRB  = {C_M_AXIS_TDATA_WIDTH/8{1'b1}};
    assign M_AXIS_TKEEP  = {C_M_AXIS_TDATA_WIDTH/8{1'b1}};
    assign M_AXIS_TLAST = is_last_word;

    // FIFO instantiation
    xpm_fifo_sync #(
        .FIFO_MEMORY_TYPE("auto"),
        .ECC_MODE("no_ecc"),
        .FIFO_WRITE_DEPTH(8192),
        .WRITE_DATA_WIDTH(32),
        .READ_DATA_WIDTH(32),
        .READ_MODE("fwft"),
        .FIFO_READ_LATENCY(1),
        .DOUT_RESET_VALUE("0")
    ) u_fifo (
        .rst(~M_AXIS_ARESETN),
        .wr_clk(M_AXIS_ACLK),
        .wr_en(fifo_wr_en),
        .din(fifo_din),
        .rd_en(fifo_rd_en),
        .dout(fifo_dout),
        .full(fifo_full),
        .empty(fifo_empty),
        .injectsbiterr(1'b0),
        .injectdbiterr(1'b0)
    );


endmodule
