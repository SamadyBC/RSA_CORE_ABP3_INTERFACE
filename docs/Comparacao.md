# Revisão arquitetural do `rsa_apb.sv`

Analisei os 355 linhas do arquivo `rsa_apb.sv` e comparei sua implementação com o contrato temporal que estabelecemos a partir do RTL e dos VCDs do `rsa_core`.

Minha avaliação é que a arquitetura proposta está bem alinhada com nossas conclusões e constitui uma base adequada para o wrapper APB3. A separação de responsabilidades é coerente, o banco de registradores cobre as funcionalidades principais e o sequenciador utiliza corretamente os quatro estados que discutimos.

Entretanto, identifiquei duas divergências importantes em relação ao contrato e alguns pontos que precisam de validação antes de considerarmos a implementação concluída.

## 1. Visão geral da arquitetura

O módulo está organizado em cinco partes:

Organização funcional identificada no RTL. As conexões estão simplificadas para destacar responsabilidades.

Essa decomposição está de acordo com o que havíamos planejado: desacoplar a interface APB do protocolo de alimentação sequencial do core.

## 2. Matriz de conformidade

| Funcionalidade                        | Avaliação                                           |
| ------------------------------------- | --------------------------------------------------- |
| Interface APB3 de 32 bits             | Conforme                                            |
| Mapeamento de registradores           | Conforme                                            |
| `PREADY = 1`                          | Conforme                                            |
| `PSLVERR` durante a fase de acesso    | Conforme nos casos previstos                        |
| Proteção de operandos durante `BUSY`  | Conforme                                            |
| `CTRL.SRST` prioritário sobre `START` | Conforme                                            |
| Flags `DONE` e `ERROR` sticky         | Conforme                                            |
| Interrupção por nível                 | Conforme                                            |
| Sequenciador de quatro estados        | Conforme                                            |
| Desassertação entre os loads          | Conforme para `LOAD_GAP ≥ 1`                        |
| Semântica de `LOAD_GAP=0`             | Divergente                                          |
| Detecção de conclusão                 | Funcionalmente plausível, mas diferente do contrato |
| Reset externo com dois flip-flops     | Conforme estruturalmente                            |
| Recuperação após `SRST`               | Adequada em princípio; pendente de teste            |
| Latência exata da operação            | Ainda não validada                                  |

As avaliações de conformidade são baseadas em inspeção estática do RTL, não em simulação do wrapper.

## 3. Primeira divergência: interpretação de `LOAD_GAP`

Este é o ponto mais evidente.

A implementação declara:

```
parameter int LOAD_GAP = 1;
```

E no estado `S_LOAD`:

```
S_LOAD: begin
    if (core_rdy_q) begin
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
```

### O que está correto

Com `LOAD_GAP=1`, a sequência efetivamente produz:

```
LOAD MSG → GAP → LOAD EXP → GAP → LOAD MOD → WAIT
```

Como `core_load` só fica ativo em `S_LOAD`, o estado `GAP` fornece o ciclo de desassertação obrigatório.

Isso satisfaz o handshake observado no VCD.

A transição direta de `LOAD MOD → WAIT` também é funcionalmente aceitável, pois `core_load` será desassertado em `WAIT`; na borda seguinte, o controlador do core poderá sair de `WAIT_N`.

### O que diverge do contrato

No documento consolidado, propusemos interpretar `LOAD_GAP` como a quantidade de ciclos adicionais aos ciclos obrigatórios de liberação.

Na implementação atual, `LOAD_GAP` representa o intervalo total de ciclos com `core_load=0` entre dois carregamentos.

A diferença é:

| Parâmetro    | Proposta documentada              | RTL atual            |
| ------------ | --------------------------------- | -------------------- |
| `LOAD_GAP=0` | Um ciclo obrigatório de liberação | Nenhum ciclo         |
| `LOAD_GAP=1` | Dois ciclos sem load              | Um ciclo sem load    |
| `LOAD_GAP=2` | Três ciclos sem load              | Dois ciclos sem load |

O problema funcional aparece com `LOAD_GAP=0`: o sequenciador permanece em `S_LOAD`, incrementando `load_idx`, mas mantém `core_load=1`.

Nesse caso, o core não consegue reconhecer o próximo operando, conforme demonstramos anteriormente.

### Minha recomendação

Existem duas alternativas tecnicamente defensáveis.

Alternativa A — Preservar o RTL atual: manter `LOAD_GAP=1` como mínimo permitido, documentando que `LOAD_GAP=0` é incompatível com o IP fornecido. Nesse caso, recomendo impedir explicitamente configurações inferiores a 1.

Alternativa B — Adotar a semântica do contrato: manter `LOAD_GAP=0` como padrão, mas fazer `S_GAP` executar um ciclo obrigatório mais os ciclos adicionais parametrizados.

Eu prefiro a alternativa B pela consistência com nosso contrato. Porém, se o objetivo principal for minimizar alterações em um código que vocês já escreveram, a alternativa A é igualmente válida como decisão de integração, desde que a restrição fique explícita.

