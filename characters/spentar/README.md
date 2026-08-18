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
- Necropotência: conexão dobrada, +2 PM temporários por inimigo derrotado com Necromancia, até 7 por cena.
- O cajado concede 10 PV temporários quando ao menos um inimigo falha na resistência.

CD 22/24 e o acúmulo dos PV temporários são regras explícitas desta mesa (`houseRules` em `character.json`), não alegações sobre a regra oficial.

## Páginas e fluxo

O painel possui Combate, Conjuração, Necromancia, Ficha e Ajustes. O resolvedor guarda seleção, alvos, almas liberadas e aprimoramentos por magia. Custos e almas são cobrados em uma transação: falha do host físico restaura integralmente o snapshot.

Magias com dano confirmado usam dados físicos; Profanar resolve os grupos maximizados sem criar dados desnecessários. Magias marcadas `automation: reference` cobram o custo-base confirmado, exibem o resumo operacional e aguardam a resolução informada pelo jogador.

## Estado e isolamento

O estado usa `stateSchemaVersion: 1` e o envelope obrigatório `characterId: "spentar"`. Saves de outro personagem e saves sem identidade são recusados. Fim da cena remove Profanar, conexão, efeitos, PV e PM temporários; almas permanecem até `Fim do dia`. Dados físicos são identificados pelo personagem e pelo GUID do painel.

## Pendências antes da publicação

- Conferir no TTS todas as páginas, estados, cores e tamanhos.
- Confirmar os aprimoramentos das magias marcadas para referência.
- Executar a matriz de Profanar, almas, resistências, Necropotência e rollback.
- Validar Spentar e Corvan simultaneamente sem estado, helper ou dados cruzados.
- Somente então habilitar produção e publicar `spentar-v0.1.0` estável.
