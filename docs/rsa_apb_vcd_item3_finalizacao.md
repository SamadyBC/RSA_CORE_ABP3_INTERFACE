# RSA_APB — Análise do VCD, item 3: finalização normal e com erro

## Objetivo

Caracterizar o contrato temporal de saída do `rsa_core` de 32 bits para orientar a captura de `RESULT` e a atualização de `STATUS` no futuro wrapper `RSA_APB`. A análise corresponde aos casos normal e de módulo zero discutidos anteriormente.

## 1. Sinais de interesse e funcionamento no RTL

O controlador `rsa_core_ctrl` disponibiliza as saídas registradas `core_done`, `core_err` e `core_dout` (por meio de `done_ff`, `err_ff` e `c_reg`). No estado `DONE`, registra o resultado em `c_reg`, ativa `done_ff` e limpa `err_ff`. No estado `ERROR`, ativa tanto `done_ff` quanto `err_ff` e coloca todos os bits de `c_reg` em 1.

| Situação | `core_done` | `core_err` | `core_dout` |
|---|---:|---:|---|
| Conclusão normal | 1 | 0 | Resultado modular |
| Conclusão com `n = 0` | 1 | 1 | `32'hFFFF_FFFF` |

**Interpretação:** para este RTL, `core_done` indica o evento de conclusão; `core_err` qualifica esse evento como sucesso ou erro. Isso difere da interpretação de `core_err` como pulso de conclusão independente descrita na especificação do wrapper.

## 2. Conclusão com erro — teste 1

Entradas: `M = 0`, `e = 0`, `n = 0`.

| Tempo (ns) | Evento | `core_done` | `core_err` | `core_dout` |
|---:|---|---:|---:|---|
| 280 | MOD apresentado (`core_load = 1`) | 0 | 0 | Ainda não válido |
| 290 | MOD capturado | 0 | 0 | Ainda não válido |
| 300 | `core_load = 0` | 0 | 0 | Ainda não válido |
| 330 | Erro registrado | 1 | 1 | `FFFF_FFFF` |
| 350 | `core_done` retorna a zero | 0 | 1 | `FFFF_FFFF` |

O pulso de `core_done` ocupa **20 ns**, equivalentes a **um período de `core_clk`**. O sinal `core_err` permanece ativo após o encerramento do pulso; portanto, não é um pulso de um ciclo nesse caminho de erro.

## 3. Conclusão normal — teste 2

Entradas: `M = 0`, `e = 0`, `n = 1`; resultado esperado `0`.

| Tempo (ns) | Evento | `core_done` | `core_err` |
|---:|---|---:|---:|
| 680 | MOD apresentado | 0 | 1 |
| 690 | MOD capturado | 0 | 1 |
| 5310 | `mod_done = 1` | 0 | 1 |
| 5330 | Controlador entra em `DONE` | 0 | 1 |
| 5350 | Resultado registrado e conclusão sinalizada | 1 | 0 |
| 5370 | `core_done` retorna a zero | 0 | 0 |

**Observação:** o `core_err` remanescente da operação anterior ainda está em 1 durante a nova operação. Só é limpo no término normal, junto à atualização de `core_dout` e ativação de `core_done`.

## 4. Persistência de `core_err` e risco de conclusão falsa

Uma lógica de conclusão do tipo:

```systemverilog
if (core_done || core_err) begin
    // finalizar operação
end
```

não é adequada para a implementação observada. Após um teste com erro, `core_err` pode permanecer em 1 e provocar o encerramento prematuro da operação seguinte.

A interpretação proposta para a interface é:

```systemverilog
if (core_done) begin
    if (core_err) begin
        // conclusão com erro
    end
    else begin
        // conclusão normal
    end
end
```

Essa lógica deve operar apenas quando o sequenciador estiver efetivamente aguardando o término do cálculo, e não indiscriminadamente em todos os estados.

## 5. Instante de captura pelo wrapper

O core atualiza `core_done`, `core_err` e `core_dout` em registradores acionados por `posedge core_clk`. No sistema integrado, `core_clk = PCLK`.

Como os registradores usam atribuições não bloqueantes, o `RSA_APB` que também amostra em `posedge PCLK` enxerga os valores anteriores ao evento que acabou de atualizar o core. Assim, no caso normal analisado:

