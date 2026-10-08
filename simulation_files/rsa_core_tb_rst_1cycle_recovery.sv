
`timescale 1ns / 1ns

module rsa_core_tb;

    // -------------------------------------------------------------------------
    // PARAMETERS
    // -------------------------------------------------------------------------
    parameter int unsigned DATA_WIDTH = 32;
    parameter int          CLK_PERIOD = 20;
    parameter bit          RESET      = 1'b1;
    parameter bit          LOAD       = 1'b1;

    // -------------------------------------------------------------------------
    // SIGNAL DECLARATIONS
    // -------------------------------------------------------------------------
    logic                  core_clk;
    logic                  core_rst;
    logic                  core_load;
    logic [DATA_WIDTH-1:0] core_din;

    logic [DATA_WIDTH-1:0] message;
    logic [DATA_WIDTH-1:0] encryption_key;
    logic [DATA_WIDTH-1:0] modulus;

    logic                  core_done;
    logic                  core_err;
    logic [DATA_WIDTH-1:0] core_dout;
    logic                  core_clk_o;

    int test_num;
    int passed_count;
    int failed_count;

    // -------------------------------------------------------------------------
    // DUV INSTANTIATION
    // -------------------------------------------------------------------------
    rsa_core #(
        .DATA_WIDTH (DATA_WIDTH),
        .RESET      (RESET),
        .LOAD       (LOAD)
    ) duv (
        .core_clk   (core_clk),
        .core_rst   (core_rst),
        .core_load  (core_load),
        .core_din   (core_din),
        .core_done  (core_done),
        .core_err   (core_err),
        .core_dout  (core_dout),
        .core_clk_o (core_clk_o)
    );

    // -------------------------------------------------------------------------
    // SIMULATION DATA
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("waveform_32bit_rst_1cycle.vcd");
        $dumpvars(0, rsa_core_tb);
    end

    // -------------------------------------------------------------------------
    // CLOCK GENERATION
    // -------------------------------------------------------------------------
    initial begin
        core_clk = 1'b0;

        forever begin
            #(CLK_PERIOD / 2);
            core_clk = ~core_clk;
        end
    end

    // -------------------------------------------------------------------------
    // RESET GENERATION
    // -------------------------------------------------------------------------
    initial begin

        // Initial reset
        core_rst = ~RESET;

        #(5 * CLK_PERIOD);

        core_rst = RESET;

        #(2 * CLK_PERIOD);

        core_rst = ~RESET;

        // Reset durante operacao sera aplicado pela task dedicada.
    end

    // -------------------------------------------------------------------------
    // LOAD ONE VALUE INTO THE RSA CORE
    // -------------------------------------------------------------------------
    task automatic load_value(
        input logic [DATA_WIDTH-1:0] value
    );
        begin
            @(negedge core_clk);

            core_load = LOAD;
            core_din  = value;

            @(negedge core_clk);

            core_load = ~LOAD;
            core_din  = '0;

            @(negedge core_clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // RUN ONE RSA TEST
    //
    // expected_err:
    //     0 -> normal RSA operation expected
    //     1 -> error condition expected
    // -------------------------------------------------------------------------
    task automatic run_test(
        input logic [DATA_WIDTH-1:0] test_message,
        input logic [DATA_WIDTH-1:0] test_key,
        input logic [DATA_WIDTH-1:0] test_modulus,
        input logic [DATA_WIDTH-1:0] expected,
        input logic                  expected_err
    );

        int timeout_count;

        begin
            message        = test_message;
            encryption_key = test_key;
            modulus        = test_modulus;

            wait (core_done == 1'b0);

            // Input order:
            // 1. message
            // 2. encryption key
            // 3. modulus
            load_value(message);
            load_value(encryption_key);
            load_value(modulus);

            timeout_count = 0;

            while ((core_done !== 1'b1) &&
                   (timeout_count < 100000)) begin

                @(posedge core_clk);
                timeout_count++;
            end

            test_num++;

            if (core_done !== 1'b1) begin

                failed_count++;

                $display(
                    "Test %2d: M=%08h E=%08h N=%08h -> TIMEOUT  Expected=%08h ERR=%b [FAILED]",
                    test_num,
                    message,
                    encryption_key,
                    modulus,
                    expected,
                    expected_err
                );

            end
            else if ((core_dout !== expected) ||
                     (core_err  !== expected_err)) begin

                failed_count++;

                $display(
                    "Test %2d: M=%08h E=%08h N=%08h -> C=%08h ERR=%b  Expected=%08h ERR=%b [FAILED]",
                    test_num,
                    message,
                    encryption_key,
                    modulus,
                    core_dout,
                    core_err,
                    expected,
                    expected_err
                );

            end
            else begin

                passed_count++;

                $display(
                    "Test %2d: M=%08h E=%08h N=%08h -> C=%08h ERR=%b  Expected=%08h ERR=%b [PASSED]",
                    test_num,
                    message,
                    encryption_key,
                    modulus,
                    core_dout,
                    core_err,
                    expected,
                    expected_err
                );

            end

            if (core_done === 1'b1) begin
                wait (core_done == 1'b0);
            end

            #(10 * CLK_PERIOD);
        end
    endtask

    // -------------------------------------------------------------------------
    // ONE-CYCLE RESET DURING ACTIVE COMPUTATION + RECOVERY
    // -------------------------------------------------------------------------
    task automatic test_reset_recovery();
        begin
            $display("\n=== ONE-CYCLE RESET DURING COMPUTATION ===");

            // Operacao A: interrompida antes da conclusao.
            load_value(32'd2);
            load_value(32'd15);
            load_value(32'd13);

            // Permite a entrada na fase de calculo, mas nao sua conclusao.
            repeat (8) @(posedge core_clk);
            @(negedge core_clk);

            if (duv.rsa_core_ctrl_blk.state_reg !== 4'd9 ||
                core_done !== 1'b0) begin
                failed_count++;
                $display("RESET TEST: nao estava em ANALYZE antes do reset [FAILED]");
            end
            else
                $display("RESET TEST: operacao A ativa em ANALYZE [OK]");

            // Um periodo completo, abrangendo exatamente um posedge.
            core_rst = RESET;

            @(posedge core_clk);
            #1;

            if (duv.rsa_core_ctrl_blk.state_reg !== 4'd0) begin
                failed_count++;
                $display("RESET TEST: controlador nao entrou em INIT [FAILED]");
            end
            else
                $display("RESET TEST: controlador entrou em INIT [OK]");

            @(negedge core_clk);
            core_rst = ~RESET;

            // Na borda seguinte as acoes de INIT sao executadas.
            @(posedge core_clk);
            #1;

            if (duv.rsa_core_ctrl_blk.state_reg !== 4'd1 ||
                core_done !== 1'b0 || core_err !== 1'b0) begin

                failed_count++;
                $display("RESET TEST: recuperacao para LOAD_M / flags [FAILED]");
            end
            else
                $display("RESET TEST: pronto para nova mensagem [OK]");

            // Confirma ausencia de uma conclusao espuria apos o aborto.
            repeat (5) begin
                @(posedge core_clk);
                #1;

                if (core_done !== 1'b0) begin
                    failed_count++;
                    $display("RESET TEST: core_done espurio apos aborto [FAILED]");
                end
            end

            // Operacao B: deve terminar corretamente apos o reset.
            // 2^5 mod 13 = 6; usa a task original e seu timeout.
            run_test(32'd2, 32'd5, 32'd13, 32'd6, 1'b0);
        end
    endtask

    // -------------------------------------------------------------------------
    // TEST STIMULUS
    // -------------------------------------------------------------------------
    initial begin

        core_load      = ~LOAD;
        core_din       = '0;
        message        = '0;
        encryption_key = '0;
        modulus        = '0;

        test_num     = 0;
        passed_count = 0;
        failed_count = 0;

        $display("------------------------------------------------------------------------------------------------");
        $display("RSA Core - 32-bit SystemVerilog Testbench");
        $display("------------------------------------------------------------------------------------------------");
        $display("       Message   Exponent    Modulus    Result       Expected");
        $display("------------------------------------------------------------------------------------------------");

        #(8 * CLK_PERIOD);

        // Teste isolado do contrato temporal de SRST (1 ciclo).
        test_reset_recovery();

        // =====================================================================
        // ORIGINAL 40 TESTS
        // =====================================================================

        // Modulus = 0 -> error condition
        run_test(32'd0 , 32'd0 , 32'd0 , 32'hFFFFFFFF, 1'b1); // Test 01

        run_test(32'd0 , 32'd0 , 32'd1 , 32'd0 , 1'b0); // Test 02
        run_test(32'd0 , 32'd0 , 32'd2 , 32'd1 , 1'b0); // Test 03
        run_test(32'd0 , 32'd0 , 32'd15, 32'd1 , 1'b0); // Test 04

        // Modulus = 0 -> error condition
        run_test(32'd0 , 32'd1 , 32'd0 , 32'hFFFFFFFF, 1'b1); // Test 05
        run_test(32'd0 , 32'd2 , 32'd0 , 32'hFFFFFFFF, 1'b1); // Test 06
        run_test(32'd0 , 32'd15, 32'd0 , 32'hFFFFFFFF, 1'b1); // Test 07
        run_test(32'd1 , 32'd0 , 32'd0 , 32'hFFFFFFFF, 1'b1); // Test 08
        run_test(32'd2 , 32'd0 , 32'd0 , 32'hFFFFFFFF, 1'b1); // Test 09
        run_test(32'd15, 32'd0 , 32'd0 , 32'hFFFFFFFF, 1'b1); // Test 10

        run_test(32'd1 , 32'd1 , 32'd1 , 32'd0 , 1'b0); // Test 11
        run_test(32'd1 , 32'd1 , 32'd2 , 32'd1 , 1'b0); // Test 12
        run_test(32'd1 , 32'd1 , 32'd15, 32'd1 , 1'b0); // Test 13
        run_test(32'd1 , 32'd2 , 32'd1 , 32'd0 , 1'b0); // Test 14
        run_test(32'd1 , 32'd15, 32'd1 , 32'd0 , 1'b0); // Test 15
        run_test(32'd2 , 32'd1 , 32'd1 , 32'd0 , 1'b0); // Test 16
        run_test(32'd15, 32'd1 , 32'd1 , 32'd0 , 1'b0); // Test 17
        run_test(32'd2 , 32'd2 , 32'd2 , 32'd0 , 1'b0); // Test 18
        run_test(32'd2 , 32'd2 , 32'd3 , 32'd1 , 1'b0); // Test 19
        run_test(32'd2 , 32'd2 , 32'd15, 32'd4 , 1'b0); // Test 20
        run_test(32'd2 , 32'd3 , 32'd2 , 32'd0 , 1'b0); // Test 21
        run_test(32'd2 , 32'd15, 32'd2 , 32'd0 , 1'b0); // Test 22
        run_test(32'd3 , 32'd2 , 32'd2 , 32'd1 , 1'b0); // Test 23
        run_test(32'd15, 32'd2 , 32'd2 , 32'd1 , 1'b0); // Test 24
        run_test(32'd4 , 32'd10, 32'd9 , 32'd4 , 1'b0); // Test 25
        run_test(32'd11, 32'd1 , 32'd7 , 32'd4 , 1'b0); // Test 26
        run_test(32'd9 , 32'd4 , 32'd7 , 32'd2 , 1'b0); // Test 27
        run_test(32'd9 , 32'd9 , 32'd3 , 32'd0 , 1'b0); // Test 28
        run_test(32'd8 , 32'd10, 32'd1 , 32'd0 , 1'b0); // Test 29
        run_test(32'd2 , 32'd5 , 32'd3 , 32'd2 , 1'b0); // Test 30
        run_test(32'd9 , 32'd5 , 32'd3 , 32'd0 , 1'b0); // Test 31
        run_test(32'd8 , 32'd5 , 32'd3 , 32'd2 , 1'b0); // Test 32
        run_test(32'd14, 32'd5 , 32'd3 , 32'd2 , 1'b0); // Test 33
        run_test(32'd2 , 32'd5 , 32'd3 , 32'd2 , 1'b0); // Test 34
        run_test(32'd12, 32'd5 , 32'd3 , 32'd0 , 1'b0); // Test 35
        run_test(32'd1 , 32'd5 , 32'd3 , 32'd1 , 1'b0); // Test 36
        run_test(32'd7 , 32'd5 , 32'd3 , 32'd1 , 1'b0); // Test 37
        run_test(32'd0 , 32'd5 , 32'd3 , 32'd0 , 1'b0); // Test 38
        run_test(32'd11, 32'd5 , 32'd3 , 32'd2 , 1'b0); // Test 39
        run_test(32'd15, 32'd15, 32'd15, 32'd0 , 1'b0); // Test 40

        // =====================================================================
        // ADDITIONAL 32-BIT VALIDATION TESTS
        // =====================================================================

        // 2^5 mod 13 = 6
        run_test(
            32'h00000002,
            32'h00000005,
            32'h0000000D,
            32'h00000006,
            1'b0
        ); // Test 41

        // 4^3 mod 17 = 13
        run_test(
            32'h00000004,
            32'h00000003,
            32'h00000011,
            32'h0000000D,
            1'b0
        ); // Test 42

        // 7^2 mod 19 = 11
        run_test(
            32'h00000007,
            32'h00000002,
            32'h00000013,
            32'h0000000B,
            1'b0
        ); // Test 43

        // M^0 mod N = 1
        run_test(
            32'h12345678,
            32'h00000000,
            32'h00010001,
            32'h00000001,
            1'b0
        ); // Test 44

        // 0^5 mod N = 0
        run_test(
            32'h00000000,
            32'h00000005,
            32'h01234567,
            32'h00000000,
            1'b0
        ); // Test 45

        // 1^7 mod N = 1
        run_test(
            32'h00000001,
            32'h00000007,
            32'h89ABCDEF,
            32'h00000001,
            1'b0
        ); // Test 46

        // Exercise bits above the original 4-bit range
        run_test(
            32'h00010001,
            32'h00000002,
            32'h0000FFFF,
            32'h00000004,
            1'b0
        ); // Test 47

        run_test(
            32'h00010000,
            32'h00000002,
            32'h00010001,
            32'h00000001,
            1'b0
        ); // Test 48

        // Full-width message
        run_test(
            32'h12345678,
            32'h00000001,
            32'h00010001,
            32'h00004444,
            1'b0
        ); // Test 49

        run_test(
            32'hABCDEF01,
            32'h00000001,
            32'h00FFFFFF,
            32'h00CDEFAC,
            1'b0
        ); // Test 50

        run_test(
            32'hFFFFFFFF,
            32'h00000001,
            32'hFFFFFFFB,
            32'h00000004,
            1'b0
        ); // Test 51

        // 32 x 32 multiplication -> 64-bit intermediate value
        run_test(
            32'h12345678,
            32'h00000002,
            32'hFFFFFFFF,
            32'h1F403F1C,
            1'b0
        ); // Test 52

        // Exercise bit 31
        run_test(
            32'h80000000,
            32'h00000002,
            32'hFFFFFFFF,
            32'h40000000,
            1'b0
        ); // Test 53

        // Multiple modular multiplications with large operand
        run_test(
            32'hDEADBEEF,
            32'h00000003,
            32'hFFFFFFFB,
            32'h62FBD2EA,
            1'b0
        ); // Test 54

        // Explicit error test
        run_test(
            32'h12345678,
            32'h00000003,
            32'h00000000,
            32'hFFFFFFFF,
            1'b1
        ); // Test 55

        // =====================================================================
        // TEST SUMMARY
        // =====================================================================

        $display("------------------------------------------------------------------------------------------------");
        $display("Tests executed : %0d", test_num);
        $display("Passed         : %0d", passed_count);
        $display("Failed         : %0d", failed_count);
        $display("------------------------------------------------------------------------------------------------");

        if (failed_count == 0)
            $display("32-bit RSA Core validation: PASSED");
        else
            $display("32-bit RSA Core validation: FAILED");

        $display("------------------------------------------------------------------------------------------------");
        $display("End of Simulation");

        #CLK_PERIOD;
        $finish;
    end

endmodule
