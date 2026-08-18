# Teste manual multi-personagem — v0.2.1

## Pré-condições

- A revisão que contém `fixtures/characters/arcane-test/assets/panel-board.png`
  precisa estar disponível no branch `main`, pois o TTS baixa o asset pela URL
  raw incorporada pelo build.
- Use uma sala nova com scripting e acesso ao GitHub habilitados.
- Importe os arquivos gerados pelo mesmo commit:
  - `dist/corvan/Corvan_Duras_Console.json`;
  - `dist/arcane-test/Arcane_Test_Console.json`.

## Roteiro

1. Importe primeiro o Corvan e depois o Arcane Test. Confirme que os dois
   painéis e as duas interfaces aparecem com artes diferentes.
2. No Arcane, clique em **CONJURAR**. O foco deve passar de `12/12` para
   `11/12` e as conjurações de `0` para `1`. O Corvan não pode mudar.
3. No Corvan, gaste PV/PM, ative Duelo ou Baluarte e faça uma rolagem de ataque
   e uma de dano. O foco e as conjurações do Arcane devem permanecer `11` e `1`.
4. Clique em **LIMPAR DADOS** no Corvan. Somente os dados criados pelo Corvan
   devem desaparecer. O Arcane e seu estado devem continuar intactos.
5. Use **DESFAZER** no Corvan. Confirme que somente o estado do Corvan volta.
6. Clique em **REINICIAR** no Arcane. Ele deve voltar a `12/12` e `0`; PV, PM,
   efeitos e dados do Corvan não podem mudar.
7. Salve e recarregue a sala. Confirme que cada painel recupera seu próprio
   estado e que nenhum deles assume o helper ou a interface do outro.
8. Clique em **REFRESH** no Arcane. Como a fixture não possui release pública,
   a atualização deve falhar com segurança e preservar `12/12` e `0`.
9. Clique em **REFRESH** no Corvan. Enquanto a v0.2.1 não for estável, ele não
   deve instalar uma pre-release automaticamente nem afetar o Arcane.

## Evidências a registrar

- Screenshot dos dois painéis carregados na mesma mesa.
- Resultado do passo 3 com um dado do Corvan visível.
- Estado de ambos antes e depois de limpar, desfazer e reiniciar.
- Mensagens apresentadas pelos dois Refreshes.
- `Games > Chat` ou o console do TTS caso apareça qualquer erro de script.

## Gate de release estável

Depois que este roteiro passar, altere o perfil do Corvan para
`prerelease: false` antes de criar a tag `v0.2.1`. A primeira publicação dessa
tag deve ser a stable; o workflow não promove automaticamente uma release já
publicada como pre-release.

O teste final do Refresh de um Saved Object Corvan v0.2.0 distribuído só pode
acontecer quando a v0.2.1 estiver no canal estável `/releases/latest`. Faça essa
publicação como canário controlado e mantenha o retorno do Latest para v0.2.0
como plano de rollback operacional.
