# Análise Teórica Inicial — RSA_APB

A especificação já define quase todo o comportamento externo e interno necessário para o `RSA_APB`. Antes de escolher a arquitetura RTL, vale decompor o documento em requisitos funcionais e identificar quais decisões ainda ficam abertas para implementação.

O ponto central é que o `RSA_APB` não altera o algoritmo RSA. Ele funciona como um **wrapper APB3** para o `rsa_core` de 32 bits. O software escreve `M`, `e` e `n` em registradores, dispara `START`, e posteriormente lê o resultado ou observa uma condição de erro.

---

## 1. Visão funcional do sistema

Podemos interpretar o sistema em três níveis:

```text
APB Master
    │
    │ PADDR / PWDATA / PWRITE / PSEL / PENABLE
    ▼
+-------------------------------+
|            RSA_APB            |
|                               |
|  APB interface / registers    |
|             │                 |
|             ▼                 |
|      Control / Sequencer      |
|             │                 |
|             ▼                 |
|         rsa_core              |
|                               |
+-------------------------------+
    │
    ├── PRDATA
    ├── PREADY
    ├── PSLVERR
    └── irq
```

Essa interpretação é consistente com o diagrama de blocos da especificação: há uma camada de registradores entre o barramento e o `rsa_core`, e uma unidade de controle responsável pela interface APB e pela sequência de carregamento do core.

O `rsa_core` recebe somente:

```text
core_clk
core_rst
core_load
core_din[31:0]
```

e fornece:

```text
core_done
core_error
core_dout[31:0]
```

Portanto, o wrapper precisa converter uma interface de registradores aleatoriamente acessíveis pelo software em uma interface **sequencial de carregamento** para o RSA.

---

## 2. Interface APB3 externa

A interface externa definida é:

```systemverilog
input  logic        PCLK;
input  logic        PRESETn;
input  logic        PSEL;
input  logic        PENABLE;
input  logic        PWRITE;
input  logic [11:0] PADDR;
input  logic [31:0] PWDATA;

output logic [31:0] PRDATA;
output logic        PREADY;
output logic        PSLVERR;

output logic        irq;
```

Há algumas implicações importantes aqui.

### Barramento de dados

É diretamente de 32 bits:

```text
PWDATA[31:0]
PRDATA[31:0]
```

portanto cada registrador interno pode corresponder exatamente a uma palavra APB.

### Endereço

`PADDR` possui 12 bits, dando uma janela total de:

\[
2^{12}=4096\text{ bytes}=4\text{ KB}
\]

Mas os registradores existentes ocupam apenas:

```text
0x000 – 0x01C
```

O restante:

```text
0x020 – 0xFFC
```

fica reservado.

Como os registradores têm 32 bits, os bits:

```text
PADDR[1:0]
```

são ignorados. A especificação considera os acessos alinhados por palavra.

---

## 3. APB não terá wait states

Esse é um requisito importante para nossa futura arquitetura.

A especificação exige:

```text
PREADY = 1
```

constantemente.

Logo o `RSA_APB` nunca pode estender uma transferência APB.

Toda transferência será:

```text
ciclo N       SETUP
ciclo N+1     ACCESS
```

e termina no ACCESS.

A especificação afirma que cada transferência APB ocupa dois ciclos de `PCLK`.

Isso sugere fortemente que não precisamos criar uma FSM APB complexa para controlar `PREADY`.

Provavelmente teremos simplesmente uma condição semelhante a:

```text
apb_access = PSEL && PENABLE
```

e então:

```text
apb_write = PSEL && PENABLE && PWRITE
apb_read  = PSEL && PENABLE && !PWRITE
```

Ainda não estamos propondo a implementação final, mas conceitualmente esse será provavelmente o ponto em que uma transferência é efetivada.

---

## 4. O mapa de registradores

A especificação define oito registradores:

| Offset | Registro | Acesso | Função |
|---:|---|---|---|
| `0x00` | `CTRL` | WO | START / software reset |
| `0x04` | `STATUS` | RO/W1C | BUSY / DONE / ERROR |
| `0x08` | `IER` | RW | habilitação de interrupções |
| `0x0C` | `MSG` | RW | mensagem |
| `0x10` | `EXP` | RW | expoente |
| `0x14` | `MOD` | RW | módulo |
| `0x18` | `RESULT` | RO | resultado |
| `0x1C` | `ID` | RO | identificação/versionamento |

