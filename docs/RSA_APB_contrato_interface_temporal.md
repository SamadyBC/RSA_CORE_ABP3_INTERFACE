# RSA_APB — Contrato de interface e comportamento temporal do `rsa_core`

**Versão:** 1.0 — 08/10/2026  
**Escopo:** integração de um `rsa_core` SystemVerilog de 32 bits como IP interno do periférico `RSA_APB` (AMBA 3 APB).  
**Natureza:** documento de referência para a **discussão posterior da arquitetura**; não constitui implementação RTL nem especificação modificada oficialmente.

## 1. Objetivo e critérios de evidência

Consolidar as conclusões das quatro etapas de caracterização temporal:

1. Reset inicial e retorno aos estados de espera;
2. Carregamento sequencial de `MSG`, `EXP` e `MOD`;
3. Conclusão normal e conclusão com erro;
4. Reset durante a operação, incluindo pulso de **um ciclo** e operação subsequente.

As afirmações usam as seguintes classificações:

- **[ESP]** — requisito do documento *RSA_APB — 32-bit RSA Coprocessor with APB Interface* (`apb_integration.pdf`);
- **[RTL]** — comportamento identificado no `rsa_core` disponível;
- **[VCD]** — comportamento observado nas simulações e arquivos de waveform;
- **[PROPOSTA]** — estratégia de adaptação a decidir/implementar no wrapper;
- **[PENDENTE]** — aspecto que exigirá validação no nível do wrapper ou deliberação explícita.

Essa separação impede que uma proposta de integração seja confundida com um requisito literal do enunciado.

## 2. Interfaces e domínio de clock

### 2.1 Interface interna real do core

| Sinal | Direção no core | Largura | Contrato observado |
|---|---|---:|---|
| `core_clk` | Entrada | 1 | Clock dos três blocos internos; será conectado a `PCLK` **[ESP/RTL]** |
| `core_rst` | Entrada | 1 | Reset **síncrono, ativo em alto** **[RTL/VCD]** |
| `core_load` | Entrada | 1 | Sinal ativo em alto utilizado no sequenciamento da recepção de operandos **[RTL/VCD]** |
| `core_din` | Entrada | 32 | Dados de entrada, na ordem mensagem, expoente e módulo **[RTL/VCD]** |
| `core_done` | Saída | 1 | Indica conclusão de sucesso **ou erro**; pulso de um período **[RTL/VCD]** |
| `core_err` | Saída | 1 | Qualifica conclusão com erro; pode continuar ativo após `core_done` **[RTL/VCD]** |
| `core_dout` | Saída | 32 | Saída registrada do cálculo, ou `FFFF_FFFF` no caminho de erro com módulo nulo **[RTL/VCD]** |
| `core_clk_o` | Saída | 1 | Reprodução de `core_clk` no módulo fornecido **[RTL]** |

**Diferença nominal:** o enunciado chama a saída de erro de `core_error`, enquanto o RTL disponível utiliza `core_err`. A conexão precisa usar o nome real do porto do IP ou um sinal intermediário equivalente. **[ESP/RTL]**

### 2.2 Interface externa do wrapper e requisitos básicos

O `RSA_APB` é um slave AMBA 3 APB, com `PCLK`, `PRESETn` ativo em baixo, `PSEL`, `PENABLE`, `PWRITE`, `PADDR[11:0]`, `PWDATA[31:0]`, `PRDATA[31:0]`, `PREADY`, `PSLVERR` e `irq`. O barramento é de 32 bits, tem janela de endereços de 4 KiB e utiliza endereços de palavra; os bits `PADDR[1:0]` são ignorados. **[ESP]**

- `PREADY = 1`: não há *wait states* na interface APB. **[ESP]**
- `PSLVERR` tem significado durante a fase de acesso. **[ESP]**
- `irq` é um sinal de nível: `STATUS.DONE & IER.DONE_IE | STATUS.ERROR & IER.ERR_IE`. **[ESP]**
- A interface APB e o core compartilham o mesmo domínio de clock: `core_clk = PCLK`. **[ESP]**

**Importante:** ausência de *wait states* na transferência APB não implica que o cálculo RSA termine em uma transferência. O software acompanha `STATUS` ou `irq`. **[ESP]**

