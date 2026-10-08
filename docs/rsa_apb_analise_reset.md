# Análise do Reset no `RSA_APB` e no `rsa_core`

Este documento consolida a análise do mecanismo de reset previsto para o `RSA_APB`, correlacionando a especificação do wrapper com o comportamento temporal já observado no `rsa_core`.

O objetivo é estabelecer uma interpretação clara dos diferentes tipos de reset antes da definição final da arquitetura RTL.

---

## 1. Requisito de reset da especificação

A especificação define dois mecanismos distintos:

1. `PRESETn`, reset externo da interface APB;
2. `CTRL.SRST`, reset por software.

O comportamento requerido é:

```text
PRESETn = 0
    ↓
reseta todos os registradores do RSA_APB
    ↓
sequenciador retorna para IDLE
    ↓
core_rst é assertado
```

Já o software reset deve:

```text
CTRL.SRST = 1
    ↓
core_rst é assertado por 1 ciclo
    ↓
sequenciador retorna para IDLE
    ↓
operação em andamento é abortada
    ↓
STATUS é limpo
```

Entretanto, `SRST` não deve alterar:

```text
MSG
EXP
MOD
RESULT
IER
```

---

## 2. Reset externo e reset interno não são equivalentes

O `PRESETn` atua sobre o periférico completo.

Assim, ele deve resetar:

```text
CTRL / comandos internos
STATUS
IER
MSG
EXP
MOD
RESULT
sequenciador
rsa_core
```

Já `SRST` atua apenas sobre a lógica de operação.

Ele deve afetar:

```text
sequenciador
STATUS
rsa_core
```

mas preservar:

```text
MSG
EXP
MOD
RESULT
IER
```

Portanto, não é adequado implementar um único reset global do tipo:

```text
internal_reset = !PRESETn || SRST
```

e aplicar esse sinal indiscriminadamente a todos os registradores internos.

---

## 3. Necessidade de sincronização de `PRESETn`

A especificação informa que `core_rst` é síncrono e que a desassertação de `PRESETn` deve passar por um sincronizador de dois flip-flops antes de alcançar o `rsa_core`.

Logo, não é adequado utilizar diretamente:

```systemverilog
assign core_rst = ~PRESETn;
```

porque isso permitiria que a desassertação de `core_rst` ocorresse em qualquer instante relativo ao `PCLK`.

O comportamento desejado é:

```text
assertion  → imediata
deassertion → sincronizada com PCLK
```

Esse padrão é conhecido como:

```text
asynchronous assertion
synchronous deassertion
```

---

## 4. Estrutura conceitual do sincronizador

A estrutura esperada é aproximadamente:

```text
                   PCLK
                    │
PRESETn ──────► FF1 ───► FF2
   │                    │
   │                    ▼
   │              reset sincronizado
   │                    │
   └────────────────────┤
                        ▼
                     core_rst
```

Uma implementação conceitual seria:

```systemverilog
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
```

Essa estrutura representa apenas o caminho associado a `PRESETn`. O `SRST` ainda deverá ser combinado posteriormente com esse reset sincronizado.

---

## 5. Comportamento temporal da desassertação

Quando `PRESETn` retorna para `1`, a liberação de reset não ocorre imediatamente.

A sequência é:

```text
PRESETn sobe
    ↓
1ª borda de PCLK
FF1 = 1
FF2 = 0
core_rst continua ativo
    ↓
2ª borda de PCLK
FF1 = 1
FF2 = 1
core_rst é liberado
```

Visualmente:

```text
PCLK
        ↑         ↑
        │         │

PRESETn
___________|‾‾‾‾‾‾‾‾‾
           ↑
        liberação

FF1        0 ─────► 1

FF2        0 ─────────► 1

core_rst
‾‾‾‾‾‾‾‾‾‾‾‾‾‾|______
                ↑
         liberação síncrona
```

Isso garante que o `rsa_core` deixe o estado de reset de forma alinhada ao clock.

---

## 6. Relação com o comportamento observado no VCD

Na testbench do `rsa_core`, `core_rst` é aplicado diretamente ao core.

Foi observado que:

```text
core_rst = 1
    ↓
próximo posedge de core_clk
    ↓
state_reg → INIT
```

Isso confirma que o reset do `rsa_core` é efetivamente síncrono.

No sistema integrado, o comportamento interno do core permanece o mesmo.

A diferença é que `core_rst` será produzido pelo wrapper:

```text
PRESETn
   ↓
sincronizador de reset
   ↓
core_rst
   ↓
rsa_core
```

Assim, o sincronizador não altera o comportamento do core; ele apenas controla de forma segura o momento da liberação do reset.

---

## 7. Inclusão de `CTRL.SRST`

Além do reset originado por `PRESETn`, o `core_rst` deve poder ser gerado por uma escrita em `CTRL.SRST`.

A estrutura conceitual passa a ser:

```text
                    PRESETn
                       │
                       ▼
             2-FF reset synchronizer
                       │
                       │
                       ├────────────┐
                       │            │
                       ▼            ▼
                reset externo    SRST pulse
                       │            │
                       └─────┬──────┘
                             ▼
                          core_rst
                             │
                             ▼
                         rsa_core
```