Essa tabela já nos dá uma separação bastante natural dos recursos internos.

### Registradores físicos necessários

Certamente precisaremos armazenar:

```text
MSG    [31:0]
EXP    [31:0]
MOD    [31:0]
RESULT [31:0]
IER    [1:0]
```

Além dos bits de status:

```text
BUSY
DONE
ERROR
```

Já `CTRL` não precisa necessariamente existir como registrador físico de 32 bits.

Isso ocorre porque:

```text
START
SRST
```

são comandos **self-clearing**.

Então provavelmente serão eventos de um ciclo gerados por uma escrita APB, e não bits persistentemente armazenados.

---

## 5. CTRL

O registrador:

```text
0x00 CTRL
```

possui somente:

```text
bit 0 START
bit 1 SRST
```

Os dois são write-only e self-clearing.

Do ponto de vista funcional:

### START

Uma escrita:

```text
CTRL.START = 1
```

quando:

```text
BUSY = 0
```

deve:

```text
DONE  <- 0
ERROR <- 0
BUSY  <- 1
```

e iniciar a sequência:

```text
MSG
 ↓
EXP
 ↓
MOD
 ↓
rsa_core
```

### SRST

Uma escrita:

```text
CTRL.SRST = 1
```

deve:

```text
core_rst = 1 por um ciclo
sequencer -> IDLE
STATUS -> 0
```

Além disso:

```text
MSG
EXP
MOD
RESULT
IER
```

não são alterados.

Esse detalhe será particularmente importante na implementação do reset.

### Prioridade

Caso:

```text
START = 1
SRST  = 1
```

na mesma escrita:

```text
SRST vence
START é ignorado
```

Então já temos uma prioridade funcional explícita:

```text
SRST > START
```

---

## 6. STATUS

Os bits são:

```text
bit 2 ERROR
bit 1 DONE
bit 0 BUSY
```

Eles possuem comportamentos bastante diferentes.

### BUSY

Não é W1C.

É controlado pelo hardware.

```text
START
  │
  ▼
BUSY = 1
  │
  │ operação
  ▼
core_done ou core_error
  │
  ▼
BUSY = 0
```

### DONE

É um bit sticky.

```text
core_done
   ↓
DONE = 1
```

Permanece em `1` até:

```text
write 1 em STATUS.DONE
```

ou até uma nova operação começar.

### ERROR

Segue a mesma lógica:

```text
core_error
   ↓
ERROR = 1
```

permanece em `1` até ser limpo explicitamente ou uma nova operação iniciar.

Essa persistência é necessária porque `core_done` e `core_error` existem por apenas **um ciclo**, enquanto software pode levar muitos ciclos até ler o periférico.

---

## 7. Write-1-to-clear

Esse comportamento merece atenção porque frequentemente causa erro em RTL.

Se o software escrever:

```text
STATUS = 32'h0000_0002
```

então:

```text
DONE -> 0
```

mas:

```text
ERROR
```

não deve ser modificado.

Analogamente:

```text
STATUS = 32'h0000_0004
```

limpa somente `ERROR`.

Portanto não podemos simplesmente fazer:

```text
status <= PWDATA;
```

O comportamento é algo conceitualmente equivalente a:

```text
if (PWDATA[1])
    DONE <= 0;

if (PWDATA[2])
    ERROR <= 0;
```

Isso será importante quando definirmos a lógica sequencial.

---

## 8. Registradores de operandos

Os três operandos são independentes:

```text
MSG
EXP
MOD
```

O software pode escrevê-los em qualquer ordem.

Além disso, depois que uma operação acaba, os valores permanecem armazenados.

Isso permite, por exemplo:

```text
MSG = M1
EXP = e
MOD = n
START

...

MSG = M2
START
```

sem reescrever `EXP` e `MOD`.

---

## 9. Restrição durante BUSY

Enquanto:

```text
BUSY = 1
```

não podemos escrever:

```text
MSG
EXP
MOD
```

Uma tentativa precisa:

```text
PSLVERR = 1
```

e, igualmente importante:

```text
o registrador não pode mudar
```

O mesmo acontece se houver:

```text
CTRL.START = 1
```

durante `BUSY`.

Esse é um requisito de **atomicidade da operação**: os três operandos utilizados pelo RSA permanecem estáveis enquanto o cálculo ocorre.

