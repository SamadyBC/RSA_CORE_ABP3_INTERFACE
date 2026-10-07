# WELCOME TO RSA_CORE_ABP3_INTERFACE

## Plano de Desenvolvimento

O objetivo do projeto é desenvolver o módulo `RSA_APB` em SystemVerilog, encapsulando o `rsa_core` de 32 bits existente e permitindo seu controle por meio de uma interface compatível com o protocolo **AMBA 3 APB**. O desenvolvimento será realizado seguindo o fluxo de projeto digital empregado anteriormente, contemplando especificação, arquitetura, implementação RTL, verificação funcional e síntese.

### 1. Análise da especificação

- [ ] Estudar a especificação funcional do `RSA_APB`.
- [ ] Estudar o funcionamento do `rsa_core` de 32 bits existente.
- [ ] Identificar os sinais de entrada, saída e controle do `rsa_core`.
- [ ] Estudar as operações de transferência previstas pelo protocolo AMBA 3 APB.
- [ ] Identificar os sinais APB necessários para a interface.
- [ ] Determinar os requisitos de leitura e escrita do periférico.
- [ ] Identificar condições de reset, erro e finalização das operações.
- [ ] Levantar restrições funcionais e temporais apresentadas na especificação.

### 2. Definição da arquitetura

- [ ] Definir a arquitetura do módulo `RSA_APB`.
- [ ] Determinar a interface entre o barramento APB e o `rsa_core`.
- [ ] Definir quais registradores serão acessíveis pelo barramento.
- [ ] Elaborar o mapa de registradores e endereços do periférico.
- [ ] Definir registradores de dados, configuração, comando e status conforme necessário.
- [ ] Determinar como as operações APB serão convertidas em sinais de controle para o `rsa_core`.
- [ ] Definir o comportamento das leituras realizadas pelo mestre APB.
- [ ] Definir o comportamento das escritas realizadas pelo mestre APB.
- [ ] Definir o tratamento de acessos inválidos e geração de erro, caso previsto pela especificação.
- [ ] Elaborar o diagrama de blocos da arquitetura final.

### 3. Planejamento da implementação RTL

- [ ] Definir a divisão do projeto em módulos SystemVerilog.
- [ ] Definir responsabilidades de cada módulo RTL.
- [ ] Definir parâmetros, tipos, constantes e endereços utilizados pela interface.
- [ ] Definir a lógica combinacional e sequencial necessária.
- [ ] Avaliar a necessidade de uma máquina de estados para controle da interface ou do `rsa_core`.
- [ ] Definir convenções de nomenclatura e organização dos arquivos em `rtl/`.

Estrutura inicial:

```text
rtl/
├── rsa_core.v
├── rsa_core.sv
└── rsa_apb.sv
```

Novos módulos auxiliares poderão ser adicionados à pasta `rtl/` caso a arquitetura definida na especificação justifique sua separação.

### 4. Planejamento da verificação

Antes da implementação definitiva, devem ser definidos os comportamentos que precisarão ser comprovados durante a simulação.

- [ ] Definir os cenários básicos de reset.
- [ ] Definir testes de escrita APB.
- [ ] Definir testes de leitura APB.
- [ ] Definir testes para todos os registradores mapeados.
- [ ] Definir testes para acessos a endereços inválidos.
- [ ] Definir testes para o início de uma operação RSA.
- [ ] Definir testes para acompanhamento do estado da operação RSA.
- [ ] Definir testes para obtenção do resultado da operação.
- [ ] Definir testes de operações APB consecutivas.
- [ ] Definir testes para condições de erro.
- [ ] Definir casos de fronteira e valores extremos.
- [ ] Determinar os resultados esperados de cada cenário antes da execução das simulações.

Essa etapa deverá fornecer posteriormente a base para a construção do ambiente de verificação utilizando **UVM**.

### 5. Implementação RTL