Conceitualmente:

```systemverilog
core_rst = reset_from_presetn | srst_pulse;
```

---

## 8. Comportamento esperado de `SRST`

Quando software escreve:

```text
CTRL.SRST = 1
```

o wrapper deve:

```text
core_rst = 1 por um ciclo de PCLK
sequencer → IDLE
STATUS → 0
```

e preservar:

```text
MSG
EXP
MOD
RESULT
IER
```

A operação em andamento deve ser abortada.

---

## 9. Um ciclo de `core_rst` é suficiente?

Inicialmente havia uma dúvida porque a testbench mantém `core_rst` ativo por dois ciclos.

Porém, analisando o RTL do `rsa_core`, um pulso de um ciclo é suficiente para forçar:

```text
state_reg → INIT
```

na primeira borda ativa.

Na borda seguinte, mesmo com `core_rst` já desassertado, o controlador estará em `INIT` e executará as ações sequenciais desse estado:

```systemverilog
err_ff   <= 1'b0;
start_ff <= 1'b0;
done_ff  <= 1'b0;
```

Portanto, o comportamento esperado é:

```text
core_rst
       _______
______|       |________
       1 ciclo

        ↑             ↑
        │             │
        │             └── executa ações de INIT
        │
        └── state_reg → INIT
```

Assim, o requisito de `SRST` com duração de um ciclo é compatível, em princípio, com a implementação atual do `rsa_core`.

Esse ponto ainda pode ser validado com uma simulação específica.

---

## 10. Diferença funcional entre `PRESETn` e `SRST`

### `PRESETn`

```text
PRESETn = 0
     ↓
wrapper completamente resetado
     ↓
core_rst = 1
     ↓
PRESETn = 1
     ↓
sincronizador FF1
     ↓
sincronizador FF2
     ↓
core_rst = 0
```

### `SRST`

```text
APB write CTRL.SRST = 1
          ↓
STATUS = 0
sequencer → IDLE
          ↓
core_rst = 1
          │
          │ 1 PCLK
          ▼
core_rst = 0
```

Enquanto:

```text
MSG / EXP / MOD / RESULT / IER
```

permanecem inalterados.

---

## 11. Implicação para a arquitetura do `RSA_APB`

A análise indica que a arquitetura deve conter uma responsabilidade lógica específica para reset.

Mesmo que ela seja implementada dentro de um único arquivo `rsa_apb.sv`, é útil tratá-la conceitualmente como um bloco separado:

```text
                        RSA_APB
                           │
        ┌──────────────────┼───────────────────┐
        │                  │                   │
        ▼                  ▼                   ▼
   APB/registers      RSA sequencer        Reset Control
                                                │
                             ┌──────────────────┤
                             │                  │
                         PRESETn              SRST
                             │                  │
                      2-FF synchronizer      pulse
                             │                  │
                             └────────┬─────────┘
                                      ▼
                                   core_rst
                                      │
                                      ▼
                                  rsa_core
```

Essa separação ajuda a evitar mistura entre:

```text
reset global do periférico
```

e:

```text
reset funcional do core
```

---

## 12. Conclusões obtidas

A análise permite considerar os seguintes pontos como estabelecidos:

```text
✓ PRESETn é ativo em nível baixo
✓ PRESETn reseta todos os registradores do wrapper
✓ PRESETn deve manter core_rst ativo
✓ a desassertação de PRESETn deve ser sincronizada
✓ o sincronizador requerido possui dois flip-flops
✓ core_rst é síncrono para o rsa_core
✓ SRST não é equivalente a PRESETn
✓ SRST deve durar um ciclo
✓ SRST deve abortar a operação atual
✓ SRST deve limpar STATUS
✓ SRST deve retornar o sequenciador para IDLE
✓ SRST deve preservar MSG, EXP, MOD, RESULT e IER
✓ core_rst terá duas origens: reset externo e software reset
✓ um ciclo de SRST é, em princípio, compatível com o RTL atual do rsa_core
```

---

## 13. Pontos ainda em aberto

Apesar da interpretação já estar bem definida, alguns detalhes ainda deverão ser confirmados durante a implementação e verificação:

```text
- relação exata entre o sincronizador de reset e o estado IDLE do wrapper;
- em qual ciclo o wrapper poderá aceitar START após a liberação de PRESETn;
- comportamento preciso do sequenciador APB enquanto o reset sincronizado ainda está ativo;
- validação experimental de SRST de apenas um ciclo;
- comportamento de um SRST aplicado durante uma operação RSA em andamento.
```

Esses pontos devem ser incorporados aos testes do `RSA_APB`.

---

## 14. Próxima etapa

Com o mecanismo de reset conceitualmente definido, a próxima análise do VCD deve avançar para:

```text
Item 2 — carregamento dos operandos M → e → n
```

O objetivo será reconstruir ciclo a ciclo:

```text
LOAD_M
WAIT_M
LOAD_E
WAIT_E
LOAD_N
WAIT_N
```

e relacionar esses estados com:

```text
core_load
core_din
core_clk
```

para fechar o protocolo temporal que o sequenciador do `RSA_APB` deverá gerar.
