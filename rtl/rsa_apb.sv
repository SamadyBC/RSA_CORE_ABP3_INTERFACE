//-----------------------------------------------------------------------------
// RSA_APB - Coprocessador RSA 32 bits com interface AMBA 3 APB (APB3)
//
//   C = M^e mod n
//
// Blocos internos:
//   1. Decodificacao APB  : enderecos, deteccao de escrita/leitura, PSLVERR
//   2. Banco de registros : CTRL, STATUS, IER, MSG, EXP, MOD, RESULT, ID
//   3. Sequenciador       : gera os 3 pulsos de core_load (M, e, n)
//   4. Sincronizador reset: PRESETn -> core_rst (2 flops) + pulso de SRST
//   5. rsa_core           : nucleo de exponenciacao modular (reference design)
//
// Mapa de registros (offset em bytes, PADDR[1:0] ignorado):
//   0x00 CTRL   WO      [1] SRST  [0] START   (auto-limpantes)
//   0x04 STATUS RO/W1C  [2] ERROR [1] DONE    [0] BUSY
//   0x08 IER    RW      [1] ERR_IE [0] DONE_IE
//   0x0C MSG    RW      M
//   0x10 EXP    RW      e
//   0x14 MOD    RW      n
//   0x18 RESULT RO      C
//   0x1C ID     RO      0x5253_0200
//
// Adaptacoes ao rsa_core do reference design (difere da secao 3.2 da spec):
//   - O core precisa de core_load em 0 entre operandos: LOAD_GAP padrao = 1
//     (com 0 o core trava esperando o 2o operando)
//   - Em erro o core pulsa core_done junto com core_err, e core_err fica em 1
//     ate a proxima operacao bem-sucedida. O fim de operacao e detectado por
//     core_done OU pela subida de core_error, e o tipo (erro/sucesso) pelo
//     nivel de core_error nesse ciclo. Funciona tambem com um core que siga a
//     spec a risca (core_error de 1 ciclo, sem core_done)
//   - Apos sair do reset o core gasta 1 ciclo em INIT: o primeiro load so e
//     gerado depois de core_rst ter sido amostrado em 0 (core_rdy_q)
//-----------------------------------------------------------------------------
`timescale 1ns/1ps

module rsa_apb #(
  parameter int LOAD_GAP = 1           // ciclos ociosos entre os loads (>= 1
                                       // para o rsa_core do reference design)
) (
  // APB3 slave
  input  logic        PCLK,
  input  logic        PRESETn,
  input  logic        PSEL,
  input  logic        PENABLE,
  input  logic        PWRITE,
  input  logic [11:0] PADDR,
  input  logic [31:0] PWDATA,
  output logic [31:0] PRDATA,
  output logic        PREADY,
  output logic        PSLVERR,
  // Interrupcao
  output logic        irq
);

  //---------------------------------------------------------------------------
  // Constantes
  //---------------------------------------------------------------------------
  // Endereco de palavra = PADDR[11:2]
  localparam logic [9:0] ADDR_CTRL   = 10'h000;  // 0x00
  localparam logic [9:0] ADDR_STATUS = 10'h001;  // 0x04
  localparam logic [9:0] ADDR_IER    = 10'h002;  // 0x08
  localparam logic [9:0] ADDR_MSG    = 10'h003;  // 0x0C
  localparam logic [9:0] ADDR_EXP    = 10'h004;  // 0x10
  localparam logic [9:0] ADDR_MOD    = 10'h005;  // 0x14
  localparam logic [9:0] ADDR_RESULT = 10'h006;  // 0x18
  localparam logic [9:0] ADDR_ID     = 10'h007;  // 0x1C

  localparam logic [31:0] ID_VALUE = 32'h5253_0200;  // "RS", v2.0

  // Contador do intervalo entre loads (so e usado se LOAD_GAP > 0)
  localparam int              GW       = (LOAD_GAP > 1) ? $clog2(LOAD_GAP) : 1;
  localparam logic [GW-1:0]   GAP_LAST = (LOAD_GAP > 0) ? GW'(LOAD_GAP - 1) : '0;

  // Estados do sequenciador
  typedef enum logic [1:0] {
    S_IDLE = 2'd0,   // aguardando START
    S_LOAD = 2'd1,   // core_load = 1, core_din = operando[load_idx]
    S_GAP  = 2'd2,   // ciclos ociosos entre loads (LOAD_GAP > 0)
    S_WAIT = 2'd3    // aguardando core_done / core_error
  } state_t;

  //---------------------------------------------------------------------------
  // Sinais internos
  //---------------------------------------------------------------------------
  // Registros
  logic [31:0] msg_q, exp_q, mod_q, result_q;
  logic [1:0]  ier_q;                // {ERR_IE, DONE_IE}
  logic        done_q, error_q;      // flags sticky do STATUS
  logic        srst_q;               // pulso de 1 ciclo de reset do core
  logic        busy;                 // STATUS.BUSY

  // Sequenciador
  state_t      state;
  logic [1:0]  load_idx;             // 0 = M, 1 = e, 2 = n
  logic [GW-1:0] gap_cnt;

  // Reset do core
  logic [1:0]  rst_sync;
  logic        core_rdy_q;           // core_rst ja foi amostrado em 0

  // Interface com o rsa_core
  logic        core_rst;
  logic        core_load;
  logic [31:0] core_din;
  logic        core_done;
  logic        core_error;
  logic [31:0] core_dout;

  // Decodificacao APB
  logic [9:0]  word_addr;
  logic        apb_write;            // fase de acesso de uma escrita
  logic        apb_read;             // leitura em andamento (setup ou acesso)
  logic        sel_ctrl, sel_status, sel_ier, sel_msg, sel_exp, sel_mod;
  logic        sel_result, sel_id;

  // Eventos
  logic        ctrl_srst;            // escrita de CTRL com SRST = 1
  logic        ctrl_start;           // escrita de CTRL com START = 1 (sem SRST)
  logic        start_go;             // START aceito (bloco ocioso)
  logic        err_start_busy;       // START com BUSY = 1
  logic        err_operand_busy;     // MSG/EXP/MOD com BUSY = 1
  logic        err_read_only;        // escrita em RESULT ou ID
  logic        wr_operand_ok;        // escrita valida em MSG/EXP/MOD
  logic        core_error_q;         // core_error do ciclo anterior
  logic        core_fin;             // core terminou (sucesso ou erro)
  logic        done_evt, error_evt;  // fim de operacao aceito pelo wrapper

  //---------------------------------------------------------------------------
  // 1. Decodificacao APB
  //---------------------------------------------------------------------------
  assign word_addr = PADDR[11:2];
  assign apb_write = PSEL & PENABLE &  PWRITE;
  assign apb_read  = PSEL &           ~PWRITE;

  assign sel_ctrl   = (word_addr == ADDR_CTRL);
  assign sel_status = (word_addr == ADDR_STATUS);
  assign sel_ier    = (word_addr == ADDR_IER);
  assign sel_msg    = (word_addr == ADDR_MSG);
  assign sel_exp    = (word_addr == ADDR_EXP);
  assign sel_mod    = (word_addr == ADDR_MOD);
  assign sel_result = (word_addr == ADDR_RESULT);
  assign sel_id     = (word_addr == ADDR_ID);

  // CTRL: se SRST e START vierem juntos, SRST tem prioridade e START e ignorado
  assign ctrl_srst  = apb_write & sel_ctrl &  PWDATA[1];
  assign ctrl_start = apb_write & sel_ctrl & ~PWDATA[1] & PWDATA[0];

  assign start_go         = ctrl_start & ~busy;
  assign err_start_busy   = ctrl_start &  busy;
  assign err_operand_busy = apb_write & (sel_msg | sel_exp | sel_mod) &  busy;
  assign wr_operand_ok    = apb_write & ~busy;
  assign err_read_only    = apb_write & (sel_result | sel_id);

  // Sem wait states; PSLVERR so na fase de acesso (apb_write ja inclui
  // PSEL & PENABLE)
  assign PREADY  = 1'b1;
  assign PSLVERR = err_start_busy | err_operand_busy | err_read_only;

  //---------------------------------------------------------------------------
  // 2. Banco de registros
  //---------------------------------------------------------------------------
  // Operandos: escrita rejeitada (PSLVERR) com BUSY = 1; SRST nao altera
  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
      msg_q <= '0;
      exp_q <= '0;
      mod_q <= '0;
    end else if (wr_operand_ok) begin
      if (sel_msg) msg_q <= PWDATA;
      if (sel_exp) exp_q <= PWDATA;
      if (sel_mod) mod_q <= PWDATA;
    end
  end

  // IER: sempre gravavel; SRST nao altera
  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)
      ier_q <= '0;
    else if (apb_write & sel_ier)
      ier_q <= PWDATA[1:0];
  end

  // Fim de operacao: core_done, ou subida de core_error (core que nao pulsa
  // core_done em erro). core_error em nivel indica o tipo. So e considerado
  // no estado S_WAIT e sem SRST no mesmo ciclo (SRST aborta a operacao)
  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)
      core_error_q <= 1'b0;
    else
      core_error_q <= core_error;
  end

  assign core_fin  = core_done | (core_error & ~core_error_q);
  assign done_evt  = (state == S_WAIT) & core_fin & ~core_error & ~ctrl_srst;
  assign error_evt = (state == S_WAIT) & core_fin &  core_error & ~ctrl_srst;

  // RESULT: capturado em core_done; inalterado em erro e em SRST
  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)
      result_q <= '0;
    else if (done_evt)
      result_q <= core_dout;
  end

  // STATUS.DONE / STATUS.ERROR: sticky, W1C.
  // Prioridade: SRST / START limpam; evento do core tem prioridade sobre W1C
  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
      done_q  <= 1'b0;
      error_q <= 1'b0;
    end else if (ctrl_srst | start_go) begin
      done_q  <= 1'b0;
      error_q <= 1'b0;
    end else begin
      if (done_evt)
        done_q <= 1'b1;
      else if (apb_write & sel_status & PWDATA[1])
        done_q <= 1'b0;

      if (error_evt)
        error_q <= 1'b1;
      else if (apb_write & sel_status & PWDATA[2])
        error_q <= 1'b0;
    end
  end

  // STATUS.BUSY: 1 do START ate o ciclo seguinte a core_done/core_error
  assign busy = (state != S_IDLE);

  // Leitura (mux de PRDATA). Bits reservados, CTRL e enderecos
  // reservados leem 0
  always_comb begin
    PRDATA = '0;
    if (apb_read) begin
      case (word_addr)
        ADDR_STATUS: PRDATA = {29'b0, error_q, done_q, busy};
        ADDR_IER:    PRDATA = {30'b0, ier_q};
        ADDR_MSG:    PRDATA = msg_q;
        ADDR_EXP:    PRDATA = exp_q;
        ADDR_MOD:    PRDATA = mod_q;
        ADDR_RESULT: PRDATA = result_q;
        ADDR_ID:     PRDATA = ID_VALUE;
        default:     PRDATA = '0;
      endcase
    end
  end

  // Interrupcao por nivel
  assign irq = (done_q & ier_q[0]) | (error_q & ier_q[1]);

  //---------------------------------------------------------------------------
  // 3. Sequenciador de load: M -> e -> n, depois espera o core
  //---------------------------------------------------------------------------
  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn) begin
      state    <= S_IDLE;
      load_idx <= 2'd0;
      gap_cnt  <= '0;
    end else if (ctrl_srst) begin
      state    <= S_IDLE;
      load_idx <= 2'd0;
      gap_cnt  <= '0;
    end else begin
      case (state)
        S_IDLE: begin
          if (start_go) begin
            state    <= S_LOAD;
            load_idx <= 2'd0;
          end
        end

        S_LOAD: begin
          if (core_rdy_q) begin              // senao, espera o core sair do reset
            if (load_idx == 2'd2) begin
              state <= S_WAIT;
            end else if (LOAD_GAP == 0) begin
              load_idx <= load_idx + 2'd1;
            end else begin
              state   <= S_GAP;
              gap_cnt <= '0;
            end
          end
        end

        S_GAP: begin
          if (gap_cnt == GAP_LAST) begin
            state    <= S_LOAD;
            load_idx <= load_idx + 2'd1;
          end else begin
            gap_cnt  <= gap_cnt + 1'b1;
          end
        end

        S_WAIT: begin
          if (core_fin)
            state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  assign core_load = (state == S_LOAD) & core_rdy_q;

  always_comb begin
    case (load_idx)
      2'd0:    core_din = msg_q;
      2'd1:    core_din = exp_q;
      default: core_din = mod_q;
    endcase
  end

  //---------------------------------------------------------------------------
  // 4. Reset do core: sincronizador de 2 flops (assert assincrono,
  //    deassert sincrono) OR pulso de SRST
  //---------------------------------------------------------------------------
  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)
      rst_sync <= 2'b00;
    else
      rst_sync <= {rst_sync[0], 1'b1};
  end

  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)
      srst_q <= 1'b0;
    else
      srst_q <= ctrl_srst;
  end

  assign core_rst = ~rst_sync[1] | srst_q;

  // O core so aceita load um ciclo depois de amostrar core_rst = 0
  always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)
      core_rdy_q <= 1'b0;
    else
      core_rdy_q <= ~core_rst;
  end

  //---------------------------------------------------------------------------
  // 5. Nucleo RSA
  //---------------------------------------------------------------------------
  rsa_core u_rsa_core (
    .core_clk   (PCLK),
    .core_rst   (core_rst),
    .core_load  (core_load),
    .core_din   (core_din),
    .core_done  (core_done),
    .core_err   (core_error),        // nome da porta no reference design
    .core_dout  (core_dout)
  );

endmodule
