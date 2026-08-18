import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const character = JSON.parse(await readFile(new URL('../characters/corvan/character.json', import.meta.url), 'utf8'));
const runtime = await readFile(new URL('../characters/corvan/runtime.lua', import.meta.url), 'utf8');
const ui = await readFile(new URL('../characters/corvan/ui.xml', import.meta.url), 'utf8');

function initialState() {
  return {
    hp: character.resources.hp.max,
    mp: character.resources.mp.max,
    activeWeapon: 'sword',
    effects: {
      combatDefensiveArmed: false,
      combatDefensiveDefense: false,
      duel: false,
      baluarte: false,
      baluarteShared: false,
      shieldGuardSuppressed: false,
      provocation: false,
    },
    pendingThreat: null,
    automaticResourceSpending: true,
  };
}

// Modelo pequeno e independente: documenta os resultados que o runtime Lua deve
// produzir sem exigir que uma instalação de Tabletop Simulator exista no CI.
function attackModifier(state, weaponKey = state.activeWeapon) {
  return character.weapons[weaponKey].attack
    + (Number(state.effects.duel) || 0)
    + (state.effects.combatDefensiveArmed ? character.powers.combatDefensive.attackModifier : 0);
}

function defense(state) {
  return character.defense
    - (state.effects.shieldGuardSuppressed ? character.weapons.shield.defenseModifier : 0)
    + (state.effects.combatDefensiveDefense ? character.powers.combatDefensive.defenseModifier : 0)
    + (Number(state.effects.baluarte) || 0);
}

function skillModifier(state, skillKey) {
  const skill = character.skills[skillKey];
  return skill.modifier
    - (skill.resistance && state.effects.shieldGuardSuppressed ? character.powers.solidity.resistanceModifier : 0)
    + (skill.resistance ? (Number(state.effects.baluarte) || 0) : 0);
}

function damageReduction(state) {
  return character.damageReduction
    + (Number(state.effects.duel) || 0);
}

function damageSpec(state, weaponKey, critical) {
  const weapon = character.weapons[weaponKey];
  return {
    count: weapon.damage.count * (critical ? weapon.critical.multiplier : 1),
    sides: weapon.damage.sides,
    bonus: weapon.damage.bonus
      + (Number(state.effects.duel) || 0),
  };
}

function activate(state, effect, configKey) {
  if (state.effects[effect]) return false;
  const cost = character.powers[configKey].cost;
  if (state.automaticResourceSpending && state.mp < cost) return false;
  if (state.automaticResourceSpending) state.mp -= cost;
  state.effects[effect] = true;
  return true;
}

function activateDuel(state) {
  const current = Number(state.effects.duel) || 0;
  const upgraded = character.powers.duel.upgradedAttackModifier;
  if (current >= upgraded) return false;
  const upgrading = current > 0;
  const cost = upgrading ? character.powers.duel.upgradeCost : character.powers.duel.cost;
  if (state.automaticResourceSpending && state.mp < cost) return false;
  if (state.automaticResourceSpending) state.mp -= cost;
  state.effects.duel = upgrading ? upgraded : character.powers.duel.attackModifier;
  return true;
}

function activateBaluarte(state) {
  const current = Number(state.effects.baluarte) || 0;
  if (current >= character.powers.baluarte.upgradedDefenseModifier) return false;
  const upgrading = current > 0;
  const cost = upgrading ? character.powers.baluarte.upgradeCost : character.powers.baluarte.cost;
  if (state.automaticResourceSpending && state.mp < cost) return false;
  if (state.automaticResourceSpending) state.mp -= cost;
  state.effects.baluarte = upgrading
    ? character.powers.baluarte.upgradedDefenseModifier
    : character.powers.baluarte.defenseModifier;
  return true;
}

function activateBaluarteAllies(state) {
  if (!state.effects.baluarte || state.effects.baluarteShared) return false;
  const cost = character.powers.baluarte.sharedCost;
  if (state.automaticResourceSpending && state.mp < cost) return false;
  if (state.automaticResourceSpending) state.mp -= cost;
  state.effects.baluarteShared = true;
  return true;
}