- [ ] Implementar o módulo `rsa_apb.sv`.
- [ ] Instanciar e conectar o `rsa_core` de 32 bits.
- [ ] Implementar a decodificação dos endereços APB.
- [ ] Implementar os registradores internos definidos na arquitetura.
- [ ] Implementar a lógica de escrita.
- [ ] Implementar a lógica de leitura.
- [ ] Implementar a geração dos sinais de controle do `rsa_core`.
- [ ] Implementar os sinais de resposta da interface APB.
- [ ] Implementar reset e inicialização dos registradores.
- [ ] Revisar o RTL quanto ao uso adequado de construções SystemVerilog sintetizáveis.

### 6. Verificação funcional com Xcelium

- [ ] Compilar o RTL utilizando Xcelium.
- [ ] Corrigir erros e warnings de compilação.
- [ ] Executar testes básicos da interface APB.
- [ ] Validar individualmente as operações de leitura e escrita.
- [ ] Validar o mapa de registradores.
- [ ] Validar a comunicação entre `RSA_APB` e `rsa_core`.
- [ ] Executar operações RSA completas através da interface APB.
- [ ] Comparar os resultados obtidos com os resultados esperados.
- [ ] Executar casos de erro e casos de fronteira.
- [ ] Analisar formas de onda para validar o comportamento temporal do protocolo.
- [ ] Registrar os testes executados e seus respectivos resultados.

### 7. Análise estática e qualidade do RTL

- [ ] Executar as verificações disponíveis no fluxo de ferramentas.
- [ ] Analisar warnings relacionados a largura de sinais.
- [ ] Analisar diferenças de signedness.
- [ ] Verificar atribuições incompletas e possíveis inferências de latch.
- [ ] Verificar sinais não utilizados ou não dirigidos.
- [ ] Corrigir warnings relevantes sem alterar o comportamento especificado.
- [ ] Manter o código compatível com síntese.

### 8. Síntese com Cadence Genus

- [ ] Atualizar o script de síntese para utilizar o `RSA_APB` como top-level.
- [ ] Configurar os arquivos RTL necessários.
- [ ] Definir as restrições temporais no arquivo SDC.
- [ ] Executar a elaboração do design.
- [ ] Verificar possíveis warnings de elaboração.
- [ ] Executar a síntese.
- [ ] Analisar utilização de área.
- [ ] Analisar timing.
- [ ] Verificar violações de restrições.
- [ ] Analisar a netlist sintetizada.
- [ ] Confirmar que todas as estruturas RTL foram corretamente sintetizadas.

### 9. Validação pós-síntese

- [ ] Comparar o comportamento esperado do RTL com o design sintetizado utilizando o fluxo de equivalência disponível.
- [ ] Verificar possíveis diferenças entre RTL e netlist.
- [ ] Corrigir eventuais problemas de síntese ou de codificação.
- [ ] Confirmar a consistência entre o comportamento funcional e a implementação sintetizada.

### 10. Documentação final

- [ ] Documentar a arquitetura adotada.
- [ ] Adicionar o diagrama de blocos definitivo.
- [ ] Documentar a interface do módulo `RSA_APB`.
- [ ] Documentar o mapa de registradores.
- [ ] Documentar o significado de cada endereço e campo.
- [ ] Documentar o procedimento para realizar uma operação RSA através do APB.
- [ ] Documentar os casos de teste utilizados.
- [ ] Documentar os comandos para compilação, simulação e síntese.
- [ ] Registrar limitações conhecidas ou decisões de projeto relevantes.
- [ ] Revisar o README e a organização final do repositório.

## Fluxo de desenvolvimento

O fluxo adotado para o projeto é:

```text
Especificação
      ↓
Análise do RSA Core
      ↓
Definição da interface APB
      ↓
Mapa de registradores
      ↓
Arquitetura
      ↓
Planejamento dos testes
      ↓
Implementação RTL
      ↓
Verificação funcional
      ↓
Análise estática
      ↓
Síntese
      ↓
Validação pós-síntese
      ↓
Documentação
      ↓
Base para o ambiente UVM
```

A arquitetura e os casos de teste devem ser definidos antes da implementação definitiva, de forma que o comportamento esperado do `RSA_APB` seja conhecido previamente e possa ser utilizado como referência tanto para a verificação funcional atual quanto para o posterior desenvolvimento do ambiente de verificação UVM.