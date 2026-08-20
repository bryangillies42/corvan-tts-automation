import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import test from "node:test";

const character = JSON.parse(await readFile(
  new URL("../characters/spentar/character.json", import.meta.url), "utf8"));
const runtime = await readFile(
  new URL("../characters/spentar/runtime.lua", import.meta.url), "utf8");
const ui = await readFile(
  new URL("../characters/spentar/ui.xml", import.meta.url), "utf8");

function spellDifficulty({staff = true, spellId = "inflict_wounds"} = {}) {
  const spell = character.spells[spellId];
  return character.spellcasting.baseDifficulty
    + (staff ? character.spellcasting.staffDifficultyBonus : 0)
    + (spell.school === "necromancia"
      ? character.spellcasting.necromancyDifficultyBonus : 0);
}

function defenses(souls) {
  const power = character.powers.chainFallen;
  return {
    defense: character.defenses.defense + souls * power.defensePerSoul,
    fortitude: character.defenses.fortitude + souls * power.resistancePerSoul,
    reflex: character.defenses.reflex + souls * power.resistancePerSoul,
    will: character.defenses.will + souls * power.resistancePerSoul,
  };
}

function spendMp(state, cost) {
  if (state.mp + state.temporaryMp < cost) return false;
  const temporary = Math.min(state.temporaryMp, cost);
  state.temporaryMp -= temporary;
  state.mp -= cost - temporary;
  return true;
}

function deterministicDamage({count, sides, bonus = 0, maximize = false}) {
  return (maximize ? count * sides : 0) + bonus;
}

test("identidade, versão e schema v2 estão explícitos", () => {
  assert.equal(character.id, "spentar");
  assert.equal(character.version, "0.1.0");
  assert.equal(character.stateSchemaVersion, 2);
  assert.match(runtime, /local STATE_SCHEMA_VERSION = 2/);
  assert.equal(character.resources.hp.max, 20);
  assert.equal(character.resources.mp.max, 48);
  assert.equal(character.resources.souls.max, 6);
  assert.equal(character.houseRules.profaneRequiresPerRollConfirmation.enabled, true);
});

test("CDs congeladas são 22\/23 geral e 24\/25 Necromancia", () => {
  assert.equal(spellDifficulty({staff: false, spellId: "arcane_bolt"}), 22);
  assert.equal(spellDifficulty({staff: true, spellId: "arcane_bolt"}), 23);
  assert.equal(spellDifficulty({staff: false, spellId: "inflict_wounds"}), 24);
  assert.equal(spellDifficulty({staff: true, spellId: "inflict_wounds"}), 25);
});

test("almas alteram Defesa e resistências sem ultrapassar seis", () => {
  assert.deepEqual(defenses(0), {defense: 17, fortitude: 7, reflex: 10, will: 8});
  assert.deepEqual(defenses(6), {defense: 29, fortitude: 19, reflex: 22, will: 20});
  assert.deepEqual(character.powers.chainFallen.releasedSoulDamage,
    {count: 2, sides: 6, type: "trevas"});
});

test("PM temporários são consumidos primeiro e insuficiência é atômica", () => {
  const enough = {mp: 10, temporaryMp: 3};
  assert.equal(spendMp(enough, 5), true);
  assert.deepEqual(enough, {mp: 8, temporaryMp: 0});
  const insufficient = {mp: 1, temporaryMp: 1};
  assert.equal(spendMp(insufficient, 3), false);
  assert.deepEqual(insufficient, {mp: 1, temporaryMp: 1});
});

test("exemplos obrigatórios de Profanar permanecem determinísticos", () => {
  assert.equal(deterministicDamage({count: 6, sides: 6, bonus: 18, maximize: true}), 54);
  assert.equal(deterministicDamage({count: 3, sides: 8, bonus: 9, maximize: true}), 33);
  assert.equal(deterministicDamage({count: 12, sides: 6, maximize: true}), 72);
  assert.equal(
    deterministicDamage({count: 3, sides: 8, bonus: 9, maximize: true})
      + deterministicDamage({count: 12, sides: 6, maximize: true}), 105);
});

test("Profanar exige estado de cena e confirmação granular do preparo", () => {
  assert.match(runtime, /currentState\.scene\.profanar == true\s+and currentState\.scene\.profanarTargetsConfirmed == true/s);
  assert.match(runtime, /shadow\.scene\.profanarTargetsConfirmed = preparation\.profaneTargets == true/);
  assert.match(runtime, /maximized = profaneApplies and baseTrevas/);
  assert.match(runtime, /damageType = "trevas",\s+maximized = profaneApplies/s);
  assert.match(runtime, /state\.casting\.draft\.profaneTargets = not state\.casting\.draft\.profaneTargets/);
});