## 3. Contrato de carregamento dos operandos

### 3.1 Ordem e captura

O controlador do `rsa_core` possui os estados `LOAD_M → WAIT_M → LOAD_E → WAIT_E → LOAD_N → WAIT_N`. O dado é registrado no respectivo estado `LOAD_*`; `core_load=1` permite a transição para `WAIT_*`, e **é necessário amostrar `core_load=0` numa borda positiva enquanto em `WAIT_*`** para avançar ao próximo `LOAD_*`. **[RTL/VCD]**

A ordem obrigatória é:

```text
MSG (M) → EXP (e) → MOD (n)
```

Entre duas capturas sucessivas, há obrigatoriamente pelo menos uma borda positiva com `core_load=0`. Depois do carregamento de MOD, uma borda com `core_load=0` também é necessária para que `WAIT_N` seja abandonado e a computação avance. **[RTL/VCD]**

### 3.2 Protocolo mínimo compatível com o RTL atual

Uma representação por bordas de amostragem é:

| Borda de `PCLK` | `core_load` | `core_din` | Efeito esperado |
|---:|---:|---|---|
| 1 | 1 | `MSG` | Captura M; transita para `WAIT_M` |
| 2 | 0 | indiferente | Sai de `WAIT_M` para `LOAD_E` |
| 3 | 1 | `EXP` | Captura e; transita para `WAIT_E` |
| 4 | 0 | indiferente | Sai de `WAIT_E` para `LOAD_N` |
| 5 | 1 | `MOD` | Captura n; transita para `WAIT_N` |
| 6 | 0 | indiferente | Sai de `WAIT_N` e inicia os passos de cálculo |

**Condição de estabilidade:** `core_din` deve apresentar o operando correto antes da borda que o registra. A existência do estado `LOAD_*` por si só não deve ser confundida com uma transferência APB. **[RTL]**

A testbench original utiliza intervalos **mais conservadores** (tipicamente três períodos entre as bordas de captura), mas esses intervalos adicionais não são demonstrados como uma exigência do core. **[VCD]**

### 3.3 Divergência formal com o enunciado — incompatibilidade 01

**[ESP]** O enunciado declara que o core aceita três loads *back-to-back* e que `LOAD_GAP=0` não insere ciclos ociosos entre eles. Interpretado literalmente, isso implicaria `core_load=1` em três bordas consecutivas, apenas com `core_din` alternando entre M/e/n.

**[RTL/VCD]** O core atual não aceita essa sequência: `WAIT_M` e `WAIT_E` não avançam enquanto `core_load=1`. Assim, somente M seria capturada, e os outros valores não seriam recebidos nos estados corretos.

**Conclusão:** trata-se de uma **incompatibilidade real entre o texto da especificação e o IP fornecido**, não apenas de diferença entre duas testbenches.

### 3.4 Adaptação por sequenciador — decisão de arquitetura proposta

**[PROPOSTA]** Preservar o RTL do IP já validado e adaptar os loads no wrapper com uma FSM conceitual de quatro estados:

```text
IDLE --START--> LOAD --(1 ciclo)--> GAP --(próximo operando)--> LOAD
                                         |
                                         +--(último operando liberado)--> WAIT
WAIT --(conclusão válida)--> IDLE
```

- `load_idx = 0, 1, 2` seleciona `MSG`, `EXP`, `MOD`;
- `core_load = 1` somente em `LOAD`;
- `core_load = 0` em `GAP`, `WAIT` e `IDLE`;
- a etapa de `GAP` deve ocorrer **também depois de MOD**, para liberar `WAIT_N`;
- o estado `WAIT` acompanha a conclusão da operação, não a saída de `core_err` isoladamente.

**Semântica proposta de `LOAD_GAP`:** tratá-lo como número de ciclos **adicionais** aos ciclos obrigatórios de liberação do sinal de carga. Nesse caso:

```text
Duração efetiva do intervalo entre loads = 1 + LOAD_GAP ciclos
LOAD_GAP=0 → M, release, e, release, n, release
LOAD_GAP=1 → M, release, extra, e, release, extra, n, release
```