test('fórmulas de ataque, defesa e crítico seguem os números da ficha', () => {
  const state = initialState();
  assert.equal(attackModifier(state), 13);
  state.effects.duel = 3;
  assert.equal(attackModifier(state), 16);
  state.effects.combatDefensiveArmed = true;
  state.effects.combatDefensiveDefense = true;
  assert.equal(attackModifier(state), 14);
  assert.equal(defense(state), 29, 'Combate Defensivo concede +5 DEF imediatamente');
  state.effects.combatDefensiveArmed = false;
  assert.equal(defense(state), 29, 'o ataque consome somente a penalidade armada');
  state.effects.baluarte = 4;
  assert.equal(defense(state), 33);

  assert.deepEqual(damageSpec(state, 'sword', false), { count: 1, sides: 8, bonus: 8 });
  assert.deepEqual(damageSpec(state, 'sword', true), { count: 2, sides: 8, bonus: 8 });
  assert.deepEqual(damageSpec(state, 'shield', true), { count: 2, sides: 6, bonus: 8 });
  assert.equal(damageReduction(state), 11);
  assert.equal(character.weapons.sword.critical.min, 18);

  const guardState = initialState();
  guardState.effects.shieldGuardSuppressed = true;
  assert.equal(defense(guardState), 20);
  assert.equal(skillModifier(guardState, 'fortitude'), 11);
  assert.equal(skillModifier(guardState, 'reflex'), 3);
  assert.equal(skillModifier(guardState, 'will'), 4);
  guardState.effects.baluarte = 2;
  assert.equal(defense(guardState), 22);
  assert.equal(skillModifier(guardState, 'fortitude'), 13);
});

test('custos, repetição, insuficiência e limites de recursos são determinísticos', () => {
  const state = initialState();
  assert.equal(activateDuel(state), true);
  assert.equal(state.effects.duel, 2);
  assert.equal(state.mp, 19);
  assert.equal(activateDuel(state), true);
  assert.equal(state.effects.duel, 3);
  assert.equal(state.mp, 18);
  assert.equal(activateDuel(state), false);
  assert.equal(state.mp, 18, 'Duelo +3 não acumula além do limite');
  assert.equal(activateBaluarte(state), true);
  assert.equal(state.effects.baluarte, 2);
  assert.equal(state.mp, 17);
  assert.equal(activateBaluarte(state), true);
  assert.equal(state.effects.baluarte, 4);
  assert.equal(state.mp, 16);
  assert.equal(activateBaluarteAllies(state), true);
  assert.equal(state.effects.baluarteShared, true);
  assert.equal(state.mp, 14);
  assert.equal(activateBaluarteAllies(state), false, 'compartilhamento não cobra PM duas vezes');
  assert.equal(activateBaluarte(state), false, 'Baluarte +4 não acumula além do limite');
  assert.equal(state.mp, 14);
  state.mp = 0;
  assert.equal(activate(state, 'provocation', 'provocation'), false);
  assert.equal(state.mp, 0);

  const clamp = (value, max) => Math.min(max, Math.max(0, Math.floor(value)));
  assert.equal(clamp(-99, character.resources.hp.max), 0);
  assert.equal(clamp(999, character.resources.hp.max), 78);
  assert.equal(clamp(999, character.resources.mp.max), 21);
});

test('automação desligada não valida nem desconta custos, inclusive no Baluarte', () => {
  const state = initialState();
  state.automaticResourceSpending = false;
  state.mp = 0;
  assert.equal(activateDuel(state), true);
  assert.equal(activateDuel(state), true);
  assert.equal(activate(state, 'provocation', 'provocation'), true);
  assert.equal(activateBaluarte(state), true);
  assert.equal(activateBaluarte(state), true);
  assert.equal(activateBaluarteAllies(state), true);
  assert.equal(state.mp, 0);
  assert.equal(state.effects.baluarte, 4);
  assert.equal(state.effects.baluarteShared, true);
});

test('UI e runtime usam ajustes livres de PV/PM e removem os setters absolutos', () => {
  for (const id of [
    'pv_adjust', 'pv_subtract', 'pv_add',
    'pm_adjust', 'pm_subtract', 'pm_add',
    'automatic_resource_spending',
  ]) {
    assert.match(ui, new RegExp(`id="${id}"`));
  }
  for (const removed of [
    'pv_m5', 'pv_m1', 'pv_p1', 'pv_p5', 'pm_m5', 'pm_m1', 'pm_p1', 'pm_p5',
    'pv_input', 'pm_input',
  ]) {
    assert.doesNotMatch(ui, new RegExp(`id="${removed}"`));
    assert.doesNotMatch(runtime, new RegExp(`\\b${removed}\\b`));
  }
  assert.match(runtime, /math\.abs\(number\)/);
  assert.match(runtime, /number ~= math\.floor\(number\) or number < 1 or number > 999/);
  assert.match(runtime, /if target ~= current then\s+pushUndo\(\)/);
  assert.match(runtime, /resourceAdjustments\[resource\] = ""\s+cacheAndRender\(\)/);
});

