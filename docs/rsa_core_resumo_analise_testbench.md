# Resumo da Análise da Testbench do `rsa_core`

Este documento consolida o que foi identificado a partir da análise da testbench do `rsa_core` de 32 bits e lista os pontos que ainda precisam ser confirmados diretamente nas formas de onda.

O objetivo desta etapa é fechar o contrato temporal entre o futuro `RSA_APB` e o `rsa_core` antes da definição final da arquitetura RTL do wrapper.

---

## 1. Configuração geral da testbench

A testbench opera com:

```systemverilog
parameter int unsigned DATA_WIDTH = 32;
parameter int          CLK_PERIOD = 20;
parameter bit          RESET      = 1'b1;
parameter bit          LOAD       = 1'b1;
```

Portanto:

```text
DATA_WIDTH = 32 bits
Tclk       = 20 ns
fclk       = 50 MHz
```

Embora os primeiros 40 testes sejam derivados da versão original de 4 bits, todos são executados sobre o `rsa_core` configurado com `DATA_WIDTH = 32`.

Os testes adicionais, de 41 a 55, exercitam explicitamente valores maiores, incluindo bits superiores, bit 31 e operações com intermediários de 64 bits.

Total:

```text
55 testes
```

---

## 2. Reset utilizado na testbench

A sequência de reset é:

```text
core_rst = 0 inicialmente

após 5 ciclos:
core_rst = 1

mantém reset por 2 ciclos

depois:
core_rst = 0
```

Como `RESET = 1`, o reset do core é ativo em nível alto.

O RTL utiliza reset síncrono, portanto o efeito real do reset acontece nas bordas de subida de `core_clk` enquanto `core_rst = 1`.

O estímulo principal começa somente após um atraso adicional, permitindo que o core saia do reset e retorne ao estado esperado para receber operandos.

---

## 3. Protocolo utilizado para carregar um valor

A task `load_value()` define o protocolo efetivamente utilizado pela testbench:

```systemverilog
@(negedge core_clk);

core_load = LOAD;
core_din  = value;

@(negedge core_clk);

core_load = ~LOAD;
core_din  = '0;

@(negedge core_clk);
```

Os estímulos são alterados na borda de descida do clock, enquanto o DUT registra dados na borda de subida.

Isso evita condição de corrida entre testbench e DUT.

O comportamento temporal esperado para cada valor é:

```text
negedge              posedge              negedge
   │                     │                    │
   │ core_load = 1       │                    │ core_load = 0
   │ core_din  = value   │ captura do valor   │ core_din  = 0
   ▼                     ▼                    ▼
```

Assim, `core_load` permanece ativo por aproximadamente um período de clock e contém uma única borda positiva destinada à captura.

---

## 4. Ordem dos operandos

A testbench carrega os operandos na seguinte ordem:

```text
1. message
2. encryption_key
3. modulus
```

Ou seja:

```text
1º core_load → M
2º core_load → e
3º core_load → n
```

Essa ordem está confirmada tanto pelo RTL quanto pela testbench.

---

## 5. Existe gap entre os operandos

Cada chamada de `load_value()` possui uma borda negativa adicional antes de retornar.

Como `run_test()` chama:

```systemverilog
load_value(message);
load_value(encryption_key);
load_value(modulus);
```

os pulsos de `core_load` não são consecutivos.

A testbench utiliza um protocolo conservador:

```text
load M
  ↓
período com core_load = 0
  ↓
load e
  ↓
período com core_load = 0
  ↓
load n
  ↓
core_load = 0
```

Isso é compatível com os estados internos:

```text
LOAD_M → WAIT_M → LOAD_E → WAIT_E → LOAD_N → WAIT_N
```

e confirma que o core foi funcionalmente validado usando pulsos separados.

---

## 6. Loads back-to-back ainda não estão comprovados

A especificação do `RSA_APB` afirma que o `rsa_core` aceita carregamentos consecutivos sem necessidade de gap.

Entretanto, a testbench analisada não valida esse comportamento.

Ela sempre fornece ciclos com `core_load = 0` entre os operandos.

Portanto, ainda não podemos considerar comprovado que:

```text
M
e
n
```

possam ser apresentados em três ciclos consecutivos com `core_load` ativo em sequência.

Esse é um dos principais pontos a confirmar nas formas de onda ou através de um teste temporal específico.

---

## 7. Como a conclusão da operação é detectada

Após carregar os três operandos, a testbench espera:

```systemverilog
while ((core_done !== 1'b1) &&
       (timeout_count < 100000)) begin

    @(posedge core_clk);
    timeout_count++;
end
```

Assim:

```text
core_done = sinal de conclusão da operação
```

A testbench não utiliza `core_err` como evento de término.

O fluxo esperado é:

```text
operação
   ↓
wait core_done
   ↓
core_done = 1
   ↓
verificar core_err
```

---

## 8. Relação entre `core_done` e `core_err`

Após `core_done` ser detectado, a testbench verifica simultaneamente:

```text
core_dout
core_err
```

Logo, o contrato assumido pela testbench é:

```text
                 core_done
                     │
                     ▼
              operação terminou
                     │
              ┌──────┴──────┐
              │             │
       core_err = 0   core_err = 1
              │             │
           sucesso         erro
```

Isso sugere que `core_err` deve ser interpretado como um qualificador da conclusão e não necessariamente como um evento de término independente.

---

## 9. Comportamento esperado em erro

Os testes com:

```text
n = 0
```

esperam:

```text
core_done = 1
core_err  = 1
core_dout = 32'hFFFF_FFFF
```

Esse comportamento ocorre tanto nos casos derivados da versão de 4 bits quanto em um teste adicional específico de 32 bits.

Portanto, o comportamento de erro esperado pela testbench está consistente com o RTL analisado.