O último `release` pode ser realizado no primeiro ciclo de `WAIT`, **desde que** haja uma borda efetiva de `PCLK` com `core_load=0` em `WAIT_N`; a alternativa com passagem explícita por `GAP` após MOD facilita a revisão. **[PROPOSTA]**

**Ressalva:** a semântica de “ciclos adicionais” é uma **mudança de interpretação**, não o significado literal de `LOAD_GAP` no enunciado. Deve ser registrada ou aprovada como decisão de integração. Evitar expressões de contador `LOAD_GAP-1` sem tratamento explícito de zero. **[PENDENTE]**

## 4. Contrato de conclusão normal e de erro

### 4.1 Valores esperados na conclusão

| Condição do core | `core_done` | `core_err` | `core_dout` |
|---|---:|---:|---|
| Conclusão normal | 1 | 0 | Resultado calculado |
| Erro devido a `MOD=0` | 1 | 1 | `32'hFFFF_FFFF` |

No estado interno `DONE`, o core registra o resultado, ativa `done_ff` e limpa `err_ff`; no estado `ERROR`, ativa **ambos** `done_ff` e `err_ff` e registra todos os bits de `c_reg` em 1. **[RTL/VCD]**

### 4.2 Evidência temporal — VCD original (`CLK_PERIOD=20 ns`)

**Erro, teste inicial com `M=0`, `e=0`, `n=0`:**

| Tempo | Comportamento |
|---:|---|
| 330 ns | `core_done=1`, `core_err=1`, `core_dout=FFFF_FFFF` |
| 350 ns | `core_done=0`, mas `core_err=1` continua ativo |

**Conclusão normal, operação seguinte:**

| Tempo | Comportamento |
|---:|---|
| 5350 ns | `core_done=1`, `core_err=0`, resultado atualizado |
| 5370 ns | `core_done=0` |

Assim, `core_done` é um pulso de **um período**, mas `core_err` pode permanecer ativo desde o erro anterior até a conclusão normal seguinte (ou uma inicialização apropriada). **[VCD]**

### 4.3 Divergência formal com o enunciado — incompatibilidade 02

**[ESP]** O texto caracteriza `core_done` e `core_error` como pulsos distintos de um ciclo; em erro, `core_error` seria assertado **em vez de** `core_done`.

**[RTL/VCD]** O sinal existente `core_err` não é um pulso garantido, e **coincide com `core_done`** quando há erro.

**Contrato seguro para o wrapper [PROPOSTA]:**

```systemverilog
// Ideia de condição de evento, não implementação final:
if (waiting_for_current_operation && core_done) begin
    if (core_err) begin
        // Operação atual terminou com erro; RESULT não é atualizado.
    end else begin
        // Operação atual concluiu; RESULT recebe core_dout.
    end
end
```

Não usar `core_done || core_err` como condição genérica de conclusão: um `core_err` antigo poderia encerrar falsamente uma operação nova. **[RTL/VCD]**

### 4.4 Amostragem síncrona entre core e wrapper

`core_done`, `core_err` e `core_dout` são sinais registrados no domínio de `PCLK`. Quando o core os atualiza na borda `t`, um `always_ff @(posedge PCLK)` no wrapper só os observa atualizados na **borda seguinte**, em virtude da semântica de atribuições não bloqueantes. **[RTL]**

Exemplo observado: core registra o evento em 5350 ns; wrapper síncrono pode reconhecer `core_done=1`, ler `core_err` e capturar `core_dout` na borda de 5370 ns. A desassertação simultânea de `core_done` pelo core nessa borda não compromete a amostragem pelo wrapper. **[RTL/VCD, inferência de integração]**

## 5. Repercussões para os registradores APB

### 5.1 Mapa de registradores exigido

