# Teste manual do Corvan — v0.2.5

Candidato: `Corvan_Duras_Console_v0.2.5-test.json`, com runtime v0.2.5 e bootstrap 1.0.3. Não cria tag nem publica release. O painel novo nasce com recursos padrão; mantenha o painel/salvamento antigo para comparação e consulta do estado.

## Inicialização e desempenho

1. Em uma cópia descartável da mesa, importe o objeto de teste. Confirme v0.2.5, PV 78, PM 21, Defesa 27 e RD 10.
2. Salve essa mesa e abra-a novamente. Compare os segundos iniciais com uma cópia equivalente contendo somente o painel v0.2.4. Use a mesma mesa, quantidade de objetos e condições de rede; não mantenha os dois painéis na comparação de desempenho.
3. Repita três vezes por versão e anote tempo até o painel responder e presença de travamentos. Faça também uma comparação com outro jogador entrando na sessão já aberta: esse caminho precisa de observação no TTS e não é medido pelo simulador Lua.
4. Confirme que a moldura não pisca nem fica branca, os controles respondem e nenhum helper extra aparece após reabrir a mesa.
5. Teste sem rede, com as texturas já em cache: o painel e as regras devem continuar funcionando; uma imagem indisponível deve manter o fallback físico.

## Estado e controles

1. Gaste PV/PM, ative Duelo/Baluarte, altere o offset dos dados e desligue o gasto automático. Salve e reabra; confirme valores, efeitos, calibração e preferência.
2. Repita com gasto automático ligado. Ajuste PV/PM e alterne configurações rapidamente; o próximo frame deve mostrar o estado mais recente.
3. Valide Desfazer, fim de turno, fim de cena e Reset. Use o [roteiro v0.2.4](corvan-v0.2.4.md) para números, ataque, dano, crítico, resistências e Fortificação.
4. Em uma mesa descartável com dois painéis, confirme isolamento de dados e limpeza. A cópia não pode assumir o helper nem os dados do original.
5. Se o botão CARREGAR PAINEL aparecer por falha de UI, confirme que recupera a interface com os valores atuais.

## Compatibilidade de atualização

O Refresh consulta a última release publicada, não esta branch. Antes da publicação, a compatibilidade com o bootstrap congelado 1.0.2 é verificada pelo smoke Lua. Após disponibilizar a release, atualize uma cópia do painel antigo e confirme preservação de recursos, efeitos, preferência, posição, rotação, escala e GUID. O Refresh não instala o bootstrap 1.0.3; o objeto novo é necessário para receber todas as otimizações.

## Evidência automatizada

`npm test` valida contratos, build, regras e release. `npm run test:lua` usa o MoonSharp instalado com o TTS e inclui `tests/lua/startup-performance.lua`, que executa bootstrap e runtime reais em ambientes separados com filas de frames, timers e HTTP.

Na abertura simulada com helper saudável e XML persistido atual: **1 montagem de XML, 1 requisição de imagem, 1 registro do helper, nenhuma recarga e 2 renderizações em frames distintos**. O teste cobre as duas ordens de carregamento, preferência ligada/desligada, registros repetidos com HTTP pendente, recuperação forçada, callbacks obsoletos, falha transitória de atributo, rede indisponível e bootstrap legado. Esses contadores demonstram a remoção de trabalho redundante; não representam uma medição de FPS ou segundos no Unity.

O Spentar tem implementação de desenvolvimento na branch `codex/spentar-v0.1.0` (PR #3), ainda não integrada ao main. Ele usa o mesmo `shared/bootstrap.lua` e recebe as otimizações compartilhadas ao incorporar esta alteração. Esta versão não publica nem habilita a release do Spentar.

Também foi validada uma cópia temporária do commit Spentar `8f6d941`, substituindo somente o bootstrap pelo 1.0.3 desta alteração e ajustando as expectativas dos testes para essa versão e a deduplicação: **105 testes Node aprovados**, além do smoke MoonSharp com Corvan, Arcane e Spentar. A branch e o PR originais do Spentar não foram alterados.
