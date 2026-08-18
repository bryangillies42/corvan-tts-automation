# Console do Corvan

Este documento concentra o comportamento do produto Corvan. A documentação raiz descreve o monorepo e o contrato multi-personagem; aqui ficam as regras e a compatibilidade que não devem ser inferidas para outros personagens.

## Identidade e artefatos

- `characterId`: `corvan`
- Nome: **Corvan Duras**
- Produto: Console de Combate do Corvan
- Tag estável legada: `vX.Y.Z`
- Descoberta do Refresh: endpoint `/releases/latest`
- `globalLatest`: verdadeiro para releases estáveis do Corvan
- Marker legado do runtime: `CORVAN_RUNTIME`
- Bootstrap mínimo legado: `1.0.2`

Os nomes dos artefatos publicados continuam compatíveis com os objetos já distribuídos:

```text
corvan-runtime.lua
manifest.json
Corvan_Duras_Console.json
```

O Saved Object é importado uma vez no TTS. O botão **Refresh** atualiza o runtime e a UI no helper, sem recarregar a prancha visível e sem alterar GUID, posição, rotação ou escala. O runtime seed incluído no objeto permite continuar usando o painel sem rede; a rede é necessária para procurar e baixar atualizações.

## Estado e migração

O estado do Corvan usa o envelope multi-personagem com `characterId: "corvan"`. O migrador legado aceita o estado plano dos objetos anteriores à identidade multi-personagem e o converte sem restaurar recursos gastos nem apagar efeitos ativos. PV/PM atuais, preferências, resultado, dados físicos, rollback e a posição dos dados devem sobreviver ao Refresh.

Estados com outro `characterId` são recusados. Se manifesto, runtime, marker, health check, tag, tamanho ou SHA não corresponderem ao Corvan, a instalação é abortada e o runtime anterior permanece ativo.

## Comportamento atual

O painel automatiza:

- PV/PM ajustáveis por valor;
- Defesa e RD calculadas;
- Espada Longa e Escudo Pesado;
- rolagens físicas de ataque, dano e crítico;
- poderes e recursos;
- perícias e resistências;
- início do turno, fim da cena, desfazer e limpeza dos dados;
- calibração da posição dos dados;
- Refresh com verificação, cache e rollback.

As mensagens do chat mantêm somente os destaques mínimos estabilizados: o nome do personagem e o valor do resultado recebem cor; as demais partes são texto simples. As faces dos dados aparecem entre parênteses para evitar a combinação de tags que já causou problemas de renderização no chat. Uma nova rolagem remove os dados anteriores pertencentes ao próprio painel; **Limpar Dados** faz isso manualmente sem alterar o estado ou o resultado.

## Valores da última release estável

A v0.2.0 é a referência funcional anterior à fundação multi-personagem:

- nível 7;
- PV 78 e PM 21;
- Defesa 24;
- Espada Longa +13;
- Escudo Pesado +12;
- **Estilo de Arma e Escudo**, **Solidez**, **Duelo**, **Baluarte**, **Duelista Escudado**, **Encouraçado**, **Placas da Ira**, **Bastião**, **Armas da Ambição** e demais poderes já presentes na ficha;
- atalhos para Cavalgar, Diplomacia, Guerra e Pontaria;
- velocidade vertical dos dados variada, mantendo limites laterais e de giro;
- chat com destaques mínimos e crítico exibido como `CRÍTICO` em vermelho.

A v0.2.1 não deve alterar esses cálculos, poderes, textos, cores, proporções ou contratos de UI. O foco é mover o produto para a arquitetura multi-personagem, adicionar identidade e preservar o Refresh de um objeto v0.2.0 existente.

## Histórico resumido

- **v0.1.7** — moldura alinhada ao painel passou a ser camada visual da UI, mantendo fallback da textura física.
- **v0.1.8** — ficha no nível 6; atualização de PV/PM máximos preservando valores gastos; renovação de efeitos de turno.
- **v0.1.9** — hierarquia visual do chat e rótulos explícitos de resultado/cálculo.
- **v0.2.0** — ficha no nível 7, novos poderes/perícias, estado preservado no Refresh, chat reduzido a destaques seguros e força vertical dos dados mais variada.
- **v0.2.1** — fundação multi-personagem, sem mudança intencional nas regras do Corvan.

## Teste e release

Antes de publicar uma versão Corvan:

1. Execute os testes Node, o build determinístico e o smoke Lua.
2. Use um Saved Object v0.2.0 real, gaste PV/PM e ative efeitos.
3. Faça Refresh para a nova versão e confirme estado, GUID, posição, rotação, escala, UI, helper e dados.
4. Teste dois painéis na mesma mesa, incluindo rolagem, limpeza, desfazer e rollback.
5. Publique a tag legada `vX.Y.Z` somente após validar o manifesto e os três artefatos.

O Corvan é o único produto que usa `/releases/latest` e pode atualizar instalações antigas sem trocar a URL de descoberta. A release continua imutável; correções posteriores usam outra versão SemVer.