test("Necropotência e cajado aplicam benefícios uma vez por conjuração", () => {
  assert.equal(character.powers.necropotency.temporaryMpPerQualifyingCast, 2);
  assert.equal(character.powers.necropotency.maximumTemporaryMpPerScene, 7);
  assert.equal(character.equipment.staff.temporaryHpOnAnyFailedResistance, 10);
  assert.match(runtime, /defeated < 1 then return 0/);
  assert.match(runtime, /temporaryMpPerQualifyingCast/);
  assert.doesNotMatch(runtime, /temporaryMpPerDefeatedEnemy/);
  assert.match(runtime, /pending\.failed > 0[\s\S]*temporaryHpOnAnyFailedResistance/);
  assert.match(runtime, /local function nextPendingResolution\(\)/);
  assert.match(runtime, /state\.casting\.pendingResolution = nextPendingResolution\(\)/);
});

test("catálogo completo distingue dano de referência manual", () => {
  assert.deepEqual(Object.keys(character.spells).sort(), [
    "animate_dead", "arcane_armor", "arcane_bolt", "ballistic_spirit",
    "curse", "dimensional_step", "fear", "inflict_wounds",
    "phantom_vitality", "profane",
  ]);
  for (const spell of Object.values(character.spells)) {
    for (const field of ["name", "summary", "action", "range", "target",
      "duration", "resistance", "damageType", "automation", "upgrades",
      "consequences"]) {
      assert.ok(Object.hasOwn(spell, field), `${spell.name} sem ${field}`);
    }
  }
});

