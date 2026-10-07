# Resumo da Análise do `rsa_core` — Contrato Temporal e Interface Externa

Este documento resume a análise inicial do módulo `rsa_core` de 32 bits, com foco no comportamento temporal observado pela interface externa. O objetivo é estabelecer o contrato que o futuro `RSA_APB` deverá respeitar antes da definição da arquitetura RTL do wrapper.

---

## 1. Interface externa do `rsa_core`

O módulo utiliza a seguinte interface principal:

```systemverilog
input  logic        core_clk;
input  logic        core_rst;
input  logic        core_load;
input  logic [31:0] core_din;

output logic        core_done;
output logic        core_err;
output logic [31:0] core_dout;
output logic        core_clk_o;
```

O `rsa_core` opera em um único domínio de clock e utiliza `core_clk` como referência para todos os blocos internos.

---

## 2. Estrutura interna

O `rsa_core` é composto por três blocos principais:

```text
                    rsa_core
                        │
           ┌────────────┼────────────┐
           │            │            │
           ▼            ▼            ▼
     rsa_core_ctrl   rsa_core_mult  rsa_core_mod
```

O fluxo de cálculo ocorre da seguinte forma:

```text
rsa_core_ctrl
      │
      │ ctrl_start
      ▼
rsa_core_mult
      │
      │ mult_done + produto
      ▼
rsa_core_mod
      │
      │ mod_done + resultado
      ▼
rsa_core_ctrl
```

O wrapper externo controla diretamente apenas:

```text
core_rst
core_load
core_din
```

A sequência interna de multiplicação e módulo ocorre automaticamente após o carregamento dos operandos.

---

## 3. Sequência de carregamento dos operandos

A FSM do controlador utiliza, inicialmente, os estados:

```text
INIT
  ↓
LOAD_M
  ↓
WAIT_M
  ↓
LOAD_E
  ↓
WAIT_E
  ↓
LOAD_N
  ↓
WAIT_N
```

A ordem de carregamento é:

```text
M → e → n
```

onde:

- `M` é a mensagem;
- `e` é o expoente;
- `n` é o módulo.

---

## 4. Comportamento de `core_load`

O comportamento mais importante identificado no RTL é que `core_load` não pode permanecer ativo continuamente durante os três operandos.

Após cada carregamento, o sinal deve ser desassertado para permitir que a FSM saia do respectivo estado `WAIT_*`.

O protocolo conservador observado no RTL é:

```text
load M
  ↓
core_load = 0
  ↓
load e
  ↓
core_load = 0
  ↓
load n
  ↓
core_load = 0
```

Visualmente:

```text
           M               e               n
           │               │               │
core_load  ┌───┐           ┌───┐           ┌───┐
___________│ 1 │___________│ 1 │___________│ 1 │________
           └───┘           └───┘           └───┘
```

Isso significa que o wrapper APB deverá respeitar esse protocolo, salvo se a análise da testbench e das formas de onda mostrar alguma particularidade adicional.

---

## 5. Captura de `core_din`

Os operandos são armazenados nos estados:

```text
LOAD_M
LOAD_E
LOAD_N
```

e são amostrados em borda de subida de `core_clk`.

O comportamento esperado é:

```text
state = LOAD_M + core_load = 1 + core_din = M
    → captura M

state = LOAD_E + core_load = 1 + core_din = e
    → captura e

state = LOAD_N + core_load = 1 + core_din = n
    → captura n
```

Como os registradores internos são atualizados dentro de `always_ff @(posedge core_clk)`, os valores devem estar estáveis antes da borda ativa.

---

## 6. Início efetivo da operação

Após o terceiro carregamento, o controlador entra em `WAIT_N`.

O processamento não inicia enquanto `core_load` continuar ativo.

A sequência é:

```text
LOAD_N com core_load = 1
        ↓
WAIT_N
        ↓
core_load deve voltar a 0
        ↓
avalia n e e
        ↓
inicia processamento
```

Portanto, a desassertação de `core_load` após o terceiro operando faz parte do protocolo necessário para iniciar o cálculo.

---

## 7. Tratamento de `n = 0`

O módulo zero é detectado diretamente pelo controlador antes da operação matemática:

```text
n == 0
  ↓
ERROR
```

O erro não depende diretamente da saída `mod_err` do bloco `rsa_core_mod`.

Na implementação atual, `mod_err` não está conectado ao top-level.

---

## 8. Comportamento de erro