---

## 10. Sequenciamento para o `rsa_core`

Aqui está provavelmente a parte mais importante da lógica de controle.

O `rsa_core` não possui:

```text
message
exponent
modulus
```

como três entradas independentes.

Ele possui apenas:

```text
core_din[31:0]
core_load
```

e espera receber:

```text
1º load -> MSG
2º load -> EXP
3º load -> MOD
```

Portanto, após START, temos conceitualmente:

```text
        START
          │
          ▼
       load MSG
core_din = MSG
core_load = 1
          │
          ▼
       load EXP
core_din = EXP
core_load = 1
          │
          ▼
       load MOD
core_din = MOD
core_load = 1
          │
          ▼
         WAIT
          │
       ┌──┴───┐
       │      │
 core_done core_error
       │      │
       ▼      ▼
     DONE    ERROR
```

Com:

```text
LOAD_GAP = 0
```

os três loads podem acontecer em ciclos consecutivos.

Isso praticamente confirma que precisaremos de algum tipo de **sequenciador**.

A discussão de arquitetura depois será principalmente:

> implementar isso como FSM explícita ou como contador/estado codificado?

A tendência inicial é usar uma FSM explícita, mas essa decisão será tomada somente após validar o comportamento temporal do `rsa_core`.

---

## 11. RESULT

Quando:

```text
core_done = 1
```

precisamos realizar simultaneamente:

```text
RESULT <= core_dout
DONE   <= 1
BUSY   <= 0
```

Quando:

```text
core_error = 1
```

temos:

```text
ERROR <= 1
BUSY  <= 0
```

mas:

```text
RESULT permanece inalterado
```

Esse último ponto é particularmente importante para os testes.

Se tivermos:

```text
resultado anterior = 0x12345678
```

e uma nova operação utiliza:

```text
MOD = 0
```

após o erro devemos continuar lendo:

```text
RESULT = 0x12345678
```

e não zero.

---

## 12. Interrupção

A saída `irq` pode ser puramente combinacional:

\[
irq =
(DONE \land DONE\_IE)
\lor
(ERROR \land ERR\_IE)
\]

Então não parece necessário haver um registrador próprio para `irq`.

Ele pode ser derivado de:

```text
STATUS
+
IER
```

---

## 13. IER

O registrador possui:

```text
IER[0] = DONE_IE
IER[1] = ERR_IE
```

Os demais bits são reservados e precisam ler zero.

Por isso, mesmo recebendo:

```text
PWDATA = 32'hFFFFFFFF
```

em uma escrita para IER, conceitualmente só os dois bits menos significativos deveriam ser armazenados:

```text
IER = 2'b11
```

e uma leitura retorna:

```text
PRDATA = 32'h00000003
```

---

## 14. ID

Esse registro é constante:

```text
ID = 32'h5253_0200
```

decomposto como:

```text
31:16 = 0x5253 = "RS"
15:8  = 0x02   = major version
7:0   = 0x00   = minor version
```

Logo, provavelmente nem precisa existir um flip-flop físico.

Na lógica de leitura podemos simplesmente retornar:

```text
32'h5253_0200
```

---

## 15. PSLVERR

Esse ponto merece atenção porque a especificação não está dizendo que todo acesso inválido gera erro.

As condições explicitamente apresentadas são:

```text
write RESULT
write ID
```

e, durante BUSY:

```text
write MSG
write EXP
write MOD
write CTRL.START
```

Uma leitura de `CTRL`:

```text
PRDATA = 0
PSLVERR = 0
```

Também sabemos que `CTRL.START` durante `BUSY` gera erro.

---

## 16. Um ponto que considero ambíguo

Há uma pequena lacuna relevante na especificação.

Ela informa:

> offsets `0x20` a `0xFFC` são reservados.

Mas a seção de `PSLVERR` lista explicitamente apenas:

```text
write RESULT
write ID
write START/operandos durante BUSY
```

Não está claramente indicado se:

```text
read endereço reservado
write endereço reservado
```

deve:

```text
PSLVERR = 1
```

ou simplesmente:

```text
PRDATA = 0
PSLVERR = 0
```

Isso não deve ser decidido silenciosamente.

Quando formos implementar, convém verificar se existe orientação do professor ou alguma referência adicional. Caso não exista, será necessário documentar a decisão adotada.

---