test('preferência de gasto automático migra ligada e é preservada por Undo e Reset', () => {
  assert.match(runtime, /automaticResourceSpending = true/);
  assert.match(runtime, /normalized\.automaticResourceSpending = source\.automaticResourceSpending ~= false/);
  assert.match(runtime, /restored\.automaticResourceSpending = automaticResourceSpending/);
  assert.match(runtime, /state = defaultState\(\)[\s\S]*state\.automaticResourceSpending = automaticResourceSpending/);
  assert.match(runtime, /if not state\.automaticResourceSpending then return true end/);
  assert.match(runtime, /if not state\.automaticResourceSpending then return end/);
  assert.match(ui, /<Toggle id="automatic_resource_spending" isOn="true" onValueChanged="dispatch"/);
});

test('Duelista Escudado, guarda do escudo e remoção da Torre Armada fazem parte do contrato', () => {
  assert.match(runtime, /function CorvanRules\.calculateDamageReduction\(/);
  assert.match(runtime, /effects\.shieldGuardSuppressed/);
  assert.match(runtime, /state\.activeWeapon == "shield"[\s\S]*state\.effects\.shieldGuardSuppressed = true/);
  assert.match(runtime, /state\.effects\.shieldGuardSuppressed = false/);
  assert.match(ui, /id="passive_duelist_shielded"/);
  assert.match(ui, /ESTILO \+ SOLIDEZ \+ ENCOURAÇADO/);
  assert.match(runtime, /upgradedDamageReduction/);
  assert.doesNotMatch(ui, /power_torre_armada|TORRE ARMADA/);
  assert.doesNotMatch(runtime, /armedTower|power_torre_armada|Torre Armada/);
});

test('migração de nível aumenta apenas recursos cheios, inclusive no salto direto da v0.1.5', () => {
  assert.match(runtime, /CHARACTER\.version == "0\.2\.0"/);
  assert.match(runtime, /CHARACTER\.version == "0\.2\.1"/);
  assert.match(runtime, /source\.runtimeVersion ~= "0\.1\.6"/);
  assert.match(runtime, /source\.runtimeVersion ~= "0\.1\.7"/);
  assert.match(runtime, /source\.runtimeVersion ~= "0\.1\.8"/);
  assert.match(runtime, /source\.runtimeVersion ~= "0\.1\.9"/);
  assert.match(runtime, /source\.runtimeVersion ~= "0\.2\.0"/);
  assert.match(runtime, /source\.runtimeVersion ~= "0\.2\.1"/);
  assert.match(runtime, /source\.hp or source\.pv, 0\) == 47[\s\S]*normalized\.hp = 55/);
  assert.match(runtime, /source\.mp or source\.pm, 0\) == 12[\s\S]*normalized\.mp = 15/);
  assert.match(runtime, /normalized\.hp == 55[\s\S]*normalized\.hp = 69/);
  assert.match(runtime, /normalized\.mp == 15[\s\S]*normalized\.mp = 18/);
  assert.match(runtime, /normalized\.hp == 69[\s\S]*normalized\.hp = 78/);
  assert.match(runtime, /normalized\.mp == 18[\s\S]*normalized\.mp = 21/);
});

test('início do turno preserva Duelo e Provocação; fim da cena remove todos os efeitos', () => {
  const state = initialState();
  Object.keys(state.effects).forEach((key) => { state.effects[key] = true; });
  state.pendingThreat = { weaponKey: 'sword', natural: 19 };

  for (const key of [
    'combatDefensiveArmed', 'combatDefensiveDefense', 'baluarte',
    'baluarteShared', 'shieldGuardSuppressed',
  ]) {
    state.effects[key] = false;
  }
  state.pendingThreat = null;
  assert.equal(state.effects.duel, true);
  assert.equal(state.effects.provocation, true);

  Object.keys(state.effects).forEach((key) => { state.effects[key] = false; });
  assert.deepEqual(state.effects, initialState().effects);
});

