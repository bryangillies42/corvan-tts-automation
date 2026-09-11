# Startup do Corvan

## Rodada bootstrap 1.0.6

Esta rodada compara o candidato compacto com `45cd049c9894cb350e922a39a0d4dcaed624afd2`, que já contém o bootstrap 1.0.5 e as deduplicações anteriores.

- O build remove comentários e whitespace dispensável dos artefatos Lua, preservando strings longas e curtas, e remove comentários/espaços entre tags da XML.
- O save deixa de repetir `runtimeSource` e `uiXml` quando são exatamente os seeds já embutidos. Uma versão baixada diferente continua persistida integralmente, preservando cópia, uso offline, update e rollback.
- Saves antigos com o estado completo continuam aceitos sem migração manual.

| Medida | Bootstrap 1.0.5 | Bootstrap 1.0.6 | Redução |
| --- | ---: | ---: | ---: |
| Saved Object | 277.918 bytes | 215.608 bytes | 22,42% |
| Script do painel | 229.633 caracteres | 180.113 caracteres | 21,56% |
| Runtime do helper | 130.494 caracteres | 101.761 caracteres | 22,02% |
| XML | 32.250 caracteres | 25.019 caracteres | 22,42% |
| Estado do painel após salvar sessão | 173.699 caracteres | 2.364 caracteres | 98,64% |
| Save isolado estimado | 619.754 bytes | 339.591 bytes | 45,21% |

O save estimado foi obtido substituindo, somente em memória, os artefatos e o estado do Corvan no save isolado usado na medição real. Não inclui Spentar. O TTS ainda precisa compilar painel e helper e montar 187 elementos da UI; a redução de bytes não equivale automaticamente à mesma redução em segundos.

No benchmark MoonSharp de 20 cargas por cenário, a equivalência funcional e todos os contadores de operações permaneceram iguais, com SHA-256 e reload em zero. As medianas do harness caíram:

| Cenário | 1.0.5 → 1.0.6 | Redução |
| --- | ---: | ---: |
| Painel primeiro / UI restaurada | 86,52 → 62,76 ms | 27,46% |
| Helper primeiro / UI restaurada | 73,02 → 60,82 ms | 16,71% |
| UI dinâmica restaurada | 95,72 → 83,54 ms | 12,72% |
| UI ausente | 67,64 → 56,58 ms | 16,36% |
| GUID antigo / 1.000 objetos | 71,78 → 57,18 ms | 20,35% |
| Busca sem anúncio / 1.000 objetos | 78,44 → 67,02 ms | 14,56% |

Esses tempos incluem compilação dos fontes Lua no MoonSharp local, mas continuam excluindo layout Unity, assets e I/O do TTS.

## Rodada bootstrap 1.0.5

Esta rodada compara com os objetos de performance anteriores: Corvan em `6dbc38e7d9047c0f7fcd259288268555a75bb9fa` e Spentar em `f779488f7abe856d8db8b05a328d99feaf1e3719`, ambos com bootstrap 1.0.4.

## Alterações

- Aguardar a UI restaurada e adotá-la quando sua estrutura e atributos estáticos correspondem ao template. Atributos dinâmicos efetivamente escritos são registrados no save e reaplicados pelo runtime. Diferenças de layout, UI ausente, falha de comparação ou recuperação explícita levam à reconstrução.
- Comparar os IDs com conjuntos, sem procurar cada ID no XML inteiro.
- Vincular o runtime uma vez e aproveitar a restauração atômica confirmada; runtimes sem essa capacidade continuam usando a importação legada.
- Configurar o auxiliar uma vez por instância e evitar regravar suas notas durante a vinculação moderna.
- Dar 0,25 s de tempo agendado para auxiliares salvos se anunciarem; verificar GUID e propriedade antes de reutilizá-los. Quando ainda é necessário varrer a mesa, filtrar notas pelo GUID antes de decodificar JSON.

## Benchmark

`startup-corvan.json` e `startup-spentar.json` registram os commits, hashes e resultados. O harness executa bootstrap e runtime reais em ambientes Lua separados no MoonSharp local. Não abre o TTS nem controla a interface do computador.

