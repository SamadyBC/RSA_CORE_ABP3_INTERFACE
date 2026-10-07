`timescale 1ns/1ns

module rsa_core #(
    parameter int DATA_WIDTH = 32,
    parameter bit RESET      = 1'b1,
    parameter bit LOAD       = 1'b1
)(
    input  logic                    core_clk,
    input  logic                    core_rst,
    input  logic                    core_load,
    input  logic [DATA_WIDTH-1:0]   core_din,

    output logic                    core_done,
    output logic                    core_err,
    output logic [DATA_WIDTH-1:0]   core_dout,
    output logic                    core_clk_o
);

    assign core_clk_o = core_clk;

    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    logic ctrl_start_sig;
    logic [DATA_WIDTH-1:0] ctrl_m_sig;
    logic [DATA_WIDTH-1:0] ctrl_n_sig;
    logic [DATA_WIDTH-1:0] ctrl_doutx_sig;

    logic mult_done_sig;
    logic [2*DATA_WIDTH-1:0] mult_c_sig;

    logic mod_done_sig;
    logic [DATA_WIDTH-1:0] mod_c_sig;


    // -------------------------------------------------------------------------
    // Multiplier
    // -------------------------------------------------------------------------
    rsa_core_mult #(
        .DATA_WIDTH(DATA_WIDTH),
        .RESET(RESET),
        .START(1'b1)
    ) rsa_core_mult_blk (
        .mult_clk   (core_clk),
        .mult_rst   (core_rst),
        .mult_start (ctrl_start_sig),
        .mult_a     (ctrl_m_sig),
        .mult_b     (ctrl_doutx_sig),
        .mult_done  (mult_done_sig),
        .mult_c     (mult_c_sig)
    );


    // -------------------------------------------------------------------------
    // Modulo
    // -------------------------------------------------------------------------
    rsa_core_mod #(
        .DATA_WIDTH(DATA_WIDTH),
        .RESET(RESET),
        .START(1'b1)
    ) rsa_core_mod_blk (
        .mod_clk   (core_clk),
        .mod_rst   (core_rst),
        .mod_start (mult_done_sig),
        .mod_a     (mult_c_sig),
        .mod_b     (ctrl_n_sig),
        .mod_done  (mod_done_sig),
        .mod_err   (),
        .mod_c     (mod_c_sig)
    );


    // -------------------------------------------------------------------------
    // Controller
    // -------------------------------------------------------------------------
    rsa_core_ctrl #(
        .DATA_WIDTH(DATA_WIDTH),
        .RESET(RESET),
        .LOAD(LOAD)
    ) rsa_core_ctrl_blk (
        .ctrl_clk   (core_clk),
        .ctrl_rst   (core_rst),
        .ctrl_load  (core_load),
        .ctrl_din   (core_din),
        .ctrl_loadx (mod_done_sig),
        .ctrl_dinx  (mod_c_sig),

        .ctrl_done  (core_done),
        .ctrl_err   (core_err),
        .ctrl_c     (core_dout),
        .ctrl_start (ctrl_start_sig),
        .ctrl_n     (ctrl_n_sig),
        .ctrl_m     (ctrl_m_sig),
        .ctrl_doutx (ctrl_doutx_sig)
    );

endmodule


// =============================================================================
// MODULO
// =============================================================================

module rsa_core_mod #(
    parameter int DATA_WIDTH = 32,
    parameter bit RESET      = 1'b1,
    parameter bit START      = 1'b1
)(
    input  logic                      mod_clk,
    input  logic                      mod_rst,
    input  logic                      mod_start,
    input  logic [2*DATA_WIDTH-1:0]   mod_a,
    input  logic [DATA_WIDTH-1:0]     mod_b,

    output logic                      mod_done,
    output logic                      mod_err,
    output logic [DATA_WIDTH-1:0]     mod_c
);

    // -------------------------------------------------------------------------
    // Width constants
    // -------------------------------------------------------------------------
    localparam int MOD_CNT_WIDTH = DATA_WIDTH + 1;
    localparam int MOD_REG_WIDTH = 2 * DATA_WIDTH;


    // -------------------------------------------------------------------------
    // States
    // -------------------------------------------------------------------------
    localparam logic [2:0]
        INIT     = 3'b000,
        CHECK    = 3'b001,
        PREPARE  = 3'b010,
        COMPARE  = 3'b011,
        SUBTRACT = 3'b100,
        SHIFT    = 3'b101,
        DONE     = 3'b110,
        ERROR    = 3'b111;


    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    logic [2:0] state_reg;
    logic [2:0] state_ns;

    logic [DATA_WIDTH:0] a_cnt;

    logic [2*DATA_WIDTH-1:0] t_reg;
    logic [2*DATA_WIDTH-1:0] n_reg;

    logic [DATA_WIDTH-1:0] r_reg;

    logic mod_done_ff;
    logic mod_err_ff;


    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------
    assign mod_done = mod_done_ff;
    assign mod_err  = mod_err_ff;
    assign mod_c    = r_reg;


    // -------------------------------------------------------------------------
    // Next-state logic
    // -------------------------------------------------------------------------
    always_comb begin

        if (mod_rst == RESET) begin
            state_ns = INIT;
        end
        else begin

            case (state_reg)

                INIT: begin
                    if (mod_start == START)
                        state_ns = CHECK;
                    else
                        state_ns = INIT;
                end


                CHECK: begin
                    if (n_reg[DATA_WIDTH-1:0] == {DATA_WIDTH{1'b0}})
                        state_ns = ERROR;
                    else
                        state_ns = PREPARE;
                end


                PREPARE: begin
                    if (n_reg[2*DATA_WIDTH-2] == 1'b0)
                        state_ns = PREPARE;
                    else
                        state_ns = COMPARE;
                end


                COMPARE: begin
                    if (t_reg >= n_reg)
                        state_ns = SUBTRACT;
                    else
                        state_ns = SHIFT;
                end


                SUBTRACT: begin
                    if (a_cnt != '0)
                        state_ns = COMPARE;
                    else
                        state_ns = DONE;
                end


                SHIFT: begin
                    if (a_cnt != '0)
                        state_ns = COMPARE;
                    else
                        state_ns = DONE;
                end


                DONE: begin
                    state_ns = INIT;
                end


                ERROR: begin
                    state_ns = INIT;
                end


                default: begin
                    state_ns = INIT;
                end

            endcase
        end

    end


    // -------------------------------------------------------------------------
    // Sequential logic
    // -------------------------------------------------------------------------
    always_ff @(posedge mod_clk) begin

        case (state_reg)

            INIT: begin
                mod_done_ff <= 1'b0;

                t_reg <= mod_a;

                n_reg[DATA_WIDTH-1:0] <= mod_b;

                n_reg[2*DATA_WIDTH-1:DATA_WIDTH]
                    <= {DATA_WIDTH{1'b0}};

                a_cnt <= '0;
            end


            CHECK: begin
                // No register transfer in this state.
            end


            PREPARE: begin

                // Explicit truncation to MOD_CNT_WIDTH.
                a_cnt <= MOD_CNT_WIDTH'(a_cnt + 1'b1);

                n_reg <= {
                    n_reg[2*DATA_WIDTH-2:0],
                    1'b0
                };
            end


            COMPARE: begin
                // No register transfer in this state.
            end


            SUBTRACT: begin

                // Explicit truncation to 2*DATA_WIDTH.
                t_reg <= MOD_REG_WIDTH'(t_reg - n_reg);

                n_reg <= {
                    1'b0,
                    n_reg[2*DATA_WIDTH-1:1]
                };

                // Explicit truncation to MOD_CNT_WIDTH.
                a_cnt <= MOD_CNT_WIDTH'(a_cnt - 1'b1);
            end


            SHIFT: begin

                n_reg <= {
                    1'b0,
                    n_reg[2*DATA_WIDTH-1:1]
                };

                // Explicit truncation to MOD_CNT_WIDTH.
                a_cnt <= MOD_CNT_WIDTH'(a_cnt - 1'b1);
            end


            DONE: begin
                r_reg       <= t_reg[DATA_WIDTH-1:0];
                mod_done_ff <= 1'b1;
                mod_err_ff  <= 1'b0;
            end


            ERROR: begin
                mod_err_ff  <= 1'b1;
                mod_done_ff <= 1'b1;
                r_reg       <= {DATA_WIDTH{1'b1}};
            end


            default: begin
                // No action.
            end

        endcase

        state_reg <= state_ns;

    end

endmodule


// =============================================================================
// CONTROLLER
// =============================================================================

module rsa_core_ctrl #(
    parameter int DATA_WIDTH = 32,
    parameter bit RESET      = 1'b1,
    parameter bit LOAD       = 1'b1
)(
    input  logic                  ctrl_clk,
    input  logic                  ctrl_rst,
    input  logic                  ctrl_load,
    input  logic [DATA_WIDTH-1:0] ctrl_din,

    input  logic                  ctrl_loadx,
    input  logic [DATA_WIDTH-1:0] ctrl_dinx,

    output logic                  ctrl_done,
    output logic                  ctrl_err,
    output logic [DATA_WIDTH-1:0] ctrl_c,

    output logic                  ctrl_start,
    output logic [DATA_WIDTH-1:0] ctrl_n,
    output logic [DATA_WIDTH-1:0] ctrl_m,
    output logic [DATA_WIDTH-1:0] ctrl_doutx
);


    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------
    localparam logic [DATA_WIDTH-1:0] ZERO = DATA_WIDTH'(0);
    localparam logic [DATA_WIDTH-1:0] ONE  = DATA_WIDTH'(1);
    localparam logic [DATA_WIDTH-1:0] TWO  = DATA_WIDTH'(2);


    // -------------------------------------------------------------------------
    // States
    // -------------------------------------------------------------------------
    localparam logic [3:0]
        INIT    = 4'd0,
        LOAD_M  = 4'd1,
        WAIT_M  = 4'd2,
        LOAD_E  = 4'd3,
        WAIT_E  = 4'd4,
        LOAD_N  = 4'd5,
        WAIT_N  = 4'd6,
        ERROR   = 4'd7,
        CASE0   = 4'd8,
        ANALYZE = 4'd9,
        DONE    = 4'd10,
        CASE1   = 4'd11,
        CASE2   = 4'd12,
        START   = 4'd13;


    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    logic [3:0] state_reg;
    logic [3:0] state_ns;

    logic [DATA_WIDTH-1:0] n_reg;
    logic [DATA_WIDTH-1:0] e_reg;
    logic [DATA_WIDTH-1:0] m_reg;
    logic [DATA_WIDTH-1:0] x_reg;
    logic [DATA_WIDTH-1:0] c_reg;

    logic err_ff;
    logic start_ff;
    logic done_ff;


    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------
    assign ctrl_c     = c_reg;
    assign ctrl_n     = n_reg;
    assign ctrl_m     = m_reg;
    assign ctrl_doutx = x_reg;

    assign ctrl_done  = done_ff;
    assign ctrl_start = start_ff;
    assign ctrl_err   = err_ff;


    // -------------------------------------------------------------------------
    // Next-state logic
    // -------------------------------------------------------------------------
    always_comb begin

        if (ctrl_rst == RESET) begin
            state_ns = INIT;
        end
        else begin

            case (state_reg)

                INIT: begin
                    state_ns = LOAD_M;
                end


                LOAD_M: begin
                    state_ns =
                        (ctrl_load == LOAD)
                        ? WAIT_M
                        : LOAD_M;
                end


                WAIT_M: begin
                    state_ns =
                        (ctrl_load == LOAD)
                        ? WAIT_M
                        : LOAD_E;
                end


                LOAD_E: begin
                    state_ns =
                        (ctrl_load == LOAD)
                        ? WAIT_E
                        : LOAD_E;
                end


                WAIT_E: begin
                    state_ns =
                        (ctrl_load == LOAD)
                        ? WAIT_E
                        : LOAD_N;
                end


                LOAD_N: begin
                    state_ns =
                        (ctrl_load == LOAD)
                        ? WAIT_N
                        : LOAD_N;
                end


                WAIT_N: begin

                    if (ctrl_load == LOAD)
                        state_ns = WAIT_N;

                    else if (n_reg == ZERO)
                        state_ns = ERROR;

                    else if (e_reg == ZERO)
                        state_ns = CASE0;

                    else if (e_reg == ONE)
                        state_ns = CASE1;

                    else
                        state_ns = CASE2;
                end


                ERROR: begin
                    state_ns = LOAD_M;
                end


                CASE0: begin
                    state_ns = ANALYZE;
                end


                ANALYZE: begin

                    if (!ctrl_loadx)
                        state_ns = ANALYZE;

                    else if (e_reg == ZERO)
                        state_ns = DONE;

                    else
                        state_ns = START;
                end


                DONE: begin
                    state_ns = LOAD_M;
                end


                CASE1: begin
                    state_ns = ANALYZE;
                end


                CASE2: begin
                    state_ns = ANALYZE;
                end


                START: begin
                    state_ns = ANALYZE;
                end


                default: begin
                    state_ns = INIT;
                end

            endcase
        end

    end


    // -------------------------------------------------------------------------
    // Sequential logic
    // -------------------------------------------------------------------------
    always_ff @(posedge ctrl_clk) begin

        case (state_reg)

            INIT: begin
                err_ff   <= 1'b0;
                start_ff <= 1'b0;
                done_ff  <= 1'b0;
            end


            LOAD_M: begin
                m_reg   <= ctrl_din;
                x_reg   <= ctrl_din;
                done_ff <= 1'b0;
            end


            WAIT_M: begin
                // No action.
            end


            LOAD_E: begin
                e_reg <= ctrl_din;
            end


            WAIT_E: begin
                // No action.
            end


            LOAD_N: begin
                n_reg <= ctrl_din;
            end


            ERROR: begin
                done_ff <= 1'b1;
                err_ff  <= 1'b1;
                c_reg   <= {DATA_WIDTH{1'b1}};
            end


            CASE0: begin
                start_ff <= 1'b1;
                m_reg    <= ONE;
                x_reg    <= ONE;
            end


            ANALYZE: begin
                x_reg    <= ctrl_dinx;
                start_ff <= 1'b0;
            end


            DONE: begin
                c_reg   <= x_reg;
                done_ff <= 1'b1;
                err_ff  <= 1'b0;
            end


            CASE1: begin
                start_ff <= 1'b1;
                x_reg    <= ONE;

                // Explicit result width.
                e_reg <= DATA_WIDTH'(e_reg - ONE);
            end


            CASE2: begin
                start_ff <= 1'b1;

                // Explicit result width.
                e_reg <= DATA_WIDTH'(e_reg - TWO);
            end


            START: begin
                start_ff <= 1'b1;

                // Explicit result width.
                e_reg <= DATA_WIDTH'(e_reg - ONE);
            end


            default: begin
                // No action.
            end

        endcase

        state_reg <= state_ns;

    end

endmodule


// =============================================================================
// MULTIPLIER
// =============================================================================

module rsa_core_mult #(
    parameter int DATA_WIDTH = 32,
    parameter bit RESET      = 1'b1,
    parameter bit START      = 1'b1
)(
    input  logic                    mult_clk,
    input  logic                    mult_rst,
    input  logic                    mult_start,

    input  logic [DATA_WIDTH-1:0]   mult_a,
    input  logic [DATA_WIDTH-1:0]   mult_b,

    output logic                    mult_done,
    output logic [2*DATA_WIDTH-1:0] mult_c
);

    // -------------------------------------------------------------------------
    // Width constants
    // -------------------------------------------------------------------------
    localparam int MULT_CNT_WIDTH = $clog2(DATA_WIDTH + 1);
    localparam int MULT_REG_WIDTH = 2 * DATA_WIDTH;
    localparam logic [MULT_CNT_WIDTH-1:0] LAST_COUNT = MULT_CNT_WIDTH'(DATA_WIDTH - 1);


    // -------------------------------------------------------------------------
    // States
    // -------------------------------------------------------------------------
    localparam logic [2:0]
        INIT      = 3'd0,
        ANALYZE   = 3'd1,
        SHIFT_ADD = 3'd2,
        SHIFT     = 3'd3,
        DONE      = 3'd4;


    // -------------------------------------------------------------------------
    // Internal signals
    // -------------------------------------------------------------------------
    logic [2:0] state_reg;
    logic [2:0] state_ns;

    logic [MULT_CNT_WIDTH-1:0] a_cnt;

    logic [DATA_WIDTH-1:0] a_reg;
    logic [DATA_WIDTH-1:0] b_reg;

    logic [2*DATA_WIDTH-1:0] p_reg;
    logic [2*DATA_WIDTH-1:0] c_reg;

    logic done_ff;


    // -------------------------------------------------------------------------
    // Outputs
    // -------------------------------------------------------------------------
    assign mult_done = done_ff;
    assign mult_c    = c_reg;


    // -------------------------------------------------------------------------
    // Next-state logic
    // -------------------------------------------------------------------------
    always_comb begin

        if (mult_rst == RESET) begin
            state_ns = INIT;
        end
        else begin

            case (state_reg)

                INIT: begin
                    state_ns =
                        (mult_start == START)
                        ? ANALYZE
                        : INIT;
                end


                ANALYZE: begin
                    state_ns =
                        (b_reg[DATA_WIDTH-1])
                        ? SHIFT_ADD
                        : SHIFT;
                end


                SHIFT_ADD: begin

                    if (a_cnt != LAST_COUNT)
                        state_ns =
                            (b_reg[DATA_WIDTH-1])
                            ? SHIFT_ADD
                            : SHIFT;
                    else
                        state_ns = DONE;
                end


                SHIFT: begin

                    if (a_cnt != LAST_COUNT)
                        state_ns =
                            (b_reg[DATA_WIDTH-1])
                            ? SHIFT_ADD
                            : SHIFT;
                    else
                        state_ns = DONE;
                end


                DONE: begin
                    state_ns = INIT;
                end


                default: begin
                    state_ns = INIT;
                end

            endcase
        end

    end


    // -------------------------------------------------------------------------
    // Sequential logic
    // -------------------------------------------------------------------------
    always_ff @(posedge mult_clk) begin

        case (state_reg)

            INIT: begin
                p_reg   <= '0;
                a_cnt   <= '0;
                done_ff <= 1'b0;

                a_reg <= mult_a;
                b_reg <= mult_b;
            end


            ANALYZE: begin

                b_reg <= {
                    b_reg[DATA_WIDTH-2:0],
                    1'b0
                };
            end


            SHIFT_ADD: begin

                // Explicitly truncate the arithmetic result to 2*DATA_WIDTH.
                p_reg <= MULT_REG_WIDTH'(
                    a_reg
                    + {
                        p_reg[2*DATA_WIDTH-2:0],
                        1'b0
                    }
                );

                // Explicitly truncate counter result.
                a_cnt <= MULT_CNT_WIDTH'(a_cnt + 1'b1);

                b_reg <= {
                    b_reg[DATA_WIDTH-2:0],
                    1'b0
                };
            end


            SHIFT: begin

                p_reg <= {
                    p_reg[2*DATA_WIDTH-2:0],
                    1'b0
                };

                // Explicitly truncate counter result.
                a_cnt <= MULT_CNT_WIDTH'(a_cnt + 1'b1);

                b_reg <= {
                    b_reg[DATA_WIDTH-2:0],
                    1'b0
                };
            end


            DONE: begin
                done_ff <= 1'b1;
                c_reg   <= p_reg;
            end


            default: begin
                // No action.
            end

        endcase

        state_reg <= state_ns;

    end

endmodule