---

## 10. `core_done` antes do próximo teste

Ao final de cada teste, a testbench espera:

```text
core_done → 0
```

antes de iniciar a operação seguinte.

Além disso, existe um intervalo adicional de:

```text
10 × CLK_PERIOD = 200 ns
```

entre os testes.

Isso torna a testbench bastante conservadora e evita que operações sucessivas ocorram imediatamente após a conclusão anterior.

---

## 11. Possível persistência de `core_err`

Pela análise do RTL, `core_err` pode permanecer em `1` depois de um erro.

A testbench não espera explicitamente:

```text
core_err → 0
```

antes de iniciar o próximo teste.

Ela apenas:

```text
espera core_done = 0
aguarda intervalo
inicia novo teste
```

Isso significa que a testbench não valida explicitamente a duração de `core_err`.

Esse comportamento precisa ser confirmado no waveform.

---

## 12. Cobertura funcional dos testes

A testbench cobre:

```text
✓ operações básicas
✓ expoente zero
✓ expoente um
✓ módulo igual a zero
✓ módulo igual a um
✓ mensagem igual a zero
✓ valores pequenos
✓ valores maiores que 4 bits
✓ operandos com bit 31 ativo
✓ mensagens full-width
✓ multiplicação 32 × 32 com resultado intermediário de 64 bits
✓ múltiplas reduções modulares
✓ timeout para operações que não terminam
```

Isso fornece boa confiança funcional na implementação de 32 bits.

---

## 13. O que a testbench não valida explicitamente

Apesar da boa cobertura funcional, ela não é uma testbench temporal rigorosa.

Os seguintes comportamentos ainda não estão diretamente comprovados:

```text
✗ duração exata de core_done
✗ duração exata de core_err
✗ momento exato em que core_dout se torna válido
✗ menor gap permitido entre core_load
✗ funcionamento com loads back-to-back
✗ comportamento se core_load permanecer ativo
✗ comportamento durante reset no meio de uma operação
✗ comportamento logo após reset
✗ aborto de operação
✗ valor de core_dout antes da conclusão
✗ número exato de ciclos entre terceiro load e core_done
```

---

## 14. Contrato temporal consolidado até agora

Com base em RTL + testbench:

| Característica | Situação atual |
|---|---|
| Clock | borda de subida |
| Frequência utilizada na TB | 50 MHz |
| Reset | síncrono, ativo em `1` |
| Ordem dos operandos | `M → e → n` |
| Entrada dos operandos | `core_din[31:0]` |
| Validação | pulso de `core_load` |
| Estímulo gerado | em `negedge` |
| Captura esperada | em `posedge` |
| Gap entre operandos | presente na TB |
| Loads back-to-back | ainda não comprovados |
| Evento de término | `core_done` |
| Sucesso | `core_done=1`, `core_err=0` |
| Erro | `core_done=1`, `core_err=1` |
| Resultado de erro | `32'hFFFF_FFFF` |
| Próxima operação | somente após `core_done=0` |
| Persistência de `core_err` | ainda precisa ser confirmada |
| Resultado 32-bit | amplamente testado |

---

## 15. Pontos que devem ser verificados no waveform

### 15.1 Carregamento dos operandos

Confirmar:

```text
M → e → n
```

e verificar:

- duração real de cada pulso de `core_load`;
- número exato de ciclos entre pulsos;
- estado de `core_din` durante cada pulso;
- borda em que cada operando é capturado.

### 15.2 Início do processamento

Determinar:

- em qual ciclo o core deixa de estar apenas carregando dados;
- quantos ciclos existem entre o terceiro load e o início efetivo do cálculo;
- se a desassertação de `core_load` é necessária após o terceiro operando.

### 15.3 Finalização normal

Confirmar:

```text
core_done
core_dout
core_err
```

e observar:

- duração de `core_done`;
- relação temporal entre `core_done` e `core_dout`;
- se `core_dout` já está válido no mesmo ciclo em que `core_done` sobe;
- quanto tempo `core_dout` permanece válido.

### 15.4 Finalização com erro

Para um caso com:

```text
n = 0
```

confirmar:

```text
core_done = 1
core_err  = 1
core_dout = FFFFFFFF
```

e medir:

- duração de `core_done`;
- duração de `core_err`;
- comportamento de `core_err` depois que `core_done` retorna a zero.

### 15.5 Reset

Verificar:

- quantos ciclos são necessários para o controlador responder ao reset;
- estado das saídas durante reset;
- estado das saídas imediatamente após a desassertação;
- quanto tempo o core leva para voltar a aceitar `M`.

---

## 16. Hipótese de interface para o futuro `RSA_APB`

Até que as formas de onda confirmem o comportamento temporal, a hipótese mais segura para o wrapper é:

```text
START
  ↓
load M
  ↓
gap
  ↓
load e
  ↓
gap
  ↓
load n
  ↓
gap
  ↓
wait core_done
  ↓
sample core_err
  ↓
core_err = 0 → sucesso
core_err = 1 → erro
```

A arquitetura RTL definitiva do `RSA_APB` não deve ser fechada antes da validação desses pontos no waveform.

---

## 17. Próxima etapa

A próxima etapa é analisar as formas de onda do `rsa_core`.

Inicialmente, os sinais mais importantes são:

```text
core_clk
core_rst
core_load
core_din
core_done
core_err
core_dout
```

Caso necessário, depois serão adicionados sinais internos, principalmente:

```text
rsa_core_ctrl.state_reg
rsa_core_ctrl.state_ns
m_reg
e_reg
n_reg
```

Esses sinais permitirão correlacionar diretamente o protocolo externo com as transições da FSM interna e fechar o contrato temporal utilizado pelo futuro `RSA_APB`.