| Offset | Registro | Acesso | Valor após `PRESETn` | Função |
|---|---|---|---|---|
| `0x00` | `CTRL` | WO, leitura zero | `0000_0000` | `START` bit 0, `SRST` bit 1; comandos autocanceláveis |
| `0x04` | `STATUS` | RO/W1C | `0000_0000` | `BUSY` bit 0, `DONE` bit 1, `ERROR` bit 2 |
| `0x08` | `IER` | RW | `0000_0000` | `DONE_IE` bit 0, `ERR_IE` bit 1 |
| `0x0C` | `MSG` | RW | `0000_0000` | Mensagem |
| `0x10` | `EXP` | RW | `0000_0000` | Expoente |
| `0x14` | `MOD` | RW | `0000_0000` | Módulo |
| `0x18` | `RESULT` | RO | `0000_0000` | Último resultado bem-sucedido |
| `0x1C` | `ID` | RO | `5253_0200` | Identificador fixo |

**[ESP]** Bits reservados são lidos como zero; registros de operandos retêm seu conteúdo entre operações. Escritas de operandos e `CTRL.START` com `BUSY=1` geram `PSLVERR` e não têm efeito; escritas em `RESULT` e `ID` também geram `PSLVERR` sem efeito. `CTRL.SRST` tem prioridade quando escrito simultaneamente a `START`. Restrições sobre endereços reservados e escritas em bits reservados requerem interpretação cuidadosa do enunciado antes de fechar o decodificador. **[PENDENTE]**

### 5.2 Regras de atualização a implementar

| Evento aceito | `BUSY` | `DONE` | `ERROR` | `RESULT` |
|---|---:|---:|---:|---|
| `CTRL.START` com periférico livre | 1 | 0 | 0 | Preserva |
| Carregamento/processamento | 1 | 0 | 0 | Preserva |
| `core_done=1`, `core_err=0`, no `WAIT` | 0 | 1 | 0 | Captura `core_dout` |
| `core_done=1`, `core_err=1`, no `WAIT` | 0 | 0 | 1 | Preserva |
| W1C de `STATUS.DONE` | Preserva | 0 | Preserva | Preserva |
| W1C de `STATUS.ERROR` | Preserva | Preserva | 0 | Preserva |
| `CTRL.SRST` | 0 | 0 | 0 | Preserva |
| `PRESETn` | 0 | 0 | 0 | Zera |

`STATUS.DONE` e `STATUS.ERROR` são **sticky**: não são espelhos combinacionais de `core_done` e `core_err`. O disparo de `irq` depende desses bits armazenados e do `IER`, não dos sinais brutos do IP. **[ESP/PROPOSTA]**

**[PENDENTE]** Definir prioridades nas coincidências de W1C, conclusão e `SRST`, preservando a prioridade explícita de `SRST` sobre `START`. Definir precisamente a borda a partir da qual `BUSY` deixa de ser 1, coerente com a etapa de registro do evento.

## 6. Contrato de reset e aborto

### 6.1 Reset externo `PRESETn`

- **[ESP]** `PRESETn=0` reinicializa todos os registradores do wrapper e seu sequenciador, e reinicializa o core.
- **[ESP]** A desassertação de `PRESETn` deve passar por sincronizador de **dois flip-flops** para alimentar o reset síncrono do core; a assertiva é tratada como assíncrona no circuito de sincronização proposto.
- **[RTL/VCD]** O reset `core_rst` do IP é ativo em alto e é observado em bordas positivas. O retorno da FSM para `INIT` não é sinônimo de execução instantânea das atribuições que pertencem ao estado `INIT`.

### 6.2 Software reset `CTRL.SRST`

**[ESP]** Um comando `SRST` deve:

1. Gerar `core_rst=1` por **exatamente um ciclo de PCLK**;
2. Abortar a operação corrente;
3. Retornar a FSM do wrapper para `IDLE`;
4. Limpar `STATUS.BUSY`, `DONE` e `ERROR`;
5. **Preservar** `MSG`, `EXP`, `MOD`, `IER` e `RESULT`.

`SRST` e `PRESETn` não são equivalentes: apenas `PRESETn` reinicializa o banco de registradores completo. **[ESP]**

### 6.3 VCD de reset arbitrário de dois ciclos — cenário anterior

No waveform original, `core_rst` foi mantido ativo de **14140 ns a 14180 ns**, durante o processamento modular:

