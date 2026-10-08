
module rsa_apb_top #(
    parameter int LENGTH = 32,
    parameter bit RESET      = 1'b0,
)(
    input logic pclk, presetn, psel, penable, pwrite,
    input logic [31:0] pwdata,
    input logic [11:0] paddr,
    output logic [31:0] prdata,
    output logic pready, pslverr, irq
);


//Desenvolvimento numa abordagem top-down: Olhando os componentes de cima para baixo

    mux_mem U00(
        din(),
        sel(),
        dout()
    );

    mux_mem U01(
        din(),
        sel(),
        dout()
    );

    //===========================================================
    //Reset Control - Bloco de Sincronização do Reset
    logic rst_sync_ff1;
    logic rst_sync_ff2;

    always_ff @(posedge PCLK or negedge PRESETn) begin
        if (!PRESETn) begin
            rst_sync_ff1 <= 1'b0;
            rst_sync_ff2 <= 1'b0;
        end
        else begin
            rst_sync_ff1 <= 1'b1;
            rst_sync_ff2 <= rst_sync_ff1;
        end
    end

    assign core_rst = ~rst_sync_ff2;
    //============================================================

    //APB/Registers

    rsa_core U02(
        .inputs()
        .outputs()
    );



endmodule