Essa é uma decisão arquitetural, não um erro inevitável da implementação.

## 4. Segunda divergência: detecção de conclusão do core

O código utiliza:

```
assign core_fin = core_done | (core_error & ~core_error_q);
```

E posteriormente:

```
assign done_evt =
    (state == S_WAIT) & core_fin & ~core_error & ~ctrl_srst;

assign error_evt =
    (state == S_WAIT) & core_fin & core_error & ~ctrl_srst;
```

### Qual é a intenção dessa lógica?

Ela tenta acomodar dois comportamentos diferentes:

1. O core real, em que `core_done=1` sinaliza tanto sucesso quanto erro.
2. O comportamento descrito na especificação, em que `core_error` poderia ser um pulso de conclusão independente.

Isso mostra que vocês identificaram corretamente a divergência entre as interfaces.

### A lógica funciona com o core real?

Em condições normais de operação, sim.

Quando uma operação termina com sucesso:

```
core_done  = 1
core_error = 0
```

Então:

```
core_fin  = 1
done_evt  = 1
error_evt = 0
```

Quando termina com erro:

```
core_done  = 1
core_error = 1
```

Então:

```
core_fin  = 1
done_evt  = 0
error_evt = 1
```

Além disso, como vocês usam um detector de borda de subida de `core_error`, seu nível persistente não deve disparar repetidamente o evento após uma conclusão já reconhecida.

### Onde está a divergência?

Nosso contrato recomenda uma solução mais específica:

```
assign core_fin = core_done;
```

Isso porque os VCDs demonstraram que, no RTL fornecido, `core_done` é o sinal de conclusão tanto em sucesso quanto em erro.

O detector adicional de borda de `core_error` não é necessário para o core que estamos integrando.

Também amplia a quantidade de condições que precisarão ser verificadas no wrapper.

Por exemplo, se `core_error` apresentar uma transição de `0` para `1` enquanto a FSM estiver em `S_WAIT`, antes da assertiva de `core_done`, a implementação interpretará esse evento como conclusão.

Esse comportamento pode ser desejável para um core que siga literalmente a especificação, mas não foi identificado como necessário no IP real.

Minha recomendação é utilizar apenas `core_done` para detectar a conclusão e `core_error` para qualificá-la.

Isso simplifica o circuito e mantém correspondência direta com o contrato temporal validado.

## 5. Revisão do banco de registradores

Nesta parte, a implementação está especialmente consistente.

### Operandos

```
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
```

A lógica impede modificações nos operandos durante `BUSY` e permite sua preservação entre operações.

Também mantém os operandos intactos durante `SRST`, como exige a especificação.

### RESULT

```
else if (done_evt)
    result_q <= core_dout;
```

Correto: `RESULT` só é atualizado na conclusão bem-sucedida.

Em caso de erro, o resultado anterior é mantido. Isso é particularmente importante porque o core fornece `FFFFFFFF` quando o módulo é zero, mas esse valor não deve substituir o último resultado válido no wrapper.

### STATUS

Os registradores `done_q` e `error_q` são implementados como flags sticky e oferecem suporte a W1C.

A prioridade adotada é:

```
PRESETn
   ↓
SRST / START
   ↓
Evento de conclusão
   ↓
W1C
```

Essa organização é consistente.

No nosso contrato, a prioridade entre W1C e conclusão havia sido deixada em aberto. Vocês tomaram uma decisão explícita: a conclusão prevalece sobre uma limpeza W1C simultânea.

Considero essa escolha adequada, pois evita perder a informação de uma operação recém-concluída.

Ela deve, entretanto, fazer parte da especificação comportamental da implementação e ser coberta pela testbench APB.

## 6. STATUS.BUSY

O código utiliza:

```
assign busy = (state != S_IDLE);
```

Essa é uma solução simples e apropriada para a arquitetura escolhida.

Quando `START` é aceito, o sequenciador passa a `S_LOAD` e `busy` é ativado.

Quando uma conclusão é reconhecida em `S_WAIT`, o sequenciador retorna a `S_IDLE` e `busy` é desativado.

Isso mantém `BUSY` associado ao ciclo de vida da operação.

Uma observação: como `busy` é combinacionalmente derivado do estado, o instante exato de sua mudança depende da atualização de `state` na borda do clock. Precisaremos verificar a leitura de `STATUS` quando ela coincidir com um evento de conclusão.

Não considero necessária a introdução de um `busy_ff` independente neste momento.

## 7. Interface APB3 e geração de PSLVERR

A decodificação principal está correta:

```
assign apb_write = PSEL & PENABLE & PWRITE;
assign PREADY    = 1'b1;
```

As atualizações dos registradores acontecem durante a fase de acesso, e não durante a fase de setup.

O sinal `PSLVERR` contempla:

- `START` enquanto `BUSY=1`;
- escrita de `MSG`, `EXP` ou `MOD` durante `BUSY=1`;
- escrita em `RESULT` ou `ID`.