| Tempo | Ocorrência observada |
|---:|---|
| 14130 ns | `rsa_core_ctrl` em `ANALYZE`, `rsa_core_mod` em `COMPARE` |
| 14140 ns | Assertiva de `core_rst` |
| 14150 ns | FSMs afetadas retornam a `INIT` |
| 14170 ns | Ações associadas a `INIT` executadas |
| 14180 ns | Desassertiva de `core_rst` |
| 14190 ns | Controlador avança para `LOAD_M` |

Não houve conclusão da operação abortada. `core_dout` preservou um resultado anterior no trecho examinado; seu valor não deve ser interpretado como conclusão nova. O timeout produzido pela testbench original decorreu de continuar esperando uma operação intencionalmente interrompida. **[VCD]**

### 6.4 VCD final de reset de apenas um ciclo — validação conclusiva do IP

No `waveform_32bit_rst_1cycle.vcd`, o reset de uma operação A em processamento foi seguido por outra operação B válida:

| Tempo | Ocorrência observada |
|---:|---|
| **480 ns** | `core_rst` sobe |
| **490 ns** | `rsa_core_ctrl` retorna a `INIT` |
| **500 ns** | `core_rst` desce: pulso de **20 ns = 1 CLK_PERIOD** |
| **510 ns** | Controlador alcança `LOAD_M` |
| 630 ns | `WAIT_M` após receber M da operação B |
| 690 ns | `WAIT_E` após receber e |
| 750 ns | `WAIT_N` após receber n |
| 770 ns | `CASE2` |
| 790 ns | `ANALYZE` |
| **18550 ns** | `core_done=1`; `core_dout=0000_0006` |
| **18570 ns** | `core_done=0` |

Operação B:

```text
M = 2, e = 5, n = 13
2^5 mod 13 = 6
```

A validação funcional que acompanhou esse waveform registrou **56 operações verificadas, 56 aprovadas e 0 falhas** (55 casos originais e 1 caso de recuperação). **[VCD]**

**Conclusão restrita ao IP:** um pulso síncrono de **um ciclo contendo uma borda ativa** pode abortar o processamento atual, devolver o controlador ao ponto de carga e permitir um cálculo correto posterior. O resultado não comprova por si só a implementação do comando APB `CTRL.SRST`, da sincronização de `PRESETn` ou das prioridades de registradores; esses mecanismos pertencem ao futuro wrapper. **[VCD/PENDENTE]**

## 7. Latência e implicações de temporização

**[ESP]** `PREADY=1`; cada transferência APB percorre setup e access, sem ciclos de espera extras. O documento apresenta uma latência de operação de `4 + T_core` para `LOAD_GAP=0`, pressupondo carregamentos consecutivos. `T_core` é a latência interna medida a partir do terceiro carregamento até a conclusão.

**[RTL/VCD]** São necessários ciclos de liberação do `core_load` entre operandos. Logo, **não é válido assumir a mesma fórmula temporal sem redefinir a contagem exata dos ciclos**. A duração do estado `WAIT`, a borda de amostragem de `core_done` pelo wrapper e o primeiro instante válido de `BUSY=0` também contribuem para a latência observável por software.

**[PENDENTE]** Quando a FSM do wrapper for definida no nível de borda a borda, derivar a fórmula fechada de latência para `LOAD_GAP=0` e para valores não nulos. Não substituir automaticamente `4 + T_core` por um número sem estabelecer a origem da contagem e a borda de aceitação de `START`.

## 8. Matriz final de conformidade / riscos

