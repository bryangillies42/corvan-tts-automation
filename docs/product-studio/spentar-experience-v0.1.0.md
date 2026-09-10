# Spentar v0.1.0 - bancada de rolagens preparadas

## Design read

Painel operacional de grimório para o jogador do Spentar usar durante uma mesa de TTS, preservando a linguagem necromântica escura existente e priorizando declarar condições, conferir a fórmula e rolar sem atravessar um wizard bloqueante.

A ideia memorável é uma **bancada de conjuração**: estados de cena ficam sempre visíveis, cada magia lembra seu último preparo e qualquer cálculo confirmado pode ser ajustado manualmente antes da rolagem. A principal restrição é não fingir que o objeto conhece regras contextuais ou aprimoramentos ainda não confirmados.

## Referências e decisões

- Fonte visual principal: UI e arte física atuais do Spentar.
- Referência de interação: ações diretas, rodapé persistente e feedback local do Corvan.
- Preservar: painel opaco 1600x1000, paleta necromântica, cinco áreas funcionais, barra de recursos, último resultado, Undo e Limpar Dados.
- Remover: wizard obrigatório, contador universal de aprimoramento, bloqueio global durante resolução e controles que aparentem automação inexistente.
- Inputs: campos digitáveis com limites objetivos; botões +/- permanecem apenas onde são mais rápidos.
- XML permanece sem imagem remota. A arte continua exclusivamente no objeto físico.

## Modelo de experiência

### Estado persistente

- Recursos: PV, PM, PV temporários e PM temporários.
- Cena: cajado, Profanar, Conexão e círculo, PV pagos, Necropotência obtida e Armadura Arcana.
- Dia: almas armazenadas.
- Rodada: comandos usados.
- Invocações: corpos disponíveis, mortos-vivos ativos, espíritos ativos, dados por espírito e parceiro cadáver.
- Preferências: gasto automático, dados físicos, chat detalhado e offset.
- Preparos: um rascunho por magia com custo total, alvos, dados, bônus, almas, confirmação dos alvos dentro de Profanar, efeito/aprimoramento e observação.

### Jornada primária

1. Selecionar uma magia ou ação rápida.
2. Editar somente as variáveis relevantes no rascunho.
3. Conferir custo e fórmula atualizados no mesmo painel.
4. Usar **Rolar** para dados ou **Aplicar sem rolar** para efeitos de referência.
5. Registrar falhas e inimigos vivos derrotados numa resolução não bloqueante.

### Regras de segurança

- Nenhum custo ou alma é consumido ao editar ou salvar um preparo.
- Confirmação repetida usa transactionId e não cobra duas vezes.
- Cancelar/Limpar durante dados restaura o snapshot.
- Falhas e derrotados não bloqueiam navegação; ficam pendentes até aplicar ou descartar.
- Necropotência concede +2 PM temporários uma vez por conjuração qualificada, não por inimigo.
- O cajado concede +10 PV temporários uma vez por conjuração com uma ou mais falhas.
- Dados e callbacks continuam isolados por characterId e GUID do painel.

## Superfícies

### Combate

- Ações rápidas: Infligir Ferimentos, Raio Arcano, Mortos-vivos e Espíritos.
- Cada ação mostra a fórmula salva e oferece **Rolar último** e **Editar**.
- Resolução pendente aparece como faixa discreta, sem bloquear outras ações.

### Magias

- Lista de magias à esquerda e editor à direita.
- Campos comuns: custo total, alvos, quantidade de dados, faces, bônus, almas e observação/aprimoramento.
- Toggles contextuais: grupo de trevas, alvos dentro de Profanar e aplicar efeito sem dados.
- Ações: **Salvar preparo**, **Rolar**, **Aplicar sem rolar** e **Restaurar padrão**.

### Necromancia

- Almas e Conexão.
- Corpos disponíveis, mortos-vivos ativos e fórmula agregada.
- Espíritos ativos e dados por espírito.
- Parceiro cadáver: nenhum, novato ou veterano, com registro manual de corpo/tipo.

### Ficha e Ajustes

- Ficha permanece como referência rolável.
- Ajustes preservam preferências, offset, diagnóstico, Refresh e Reset.

### Rodapé global

- Fim do turno, Fim da cena, Fim do dia, Desfazer, Limpar Dados e último resultado.

## Estados da UX

| Estado | Feedback | Recuperação |
|---|---|---|
| Editando | fórmula e custo ao vivo, sem gasto | salvar, rolar, aplicar ou restaurar padrão |
| Validação | campo inválido destacado por mensagem privada | corrigir sem perder o rascunho |
| Rolando | status e Cancelar/Limpar visíveis | rollback completo |
| Resolução pendente | falhas e derrotados editáveis | aplicar ou descartar; navegação continua |
| Sucesso | resultado no painel e chat mínimo | repetir último ou editar |
| Falha/timeout | motivo explícito e snapshot restaurado | tentar novamente |
| Sem release | Refresh informa canal de desenvolvimento | runtime atual preservado |

## Critérios de aceite

- Selecionar/editar/salvar não rola nem gasta recursos.
- Inputs digitáveis aceitam limites válidos e recusam texto inválido sem corromper estado.
- Rolar último usa exatamente o preparo salvo.
- Profanar maximiza somente grupos de trevas confirmados para a rolagem.
- Almas, cajado e Necropotência são aplicados uma vez nos gatilhos corretos.
- Mortos-vivos, espíritos e parceiro cadáver possuem estados independentes.
- Save/load preserva preparos, página, cena e invocações.
- Corvan v0.2.2 permanece byte/contrato independente do host do Spentar.
