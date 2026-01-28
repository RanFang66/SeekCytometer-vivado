`timescale 1ns/1ps
module event_aggregator #(
    parameter NUM_CH = 8,
    parameter integer C_WIDTH_BITS = 16,
    parameter integer C_AREA_BITS = 32,
    parameter integer C_PEAK_BITS = 18
)(
    input  wire                   analyze_en,
    input  wire [NUM_CH-1:0]      enable_mask,
    input  wire [NUM_CH-1:0]      ch_pulse_active,
    input  wire signed [C_PEAK_BITS * NUM_CH-1:0]     ch_peak_flat,
    input  wire [C_WIDTH_BITS * NUM_CH-1:0]            ch_width_flat,
    input  wire signed [C_AREA_BITS * NUM_CH-1:0]     ch_area_flat,
    output reg [31:0]             event_id,
    output wire                   event_active,
    output wire                   event_done, // high for one clock cycle when event is done

    input wire					  m_axis_aclk,	
    input wire					  m_axis_aresetn,
    (*MARK_DEBUG="true"*)
    output reg                    m_axis_tvalid,
    output reg [31:0]             m_axis_tdata,
    (*MARK_DEBUG="true"*)
    output reg                    m_axis_tlast,
    (*MARK_DEBUG="true"*)
    input  wire                   m_axis_tready,
    output wire [3:0]             m_axis_tkeep,
    output wire [3:0]             m_axis_tstrbe
);

    assign m_axis_tkeep = 4'b1111;
    assign m_axis_tstrbe = 4'b1111;
    
    wire signed [C_PEAK_BITS-1:0] ch_peak [0:NUM_CH-1];
    wire [C_WIDTH_BITS-1:0] ch_width [0:NUM_CH-1];
    wire signed [C_AREA_BITS-1:0] ch_area [0:NUM_CH-1];
    genvar i;
    generate
    for (i = 0; i < NUM_CH; i = i + 1) begin : UNPACK_PEAK
        assign ch_peak[i] = ch_peak_flat[i*C_PEAK_BITS +: C_PEAK_BITS];
        assign ch_width[i] = ch_width_flat[i*C_WIDTH_BITS +: C_WIDTH_BITS];
        assign ch_area[i] = ch_area_flat[i*C_AREA_BITS +: C_AREA_BITS];
    end
    endgenerate


    // FSM states
    localparam S_IDLE      = 0;
    localparam S_HEADER    = 1;
    localparam S_CH_PEAK   = 2;
    localparam S_CH_WIDTH  = 3;
    localparam S_CH_AREA   = 4;
    localparam S_DONE      = 5;

    (*MARK_DEBUG="true"*)
    reg [2:0] state; 
    (*MARK_DEBUG="true"*)
    reg [2:0] next_state;

    reg [2:0]  ch_index;
    reg [NUM_CH-1:0] latched_mask;
    reg signed [C_PEAK_BITS-1:0] latched_peak [0:NUM_CH-1];
    reg [C_WIDTH_BITS-1:0]        latched_width[0:NUM_CH-1];
    reg signed [C_AREA_BITS-1:0] latched_area [0:NUM_CH-1];


    assign event_active = |(ch_pulse_active & enable_mask);
    wire event_done_d0 = ((ch_pulse_active & enable_mask) == 0);

    reg event_done_d1;
    (*MARK_DEBUG="true"*)reg in_sending;
    integer j;

    always @(posedge m_axis_aclk or negedge m_axis_aresetn) begin
        if (!m_axis_aresetn) begin
            event_done_d1 <= 0;
        end else begin
            event_done_d1 <= event_done_d0;
        end
    end
    assign event_done = event_done_d0 && !event_done_d1;

    // Find next enabled channel after current ch_index
    function integer find_next_enabled(input integer cur);
        integer i;
    begin
        find_next_enabled = NUM_CH;
        begin : search
            for (i = 1; i < NUM_CH; i = i + 1) begin
                if ( i > cur && latched_mask[i]) begin
                    find_next_enabled = i;
                    disable search;
                end
            end
        end
    end
    endfunction
    

    // FSM transition
    always @(*) begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (event_done && !in_sending)       // If event done rising edge and not already sending, start sending data
                    next_state = S_HEADER;
            end
            S_HEADER: if (m_axis_tready) next_state = S_CH_PEAK;
            S_CH_PEAK: if (m_axis_tready) next_state = S_CH_WIDTH;
            S_CH_WIDTH: if (m_axis_tready) next_state = S_CH_AREA;
            S_CH_AREA: if (m_axis_tready) begin
                // Find next enabled channel
                if (find_next_enabled(ch_index) == NUM_CH)
                    next_state = S_DONE;
                else
                    next_state = S_CH_PEAK;
            end
            S_DONE: if (m_axis_tready) next_state = S_IDLE;
        endcase
    end



    // FSM sequential + data outputs
    always @(posedge m_axis_aclk) begin
        if (!m_axis_aresetn || !analyze_en) begin
            state <= S_IDLE;
            m_axis_tvalid <= 0;
            m_axis_tdata  <= 0;
            m_axis_tlast  <= 0;
            in_sending <= 0;
            event_id <= 0;
            ch_index <= 0;
        end else begin
            state <= next_state;
            m_axis_tvalid <= 0;
            m_axis_tlast  <= 0;

            case (state)
                S_IDLE: begin
                    if (event_done) begin
                        // Latch all channel data
                        latched_mask <= enable_mask;
                        for (j = 0; j < NUM_CH; j = j + 1) begin
                            latched_peak[j]  <= ch_peak[j];
                            latched_width[j] <= ch_width[j];
                            latched_area[j]  <= ch_area[j];
                        end

                        event_id <= event_id + 1;
                        ch_index <= 0;
                        in_sending <= 1;
                    end else begin
                        in_sending <= 0;
                    end
                end

                S_HEADER: if (m_axis_tready) begin
                    m_axis_tvalid <= 1;
                    m_axis_tdata  <= {event_id[23:0], latched_mask}; // 24bit ID + 8bit mask
                    ch_index <= (latched_mask[0]) ? 0 : find_next_enabled(-1);
                end

                S_CH_PEAK: if (m_axis_tready) begin
                    m_axis_tvalid <= 1;
                    m_axis_tdata  <= {14'b0, latched_peak[ch_index]};
                end

                S_CH_WIDTH: if (m_axis_tready) begin
                    m_axis_tvalid <= 1;
                    m_axis_tdata  <= {16'b0, latched_width[ch_index]};
                end


                S_CH_AREA: if (m_axis_tready) begin
                    m_axis_tvalid <= 1;
                    m_axis_tdata  <= latched_area[ch_index];
                    // Move to next channel
                    ch_index <= find_next_enabled(ch_index);
                end

                S_DONE: if (m_axis_tready) begin
                    m_axis_tvalid <= 1;
                    m_axis_tdata  <= 32'hDEADBEEF; // optional end marker
                    m_axis_tlast  <= 1;
                end
            endcase
        end
    end

endmodule