| Aspecto | Situação para integração | Evidência e ação |
|---|---|---|
| Core síncrono com `PCLK` | Compatível | `core_clk=PCLK` **[ESP/RTL]** |
| Reset síncrono ativo em alto | Validado no IP | Transições para `INIT` **[RTL/VCD]** |
| Reset de um ciclo | **Validado no IP** | 480–500 ns e recuperação bem-sucedida **[VCD]** |
| Ordem M/e/n | Validada | Sequência `LOAD_*`/`WAIT_*` **[RTL/VCD]** |
| Loads *back-to-back*, `LOAD_GAP=0` literal | **Incompatível** | Release obrigatório **[ESP vs. RTL/VCD]** |
| `core_error` como pulso exclusivo | **Incompatível** | `core_err` persistente e simultâneo a `core_done` no erro **[ESP vs. RTL/VCD]** |
| Resultado válido com `core_done` | Validado no IP | Atualização simultânea de `core_dout` **[RTL/VCD]** |
| Captura síncrona pelo wrapper | Fundamentada | Usar borda seguinte à atualização do core **[RTL/PROPOSTA]** |
| `RESULT` retido em erro/SRST | Requisito a implementar | Registrar resultado no wrapper, só no sucesso **[ESP/PROPOSTA]** |
| Sticky `DONE`/`ERROR`, W1C e `irq` | Requisito a implementar | Banco de registradores do wrapper **[ESP]** |
| Sincronizador de `PRESETn` | Requisito a implementar | Dois FFs; validar liberação **[ESP]** |
| `PSLVERR`, acesso APB e condições de BUSY | Requisito a implementar | Testbench APB específica **[ESP]** |
| Latência `4 + T_core` | **Reavaliar** | Contradita pelo intervalo obrigatório de loads **[ESP vs. RTL]** |

## 9. Contrato mínimo recomendado para a etapa de arquitetura

As seguintes regras formam a base técnica para a discussão, **sem antecipar uma implementação fechada**:

1. Preservar o comportamento funcional do IP `rsa_core` como referência.
2. Gerar M/e/n na ordem fixa, com `core_load` alto somente nas bordas de captura e pelo menos uma borda baixa antes do próximo operando, inclusive depois de MOD.
3. Examinar uma FSM de alimentação `IDLE–LOAD–GAP–WAIT`, indexada por `load_idx`, com `LOAD_GAP` explicitamente distinguido do release obrigatório.
4. Reconhecer conclusão **somente no contexto da operação ativa**, mediante `core_done`; ler `core_err` nessa mesma transação temporal para distinguir sucesso de erro.
5. Registrar no wrapper o resultado de sucesso e os bits de status sticky; não expor `core_err` diretamente como `STATUS.ERROR` nem atualizar `RESULT` após erro.
6. Gerar `core_rst` síncrono de um ciclo no caminho de `SRST`; separar corretamente `SRST` de `PRESETn` e proteger o sequenciador contra novos comandos durante a recuperação.
7. Usar as regras APB, prioridades, temporização e política de erro do enunciado como requisitos de aceitação do wrapper; documentar explicitamente qualquer adaptação exigida pelo IP.

## 10. Questões reservadas à discussão arquitetural

- Como tratar formalmente a incompatibilidade de `LOAD_GAP` com o texto do enunciado (reinterpretação documentada, aprovação ou revisão)?
- FSM única de quatro estados ou divisão entre interface APB e sequenciamento operacional?
- `BUSY` derivado do estado ou registrado independentemente? Quando ele sobe e desce em relação à fase APB e ao `core_done` amostrado?
- Como temporizar a saída do `SRST` e a aceitação de um novo `START`, considerando as ações de `INIT` do core?
- Quais prioridades simultâneas aplicar entre `SRST`, `START`, conclusão e escritas W1C?
- Como definir a resposta para acessos reservados e para escritas em bits reservados sem extrapolar as regras expressas?
- Qual é a latência definitiva em ciclos, medida desde a aceitação de `START` até a atualização observável de `STATUS`?

## 11. Fontes e material de verificação

**Especificação:** `apb_integration.pdf`, seções 3–7 (portos, funcionalidade, mapa, condições de erro e timing).  
**RTL:** `rsa_core.sv` (módulos `rsa_core`, `rsa_core_ctrl`, `rsa_core_mult`, `rsa_core_mod`).  
**Testbench de recuperação:** `rsa_core_tb_rst_1cycle_recovery.sv`.  
**Waveforms:** `waveform_32bit.vcd` e `waveform_32bit_rst_1cycle.vcd`.

**Análises intermediárias:** `rsa_apb_analise_reset.md`, `rsa_core_resumo_analise_temporal.md`, `rsa_apb_sequenciador_load_gap.md` e `rsa_apb_vcd_item3_finalizacao.md`.

---

**Estado do documento:** contrato temporal do **IP concluído para fins de discussão arquitetural**. Conformidade do **wrapper APB ainda não verificada**; exigirá RTL próprio, testbench APB e waveform da integração.
