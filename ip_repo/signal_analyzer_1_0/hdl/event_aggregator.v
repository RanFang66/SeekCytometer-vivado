`timescale 1ns/1ps
module event_aggregator #(
    parameter NUM_CH = 8,
    parameter integer C_WIDTH_BITS = 16,
    parameter integer C_AREA_BITS  = 32,
    parameter integer C_PEAK_BITS  = 18
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    analyze_en,
    input  wire [NUM_CH-1:0]       enable_mask,
    input  wire [NUM_CH-1:0]       ch_pulse_active,
    input  wire signed [C_PEAK_BITS * NUM_CH-1:0] ch_peak_flat,
    input  wire [C_WIDTH_BITS * NUM_CH-1:0]       ch_width_flat,
    input  wire signed [C_AREA_BITS * NUM_CH-1:0] ch_area_flat,
    input  wire [32*NUM_CH-1:0]        ch_peak_time_flat,
    input  wire                     sort_trig,
    input  wire [2:0]               drive_state,


    input wire [2:0]                speed_pre_channel,  // Channel index for pre-event (0 to NUM_CH-1)
    input wire [2:0]                speed_post_channel, // Channel index for post-event (0 to NUM_CH-1)
    input wire [31:0]               max_time_diff,      // Maximum valid time difference for speed measurement


    output reg  [31:0]             event_id,   
    output wire                    event_active,
    output wire                    event_done,      // One clock cycle high when event is done

    // BRAM Port A to write event data
    output reg  [31:0]                      bram_addr_a,
    output reg  [31:0]                      bram_din_a,
    output reg                              bram_we_a,
    output wire                             bram_en_a,
    output reg                              last_wrap_around, // Indicates if write pointer wrapped around
    // provide last written address for readout logic
    output reg  [31:0] last_written_addr,
    output wire [31:0] measured_time_diff,           // output measured speed (in time us)
    output wire [7:0]  ch_pulse_valid_latched
);

    // -- channel pulse valid in pulse judgment
    reg [NUM_CH-1 : 0] ch_pulse_valid;      // bit set 1 if there are valid pulse in correspond channel

    reg [3:0] state;
        // ------------- parameters / local -------------
    localparam [31:0] MAGIC_WORD_HEAD = 32'h55AA55AA; // Magic word for event header
    localparam [31:0] MAGIC_WORD_TAIL = 32'hAA55AA55; // Magic word for event tail
    localparam [31:0] BRAM_SIZE_BYTES = 32'h00008000; 
    localparam [31:0] BRAM_LAST_ADDR = BRAM_SIZE_BYTES - 4; // last valid address

    // FSM states
    localparam S_IDLE    = 4'd0;
    localparam S_MAGIC_HEAD = 4'd1;
    localparam S_HEADER  = 4'd2;
    localparam S_TIME_DIFF = 4'd3;
    localparam S_POST_TIME = 4'd4;    localparam S_CH_PEAK = 4'd5;
    localparam S_CH_WIDTH= 4'd6;
    localparam S_CH_AREA = 4'd7;
    localparam S_MAGIC_TAIL   = 4'd8;
    localparam S_DONE    = 4'd9;
    
    
    
    assign bram_en_a = (state != S_IDLE); // BRAM is enabled when not in idle state

    // ------------- unpack inputs -------------
    wire signed [C_PEAK_BITS-1:0] ch_peak [0:NUM_CH-1];
    wire [C_WIDTH_BITS-1:0]       ch_width[0:NUM_CH-1];
    wire signed [C_AREA_BITS-1:0] ch_area [0:NUM_CH-1];
    genvar gi;
    generate
        for (gi = 0; gi < NUM_CH; gi = gi + 1) begin : UNPACK
            assign ch_peak[gi]  = ch_peak_flat[gi*C_PEAK_BITS +: C_PEAK_BITS];
            assign ch_width[gi] = ch_width_flat[gi*C_WIDTH_BITS +: C_WIDTH_BITS];
            assign ch_area[gi]  = ch_area_flat[gi*C_AREA_BITS +: C_AREA_BITS];
        end
    endgenerate

    // ------------- event detection (same clk domain assumed) -------------
    wire [NUM_CH-1 : 0] ch_pulse_active_mask = ch_pulse_active & enable_mask;
    wire    event_active_masked = (ch_pulse_active_mask != {NUM_CH{1'b0}});
    assign  event_active = event_active_masked;//|(ch_pulse_active & enable_mask);
    // detect falling edge of event_active_masked => event_done pulse
    reg event_active_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) event_active_d <= 1'b0;
        else        event_active_d <= event_active_masked;
    end
    assign event_done = (~event_active_masked) & event_active_d; // one-clock pulse when active -> inactive





    // latched copies (on event_done)
    reg [NUM_CH-1:0]                   latched_mask;
    reg signed [C_PEAK_BITS-1:0]       latched_peak [0:NUM_CH-1];
    reg [C_WIDTH_BITS-1:0]             latched_width[0:NUM_CH-1];
    reg signed [C_AREA_BITS-1:0]       latched_area [0:NUM_CH-1];
    reg [31:0]                         latched_header; // header uses low 24 bits + 8bits flag

    // iteration index over channels
    reg [$clog2(NUM_CH+1)-1:0] ch_index; // wide enough to hold NUM_CH

    // BRAM write pointer (next free address)
    reg [31:0] write_addr;

    // Speed measurement module
//    (*MARK_DEBUG="true"*)
    wire [31:0] speed_pre_time = ch_peak_time_flat[speed_pre_channel*32 +: 32];
//    (*MARK_DEBUG="true"*)
    wire [31:0] speed_post_time = ch_peak_time_flat[speed_post_channel*32 +: 32];
    reg [31:0] latched_time_diff;
    reg [31:0] latched_post_event_time;
//    (*MARK_DEBUG="true"*)
    wire[31:0] time_diff = speed_post_time - speed_pre_time;

    integer idx;
    reg wrap_around; // indicates if write pointer wrapped around
    reg write_wrap_now;


    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wrap_around <= 1'b0;
            write_wrap_now <= 1'b0;
        end else begin
            write_wrap_now <= 1'b0;
            if (bram_we_a && write_addr == BRAM_LAST_ADDR) begin
                wrap_around <= ~wrap_around;
                write_wrap_now <= 1'b1;
            end
        end
    end

    assign measured_time_diff = latched_time_diff;      // output measured time difference
    assign ch_pulse_valid_latched = ch_pulse_valid;
    // always @(posedge clk or negedge rst_n) begin
    //     if (!rst_n) begin
    //         ch_pulse_valid <= {NUM_CH{1'b0}};
    //     end else begin
    //         if 
    //     end
    // end


    // ------------- sequential FSM and actions -------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            event_id <= 32'd0;
            latched_mask <= {NUM_CH{1'b0}};
            ch_pulse_valid <= {NUM_CH{1'b0}};
            for (idx = 0; idx < NUM_CH; idx = idx + 1) begin
                latched_peak[idx]  <= {C_PEAK_BITS{1'b0}};
                latched_width[idx] <= {C_WIDTH_BITS{1'b0}};
                latched_area[idx]  <= {C_AREA_BITS{1'b0}};
            end
            latched_header <= 32'd0;
            latched_time_diff <= 32'd0;
            latched_post_event_time <= 32'd0;
            ch_index <= 0;
            write_addr <= 32'd0;
            bram_we_a <= 1'b0;
            bram_addr_a <= 32'd0;
            bram_din_a <= 32'd0;
            last_written_addr <= 32'd0;
            last_wrap_around <= 1'b0;
        end else begin
            // default deassert write
            bram_we_a <= 1'b0;
            ch_pulse_valid <= (ch_pulse_valid | ch_pulse_active_mask);
            case (state)
                S_IDLE: begin
                    // In analyze not enabled, reset state
                    if (!analyze_en) begin
                        state <= S_IDLE;
                        event_id <= 32'd0;
                        latched_mask <= {NUM_CH{1'b0}};
                        ch_pulse_valid <= {NUM_CH{1'b0}};
                        for (idx = 0; idx < NUM_CH; idx = idx + 1) begin
                            latched_peak[idx]  <= {C_PEAK_BITS{1'b0}};
                            latched_width[idx] <= {C_WIDTH_BITS{1'b0}};
                            latched_area[idx]  <= {C_AREA_BITS{1'b0}};
                        end
                        latched_header <= 32'd0;
                        latched_time_diff <= 32'd0;
                        latched_post_event_time <=32'd0;
                        ch_index <= 0;
                        write_addr <= 32'd0;
                        bram_we_a <= 1'b0;
                        bram_addr_a <= 32'd0;
                        bram_din_a <= 32'd0;
                        last_written_addr <= 32'd0;
                        last_wrap_around <= 1'b0;
                    end else if (event_done) begin
                        // latch event data snapshot
                        latched_mask <= enable_mask;
                        
                        for (idx = 0; idx < NUM_CH; idx = idx + 1) begin
                            if (ch_pulse_valid[idx] == 1'b1) begin
                                latched_peak[idx]  <= ch_peak[idx];
                                latched_width[idx] <= ch_width[idx];
                                latched_area[idx]  <= ch_area[idx];
                            end else begin
                                latched_peak[idx]  <= {C_PEAK_BITS{1'b0}};
                                latched_width[idx] <= {C_WIDTH_BITS{1'b0}};
                                latched_area[idx]  <= {C_AREA_BITS{1'b0}};
                            end
                        end
                        latched_header <= event_id[19:0]; // low 20 bits
                        latched_header[20] <= sort_trig;                           // bit 20 indicates if event was sort trigger
                        latched_header[21] <= sort_trig && (drive_state == 3'd0); // only valid if drive_state is idle

                        latched_post_event_time <= speed_post_time;
                        if (time_diff < max_time_diff) begin
                            latched_time_diff <= time_diff;
                            latched_header[22] <= 1'b1; // valid speed measurement
                        end else begin // keep previous values    
                            latched_time_diff <= latched_time_diff;                   
                            latched_header[22] <= 1'b0; // invalid speed measurement
                        end

                        latched_header[31:24] <= ch_pulse_valid;
                        
                        // reset channel pulse valid flag
                        ch_pulse_valid <= {NUM_CH{1'b0}};

                        // increment event_id for next event (keeps header unique)
                        event_id <= event_id + 1;

                        // init channel iterator
                        ch_index <= 0;
                        // go to header write state
                        state <= S_MAGIC_HEAD;
                    end else begin                        
                        state <= S_IDLE;
                    end
                end

                S_MAGIC_HEAD: begin
                    // write magic number
                    bram_we_a <= 1'b1;
                    bram_addr_a <= write_addr;
                    bram_din_a <= MAGIC_WORD_HEAD;
                    if (write_addr >= BRAM_LAST_ADDR) write_addr <= 32'd0;
                    else write_addr <= write_addr + 32'd4; 
                    state <= S_HEADER; // go to header state
                end

                S_HEADER: begin
                    bram_we_a <= 1'b1;
                    bram_addr_a <= write_addr;
                    bram_din_a <= latched_header; 
                    if (write_addr >= BRAM_LAST_ADDR) write_addr <= 32'd0;
                    else write_addr <= write_addr + 32'd4;   
                    // go to pre-event time state
                    state <= S_TIME_DIFF;
                end

                S_TIME_DIFF: begin
                    // write time difference
                    bram_we_a <= 1'b1;
                    bram_addr_a <= write_addr;
                    bram_din_a <= latched_time_diff; // 32-bit timestamp
                    if (write_addr >= BRAM_LAST_ADDR) write_addr <= 32'd0;
                    else write_addr <= write_addr + 32'd4; 
                    state <= S_POST_TIME;
                end

                S_POST_TIME: begin
                    // write post-event time
                    bram_we_a <= 1'b1;
                    bram_addr_a <= write_addr;
                    bram_din_a <= latched_post_event_time; // 32-bit timestamp
                    if (write_addr >= BRAM_LAST_ADDR) write_addr <= 32'd0;
                    else write_addr <= write_addr + 32'd4; 
                    state <= S_CH_PEAK; // go to channel processing
                end


                S_CH_PEAK: begin
                    // find next enabled channel >= ch_index; if none, go to MAGIC
                    // If current ch_index not enabled, skip forward
                    if (ch_index >= NUM_CH) begin
                        state <= S_MAGIC_TAIL;
                    end else if (!latched_mask[ch_index]) begin
                        ch_index <= ch_index + 1;
                        state <= S_CH_PEAK;
                    end else begin
                        // write peak for ch_index (sign-extend/truncate to 32bit)
                        bram_we_a <= 1'b1;
                        bram_addr_a <= write_addr;
                        // sign-extend                   
                        bram_din_a <= {{(32-C_PEAK_BITS){latched_peak[ch_index][C_PEAK_BITS-1]}}, latched_peak[ch_index]};
                        
                        if (write_addr >= BRAM_LAST_ADDR) write_addr <= 32'd0;
                        else write_addr <= write_addr + 32'd4; 
                        state <= S_CH_WIDTH;
                    end
                end

                S_CH_WIDTH: begin
                    // write width (zero-extend up to 32)
                    bram_we_a <= 1'b1;
                    bram_addr_a <= write_addr;
                    
                    bram_din_a <= {{(32-C_WIDTH_BITS){1'b0}}, latched_width[ch_index]};
                    
                    if (write_addr >= BRAM_LAST_ADDR) write_addr <= 32'd0;
                    else write_addr <= write_addr + 32'd4; 
                    state <= S_CH_AREA;
                end

                S_CH_AREA: begin
                    bram_we_a <= 1'b1;
                    bram_addr_a <= write_addr;
                    
                    bram_din_a <= latched_area[ch_index];
                    
                    if (write_addr >= BRAM_LAST_ADDR) write_addr <= 32'd0;
                    else write_addr <= write_addr + 32'd4; 
                    // advance to next channel (even if more channels disabled, S_CH_PEAK state will skip them)
                    ch_index <= ch_index + 1;
                    state <= S_CH_PEAK;
                end

                S_MAGIC_TAIL: begin
                    // write magic number
                    bram_we_a <= 1'b1;
                    bram_addr_a <= write_addr;
                    bram_din_a <= MAGIC_WORD_TAIL;
                    if (write_addr >= BRAM_LAST_ADDR) write_addr <= 32'd0;
                    else write_addr <= write_addr + 32'd4; 
                    state <= S_DONE;
                end

                S_DONE: begin
                    // finished event write; go back to idle to accept next event
                    last_written_addr <= write_addr;
                    last_wrap_around <= wrap_around; // capture wrap around state
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end






endmodule
