# Benchmark offline de runtime

O benchmark executa os fontes Lua reais compilados de duas revisões no MoonSharp, com painel e helper em ambientes separados. Não inicia o TTS, não controla sua interface, não conecta à API do jogo e não usa rede para simular ações. A DLL do interpretador é lida da instalação local.

## Método

- Baseline Corvan: `a8508135171fa42c2fef73d03e73060d2c342250`, já com as primeiras otimizações de inicialização da v0.2.5.
- Baseline Spentar: `8f6d94128b39731883995be69a38555d63bc100f`, protótipo do PR #3 com bootstrap 1.0.2.
- Candidatos: bootstrap 1.0.4 e comunicação em lote; Corvan com exportação de estado em uma cópia; Spentar com agrupamento de renderizações, páginas ocultas adiadas, cache de planos e snapshots sem cópia descartável do histórico de Undo.
- 25 ciclos de aquecimento, seguidos de ciclos idênticos antes/depois. O relatório registra o número de ciclos, os commits e os hashes dos fontes compilados.
- Compara o estado exportado e todos os atributos dinâmicos visíveis depois de cada ação ou lote de eventos. Páginas ocultas do Spentar são conferidas ao navegar para elas. As exportações usadas exclusivamente nessa comparação não entram na contagem de cópias.
- `copyTables` conta alocações de tabelas dentro de `Core.deepCopy`, instrumentadas em memória. Não representa toda a memória alocada pelo jogo ou pelo Lua.
- Caches aquecidos e histórico de Undo preenchido são intencionais: medem uso repetido. O smoke de inicialização separado cobre a abertura sem esses caches.

Os resultados são contagens determinísticas de trabalho, não tempos de CPU, FPS, tráfego de rede em bytes ou porcentagem de aceleração do TTS. A quantidade de atributos desejados pode continuar igual dentro de um lote; o ganho principal é atravessar a comunicação entre objetos uma vez e escrever no engine somente valores alterados.

## Resultados observados

Valores por ação ou sequência, com estado e interface visível equivalentes:

| Caso | Operação medida | Antes | Depois | Redução |
| --- | --- | ---: | ---: | ---: |
| Corvan: renderização após ajuste de PV | Chamadas de UI ao painel | 37 | 1 | 97,30% |
| Corvan: alternar gasto automático | Escritas de atributos | 39 | 1 | 97,44% |
| Corvan: alternar gasto automático | Reconstruções de XML | 1 | 0 | 100% |
| Corvan: exportar estado inicial do cenário | Tabelas alocadas por cópias profundas | 8 | 5 | 37,50% |
| Spentar: ajustar recursos | Chamadas de UI ao painel | 103 | 1 | 99,03% |
| Spentar: ajustar recursos com Undo preenchido | Tabelas alocadas por cópias profundas | 4.098 | 614 | 85,02% |
| Spentar: quatro ajustes no mesmo frame | Renderizações | 4 | 1 | 75% |
| Spentar: quatro ajustes no mesmo frame | Chamadas de UI ao painel | 412 | 1 | 99,76% |

Relatórios completos: `corvan.json` e `spentar.json` nesta pasta. Os resultados do Spentar incluem também as melhorias de bootstrap que ainda não estavam na sua branch de desenvolvimento.

## Reproduzir

```powershell
npm run benchmark:lua -- -Iterations 100 -ReportPath docs/benchmarks/corvan.json

# Executado a partir do checkout do Corvan, apontando para o checkout do Spentar:
pwsh -NoProfile -File scripts/benchmark-runtime.ps1 `
  -CharacterId spentar -BaselineRef 8f6d941 `
  -CandidateRoot C:/caminho/checkout-spentar `
  -Iterations 100 -ReportPath docs/benchmarks/spentar.json
```

Os checkouts temporários usados pelo benchmark ficam no diretório temporário do sistema, fora do repositório. Nenhuma dependência é instalada. Uma divergência funcional interrompe o benchmark, em vez de produzir um relatório de sucesso.

## Compatibilidade

O protocolo em lote é anunciado pelo bootstrap. Runtimes novos usam chamadas individuais quando o bootstrap é antigo ou recusa o lote. Corvan mantém a atualização por XML do toggle nesse caminho legado. A recuperação da UI força a montagem e reaplica os valores atuais; eventos de campos nativos invalidam o cache do respectivo controle.

No Spentar, a indicação de rolagem continua sendo enviada antes de criar dados físicos; a persistência continua síncrona. Regras de combate, custos, física, timeouts e limpeza de dados não foram acelerados por alteração de comportamento.