No estado `ERROR`, o controlador realiza:

```text
core_done = 1
core_err  = 1
core_dout = 32'hFFFF_FFFF
```

Isso é relevante porque a interface externa não utiliza apenas `core_err` para indicar falha: `core_done` também é ativado nesse caso.

Esse comportamento deverá ser considerado explicitamente no `RSA_APB`.

---

## 9. Persistência de `core_err`

Pela leitura do RTL, `core_err` não aparenta ser necessariamente um pulso de apenas um ciclo.

Após o estado `ERROR`, a FSM retorna para `LOAD_M`. Nesse estado, `core_done` é limpo, mas `core_err` não é explicitamente limpo.

Assim, o comportamento esperado pelo código é aproximadamente:

```text
ERROR:
core_done = 1
core_err  = 1

ciclo seguinte:
core_done = 0
core_err  = 1
```

Esse ponto deverá ser confirmado na simulação e nas formas de onda.

---

## 10. Comportamento de `core_done` em operação normal

Na conclusão normal, o estado `DONE` registra o resultado e ativa:

```text
core_done = 1
core_err  = 0
```

No ciclo seguinte a FSM retorna para `LOAD_M`, que limpa `core_done`.

Portanto, para uma operação sem erro, espera-se:

```text
                 _______
core_done ______|       |_______
                   1 clk
```

Assim, `core_done` se comporta como um pulso de aproximadamente um ciclo.

---

## 11. Comportamento de `core_dout`

O resultado é armazenado em um registrador interno.

Em operação normal:

```text
core_dout ← resultado
```

No caso de erro:

```text
core_dout ← 32'hFFFF_FFFF
```

Como a saída é registrada, seu valor permanece disponível após o pulso de `core_done`.

O futuro `RSA_APB`, entretanto, deverá possuir seu próprio registrador `RESULT`, conforme especificado.

---

## 12. Reset

O `core_rst` é tratado de forma síncrona.

Os blocos internos utilizam:

```systemverilog
always_ff @(posedge core_clk)
```

e o reset influencia a lógica de próximo estado.

Portanto, o efeito de `core_rst` ocorre em bordas de subida de `core_clk`.

Esse comportamento é compatível com a exigência do wrapper de gerar um reset síncrono para o `rsa_core`.

---

## 13. Contrato temporal preliminar

A partir exclusivamente do RTL analisado, o comportamento esperado pode ser resumido assim:

| Característica | Comportamento |
|---|---|
| Clock | borda de subida de `core_clk` |
| Reset | síncrono |
| Ordem dos operandos | `M → e → n` |
| Entrada de dados | `core_din[31:0]` |
| Validação dos dados | `core_load` |
| Gap entre operandos | necessário pelo RTL |
| Início do cálculo | após desassertação do terceiro `core_load` |
| Resultado normal | `core_dout` registrado |
| `core_done` normal | aproximadamente 1 ciclo |
| Módulo zero | detectado pelo controlador |
| Erro | `core_done=1` e `core_err=1` |
| Valor em erro | `core_dout = 32'hFFFF_FFFF` |
| `core_err` | pode permanecer ativo após o erro |
| Domínio de clock | único |

---

## 14. Pontos que devem ser validados com a testbench e waveform

A próxima análise deve confirmar experimentalmente:

1. O formato real dos pulsos de `core_load`;
2. A existência de ciclos de gap entre `M`, `e` e `n`;
3. A borda exata em que cada operando é capturado;
4. O momento em que o cálculo começa após o terceiro load;
5. A duração de `core_done`;
6. O instante em que `core_dout` se torna válido;
7. O comportamento real de `core_err`;
8. O comportamento de `core_done` quando `n = 0`;
9. O comportamento do core durante e após `core_rst`;
10. A latência medida entre o carregamento de `n` e a conclusão da operação.

---

## 15. Próxima etapa

A próxima etapa é analisar a testbench utilizada para validar o `rsa_core`.

A testbench deverá ser usada para identificar:

- como os operandos são aplicados;
- como `core_load` é controlado;
- como o reset é aplicado;
- como a testbench aguarda a conclusão;
- quais casos normais e de erro são exercitados;
- quais hipóteses temporais já foram adotadas durante a verificação.

Após isso, os estímulos da testbench deverão ser comparados diretamente com as formas de onda, permitindo fechar o contrato temporal do `rsa_core` antes da implementação da FSM do `RSA_APB`.
