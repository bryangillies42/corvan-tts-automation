# Startup: bootstrap 1.0.5

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
