# RSA_APB — Análise do sequenciador de carregamento e da incompatibilidade de `LOAD_GAP`

## 1. Objetivo

Documentar a análise da interface de carregamento do `rsa_core` de 32 bits e a proposta de um sequenciador para o wrapper `RSA_APB`, preservando o núcleo existente. **Esta é uma proposta de arquitetura**, ainda sujeita à verificação funcional e temporal.

## 2. Requisito da especificação

A seção **4.3 — Load control logic** determina que uma escrita em `CTRL.START`, com o periférico ocioso, inicia o envio sequencial dos operandos para `rsa_core`:

1. `MSG` em `core_din`, com `core_load = 1` durante um ciclo;
2. `EXP` em `core_din`, com `core_load = 1` durante um ciclo;
3. `MOD` em `core_din`, com `core_load = 1` durante um ciclo;
4. espera por `core_done` ou `core_error`.

A seção prevê `LOAD_GAP` ciclos ociosos **entre os carregamentos**, com valor padrão zero, afirmando que o core aceita carregamentos consecutivos (*back-to-back*). `STATUS.BUSY` permanece ativo durante a operação.

Interpretada literalmente, a configuração `LOAD_GAP = 0` produziria três ciclos sucessivos com `core_load = 1`, alternando `core_din` entre `MSG`, `EXP` e `MOD`.

## 3. Comportamento observado no RTL e na testbench

No controlador existente (`rsa_core_ctrl`), os estados de recepção são:

```text
INIT → LOAD_M → WAIT_M → LOAD_E → WAIT_E → LOAD_N → WAIT_N
```

Depois de cada estado `LOAD_*`, o controlador entra em `WAIT_*`. Em `WAIT_M` e `WAIT_E`, a próxima transição só acontece se `core_load` retornar a zero. Em `WAIT_N`, a desassertação de `core_load` também é necessária para prosseguir à classificação dos operandos e ao processamento.

Consequentemente, **não é compatível com o RTL atual** a sequência de três capturas em bordas consecutivas com `core_load = 1` continuamente:

```text
ciclo          N       N+1      N+2
core_load      1        1        1
core_din      MSG      EXP      MOD
```

Após a primeira captura, o controlador permanece em `WAIT_M` enquanto `core_load = 1`, impedindo a captura de `EXP` e `MOD` nos estados pretendidos.

A testbench existente utiliza pulsos separados de `core_load`, introduzindo **três ciclos de clock entre as bordas de captura**. Isso confirma que o fluxo de testes usa um protocolo com desassertação, embora não demonstre o espaçamento mínimo possível.

Pela lógica de transição do RTL, o protocolo mínimo previsto é:

```text
borda de clock     N      N+1     N+2     N+3     N+4     N+5
core_load          1       0       1       0       1       0
core_din          MSG      —      EXP      —      MOD      —
                   │               │               │
                 captura M       captura e       captura n
```

As capturas ficam separadas por dois períodos de clock, havendo uma borda obrigatória com `core_load = 0` entre elas. A última desassertação é necessária para que o core avance a partir de `WAIT_N`.

## 4. Incompatibilidade identificada

**Interface mismatch:** a especificação do wrapper pressupõe aceitação de cargas *back-to-back*, enquanto o `rsa_core_ctrl` existente requer a desassertação de `core_load` entre os operandos.

Não é apenas uma diferença de implementação: a incompatibilidade interfere na definição de `LOAD_GAP` e na latência total informada na especificação (que declara `4 + T_core` na configuração padrão). Essa latência deverá ser reavaliada após integrar o sequenciador.

## 5. Solução proposta: sequenciador com quatro estados

A FSM proposta utiliza quatro estados e dois contadores/índices lógicos:

- `IDLE`: espera um comando `START` válido;
- `LOAD`: apresenta o operando selecionado e ativa `core_load`;
- `GAP`: mantém `core_load = 0` pelo intervalo requerido;
- `WAIT`: aguarda a conclusão do processamento RSA.

`load_idx` seleciona o operando:

| `load_idx` | Dado em `core_din` |
|---:|---|
| 0 | `MSG` |
| 1 | `EXP` |
| 2 | `MOD` |

`gap_cnt` controla a quantidade de ciclos adicionais no estado `GAP`.

```text
                 START aceito
                      │
                      ▼
                   +------+
        +----------| LOAD |<--------------+
        |          +------+               |
        |             │                   |
        |             ▼                   |
        |          +-----+                |
        |          | GAP |----------------+
        |          +-----+  mais operandos
        |             │
        |        último operando
        |             ▼
        |          +------+
        |          | WAIT |────── conclusão ───► IDLE
        |          +------+
        |
        +--- `load_idx` define MSG, EXP ou MOD
```

O ciclo do estado `LOAD` tem `core_load = 1`; `GAP` e `WAIT` mantêm `core_load = 0`. O diagrama deve ser entendido conceitualmente: uma única instância de `GAP` atende todos os operandos.

### Regras de transição propostas

