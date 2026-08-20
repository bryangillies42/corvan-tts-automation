# Teste manual do Corvan — v0.2.2

Este roteiro valida a atualização da arma do Corvan sem publicar uma release. Use o Saved Object de teste versionado `Corvan_Duras_Console_v0.2.2-test.json`; não crie a tag `v0.2.2` nem publique a release antes de concluir todos os itens abaixo.

## Preparação

1. Abra uma sala de teste do Tabletop Simulator com scripting habilitado.
2. Importe o Saved Object de teste da pasta `Saves/Saved Objects` e confirme que o painel mostra `v0.2.2`.
3. Confirme que o objeto pode ser selecionado, arrastado e solto em outra posição do board.
4. Confira a arma ativa: **Espada Maculada pela Ira**, ataque `+13`, dano `2d8+10` e crítico `18–20/x2`.
5. Mantenha o console do TTS aberto. Qualquer erro Lua, imagem branca ou travamento reprova o teste.

## Rolagens e efeitos

1. Role **Dano** e confirme que dois d8 físicos são lançados, o total usa `2d8+10` e o chat destaca somente o nome e o resultado.
2. Role ataques até obter um resultado natural entre 18 e 20. Confirme a indicação vermelha `CRÍTICO`, sem colchetes expostos ou desaparecimento do chat.
3. Confirme a ameaça e role **Crítico**: quatro d8 físicos, fórmula `4d8+10` e bônus fixo somado uma única vez.
4. Ative **Duelo +2** e repita dano e crítico. As fórmulas devem ser `2d8+12` e `4d8+12`.
5. Evolua para **Duelo +3** e repita. As fórmulas devem ser `2d8+13` e `4d8+13`.
6. Encerre a cena para remover Duelo. Ative **Combate Defensivo**, role ataque e confirme ataque `+11` e Defesa `+5`; o dano permanece `2d8+10`.
7. Alterne para o escudo e volte para a espada. Não deve surgir uma terceira arma nem mudar o estado das demais funções.

## Dados, Undo e persistência

1. Após uma rolagem, use **Limpar Dados** e confirme que apenas os dados desse painel desaparecem. O último resultado deve permanecer.
2. Gaste PV e PM, ative Duelo e outro efeito e altere a posição dos dados nas configurações.
3. Use **Desfazer** depois de uma mutação e confirme que o estado anterior volta sem apagar, recriar ou rerrolar dados físicos.
4. Salve a mesa, recarregue-a e confirme PV/PM gastos, efeitos, preferência, último resultado e posição dos dados.
5. Arraste novamente o objeto após o reload e faça outra rolagem; os dados devem nascer relativos à nova posição.
6. Encerre turno e cena e confirme que somente os efeitos temporários correspondentes são limpos.

## Compatibilidade e aceite

1. Em uma cópia de uma mesa que contenha Corvan v0.2.1, gaste PV/PM, ative efeitos e anote o offset dos dados antes do update.
2. Quando um artefato de Refresh de teste estiver disponível, atualize essa cópia para v0.2.2 e confirme que estado, GUID, posição, rotação e escala permanecem intactos.
3. Simule indisponibilidade de rede durante **Refresh** e confirme que a versão funcional anterior é preservada.
4. Repita Limpar Dados, Undo, save/load e uma rolagem depois do Refresh.

A v0.2.2 está aceita somente se todas as etapas passarem, o console permanecer sem erros e o comportamento anterior do Corvan continuar funcional. Até esse aceite, o artefato é apenas de teste e não deve virar tag ou release estável.
