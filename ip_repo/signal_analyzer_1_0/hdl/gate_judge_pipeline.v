`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: gate_judge_pipeline
// Description: Resource-efficient gate judgement module with pipelined design.
//              Supports four gate types:
//                1 — Interval gate   (1-D range on X)
//                2 — Rectangle gate  (axis-aligned bounding box)
//                3 — Polygon gate    (iterative ray-casting, 2-stage pipeline)
//                4 — Ellipse gate    (axis-aligned ellipse via bounding rect)
//
//              The polygon path iterates edges one at a time using a 2-stage
//              pipeline (stage 1: diff/compare, stage 2: multiply/accumulate),
//              reusing a single pair of multipliers across all edges.
//              This saves significant DSP resources compared to the parallel
//              version (2 multipliers vs 2×N).
//
//  Latency from trigger rising edge to valid output:
//    Interval / Rectangle :  1 cycle
//    Polygon (N edges)    :  N + 2 cycles  (max 14 for N=12)
//    Ellipse              :  4 cycles
//////////////////////////////////////////////////////////////////////////////////

module gate_judge_pipeline #(
    parameter integer C_NUM_MAX_POINTS   = 12,
    parameter integer C_POINT_DATA_WIDTH = 32
) (
    input wire  rst_n,
    input wire  sys_clk,
    input wire  enable,
    input wire  trigger,
    input wire signed [C_POINT_DATA_WIDTH-1:0] point_x,
    input wire signed [C_POINT_DATA_WIDTH-1:0] point_y,
    input wire [2:0]  gate_type,
    input wire [$clog2(C_NUM_MAX_POINTS)-1:0] gate_points_num,
    input wire [C_POINT_DATA_WIDTH * C_NUM_MAX_POINTS - 1:0] gate_points_x_pack,
    input wire [C_POINT_DATA_WIDTH * C_NUM_MAX_POINTS - 1:0] gate_points_y_pack,
    output wire valid,
    output wire result
);

    localparam CNT_WIDTH = $clog2(C_NUM_MAX_POINTS);
    localparam DW = C_POINT_DATA_WIDTH;
    localparam MW = DW * 2;                 // multiply result width

    // Gate type encoding
    localparam [2:0] GT_NO_GATE   = 3'd0,
                     GT_INTERVAL  = 3'd1,
                     GT_RECTANGLE = 3'd2,
                     GT_POLYGON   = 3'd3,
                     GT_ELLIPSE   = 3'd4,
                     GT_ALL       = 3'd5;

    // FSM states
    localparam [1:0] S_IDLE = 2'd0,
                     S_CALC = 2'd1;

    // =========================================================================
    //  Trigger rising-edge detection
    // =========================================================================
    reg trigger_dly;
    wire trigger_rise = trigger & ~trigger_dly;

    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) trigger_dly <= 1'b0;
        else        trigger_dly <= trigger;

    // =========================================================================
    //  Input latch — capture all inputs on trigger rising edge
    // =========================================================================
    reg signed [DW-1:0] px, py;
    reg [2:0]           gtype;
    reg [CNT_WIDTH-1:0] gnum;
    reg signed [DW-1:0] gx [0:C_NUM_MAX_POINTS-1];
    reg signed [DW-1:0] gy [0:C_NUM_MAX_POINTS-1];

    genvar gi;
    generate
        for (gi = 0; gi < C_NUM_MAX_POINTS; gi = gi + 1) begin : latch_pts
            always @(posedge sys_clk or negedge rst_n) begin
                if (!rst_n) begin
                    gx[gi] <= {DW{1'b0}};
                    gy[gi] <= {DW{1'b0}};
                end else if (trigger_rise) begin
                    gx[gi] <= gate_points_x_pack[gi*DW +: DW];
                    gy[gi] <= gate_points_y_pack[gi*DW +: DW];
                end
            end
        end
    endgenerate

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            px    <= {DW{1'b0}};
            py    <= {DW{1'b0}};
            gtype <= 3'd0;
            gnum  <= {CNT_WIDTH{1'b0}};
        end else if (trigger_rise) begin
            px    <= point_x;
            py    <= point_y;
            gtype <= gate_type;
            gnum  <= (gate_points_num > C_NUM_MAX_POINTS[CNT_WIDTH-1:0])
                     ? C_NUM_MAX_POINTS[CNT_WIDTH-1:0] : gate_points_num;
        end
    end

    // =========================================================================
    //  Interval / Rectangle — combinational from latched values
    // =========================================================================
    wire signed [DW-1:0] bound_xmin = (gx[0] < gx[1]) ? gx[0] : gx[1];
    wire signed [DW-1:0] bound_xmax = (gx[0] < gx[1]) ? gx[1] : gx[0];
    wire signed [DW-1:0] bound_ymin = (gy[0] < gy[1]) ? gy[0] : gy[1];
    wire signed [DW-1:0] bound_ymax = (gy[0] < gy[1]) ? gy[1] : gy[0];

    wire intv_result = (px > bound_xmin) && (px < bound_xmax);
    wire rect_result = intv_result && (py > bound_ymin) && (py < bound_ymax);

    // =========================================================================
    //  Polygon — iterative 2-stage pipeline (ray-casting)
    //
    //  Stage 1 (S1): read edge vertices via mux, compute differences & skip flag.
    //                Results registered into s1_* for the next cycle.
    //  Stage 2 (S2): multiply registered operands, compare, XOR into accumulator.
    //                This multiply maps efficiently to DSP48 (inputs are registered).
    //
    //  The two stages overlap:
    //    Cycle 1:  S1(edge 0)
    //    Cycle 2:  S2(edge 0)  +  S1(edge 1)
    //    Cycle 3:  S2(edge 1)  +  S1(edge 2)
    //      ...
    //    Cycle N:  S2(edge N-2) + S1(edge N-1)
    //    Cycle N+1: S2(edge N-1)
    //    Cycle N+2: output result
    // =========================================================================

    // --- Stage 1 registers ---
    reg signed [DW-1:0] s1_a, s1_b, s1_c, s1_d;   // lhs = a*b,  rhs = c*d
    reg                 s1_skip;                     // skip this edge
    reg                 s1_y2_gt_y1;                 // direction flag
    reg                 s1_valid;                    // stage 1 output is valid

    // --- Stage 2 combinational (multiply from registered operands) ---
    //     a = (py - y1),  b = (x2 - x1)  =>  lhs = (py-y1)*(x2-x1)
    //     c = (px - x1),  d = (y2 - y1)  =>  rhs = (px-x1)*(y2-y1)
    wire signed [MW-1:0] poly_lhs = s1_a * s1_b;
    wire signed [MW-1:0] poly_rhs = s1_c * s1_d;
    wire poly_cross_left = s1_y2_gt_y1 ? (poly_lhs < poly_rhs)
                                       : (poly_lhs > poly_rhs);
    wire poly_crosses = ~s1_skip & ~poly_cross_left;

    // --- Polygon iteration state ---
    reg [CNT_WIDTH-1:0] edge_idx;       // current edge for stage 1
    reg                 poly_feeding;   // still feeding edges into stage 1
    reg                 crossing_acc;   // XOR accumulator (odd crossings = inside)

    // --- Vertex read (combinational from register arrays) ---
    wire [CNT_WIDTH-1:0] next_idx = (edge_idx == gnum - 1'b1)
                                    ? {CNT_WIDTH{1'b0}}
                                    : (edge_idx + 1'b1);
    wire signed [DW-1:0] vx1 = gx[edge_idx];
    wire signed [DW-1:0] vy1 = gy[edge_idx];
    wire signed [DW-1:0] vx2 = gx[next_idx];
    wire signed [DW-1:0] vy2 = gy[next_idx];

    // =========================================================================
    //  Ellipse — free-running 3-stage pipeline
    //
    //  Ellipse defined by bounding rectangle: (gx[0],gy[0]) to (gx[1],gy[1]).
    //  Test:  dx²·sb² + dy²·sa² ≤ sa²·sb²
    //  where  dx = 2·px-(x0+x1),  dy = 2·py-(y0+y1),
    //         sa = x1-x0,          sb = y1-y0   (all doubled semi-axes).
    //  Pure integer arithmetic, no division.
    // =========================================================================

    // --- Stage 1: differences (registered) ---
    reg signed [DW:0] ell_dx, ell_dy, ell_sa, ell_sb;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            ell_dx <= 0;  ell_dy <= 0;
            ell_sa <= 0;  ell_sb <= 0;
        end else begin
            ell_dx <= (px <<< 1) - (gx[0] + gx[1]);
            ell_dy <= (py <<< 1) - (gy[0] + gy[1]);
            ell_sa <= gx[1] - gx[0];
            ell_sb <= gy[1] - gy[0];
        end
    end

    // --- Stage 2: squares (registered) ---
    localparam SQW = (DW + 1) * 2;
    reg signed [SQW-1:0] ell_dx2, ell_dy2, ell_sa2, ell_sb2;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            ell_dx2 <= 0;  ell_dy2 <= 0;
            ell_sa2 <= 0;  ell_sb2 <= 0;
        end else begin
            ell_dx2 <= ell_dx * ell_dx;
            ell_dy2 <= ell_dy * ell_dy;
            ell_sa2 <= ell_sa * ell_sa;
            ell_sb2 <= ell_sb * ell_sb;
        end
    end

    // --- Stage 3: cross products (registered) ---
    localparam PW = SQW * 2;
    reg signed [PW-1:0] ell_t1, ell_t2, ell_rhs;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            ell_t1 <= 0;  ell_t2 <= 0;  ell_rhs <= 0;
        end else begin
            ell_t1  <= ell_dx2 * ell_sb2;
            ell_t2  <= ell_dy2 * ell_sa2;
            ell_rhs <= ell_sa2 * ell_sb2;
        end
    end

    // --- Final compare (combinational) ---
    wire ell_result = (ell_t1 + ell_t2 <= ell_rhs);

    // --- Ellipse cycle counter ---
    reg [2:0] ell_cnt;

    // =========================================================================
    //  Main FSM
    // =========================================================================
    reg [1:0] state;
    reg       result_reg;
    reg       valid_reg;

    always @(posedge sys_clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            result_reg   <= 1'b0;
            valid_reg    <= 1'b0;
            // Polygon
            edge_idx     <= {CNT_WIDTH{1'b0}};
            crossing_acc <= 1'b0;
            s1_valid     <= 1'b0;
            s1_a <= 0;  s1_b <= 0;  s1_c <= 0;  s1_d <= 0;
            s1_skip      <= 1'b1;
            s1_y2_gt_y1  <= 1'b0;
            poly_feeding <= 1'b0;
            // Ellipse
            ell_cnt      <= 3'd0;
        end else begin
            case (state)
                // ---------------------------------------------------------
                S_IDLE: begin
                    if (trigger_rise) begin
                        state        <= S_CALC;
                        valid_reg    <= 1'b0;
                        // Polygon init
                        edge_idx     <= {CNT_WIDTH{1'b0}};
                        crossing_acc <= 1'b0;
                        s1_valid     <= 1'b0;
                        poly_feeding <= 1'b1;
                        // Ellipse init
                        ell_cnt      <= 3'd0;
                    end
                end

                // ---------------------------------------------------------
                S_CALC: begin
                    case (gtype)
                        GT_NO_GATE: begin               // never sort when there is no gate
                            result_reg <= 1'b0;
                            valid_reg <= 1'b1;
                            state <= S_IDLE;
                        end

                        // --- Interval: 1 cycle ---
                        GT_INTERVAL: begin
                            result_reg <= intv_result;
                            valid_reg  <= 1'b1;
                            state      <= S_IDLE;
                        end

                        // --- Rectangle: 1 cycle ---
                        GT_RECTANGLE: begin
                            result_reg <= rect_result;
                            valid_reg  <= 1'b1;
                            state      <= S_IDLE;
                        end

                        // --- Polygon: iterative 2-stage pipeline ---
                        GT_POLYGON: begin
                            // Stage 2: multiply & accumulate (previous edge)
                            if (s1_valid)
                                crossing_acc <= crossing_acc ^ poly_crosses;

                            // Stage 1: compute diffs for current edge
                            if (poly_feeding) begin
                                s1_a <= py  - vy1;          // py - y1
                                s1_b <= vx2 - vx1;          // x2 - x1
                                s1_c <= px  - vx1;          // px - x1
                                s1_d <= vy2 - vy1;          // y2 - y1
                                s1_skip <= (vy1 == vy2)
                                        || ((vy1 > py) == (vy2 > py));
                                s1_y2_gt_y1 <= (vy2 > vy1);
                                s1_valid <= 1'b1;

                                if (edge_idx == gnum - 1'b1)
                                    poly_feeding <= 1'b0;
                                else
                                    edge_idx <= edge_idx + 1'b1;
                            end else begin
                                s1_valid <= 1'b0;
                            end

                            // Done: stage 1 drained and stage 2 flushed
                            if (!poly_feeding && !s1_valid) begin
                                result_reg <= crossing_acc;
                                valid_reg  <= 1'b1;
                                state      <= S_IDLE;
                            end
                        end

                        // --- Ellipse: wait for 3-stage pipeline ---
                        GT_ELLIPSE: begin
                            ell_cnt <= ell_cnt + 1'b1;
                            if (ell_cnt == 3'd3) begin
                                result_reg <= ell_result;
                                valid_reg  <= 1'b1;
                                state      <= S_IDLE;
                            end
                        end

                        // --- All sort
                        GT_ALL: begin                   // always sort
                            result_reg <= 1'b1;
                            valid_reg <= 1'b1;
                            state <= S_IDLE;
                        end

                        // --- Unknown type: default to not-in-gate ---
                        default: begin
                            result_reg <= 1'b0;
                            valid_reg  <= 1'b1;
                            state      <= S_IDLE;
                        end
                    endcase
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // =========================================================================
    //  Output
    // =========================================================================
    assign result = result_reg;
    assign valid  = valid_reg & enable;

endmodule