Cada cenário recria os ambientes: painel primeiro, auxiliar primeiro, UI salva com atributos dinâmicos diferentes, UI ausente, GUID antigo com 1.000 objetos e busca de fallback sem anúncio com 1.000 objetos. Dois pares de aquecimento são descartados por cenário, e a ordem antes/depois alterna para reduzir viés. Estado e atributos dinâmicos da UI de referência são comparados após cada carga.

Os contadores representam operações dos scripts. `luaHarnessMs` é o tempo acumulado do harness, incluindo preparação dos mocks, compilação Lua, inicialização, JSON simulado e instrumentação. `luaHarnessMedianMs` e `luaHarnessP95Ms` são a mediana e o percentil 95 por carga. O relógio é monotônico, mas as esperas agendadas usam tempo simulado. O custo real do `setXml`, layout/renderização Unity, imagens, disco, rede e inicialização do jogo não é medido. Portanto, esses tempos não são segundos de abertura do TTS; podem até aumentar apesar de menos chamadas ao engine.

`copyTables` conta apenas tabelas criadas por `Core.deepCopy`. `helperConfigurations` conta gravações de notas do auxiliar (incluindo as feitas pelo runtime legado). As exportações usadas só para comparar equivalência ficam fora das medições. SHA-256 deve permanecer em zero em todos os cenários de startup.

```powershell
pwsh -NoProfile -File scripts/benchmark-runtime.ps1 -Startup -Iterations 20 -BaselineRef 6dbc38e -ReportPath docs/benchmarks/startup-corvan.json
pwsh -NoProfile -File scripts/benchmark-runtime.ps1 -Startup -Iterations 20 -CharacterId spentar -BaselineRef f779488 -CandidateRoot C:/caminho/checkout-spentar -ReportPath docs/benchmarks/startup-spentar.json
```

## Teste manual necessário

Substituir o arquivo em Saved Objects não altera um painel já inserido em um save. Insira novamente o candidato atualizado, gaste recursos/altere opções, salve em outro slot e reabra. Compare a travada e o tempo até responder usando a mesma mesa. O novo bootstrap não é instalado pelo botão Update. Também confira troca de páginas, Undo, rolagens, estado persistido e recuperação manual da UI.

## Resultados: 20 cargas por cenário

Em ambos os personagens, a UI equivalente passou de 1 reconstrução por carga para 0, e a importação adicional de estado passou de 1 para 0. No Corvan, renderizações passaram de 2 para 1 e tabelas alocadas por deepCopy de 36 para 16 (55,56% menos). No Spentar, as renderizações permaneceram em 1 e as tabelas passaram de 207 para 121 (41,55% menos). SHA-256 permaneceu em zero antes e depois.

Tempos medianos do **harness Lua**, em milissegundos, pelo percentil empírico de posto mais próximo:

| Cenário | Corvan antes → depois | Redução | Spentar antes → depois | Redução |
| --- | ---: | ---: | ---: | ---: |
| Painel primeiro / UI equivalente | 124,22 → 107,81 | 13,21% | 123,37 → 119,89 | 2,82% |
| Auxiliar primeiro / UI equivalente | 109,54 → 103,96 | 5,09% | 147,02 → 131,41 | 10,62% |
| UI salva com valores dinâmicos | 113,81 → 139,42 | -22,51% | 128,41 → 152,04 | -18,41% |
| UI ausente | 112,74 → 108,53 | 3,73% | 116,83 → 111,50 | 4,57% |
| GUID antigo / 1.000 objetos | 282,07 → 95,24 | 66,24% | 553,45 → 115,04 | 79,21% |
| Busca sem anúncio / 1.000 objetos | 303,66 → 110,17 | 63,72% | 592,72 → 129,07 | 78,22% |

A comparação estrutural de uma UI com valores dinâmicos aumenta o trabalho Lua nesse cenário (+22,51% no Corvan e +18,41% no Spentar), embora elimine a chamada de reconstrução ao engine. Não há evidência offline suficiente para afirmar que essa troca reduz o tempo total do TTS. O maior ganho do harness aparece na descoberta com GUID antigo/busca por objetos. A validação manual da travada continua necessária.
