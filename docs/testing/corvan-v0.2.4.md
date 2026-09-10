# Teste manual do Corvan — v0.2.4

Este roteiro valida o candidato `Corvan_Duras_Console_v0.2.4-test.json` antes de criar a tag, publicar a release ou fazer merge.

## Valores da ficha

1. Importe o objeto e confirme a versão `v0.2.4`, PV `78`, PM `21`, Defesa `27` e RD `10`.
2. Confirme **Escudo Pesado Reforçado**: ataque `+12`, dano `1d6+5` e Defesa `+5`.
3. Role Fortitude, Reflexos e Vontade e confirme modificadores `+18`, `+10` e `+11`.
4. Ative Combate Defensivo e Baluarte para conferir Defesa `32`, `34` e `36`; isoladamente, Baluarte deve resultar em `29` ou `31`.
5. Ataque com o escudo e confirme Defesa `22` e resistências `+13/+5/+6` até o próximo turno; depois confirme a restauração de `27` e `+18/+10/+11`.

## Fortificação 25%

1. Clique em **FORTIFICAÇÃO 25%** e confirme que um d4 físico é lançado sobre o painel.
2. Em resultado `1`, confirme **SUCESSO** no painel e no chat; em `2`, `3` ou `4`, confirme **FALHA**.
3. Confirme que a rolagem não gasta PV/PM, não altera poderes, não cria efeito persistente e não remove uma ameaça de crítico pendente.
4. Durante uma rolagem, tente usar Fortificação novamente e confirme que o painel pede para aguardar.
5. Remova o dado durante a rolagem ou force um timeout e confirme a falha segura sem anúncio público incorreto.
6. Use **LIMPAR DADOS** e confirme que somente o d4 pertencente ao painel é removido.

## Refresh e aceite

1. Em uma cópia do objeto v0.2.3, gaste PV/PM, ative efeitos e deixe uma ameaça de crítico pendente.
2. Faça Refresh para v0.2.4 e confirme que recursos gastos, efeitos, preferência, resultado, dados, GUID, posição, rotação, escala e offset são preservados.
3. Repita as rolagens principais de ataque, dano e crítico para confirmar que os valores ofensivos não mudaram.

A versão está aceita quando todas as etapas passarem sem erros no console do Tabletop Simulator.
