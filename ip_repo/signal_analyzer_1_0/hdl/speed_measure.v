`timescale 1 ns / 1 ps

module speed_measure (
    input wire clk,
    input wire rst_n,
    
    input wire analyze_en,
    input wire speed_pre_active,    // Pre channel event signal
    input wire speed_post_active,   // Post channel event signal
    input wire [63:0] time_stamp_us, // Time stamp in microseconds
    input wire [31:0] max_time_diff, // Maximum valid time difference

    output reg [31:0] post_event_time, // Time stamp of the post event
    output wire [31:0] time_diff,        // Time difference between pre and post events
    output reg valid_measurement,       // 1 if the measurement is valid, 0 otherwise
    output reg [31:0] pre_event_count,
    output reg [31:0] post_event_count
);
    reg [63:0] time_diff_long;
    reg speed_pre_active_d0, speed_pre_active_d1;
    reg speed_post_active_d0, speed_post_active_d1;
    wire speed_pre_trig, speed_post_trig;
    
    reg [63:0] last_pre_event_time; // last pre event time stamp
    reg [63:0] timeout_threshold;   // calculated timeout threshold
    
    // state machine parameters
    localparam [1:0] IDLE = 2'b00,
                     WAITING_FOR_POST = 2'b01,
                     MEASUREMENT_DONE = 2'b10,
                     ERROR_STATE = 2'b11;
    
    reg [1:0] current_state, next_state;
    
    
    assign time_diff = time_diff_long[31:0];
    // edge detection for pre and post signals
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            speed_pre_active_d0 <= 1'b0;
            speed_pre_active_d1 <= 1'b0;
            speed_post_active_d0 <= 1'b0;
            speed_post_active_d1 <= 1'b0;
        end else begin
            speed_pre_active_d0 <= speed_pre_active;
            speed_pre_active_d1 <= speed_pre_active_d0;
            speed_post_active_d0 <= speed_post_active;
            speed_post_active_d1 <= speed_post_active_d0;
        end
    end
    
    assign speed_pre_trig = speed_pre_active_d0 && !speed_pre_active_d1;
    assign speed_post_trig = speed_post_active_d0 && !speed_post_active_d1;
    
    // Calculate timeout threshold when entering WAITING_FOR_POST state
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timeout_threshold <= 64'b0;
        end else if (current_state == IDLE && speed_pre_trig) begin
            // �?32位的max_time_diff扩展�?64位后再相�?
            timeout_threshold <= time_stamp_us + {32'b0, max_time_diff};
        end
    end
    
    // State register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !analyze_en) begin
            current_state <= IDLE;
            last_pre_event_time <= 64'b0;
            valid_measurement <= 1'b0;
            time_diff_long <= 64'b0;
            post_event_time <= 32'b0;
        end else begin
            current_state <= next_state;
            
            // Store pre event time when triggered
            if (speed_pre_trig && current_state == IDLE) begin
                last_pre_event_time <= time_stamp_us;
            end
            
            // Calculate time difference and set valid flag
            if (current_state == MEASUREMENT_DONE) begin
                valid_measurement <= 1'b1;
                post_event_time <= time_stamp_us[31:0];
                time_diff_long <= time_stamp_us - last_pre_event_time;
            end else if (current_state == WAITING_FOR_POST) begin
                valid_measurement <= 1'b0;
            end else if (current_state == ERROR_STATE) begin
                valid_measurement <= 1'b0;
            end
        end
    end
    
    // Next state logic
    always @(*) begin
        case (current_state)
            IDLE: begin
                if (speed_pre_trig && analyze_en)
                    next_state = WAITING_FOR_POST;
                else
                    next_state = IDLE;
            end
            
            WAITING_FOR_POST: begin
                if (speed_post_trig)
                    next_state = MEASUREMENT_DONE;
                else if (time_stamp_us >= timeout_threshold)
                    next_state = ERROR_STATE;
                else
                    next_state = WAITING_FOR_POST;
            end
            
            MEASUREMENT_DONE: begin
                next_state = IDLE;
            end
            
            ERROR_STATE: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // Pre and post event counters
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || !analyze_en) begin
            pre_event_count <= 32'b0;
            post_event_count <= 32'b0;
        end else begin
            if (speed_pre_trig) pre_event_count <= pre_event_count + 1;
            if (speed_post_trig) post_event_count <= post_event_count + 1;    
        end
    end

endmodule