test('snapshot de undo restaura a última mutação sem representar reroll', () => {
  let state = initialState();
  const snapshot = structuredClone(state);
  state.mp -= 2;
  state.effects.duel = 3;
  const diceResultOutsideState = 17;
  state = structuredClone(snapshot);
  assert.equal(state.mp, 21);
  assert.equal(state.effects.duel, false);
  assert.equal(diceResultOutsideState, 17, 'undo não apaga ou rerrola um dado físico');
});

test('runtime expõe o contrato público e o estado de busy para o bootstrap', () => {
  for (const name of ['healthCheck', 'exportState', 'importState', 'handleUiEvent', 'registerParent']) {
    assert.match(runtime, new RegExp(`function\\s+${name}\\s*\\(`));
  }
  assert.match(runtime, /envelope\.rollInProgress\s*=\s*rollInProgress/);
  assert.match(runtime, /AdapterApi\.state\.envelope\(character, core\)/);
  assert.match(runtime, /AdapterApi\.state\.unwrap\(payload\)/);
  assert.match(runtime, /safeParentCall\("runtimeReady"/);
  assert.match(runtime, /parent\.call\(functionName, payload\)/);
  assert.match(runtime, /cacheRuntimeState/);
  assert.match(runtime, /safeParentCall\("setRuntimeUiAttribute"/);
  assert.doesNotMatch(runtime, /parent\.UI\.setAttribute/);
});

test('todo ID atualizado pelo runtime existe no XML', () => {
  const uiIds = new Set([...ui.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]));
  const renderedIds = [...runtime.matchAll(/safeSetAttribute\("([^"]+)"/g)].map((match) => match[1]);
  assert.ok(renderedIds.length > 0);
  for (const id of renderedIds) assert.ok(uiIds.has(id), `ID dinâmico ausente no XML: ${id}`);
});

test('atalhos e poderes da ficha nível 7 possuem contrato completo entre dados, UI e runtime', () => {
  const expectedSkills = {
    iniciativa: 'initiative', luta: 'fight', intimidacao: 'intimidation',
    percepcao: 'perception', fortitude: 'fortitude', reflexos: 'reflex',
    vontade: 'will', cavalgar: 'riding', diplomacia: 'diplomacy',
    guerra: 'warfare', pontaria: 'aim',
  };
  for (const [uiName, key] of Object.entries(expectedSkills)) {
    assert.match(ui, new RegExp(`id="skill_${uiName}"`));
    assert.match(runtime, new RegExp(`skill_${uiName}\\s*=\\s*"${key}"`));
    assert.ok(character.skills[key]);
  }
  assert.match(ui, /id="power_baluarte_allies"/);
  assert.match(runtime, /activateBaluarteAllies/);
  assert.match(runtime, /activateDuel/);
});

test('moldura da UI cobre painéis novos e legados sem recarregar ou alterar o objeto físico', () => {
  assert.match(ui, /<Panel id="corvanConsole"[^>]*width="1700" height="750"/s);
  assert.match(ui, /<Image id="panelBoardArt"[^>]*active="false"[^>]*width="1870" height="841"[^>]*raycastTarget="false"/s);
  assert.ok(ui.indexOf('id="panelBoardArt"') < ui.indexOf('id="corvanConsole"'));
  assert.ok(ui.indexOf('id="panelBoardArt"') < ui.indexOf('id="mainLayout"'));
  assert.match(runtime, /local PANEL_IMAGE_URL = __PANEL_IMAGE_URL_LITERAL__/);
  assert.match(runtime, /local PANEL_UI_IMAGE_URL = __PANEL_UI_IMAGE_URL_LITERAL__/);
  assert.match(runtime, /local function panelBoardOverlayNeeded\(\)[\s\S]*return true/);
  assert.match(runtime, /local function preparePanelBoardArt\(\)[\s\S]*WebRequest\.get\(PANEL_UI_IMAGE_URL[\s\S]*response_code[\s\S]*panelBoardArtReady = true/);
  assert.match(runtime, /local overlayValue = "false"/);
  assert.match(runtime, /safeSetAttribute\("panelBoardArt", "active", panelBoardOverlayActive\(\) and "true" or "false"\)/);
  assert.match(runtime, /id="panelBoardArt" active="\[\^"\]\*"/);
  assert.doesNotMatch(runtime, /parent\.setCustomObject\s*\(/);
  assert.doesNotMatch(runtime, /parent\.reload\s*\(/);
});

test('dados físicos usam offset local, espera oficial e limpeza por GUID próprio', () => {
  assert.match(runtime, /parent\.positionToWorld\(localPosition\)/);
  assert.match(runtime, /DICE_LAUNCH_DELAY_FRAMES\s*=\s*3/);
  assert.match(runtime, /DICE_VERTICAL_SPEED_MIN\s*=\s*13\.5/);
  assert.match(runtime, /DICE_VERTICAL_SPEED_MAX\s*=\s*18\.5/);
  assert.match(runtime, /local verticalSpeed = randomRange\(DICE_VERTICAL_SPEED_MIN, DICE_VERTICAL_SPEED_MAX\)/);
  assert.match(runtime, /up\.x \* verticalSpeed[\s\S]*up\.y \* verticalSpeed[\s\S]*up\.z \* verticalSpeed/);
  assert.match(runtime, /Wait\.frames\(function\(\) launchDie\(token, index\) end, DICE_LAUNCH_DELAY_FRAMES\)/);
  assert.match(runtime, /object\.addForce\(worldVelocity, 4\)/);
  assert.match(runtime, /object\.addTorque\(angularVelocity, 4\)/);
  assert.match(runtime, /object\.setVelocity\(worldVelocity\)/);
  assert.match(runtime, /object\.setAngularVelocity\(angularVelocity\)/);
  assert.match(runtime, /parameters\.pendingLaunches\s*=\s*parameters\.count/);
  assert.match(runtime, /\[6\]\s*=\s*"Die_6"/);
  assert.match(runtime, /\[8\]\s*=\s*"Die_8"/);
  assert.match(runtime, /\[20\]\s*=\s*"Die_20"/);
  assert.match(runtime, /spawnObject\s*\(\s*\{/);
  assert.match(runtime, /Wait\.condition/);
  assert.match(runtime, /object\.resting/);
  assert.match(runtime, /parameters\.motionObserved\s*=\s*\{\}/);
  assert.match(runtime, /currentRoll\.motionObserved\[index\]\s*=\s*true/);
  assert.match(runtime, /not currentRoll\.motionObserved\[index\]/);
  assert.match(runtime, /DICE_STABLE_FRAMES\s*=\s*12/);
  assert.match(runtime, /parameters\.stableRestFrames\s*=\s*\{\}/);
  assert.match(runtime, /currentRoll\.stableRestFrames\[index\]\s*<\s*DICE_STABLE_FRAMES/);
  assert.match(runtime, /object\.getRotationValue\(\)/);
  assert.match(runtime, /state\.ownedDiceGuids/);
  assert.match(runtime, /state\.ownedDiceOwnerGuid/);
  assert.match(runtime, /AdapterApi\.dice\.owns\(metadata, parentGuid\)/);
  assert.match(runtime, /AdapterApi\.dice\.metadata\(parentGuid\)/);
  assert.match(runtime, /markOwnedDie\(object\)/);
  assert.match(runtime, /destroyObject\(object\)/);
  assert.doesNotMatch(runtime, /getAllObjects\s*\(/, 'não pode apagar dados que não pertencem ao painel');
});

test('limpeza manual é isolada do estado de combate e o reset limpa dados órfãos', () => {
  assert.match(ui, /<Button id="clear_dice"[^>]*onClick="dispatch"/s);
  assert.match(runtime, /safeSetAttribute\("clear_dice", "interactable"/);
  assert.match(runtime, /if id == "clear_dice" then[\s\S]*if rollInProgress then[\s\S]*clearOwnedDice\(\)[\s\S]*cacheAndRender\(\)/);
  assert.match(runtime, /if id == "reset_state"[\s\S]*if rollInProgress then[\s\S]*pushUndo\(\)[\s\S]*clearOwnedDice\(\)[\s\S]*state = defaultState\(\)/);
  assert.doesNotMatch(
    runtime.match(/if id == "clear_dice" then[\s\S]*?return true\n    end/)?.[0] ?? '',
    /pushUndo|lastResult|pendingThreat|publicMessage|privateError\([^,]+,\s*"dados removidos/,
  );
});

test('offset padrão nasce sobre o painel e o offset legado é migrado sem schema novo', () => {
  assert.deepEqual(character.diceOffset, { x: 0, y: 3.2, z: 0 });
  assert.match(runtime, /LEGACY_DICE_OFFSET\s*=\s*\{x\s*=\s*0, y\s*=\s*2\.5, z\s*=\s*-5\}/);
  assert.match(runtime, /normalized\.diceOffset\s*=\s*deepCopy\(CHARACTER\.diceOffset/);
  assert.match(runtime, /local function localDirectionToWorld\(localDirection, magnitude\)/);
});

test('chat usa entrega resiliente, formato centralizado e nunca notificações centrais', () => {
  assert.match(runtime, /function CorvanRules\.formatRollResult\(/);
  assert.match(runtime, /function CorvanRules\.formatChatRollResult\(/);
  assert.match(runtime, /local function chatSafeMessage\(message, richText\)/);
  assert.ok(runtime.includes('gsub("%[", "［"):gsub("%]", "］")'));
  assert.doesNotMatch(runtime, /local function chatSegment\(/);
  assert.match(runtime, /local function chatColorSegment\(hex, value\)/);
  assert.match(runtime, /local function chatSafeRichText\(value\)/);
  assert.match(runtime, /if colorOpen then return chatSafeText\(text\) end/);
  assert.match(runtime, /tag == "\[FF6464\]" or tag == "\[62B8FF\]"/);
  assert.ok(runtime.includes('[FF6464]'));
  assert.ok(runtime.includes('[62B8FF]'));
  assert.doesNotMatch(runtime, /\[E8EDF2\]|\[63E6A5\]|\[FFD166\]|\[b\]|\[\/b\]/);
  assert.match(runtime, /formatChatDice\(count, sides, values\)/);
  assert.match(runtime, /AdapterApi\.chat\.formatRoll\(/);
  assert.match(runtime, /threat and "CRÍTICO" or nil/);
  assert.doesNotMatch(runtime, /AMEAÇA!/);
  assert.match(runtime, /Player\[functionName\]/);
  assert.match(runtime, /printToColor\(message, color, tint\)[\s\S]*Player\[color\]\.print\(message, tint\)/);
  assert.match(runtime, /add\(preferredColor\)[\s\S]*getSeatedPlayers\(\)[\s\S]*connectedPlayers\(\)/);
  assert.match(runtime, /local colors, managerAvailable = recipientColors\(preferredColor\)[\s\S]*if type\(printToAll\) == "function"[\s\S]*if type\(print\) == "function"/);
  assert.match(runtime, /if Player == nil then return \{\}, false end/);
  assert.doesNotMatch(runtime, /type\(Player\) ~= "table"/);
  assert.match(runtime, /return \{0\.92, 0\.94, 0\.97\}/);
  assert.doesNotMatch(runtime, /Color\.fromString/);
  assert.doesNotMatch(runtime, /tint = chatColor\(\)/);
  assert.doesNotMatch(runtime, /local CHAT_COLOR\s*=/);
  assert.match(runtime, /printToAll\(/);
  assert.match(runtime, /printToColor\(/);
  assert.match(runtime, /safeParentCall\("relayRuntimeChat", \{/);
  assert.match(runtime, /recordChatAudit\(message, "parent-relay", true\)/);
  assert.match(runtime, /chatDiagnostic\(/);
  assert.match(runtime, /local function publicRollResult\(/);
  assert.match(runtime, /message = chatSafeMessage\(message, richText\)/);
  assert.match(runtime, /richText = richText == true/);
  assert.match(runtime, /playerColor, nil, true\)/);
  assert.match(runtime, /tint = tint/);
  assert.doesNotMatch(runtime, /\+ -/);
  assert.doesNotMatch(runtime, /broadcastTo(?:All|Color)\s*\(/);
});

test('UI não usa tooltips nativos que herdam a rotação de 180 graus', () => {
  assert.match(ui, /rotation="0 0 180"/);
  assert.doesNotMatch(ui, /\btooltip(?:Position|FontSize|TextColor|BackgroundColor|BorderColor)?\s*=/i);
});

test('Refresh principal fica sempre visível e configurações mantêm um segundo atalho', () => {
  assert.match(ui, /<Button id="refresh"[^>]*onClick="refresh"/s);
  assert.match(ui, /<Button id="settings_refresh"[^>]*onClick="refresh"/s);
});
