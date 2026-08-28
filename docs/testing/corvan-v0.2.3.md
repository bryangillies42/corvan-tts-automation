# Teste manual do Corvan — v0.2.3

Este roteiro valida o candidato `Corvan_Duras_Console_v0.2.3-test.json` antes de criar a tag ou publicar a release.

## RD e regressão funcional

1. Importe o objeto e confirme `v0.2.3`, RD `10` e o texto `RD 5 + 5 = 10`.
2. Ative Duelo +2 e +3 e confirme RD `12` e `13`; encerre a cena e confirme o retorno a `10`.
3. Faça ao menos uma rolagem, altere PV/PM, use Desfazer e recarregue a mesa. Estado, dados e controles devem continuar funcionais.
4. Em uma cópia com Corvan v0.2.2, use Refresh e confirme que GUID, posição, rotação, escala, PV/PM gastos, efeitos e offset dos dados são preservados.

## Layout — regressões históricas

1. Confirme que a prancha física aparece sem imagem branca, textura antiga em cache, borda dupla ou camada visual deslocada.
2. Confira o canvas físico completo em `1870x841`, com o painel opaco centralizado em `1700x750`; moldura e controles devem usar a mesma posição, rotação e escala.
3. Confirme que os controles estão na face superior, não atravessam a malha, não ficam invertidos e continuam clicáveis; a camada decorativa não pode capturar cliques.
4. Inspecione cabeçalho, armas, cálculos, poderes, perícias, rodapé e configurações. Nenhum texto pode cortar, sobrepor outro elemento ou escapar dos cards.
5. Arraste o objeto, abra e feche configurações, salve e recarregue a mesa. O layout deve permanecer alinhado e interativo em todas as etapas.

O candidato só está aceito se todas as etapas passarem e o console do TTS permanecer sem erros Lua.
