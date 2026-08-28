# Teste manual — Spentar v0.1.0

Este roteiro é o gate para liberar a primeira release do Spentar. Enquanto ele
não estiver integralmente aprovado, o registry deve manter
`productionEnabled: false` e `prerelease: true`. A tag `spentar-v0.1.0` não deve
ser criada durante os testes: releases publicadas são imutáveis e a primeira
publicação dessa tag será a estável.

## Preparação do objeto de teste

1. Obtenha o SHA completo de 40 caracteres do commit remoto que contém os
   assets do Spentar.
2. Construa os artefatos apontando para esse commit:

   ```powershell
   npm run build:character -- --character spentar --commit <SHA-40>
   npm run verify:tts-assets -- --saved-object dist/spentar/Spentar_Console.json
   ```

3. Confirme que o verificador informou `OK` para todas as imagens. Não importe
   o objeto se houver URL em `main`, HTTP diferente de 200, MIME inesperado,
   magic bytes incompatíveis ou dimensões inválidas.
4. Copie `dist/spentar/Spentar_Console.json` para a pasta `Saved Objects` do
   perfil do TTS e abra uma sala nova com scripting e acesso ao GitHub.
5. Importe também `dist/corvan/Corvan_Duras_Console.json` gerado ou preservado
   na v0.2.2. Registre screenshots, mensagens de chat e erros do console.

O botão **LIMPAR DADOS** fica permanentemente no rodapé. Ele remove somente
dados cujo dono é o painel Spentar. Durante uma rolagem, muda para
**CANCELAR E LIMPAR**, restaura a transação e não toca em outro personagem.

## Interface, isolamento e persistência

1. Confirme que a arte física e as cinco páginas do Spentar carregam sem área
   branca, imagem `UNKNOWN`, elementos cortados ou UI do Corvan sobreposta.
2. Navegue por Combate, Magias, Necromancia, Ficha e Ajustes. A barra de
   recursos e o último resultado devem permanecer coerentes em todas as páginas.
3. Ajuste PV, PV temporários, PM, PM temporários, almas e preferências. Edite
   e salve preparos diferentes para duas magias. Salve e recarregue a sala: a
   página aberta, os preparos e uma resolução pendente devem voltar.
4. Faça uma rolagem em cada objeto. Limpar, desfazer, terminar turno, terminar
   cena e reiniciar um objeto não pode mudar recursos, dados, helper ou UI do
   outro.
5. Com uma rolagem em andamento, tente clicar novamente e usar Refresh. Não
   pode haver cobrança duplicada nem troca parcial de runtime.

## Bancada de preparos e fórmulas

Execute os casos abaixo com gasto automático ligado e desligado. Confira a
fórmula visível, o chat, os dados físicos e o estado final.

1. **Editar sem conjurar:** em Combate, clique em **EDITAR** no Infligir
   Ferimentos. Digite custo, alvos, quantidade e faces dos dados, bônus, almas,
   efeito e observação. Marque Trevas e a confirmação de alvos em Profanar.
   **SALVAR PREPARO** deve memorizar os valores sem gastar PM, consumir almas ou
   criar dados. Troque de magia, volte e confirme que cada magia reteve seu
   próprio preparo.
2. **Validação dos campos:** tente vazio, texto, decimal, negativo e valor
   acima dos limites nos campos numéricos. O último valor válido deve permanecer;
   o erro deve ser privado e nenhum recurso, Undo ou dado deve mudar.
3. **Rolar último:** volte a Combate e clique em **ROLAR ÚLTIMO**. O objeto deve
   usar exatamente o preparo salvo, cobrar uma vez e criar um único grupo de
   dados. Clique duas vezes rapidamente: não pode haver cobrança ou grupo
   duplicado. **RESTAURAR PADRÃO** muda somente o rascunho; **APLICAR SEM ROLAR**
   executa apenas os efeitos declarados para a magia.
4. **Resolução não bloqueante:** depois de uma rolagem, deixe a faixa de
   resolução pendente aberta. Navegue, edite outra magia e role uma invocação.
   Informe falhas e derrotados depois; **APLICAR** deve executar as consequências
   uma vez, e **DESCARTAR** deve avançar para a próxima pendência sem desfazer a
   rolagem anterior.