O comportamento corresponde aos erros explicitamente previstos no contrato.

Há apenas uma questão que recomendo esclarecer antes da verificação: o tratamento de acessos a endereços não implementados.

Atualmente, leituras desses endereços retornam zero, e escritas não produzem efeito nem erro.

Isso pode ser aceitável, mas depende da interpretação definitiva da especificação.

Não sugiro alterar esse comportamento sem antes verificarmos o enunciado.

## 8. Reset externo e software reset

O sincronizador implementado é:

```
always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)
        rst_sync <= 2'b00;
    else
        rst_sync <= {rst_sync[0], 1'b1};
end
```

E o reset do core é:

```
assign core_rst = ~rst_sync[1] | srst_q;
```

A estrutura implementa corretamente a liberação sincronizada por dois flip-flops.

O software reset é registrado por:

```
always_ff @(posedge PCLK or negedge PRESETn) begin
    if (!PRESETn)
        srst_q <= 1'b0;
    else
        srst_q <= ctrl_srst;
end
```

Para uma única transferência APB válida de `SRST`, `srst_q` permanece ativo durante um período de `PCLK`, conforme nossa necessidade.

### Papel de `core_rdy_q`

Vocês acrescentaram:

```
core_rdy_q <= ~core_rst;
```

E condicionaram a ativação de `core_load` à disponibilidade do core:

```
assign core_load = (state == S_LOAD) & core_rdy_q;
```

Considero essa uma escolha arquitetural importante.

Como demonstramos no VCD, o controlador precisa retornar a `INIT` e executar suas ações de inicialização antes de receber os novos operandos.

Esse mecanismo introduz uma espera entre a liberação de `core_rst` e a alimentação do core.

A lógica parece adequada, mas precisamos confirmar por simulação dois casos específicos:

- `SRST` seguido imediatamente por um novo `START`;
- `START` logo após a liberação de `PRESETn`.

Esses cenários ainda não foram verificados no nível do wrapper.

## 9. Um detalhe adicional: parametrização do core

O módulo `rsa_core` é instanciado sem parâmetros:

```
rsa_core u_rsa_core (
    .core_clk   (PCLK),
    .core_rst   (core_rst),
    .core_load  (core_load),
    .core_din   (core_din),
    .core_done  (core_done),
    .core_err   (core_error),
    .core_dout  (core_dout)
);
```

Isso é correto se o arquivo `rsa_core.sv` utilizado possuir `DATA_WIDTH=32` como valor padrão, conforme a versão que analisamos.

Entretanto, se outra versão do core for utilizada com valor padrão diferente, teremos incompatibilidades de largura.

Para maior robustez, eu recomendaria explicitar:

```
rsa_core #(
    .DATA_WIDTH(32)
) u_rsa_core (
    // ...
);
```

Não altera a arquitetura nem o comportamento esperado, apenas torna explícita a configuração do IP.

## 10. Priorização das alterações

| Prioridade | Ponto                                | Recomendação                                                                                |
| ---------- | ------------------------------------ | ------------------------------------------------------------------------------------------- |
| Alta       | `LOAD_GAP=0`                         | Decidir se o parâmetro representa ciclos totais ou adicionais; impedir o protocolo inválido |
| Alta       | `core_fin`                           | Preferir `core_done` como único evento de conclusão do IP real                              |
| Média      | Reset seguido imediatamente de START | Validar temporalmente `core_rdy_q`                                                          |
| Média      | W1C simultâneo à conclusão           | Registrar e testar a prioridade escolhida                                                   |
| Média      | Endereços reservados                 | Confirmar comportamento exigido                                                             |
| Baixa      | Parametrização de `rsa_core`         | Explicitar `DATA_WIDTH=32`                                                                  |

## Conclusão

A implementação de vocês é arquiteturalmente compatível com o contrato de interface na maior parte dos aspectos. Não identifiquei, por inspeção estática, a necessidade de substituir a arquitetura ou criar novos blocos de controle.

A FSM `S_IDLE → S_LOAD → S_GAP → S_WAIT` é adequada; os registradores estão separados por responsabilidade; a interface APB3 é coerente; e o tratamento de reset considera a particularidade temporal observada no core.

Eu concentraria a próxima discussão em duas decisões, antes de modificar o RTL:

Primeiro: vamos manter `LOAD_GAP=1` como mínimo permitido, como vocês implementaram, ou adotar `LOAD_GAP=0` com um ciclo obrigatório de liberação interno ao sequenciador?

Segundo: queremos que o wrapper seja compatível exclusivamente com o `rsa_core` fornecido, utilizando `core_done` como evento único de conclusão, ou que também suporte a interface de erro independente descrita na especificação?

Essas duas escolhas determinam pequenas alterações na implementação e influenciam diretamente como construiremos a testbench APB3. A validação dinâmica do wrapper ainda será necessária para confirmar os resultados desta revisão estática.