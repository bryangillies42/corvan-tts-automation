# Spentar — scaffold de personagem

`characterId`: `spentar`

Este diretório registra apenas a identidade e o checklist de descoberta do futuro personagem Spentar. Ele não contém ficha, números, atributos, regras, runtime funcional, UI publicável ou Saved Object. O perfil permanece `status: scaffold` e `productionEnabled: false`.

## Regra de segurança

Spentar não é publicável nesta fase. O workflow deve recusar qualquer tag `spentar-vX.Y.Z` enquanto a entrada do registry estiver desabilitada. Não crie `character.json`, runtime, manifesto ou Saved Object com valores fictícios para “preencher” o scaffold. Quando faltar uma informação, registre a pendência.

Uma release só poderá ser ativada depois que a ficha real, as referências visuais, a implementação, as migrações e os testes forem revisados. A tag futura será `spentar-vX.Y.Z` e usará `--latest=false`, sem interferir no canal legado do Corvan.

## Checklist de identidade

- [ ] Nome de exibição confirmado.
- [ ] Nome curto confirmado.
- [ ] `characterId` validado como `spentar`.
- [ ] Conceito, origem e classe confirmados a partir da ficha real.
- [ ] Nível e demais dados de progressão confirmados.
- [ ] Dimensões, proporção e raiz da UI escolhidas.
- [ ] Nome do Saved Object, runtime, manifesto e assets definidos.
- [ ] Marker exclusivo e versão mínima do bootstrap definidos.
- [ ] GM Notes do painel/helper contendo `characterId` definidas.
- [ ] Política de atualização, cache e rollback validada.

## Checklist da ficha e das regras

Preencher somente com dados conferidos na ficha e nas referências aprovadas:

- [ ] Recursos: nomes, máximos, limites, custos, recuperação e ajuste manual.
- [ ] Ações: ataques, danos, críticos, testes, alvos, alcance e efeitos.
- [ ] Magias: lista, custos, CDs, componentes, alvos, duração e rolagens.
- [ ] Necromancia: poderes, condições, custos, duração e interações.
- [ ] Perícias e resistências: nomes, modificadores e classificação.
- [ ] Cálculos derivados: precedência, bônus, penalidades, arredondamento e críticos.
- [ ] Estados temporários: ativação, expiração, renovação e conflitos.
- [ ] Mensagens de chat: conteúdo simples, destaques e textos críticos.
- [ ] Regras de rolagem física: quantidade de dados, faces, força de lançamento e posse.

## Checklist técnico

- [ ] Adaptador independente do Corvan, usando somente as APIs do core.
- [ ] `stateSchemaVersion` e estado envelopado com `characterId`.
- [ ] Estado inicial e migrações documentados.
- [ ] Estado de outro personagem recusado.
- [ ] Rollback preserva o runtime e o estado anteriores.
- [ ] UI XML validada sem assumir a geometria do Corvan.
- [ ] Identidade presente no manifesto, health check, runtimeReady, helper e dados físicos.
- [ ] Artefatos com nomes inequívocos: `spentar-runtime.lua`, `spentar-manifest.json` e `<Nome>_Console.json`.
- [ ] Build determinístico, smoke Lua e testes de isolamento concluídos.

## Checklist de arte

- [ ] Arte principal aprovada e hospedada.
- [ ] Assets de UI e fallback físico aprovados.
- [ ] URLs, tamanhos e hashes verificados no manifesto.
- [ ] Escala, rotação, hitboxes e proporção testadas no TTS.
- [ ] Fallback offline e comportamento sem textura remota testados.

## Ativação futura

Quando todas as pendências estiverem resolvidas:

1. Criar as fontes do personagem a partir de `templates/character/`.
2. Completar o perfil no registry com uma versão SemVer real, `status: active` e `productionEnabled: false`.
3. Executar build individual, build conjunto, fixtures e smoke Lua.
4. Importar o objeto e testar Spentar e Corvan na mesma mesa.
5. Ativar `productionEnabled` somente depois da revisão e dos testes reais.
6. Publicar a primeira tag `spentar-vX.Y.Z` como release independente, sempre com `--latest=false`.

Até esse ponto, este README é a única definição deliberada de Spentar no repositório.
