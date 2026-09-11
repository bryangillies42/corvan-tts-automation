# Spentar — implementação v0.1.0

`characterId`: `spentar`

O Spentar é o primeiro personagem real criado sobre a fundação multi-personagem. A implementação usa a ficha de nível 7 fornecida por Fuku e permanece bloqueada para publicação (`productionEnabled: false`) até a validação manual no Tabletop Simulator.

## Regra de segurança

Spentar ainda não é publicável. A primeira tag planejada é `spentar-v0.1.0`, sempre com `--latest=false`; ela não pode alterar o canal global legado do Corvan. Dados ausentes da ficha não recebem valores fictícios: magias sem fórmula confirmada ficam em resolução de referência/manual.

## Contrato funcional

- Recursos: 20 PV, 48 PM, PV temporários cumulativos e PM temporários consumidos antes dos normais.
- Almas: até 6; cada uma concede +2 Defesa e resistências e pode ser liberada por +2d6 de trevas.
- CD adotada pela mesa: 22 geral e 24 Necromancia, ou 23/25 com o cajado em duas mãos.
- Profanar maximiza somente grupos de dano de trevas. Bônus fixos permanecem iguais.
- Conjurar Mortos Vivos: `Nd6 + 2N + INT 6`; seis mortos-vivos causam `6d6+18`, ou 54 sob Profanar.
- Necropotência: com a conexão dobrada, uma conjuração de Necromancia que derrube ao menos um inimigo vivo concede +2 PM temporários uma vez, até 7 ganhos na cena.
- O cajado concede 10 PV temporários quando ao menos um inimigo falha na resistência.

CD 22/24 e o acúmulo dos PV temporários são regras explícitas desta mesa (`houseRules` em `character.json`), não alegações sobre a regra oficial.

## Páginas e fluxo

O painel possui Combate, Magias, Necromancia, Ficha e Ajustes. Em vez de um wizard, cada magia possui um preparo persistente e digitável com custo, alvos, dados, bônus, almas, efeito e observação. Editar ou salvar nunca gasta recursos. **Rolar último** usa exatamente o preparo salvo; **Rolar** usa o rascunho atual; **Aplicar sem rolar** atende efeitos e decisões manuais.

Custos e almas só são cobrados na execução e fazem parte de uma transação: falha, timeout ou cancelamento do host físico restaura integralmente o snapshot. Resoluções de resistência e derrotados ficam numa fila não bloqueante, permitindo continuar usando o painel.

Magias com dano confirmado usam dados físicos. Profanar maximiza apenas grupos marcados como Trevas cujos alvos tenham sido confirmados dentro da área naquele preparo, sem criar dados que seriam ignorados. Magias marcadas `automation: reference` usam as variáveis declaradas pelo jogador e exibem o resumo operacional, sem inventar regras ausentes.

## Estado e isolamento

O estado usa `stateSchemaVersion: 2`, migra saves do schema 1 e mantém o envelope obrigatório `characterId: "spentar"`. Saves de outro personagem e saves sem identidade são recusados. Fim da cena remove Profanar, conexão, efeitos, PV e PM temporários; almas permanecem até `Fim do dia`. Dados físicos são identificados pelo personagem e pelo GUID do painel.

## Pendências antes da publicação

- Conferir no TTS todas as páginas, estados, cores e tamanhos.
- Confirmar os aprimoramentos das magias marcadas para referência.
- Executar a matriz de Profanar, almas, resistências, Necropotência e rollback.
- Validar Spentar e Corvan simultaneamente sem estado, helper ou dados cruzados.
- Somente então habilitar produção e publicar `spentar-v0.1.0` estável.

## Candidato de performance

A branch codex/spentar-performance acrescenta o bootstrap 1.0.4 e o protocolo de atributos em lote. O runtime agrupa renderizações no próximo frame, atualiza páginas ocultas ao abri-las e reaproveita planos de prévia sem copiar o histórico de Desfazer. Snapshots continuam independentes, e a indicação de rolagem é enviada antes de criar dados físicos.

O objeto de teste se chama Spentar_Console_v0.1.0-performance-test.json. A versão permanece de desenvolvimento e a publicação continua desabilitada. Runtimes novos também funcionam com o protocolo individual de bootstraps antigos. Consulte [benchmark offline](../../docs/benchmarks/runtime-performance.md) para método, resultados e limites.

### Candidato de startup com bootstrap 1.0.5

Reutiliza a UI restaurada quando equivalente, anuncia o auxiliar salvo e evita importação duplicada de estado. O arquivo `Spentar_Console_v0.1.0-performance-test.json` substitui o candidato anterior em Saved Objects; reinserir o objeto na mesa antes de salvar e reabrir. [Método do benchmark de startup](../../docs/benchmarks/startup-performance.md).
