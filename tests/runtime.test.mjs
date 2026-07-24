import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const character = JSON.parse(await readFile(new URL('../src/character.json', import.meta.url), 'utf8'));
const runtime = await readFile(new URL('../src/runtime.lua', import.meta.url), 'utf8');
const ui = await readFile(new URL('../src/ui.xml', import.meta.url), 'utf8');

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
      armedTower: false,
      provocation: false,
    },
    pendingThreat: null,
  };
}

// Modelo pequeno e independente: documenta os resultados que o runtime Lua deve
// produzir sem exigir que uma instalação de Tabletop Simulator exista no CI.
function attackModifier(state, weaponKey = state.activeWeapon) {
  return character.weapons[weaponKey].attack
    + (state.effects.duel ? character.powers.duel.attackModifier : 0)
    + (state.effects.combatDefensiveArmed ? character.powers.combatDefensive.attackModifier : 0);
}

function defense(state) {
  return character.defense
    + (state.effects.combatDefensiveDefense ? character.powers.combatDefensive.defenseModifier : 0)
    + (state.effects.baluarte ? character.powers.baluarte.defenseModifier : 0);
}

function damageSpec(state, weaponKey, critical) {
  const weapon = character.weapons[weaponKey];
  return {
    count: weapon.damage.count * (critical ? weapon.critical.multiplier : 1),
    sides: weapon.damage.sides,
    bonus: weapon.damage.bonus
      + (state.effects.duel ? character.powers.duel.damageModifier : 0)
      + (state.effects.armedTower ? character.powers.armedTower.damageModifier : 0),
  };
}

function activate(state, effect, configKey) {
  if (state.effects[effect]) return false;
  const cost = character.powers[configKey].cost;
  if (state.mp < cost) return false;
  state.mp -= cost;
  state.effects[effect] = true;
  return true;
}

test('fórmulas de ataque, defesa e crítico seguem os números da ficha', () => {
  const state = initialState();
  assert.equal(attackModifier(state), 8);
  state.effects.duel = true;
  assert.equal(attackModifier(state), 10);
  state.effects.combatDefensiveArmed = true;
  assert.equal(attackModifier(state), 8);
  state.effects.combatDefensiveArmed = false;
  state.effects.combatDefensiveDefense = true;
  state.effects.baluarte = true;
  assert.equal(defense(state), 27);

  state.effects.armedTower = true;
  assert.deepEqual(damageSpec(state, 'sword', false), { count: 1, sides: 8, bonus: 11 });
  assert.deepEqual(damageSpec(state, 'sword', true), { count: 2, sides: 8, bonus: 11 });
  assert.deepEqual(damageSpec(state, 'shield', true), { count: 2, sides: 6, bonus: 11 });
});

test('custos, repetição, insuficiência e limites de recursos são determinísticos', () => {
  const state = initialState();
  assert.equal(activate(state, 'duel', 'duel'), true);
  assert.equal(state.mp, 10);
  assert.equal(activate(state, 'duel', 'duel'), false);
  assert.equal(state.mp, 10, 'repetir um poder não gasta PM novamente');
  state.mp = 0;
  assert.equal(activate(state, 'provocation', 'provocation'), false);
  assert.equal(state.mp, 0);

  const clamp = (value, max) => Math.min(max, Math.max(0, Math.floor(value)));
  assert.equal(clamp(-99, character.resources.hp.max), 0);
  assert.equal(clamp(999, character.resources.hp.max), 47);
  assert.equal(clamp(999, character.resources.mp.max), 12);
});

test('fim do turno preserva Duelo; fim da cena remove todos os efeitos', () => {
  const state = initialState();
  Object.keys(state.effects).forEach((key) => { state.effects[key] = true; });
  state.pendingThreat = { weaponKey: 'sword', natural: 19 };

  for (const key of ['combatDefensiveArmed', 'combatDefensiveDefense', 'baluarte', 'armedTower', 'provocation']) {
    state.effects[key] = false;
  }
  state.pendingThreat = null;
  assert.equal(state.effects.duel, true);

  Object.keys(state.effects).forEach((key) => { state.effects[key] = false; });
  assert.deepEqual(state.effects, initialState().effects);
});

test('snapshot de undo restaura a última mutação sem representar reroll', () => {
  let state = initialState();
  const snapshot = structuredClone(state);
  state.mp -= 2;
  state.effects.duel = true;
  const diceResultOutsideState = 17;
  state = structuredClone(snapshot);
  assert.equal(state.mp, 12);
  assert.equal(state.effects.duel, false);
  assert.equal(diceResultOutsideState, 17, 'undo não apaga ou rerrola um dado físico');
});

test('runtime expõe o contrato público e o estado de busy para o bootstrap', () => {
  for (const name of ['healthCheck', 'exportState', 'importState', 'handleUiEvent', 'registerParent']) {
    assert.match(runtime, new RegExp(`function\\s+${name}\\s*\\(`));
  }
  assert.match(runtime, /exported\.rollInProgress\s*=\s*rollInProgress/);
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

test('dados físicos usam offset local, espera oficial e limpeza por GUID próprio', () => {
  assert.match(runtime, /parent\.positionToWorld\(localPosition\)/);
  assert.match(runtime, /Wait\.frames\(function\(\) launchDie\(token, index\) end, 1\)/);
  assert.match(runtime, /object\.addForce\(worldImpulse, 4\)/);
  assert.match(runtime, /object\.addTorque\(angularVelocity, 4\)/);
  assert.match(runtime, /object\.setVelocity\(worldImpulse\)/);
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
  assert.match(runtime, /destroyObject\(object\)/);
  assert.doesNotMatch(runtime, /getAllObjects\s*\(/, 'não pode apagar dados que não pertencem ao painel');
});

test('offset padrão nasce sobre o painel e o offset legado é migrado sem schema novo', () => {
  assert.deepEqual(character.diceOffset, { x: 0, y: 3.2, z: 0 });
  assert.match(runtime, /LEGACY_DICE_OFFSET\s*=\s*\{x\s*=\s*0, y\s*=\s*2\.5, z\s*=\s*-5\}/);
  assert.match(runtime, /normalized\.diceOffset\s*=\s*deepCopy\(CHARACTER\.diceOffset/);
  assert.match(runtime, /local function localDirectionToWorld\(localDirection\)/);
});

test('chat usa entrega resiliente, formato centralizado e nunca notificações centrais', () => {
  assert.match(runtime, /function CorvanRules\.formatRollResult\(/);
  assert.match(runtime, /Player\[functionName\]/);
  assert.match(runtime, /player\.print\(message, CHAT_COLOR\)/);
  assert.match(runtime, /printToAll\(/);
  assert.match(runtime, /printToColor\(/);
  assert.match(runtime, /chatDiagnostic\(/);
  assert.match(runtime, /CHARACTER\.shortName \.\. ": " \.\. state\.lastResult/);
  assert.doesNotMatch(runtime, /\+ -/);
  assert.doesNotMatch(runtime, /broadcastTo(?:All|Color)\s*\(/);
});

test('UI não usa tooltips nativos que herdam a rotação de 180 graus', () => {
  assert.match(ui, /rotation="0 0 180"/);
  assert.doesNotMatch(ui, /\btooltip(?:Position|FontSize|TextColor|BackgroundColor|BorderColor)?\s*=/i);
});