5. **Cancelar e restaurar:** durante Rolando, **CANCELAR E LIMPAR** deve cancelar
   e restaurar PM, PM temporários, almas, preparação e estado, sem afetar Corvan.
6. **Cajado:** confirme CD geral 23 e CD de Necromancia 25 em duas mãos; desligue
   o cajado e confirme 22 e 24.
7. **Profanar granular:** ative Profanar e valide separadamente `6d6+18 = 54`,
   `3d8+9 = 33` e `12d6 = 72` somente quando **ALVOS NO PROFANAR** estiver
   confirmado no preparo correspondente. Desmarque a confirmação e repita: os
   dados devem ser rolados. Dano que não seja de trevas também continua normal.
   Grupos maximizados não devem criar dados físicos ignorados.
8. **Infligir Ferimentos:** com Profanar e seis almas liberadas, confirme
   `24 + 9 + 72 = 105`; sem Profanar, confira os grupos físicos `3d8+9` e
   `12d6`. As seis almas só são consumidas ao rolar ou aplicar, nunca ao editar.
9. **Corpos e invocações:** informe corpos disponíveis sem mortos-vivos ativos e
   confirme que um valor não altera o outro. Teste de zero a seis mortos-vivos,
   de zero a dois espíritos, um ou dois d6 por espírito e um parceiro-cadáver
   textual. Para seis mortos, confirme `6d6+18`; com Profanar confirmado, 54.
10. **Resistência e cajado:** informe zero, um e vários alvos que falharam. Dez
   PV temporários devem ser concedidos por ao menos uma falha e acumular segundo
   a regra da mesa, uma vez por conjuração. Aplicar novamente não pode duplicar.
11. **Almas:** teste captura até 6, tentativa acima do limite, liberação parcial,
   liberação total e tentativa de liberar mais do que existe. Confira +2 de
   Defesa e resistências por alma armazenada.
12. **Necropotência:** consuma primeiro PM temporários, obtenha +2 uma vez por
   conjuração qualificadora com um ou mais derrotados e confirme o teto de 7
   ganhos na cena. Vários derrotados na mesma magia não multiplicam o +2.
13. Percorra Armadura Arcana, Amedrontar, Espírito Balístico, Vitalidade
   Fantasma, Profanar, Salto Dimensional, Rogar Maldição, Raio Arcano e Raio
   Dividido. Para regras ainda não automatizadas, registre custo, dados, efeito e
   observação manualmente e confirme que o objeto não inventa aprimoramentos.

## Ciclo de vida e recuperação

1. **Fim do turno:** deve reiniciar somente comandos limitados por rodada.
2. **Fim da cena:** deve remover Profanar, Conexão, efeitos de cena, PV e PM
   temporários; almas armazenadas devem permanecer.
3. **Fim do dia:** deve limpar as almas mediante confirmação explícita.
4. **Desfazer:** use após gasto, captura/liberação de almas e encerramento de
   cena. Cada ação deve restaurar uma fotografia coerente, sem afetar o Corvan.
5. Desconecte a rede durante uma rolagem física e confirme rollback de PM,
   almas e estado. Depois restabeleça a rede e repita com sucesso.
6. Clique em **Refresh**. Enquanto não existir release estável do Spentar, a
   mensagem esperada é que nenhuma atualização estável foi encontrada, e todo
   o estado deve permanecer intacto.
7. Simule manifesto/runtime indisponível ou incompatível e confirme que o
   runtime anterior continua operante.

## Gate de publicação

A publicação só pode ser preparada quando:

- `npm test`, build conjunto, build individual, smoke MoonSharp e
  `verify:tts-assets` passam;
- todos os passos acima passam numa mesa com Corvan e Spentar juntos;
- não há erro invisível no chat nem falha de imagem depois de várias rolagens;
- evidências do teste e limitações restantes foram registradas.

Depois do aceite, altere o perfil do Spentar para `productionEnabled: true` e
`prerelease: false`, execute novamente todos os gates e só então crie
`spentar-v0.1.0`. A release deve usar `--latest=false`; o Latest global deve
continuar apontando para o Corvan.