| Estado | Ação / transição |
|---|---|
| `IDLE` | `core_load = 0`; em `START` aceito, inicializar `load_idx = 0` e seguir a `LOAD` |
| `LOAD` | `core_load = 1`; `core_din = operando[load_idx]`; após o ciclo, ir para `GAP` |
| `GAP` | `core_load = 0`; cumprir desassertação obrigatória e ciclos extras; se `load_idx < 2`, incrementar e ir para `LOAD`; caso contrário, ir para `WAIT` |
| `WAIT` | `core_load = 0`; aguardar evento de término, registrar resultado/erro e retornar a `IDLE` |

O estado `GAP` **deve ser visitado também depois de `MOD`**. A seta direta `LOAD → WAIT` do diagrama original pode, em princípio, produzir a desassertação necessária se `WAIT` já for ativo no ciclo seguinte; porém a proposta consolidada utiliza `GAP` explicitamente após os três loads, por simetria e maior facilidade de verificação.

## 6. Semântica proposta para `LOAD_GAP`

Para preservar a compatibilidade com o core, distinguem-se:

1. **Um ciclo obrigatório de release:** imposto pelo protocolo de `rsa_core_ctrl`, com `core_load = 0`;
2. **`LOAD_GAP` ciclos opcionais adicionais:** intervalo configurável de espera.

Assim, a permanência em `GAP` é definida por:

\[
T_{GAP}=1+LOAD\_GAP \quad\text{ciclos de PCLK.}
\]

Com `LOAD_GAP = 0`:

```text
LOAD MSG → RELEASE → LOAD EXP → RELEASE → LOAD MOD → RELEASE → WAIT
```

Com `LOAD_GAP = 1`:

```text
LOAD MSG → RELEASE → GAP extra → LOAD EXP → RELEASE → GAP extra
         → LOAD MOD → RELEASE → GAP extra → WAIT
```

**Atenção:** essa é uma **decisão proposta de integração**, não a interpretação literal da seção 4.3. O parâmetro passa a representar ciclos extras além do ciclo obrigatório. Tal divergência precisa constar na documentação e, idealmente, ser esclarecida com a especificação/autoria do projeto.

### Cuidado de implementação

Evitar comparações como `gap_cnt == LOAD_GAP - 1` sem tratamento especial para `LOAD_GAP = 0`: elas podem introduzir valores negativos, diferenças de largura ou de signedness. É preferível projetar o contador diretamente para o intervalo real, assegurando que o estado `GAP` nunca seja omitido.

## 7. Características da FSM

As saídas de controle podem ser implementadas no estilo **Moore**:

```text
IDLE : core_load = 0
LOAD : core_load = 1
GAP  : core_load = 0
WAIT : core_load = 0
```

A seleção de `core_din` depende de `load_idx` durante `LOAD`. Para o sinal `BUSY`, a relação `state != IDLE` é uma possibilidade, mas deve ser conferida frente ao requisito temporal de assertiva na escrita de `START` e desassertiva após a conclusão; pode ser necessário um registrador de status específico.

O reset externo (`PRESETn`) e o software reset (`CTRL.SRST`) devem retornar o sequenciador ao estado `IDLE`, respeitando a lógica de reset discutida separadamente.

## 8. Benefícios e limitações

**Benefícios:**

- preserva o `rsa_core` existente;
- resolve a necessidade de alternância `1 → 0` em `core_load`;
- reutiliza um único estado `LOAD` para os três operandos;
- permite intervalos adicionais configuráveis;
- facilita a análise temporal e a futura verificação UVM.

**Limitações e pontos que exigem confirmação:**

- incompatibilidade semântica com a frase sobre *back-to-back loads*;
- latência total maior que a estimativa nominal da especificação;
- necessidade de verificar o comportamento mínimo `1,0,1,0,1,0` em simulação específica;
- necessidade de definir precisamente a atualização de `BUSY`, `RESULT`, `DONE` e `ERROR` na transição `WAIT → IDLE`;
- necessidade de validar a recuperação do core após reset e antes de emitir `LOAD`.

## 9. Conclusão e decisão provisória

A FSM de quatro estados `IDLE`, `LOAD`, `GAP` e `WAIT`, com `load_idx` e `gap_cnt`, é uma **base tecnicamente adequada** para integrar o `rsa_core` ao APB3, desde que:

1. todo `LOAD` seja seguido por ao menos um ciclo com `core_load = 0`;
2. o último operando `MOD` também seja seguido por desassertação;
3. `LOAD_GAP` seja tratado explicitamente como número de ciclos **adicionais**;
4. o desvio em relação à especificação seja registrado e revisado;
5. o comportamento seja confirmado por simulação antes de fechar a arquitetura.

## 10. Continuidade da análise do VCD

O próximo passo é analisar a **finalização normal e com erro** (`core_done`, `core_err` e `core_dout`), seguida da verificação do **reset arbitrário durante uma operação**, conforme a divisão de análise estabelecida anteriormente. Isso permitirá determinar a lógica de atualização dos registradores `STATUS` e `RESULT` no wrapper.
