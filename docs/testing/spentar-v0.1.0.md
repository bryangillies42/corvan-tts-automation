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
   na v0.2.1. Registre screenshots, mensagens de chat e erros do console.

## Interface, isolamento e persistência

1. Confirme que a arte física e as cinco páginas do Spentar carregam sem área
   branca, imagem `UNKNOWN`, elementos cortados ou UI do Corvan sobreposta.
2. Navegue por Combate, Conjuração, Necromancia, Ficha e Ajustes. A barra de
   recursos e o último resultado devem permanecer coerentes em todas as páginas.
3. Ajuste PV, PV temporários, PM, PM temporários, almas e preferências; salve e
   recarregue a sala. A página aberta e uma conjuração preparada devem voltar.
4. Faça uma rolagem em cada objeto. Limpar, desfazer, terminar turno, terminar
   cena e reiniciar um objeto não pode mudar recursos, dados, helper ou UI do
   outro.
5. Com uma rolagem em andamento, tente clicar novamente e usar Refresh. Não
   pode haver cobrança duplicada nem troca parcial de runtime.

## Fórmulas e conjuração guiada

Execute os casos abaixo com gasto automático ligado e desligado. Confira o
resumo antes da confirmação, o chat, os dados físicos e o estado final.

1. **Cajado:** confirme CD geral 23 e CD de Necromancia 25 em duas mãos; desligue
   o cajado e confirme 22 e 24.
2. **Profanar:** valide separadamente `6d6+18 = 54`, `3d8+9 = 33` e `12d6 = 72`.
   O sistema não deve criar dados para grupos maximizados. Dano que não seja de
   trevas continua sendo rolado normalmente.
3. **Infligir Ferimentos:** com Profanar e seis almas liberadas, confirme
   `24 + 9 + 72 = 105`; sem Profanar, confira os grupos físicos `3d8+9` e
   `12d6`. As seis almas só são consumidas após confirmar.
4. **Mortos-vivos:** teste de um a seis mortos. Para seis, confirme `6d6+18` e
   o detalhamento de cada ataque; sob Profanar, confirme 54.
5. **Resistência e cajado:** informe zero, um e vários alvos que falharam. Dez
   PV temporários devem ser concedidos por ao menos uma falha e acumular segundo
   a regra da mesa, sem serem concedidos por sucesso de todos os alvos.
6. **Almas:** teste captura até 6, tentativa acima do limite, liberação parcial,
   liberação total e tentativa de liberar mais do que existe. Confira +2 de
   Defesa e resistências por alma armazenada.
7. **Necropotência:** consuma primeiro PM temporários, obtenha +2 após derrotar
   alvo válido e confirme o teto de 7 PM temporários ganhos na cena.
8. Percorra Armadura Arcana, Amedrontar, Espírito Balístico, Vitalidade
   Fantasma, Profanar, Salto Dimensional, Rogar Maldição, Raio Arcano e Raio
   Dividido, incluindo aprimoramentos nos limites do círculo.

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