## 17. Reset é o ponto mais delicado da especificação

Temos dois resets diferentes:

```text
PRESETn
CTRL.SRST
```

### PRESETn

É:

```text
ativo em LOW
```

e precisa resetar:

```text
todos os registradores
sequencer
rsa_core
```

### SRST

É completamente diferente.

Ele:

```text
reseta apenas lógica de operação
aborta operação atual
limpa STATUS
gera core_rst
```

mas preserva:

```text
MSG
EXP
MOD
RESULT
IER
```

Temos então algo conceitualmente parecido com:

```text
PRESETn
   │
   ├── reset APB registers
   ├── reset STATUS
   ├── reset operands
   ├── reset RESULT
   ├── reset IER
   └── reset sequencer

SRST
   │
   ├── reset STATUS
   ├── reset sequencer
   └── pulse core_rst
```

Isso vai influenciar bastante nossa organização dos blocos `always_ff`.

---

## 18. Sincronização de PRESETn

Existe outro requisito específico:

> `core_rst` é síncrono, e a desassertação de `PRESETn` deve passar por um sincronizador de dois flip-flops antes de chegar ao core.

Isso significa que há uma diferença entre:

```text
reset do wrapper APB
```

e:

```text
reset entregue ao rsa_core
```

Esse detalhe precisa ser analisado cuidadosamente quando virmos a implementação atual de `rsa_core.sv`, porque precisamos confirmar exatamente como o `core_rst` é amostrado.

---

## 19. Clock domain

Aqui temos uma simplificação importante:

```text
core_clk = PCLK
```

Não existe crossing de domínio.

Portanto não teremos:

```text
CDC
async FIFO
handshake entre clocks
```

entre APB e RSA.

---

## 20. Caminho completo de uma operação

Depois dessa leitura, podemos resumir uma transação RSA completa assim:

```text
1. APB write MSG
        │
2. APB write EXP
        │
3. APB write MOD
        │
4. APB write CTRL.START
        │
        ├── DONE  = 0
        ├── ERROR = 0
        └── BUSY  = 1
        │
5. core_load + MSG
        │
6. core_load + EXP
        │
7. core_load + MOD
        │
8. wait rsa_core
        │
        ├───────────────┐
        │               │
    core_done       core_error
        │               │
        ▼               ▼
RESULT <- dout       RESULT hold
DONE   <- 1          ERROR <- 1
BUSY   <- 0          BUSY  <- 0
        │               │
        └───────┬───────┘
                ▼
              irq
       dependendo do IER
```

Essa é, na prática, a especificação funcional que nosso RTL deverá implementar.

---

## 21. Separação conceitual antes da codificação

Sem ainda decidir quantos arquivos `.sv` teremos, já é possível enxergar **cinco responsabilidades lógicas distintas**:

```text
                 RSA_APB
                    │
 ┌──────────────────┼───────────────────┐
 │                  │                   │
 ▼                  ▼                   ▼
APB decode     Register bank       RSA sequencer
 │                  │                   │
 │                  │                   ▼
 │                  │               rsa_core
 │                  │
 ├── PRDATA          ├── MSG
 ├── PSLVERR         ├── EXP
 └── writes          ├── MOD
                     ├── RESULT
                     ├── STATUS
                     └── IER

              Interrupt logic
                    │
                    ▼
                   irq
```

Isso não significa necessariamente criar cinco módulos. É apenas a **separação funcional** sugerida pela própria especificação.

---

## Próxima etapa

Ainda não é recomendado começar a escrever `rsa_apb.sv`.

O próximo passo é colocar **lado a lado a interface real do `rsa_core.sv` e esta especificação**. Precisamos conferir principalmente:

```text
core_rst
core_load
core_din
core_done
core_error
core_dout
```

e entender exatamente o comportamento temporal desses sinais no core de 32 bits.

Depois disso será possível definir a arquitetura RTL concreta, incluindo:

- FSM ou sequenciador;
- banco de registradores;
- decodificação APB;
- geração de `PSLVERR`;
- geração de `irq`;
- lógica de reset;
- relações temporais ciclo a ciclo entre `RSA_APB` e `rsa_core`.

A arquitetura deve ser fechada apenas após essa validação temporal, para evitar que o wrapper seja estruturado com hipóteses incorretas sobre a forma como o `rsa_core` recebe operandos, sinaliza término e trata reset.