test("preparos são digitáveis, salvos por magia e editar não cobra", () => {
  for (const id of ["prepare_cost", "prepare_targets", "prepare_dice_count",
    "prepare_dice_sides", "prepare_bonus", "prepare_souls", "prepare_note",
    "prepare_effect", "prepare_darkness", "prepare_profane_targets",
    "prepare_save", "prepare_roll", "prepare_apply", "prepare_reset"]) {
    assert.match(runtime, new RegExp(id));
  }
  assert.match(runtime, /casting = \{[\s\S]*preparations = defaultPreparations\(\)/);
  assert.match(runtime, /state\.casting\.preparations\[state\.casting\.spellId\] = deepCopy\(state\.casting\.draft\)/);
  assert.match(runtime, /elseif id == "prepare_save" then\s+pushUndo\(\)/s);
  assert.doesNotMatch(runtime, /elseif id == "prepare_save"[\s\S]{0,300}SpentarRules\.spendMp/);
  assert.match(runtime, /parseInputInteger\(payload, spec\[1\], spec\[2\], spec\[3\]\)/);
  assert.match(runtime, /SUPPORTED_DIE_SIDES = \{\[4\]=true, \[6\]=true, \[8\]=true, \[10\]=true, \[12\]=true, \[20\]=true\}/);
  assert.match(runtime, /Faces deve ser 4, 6, 8, 10, 12 ou 20/);
});

test("atalhos rolam a última preparação salva com idempotência", () => {
  for (const id of ["quick_inflict_roll", "quick_inflict_edit",
    "quick_arcane_bolt_roll", "quick_arcane_bolt_edit", "quick_undead_roll",
    "quick_undead_edit", "quick_ballistic_roll", "quick_ballistic_edit"]) {
    assert.match(runtime, new RegExp(id));
  }
  assert.match(runtime, /beginPrepared\(spellId, deepCopy\(state\.casting\.preparations\[spellId\]\)/);
  assert.match(runtime, /state\.lastHandledEventId == payload\.eventId/);
  assert.match(runtime, /state\.casting\.transaction ~= nil then return false/);
  assert.match(runtime, /payload\.eventId == nil and isDuplicateAction/);
  assert.match(runtime, /now - previous < 0\.45/);
  assert.match(runtime, /lastUsedSpellId = spellId/);
  assert.match(runtime, /id == "combat_edit_last"/);
  assert.match(runtime, /selectSpellForConfiguration\(state\.casting\.lastUsedSpellId/);
});

test("resolução pendente é persistente e não bloqueia o painel", () => {
  assert.match(runtime, /pendingResolution = nil, pendingResolutions = \{\}/);
  assert.match(runtime, /state\.casting\.pendingResolution = pending/);
  assert.match(runtime, /pendingResolutions/);
  assert.doesNotMatch(runtime, /state\.casting\.phase == "resolution" or state\.casting\.transaction ~= nil/);
  assert.doesNotMatch(runtime, /state\.casting\.pendingResolution ~= nil and id ~=/);
  assert.match(runtime, /id == "pending_apply" or id == "resolution_apply"/);
  assert.match(runtime, /id == "pending_discard"/);
});

test("Vitalidade aplica o resultado e Espírito Balístico conjura antes do ataque", () => {
  assert.match(runtime, /kind = type\(spell\.temporaryHp\) == "table" and "temporary_hp"/);
  assert.match(runtime, /transaction\.plan\.kind == "temporary_hp"[\s\S]*temporaryHp = state\.resources\.temporaryHp \+ total/);
  assert.match(runtime, /Vitalidade Fantasma precisa ser rolada/);
  assert.match(runtime, /state\.casting\.spellId == "ballistic_spirit"[\s\S]*applyPreparedEffect/);
  assert.match(runtime, /state\.summons\.ballisticSpirits = boundedInteger\(preparation\.targets, 0, 2, 0\)/);
});

test("corpos, invocações e comandos são estados independentes", () => {
  assert.equal(character.spells.animate_dead.configuredCount, 0);
  assert.equal(character.spells.ballistic_spirit.maximumSpirits, 2);
  assert.equal(character.spells.ballistic_spirit.maximumDamageDice, 2);
  assert.match(runtime, /bodiesAvailable = 0, undeadCount = 0, ballisticSpirits = 0/);
  assert.match(runtime, /commandUsed = \{undead=false, ballistic=false\}/);
  assert.match(runtime, /bodies_available=\{"bodiesAvailable",0,99\}/);
  assert.match(runtime, /undead_count=\{"undeadCount",0,6\}/);
  assert.match(runtime, /ballistic_count=\{"ballisticSpirits",0,2\}/);
  assert.match(runtime, /ballistic_dice=\{"ballisticDice",1,2\}/);
  assert.match(runtime, /id == "mark_command_used"/);
  assert.match(runtime, /state\.summons\.commandUsed = \{undead=not release, ballistic=not release\}/);
});

test("migração v1 para v2 preserva configurações e neutraliza rolagem", () => {
  assert.match(runtime, /casting\.preparations or casting\.lastConfigurations/);
  assert.match(runtime, /Migração v1/);
  assert.match(runtime, /elseif casting\.phase == "resolution"/);
  assert.match(runtime, /normalized\.casting\.transaction = nil/);
  assert.match(runtime, /normalized\.casting\.phase = "configure"/);
  assert.match(runtime, /stateSchemaVersion = STATE_SCHEMA_VERSION/);
});

test("runtime usa envelope isolado, host opt-in e rollback transacional", () => {
  assert.match(runtime, /SpentarRules = \{\}/);
  assert.match(runtime, /CharacterRuntimeCore|RuntimeCore/);
  assert.match(runtime, /AdapterApi\.state\.envelope\(state, coreState\)/);
  assert.match(runtime, /AdapterApi\.state\.unwrap\(payload\)/);
  assert.match(runtime, /allowLegacyIdentity = false/);
  assert.match(runtime, /TtsRuntimeHost\.create/);
  assert.match(runtime, /transactionId=transaction\.id/);
  assert.match(runtime, /onRollback=function\(_, reason\) rollbackRoll/);
  assert.match(runtime, /characterState = pending\.snapshot\.character/);
  assert.match(runtime, /nextCore = pending\.snapshot\.core/);
});

test("todo ID literal atualizado pelo runtime existe na UI", () => {
  const ids = [...runtime.matchAll(/safeSet\("([^"]+)"\s*,/g)]
    .map((match) => match[1]).filter((id) => !id.endsWith("_"));
  for (const id of ids) {
    assert.match(ui, new RegExp(`\\bid=["']${id}["']`), `ID ausente na UI: ${id}`);
  }
  for (const page of ["combat", "casting", "necromancy", "sheet", "settings"]) {
    assert.match(ui, new RegExp(`\\bid=["']page_${page}["']`));
  }
});

test("reset e limpeza atuam sobre dados físicos próprios", () => {
  assert.match(runtime, /id == "reset_state" then\s+local host = createDiceHost\(\)/s);
  assert.match(runtime, /host\.clear\(coreState\.ownedDice\)/);
  assert.match(runtime, /id == "clear_dice"/);
  assert.match(runtime, /host\.cancel\("rolagem cancelada pelo jogador"\)/);
});