| Borda (ns) | `core_done` percebido pelo wrapper | Interpretação |
|---:|---:|---|
| 5350 | 0 | Core está gerando o pulso após essa borda |
| 5370 | 1 | Wrapper pode capturar `core_dout` e `core_err` |
| 5390 | 0 | Evento já foi capturado |

Portanto, uma lógica sequencial em `PCLK` consegue reconhecer um pulso de `core_done` de um ciclo sem necessitar, por princípio, de detector de borda adicional.

## 6. Requisitos para os registradores do RSA_APB

A especificação do wrapper determina indicadores de status **sticky** e retenção do resultado anterior quando ocorre erro. A interpretação proposta é:

| Evento | `STATUS.BUSY` | `STATUS.DONE` | `STATUS.ERROR` | `RESULT` |
|---|---:|---:|---:|---|
| `START` aceito | 1 | 0 | 0 | Mantém |
| Cálculo em andamento | 1 | 0 | 0 | Mantém |
| `core_done = 1` e `core_err = 0` | 0 | 1 | 0 | Captura `core_dout` |
| `core_done = 1` e `core_err = 1` | 0 | 0 | 1 | Mantém |
| W1C em `DONE` | Mantém | 0 | Mantém | Mantém |
| W1C em `ERROR` | Mantém | Mantém | 0 | Mantém |
| `CTRL.SRST` | 0 | 0 | 0 | Mantém |

Os registradores `STATUS.DONE` e `STATUS.ERROR` **não** devem ser simples conexões combinacionais aos sinais `core_done` e `core_err`. Devem registrar o resultado da operação e manter seus valores até W1C, novo START ou reset aplicável.

## 7. Consequência para a FSM do sequenciador

O modelo de quatro estados permanece aplicável:

```text
IDLE --START--> LOAD --> GAP --(próximo operando)--> LOAD
                          |
                          +--(último operando)--> WAIT
                                                    |
                                             core_done = 1
                                                    |
                                                   IDLE
```

No estado `WAIT`, a conclusão deve ser discriminada assim:

```text
core_done = 1
     |
     +-- core_err = 0 --> RESULT := core_dout; DONE := 1
     |
     +-- core_err = 1 --> RESULT mantém; ERROR := 1

Em ambos os casos: BUSY := 0; retorna a IDLE.
```

É necessário garantir que um `core_err` antigo não provoque uma conclusão falsa.

## 8. Conclusões estabelecidas

- `core_done` indica conclusão tanto em sucesso quanto em erro.
- O pulso de `core_done` dura um ciclo de clock nos casos analisados.
- `core_dout` é atualizado junto à ativação de `core_done`.
- Em módulo zero, `core_done = 1`, `core_err = 1` e `core_dout = FFFF_FFFF`.
- `core_err` pode permanecer em 1 após o pulso de `core_done` e durante a operação seguinte.
- Uma conclusão normal limpa `core_err`.
- O wrapper pode registrar as saídas válidas no `posedge PCLK` seguinte ao que gerou `core_done`.
- O wrapper deve capturar `core_err` **sob a condição `core_done`**, e atualizar `STATUS` de modo sticky.
- Em erro, `RESULT` mantém o valor da última operação bem-sucedida.

## 9. Pontos ainda em aberto

- Definir prioridade entre escrita W1C e conclusão do core quando ocorrerem simultaneamente.
- Definir prioridade entre `SRST` e conclusão nas bordas próximas ao reset.
- Verificar reset durante operação, incluindo eventual ausência de `core_done` na operação abortada.
- Confirmar o retorno seguro a `IDLE`, a limpeza de `STATUS` e o início de uma nova operação após um aborto.
- Documentar a divergência: a especificação menciona `core_error` como pulso, mas o `core_err` real pode permanecer em nível alto.

## 10. Próxima etapa — item 4 do VCD

Analisar o **reset arbitrário durante uma operação**. O objetivo será acompanhar `core_rst`, os estados do controlador, `core_done`, `core_err` e `core_dout` antes, durante e após o pulso, e avaliar as consequências para o mecanismo `CTRL.SRST` do futuro wrapper.

---

**Referências de trabalho:** `rsa_core.sv`, `rsa_core_tb.sv`, `waveform_32bit.vcd` e especificação `apb_integration.pdf`. Os tempos registrados neste documento correspondem à análise temporal discutida anteriormente e devem ser preservados com a respectiva versão do VCD.
