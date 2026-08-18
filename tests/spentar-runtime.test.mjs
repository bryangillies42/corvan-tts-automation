import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const character = JSON.parse(await readFile(
  new URL("../characters/spentar/character.json", import.meta.url), "utf8"));
const runtime = await readFile(
  new URL("../characters/spentar/runtime.lua", import.meta.url), "utf8");
const ui = await readFile(
  new URL("../characters/spentar/ui.xml", import.meta.url), "utf8");

function spellDifficulty({ staff = true, spellId = "inflict_wounds" } = {}) {
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

function damage({ count, sides, bonus = 0, profanar = false }) {
  return (profanar ? count * sides : 0) + bonus;
}

test("identidade, versão e regras de mesa estão explícitas", () => {
  assert.equal(character.id, "spentar");
  assert.equal(character.version, "0.1.0");
  assert.equal(character.stateSchemaVersion, 1);
  assert.equal(character.resources.hp.max, 20);
  assert.equal(character.resources.mp.max, 48);
  assert.equal(character.resources.souls.max, 6);
  assert.equal(character.houseRules.spellDifficulty.enabled, true);
  assert.equal(character.houseRules.staffTemporaryHpStacks.enabled, true);
  assert.equal(character.houseRules.staffTemporaryHpStacks.expires, "scene");
});

test("CDs congeladas são 22/23 geral e 24/25 Necromancia", () => {
  assert.equal(spellDifficulty({ staff: false, spellId: "arcane_bolt" }), 22);
  assert.equal(spellDifficulty({ staff: true, spellId: "arcane_bolt" }), 23);
  assert.equal(spellDifficulty({ staff: false, spellId: "inflict_wounds" }), 24);
  assert.equal(spellDifficulty({ staff: true, spellId: "inflict_wounds" }), 25);
});

test("almas alteram Defesa e todas as resistências sem ultrapassar seis", () => {
  assert.deepEqual(defenses(0), { defense: 17, fortitude: 7, reflex: 10, will: 8 });
  assert.deepEqual(defenses(6), { defense: 29, fortitude: 19, reflex: 22, will: 20 });
  assert.equal(character.powers.chainFallen.releasedSoulDamage.count, 2);
  assert.equal(character.powers.chainFallen.releasedSoulDamage.sides, 6);
});

test("PM temporários são consumidos antes dos PM normais e insuficiência é atômica", () => {
  const enough = { mp: 10, temporaryMp: 3 };
  assert.equal(spendMp(enough, 5), true);
  assert.deepEqual(enough, { mp: 8, temporaryMp: 0 });

  const insufficient = { mp: 1, temporaryMp: 1 };
  assert.equal(spendMp(insufficient, 3), false);
  assert.deepEqual(insufficient, { mp: 1, temporaryMp: 1 });
});

test("exemplos obrigatórios de Profanar são determinísticos", () => {
  assert.equal(damage({ count: 6, sides: 6, bonus: 18, profanar: true }), 54);
  assert.equal(damage({ count: 3, sides: 8, bonus: 9, profanar: true }), 33);
  assert.equal(damage({ count: 12, sides: 6, profanar: true }), 72);
  assert.equal(
    damage({ count: 3, sides: 8, bonus: 9, profanar: true })
      + damage({ count: 12, sides: 6, profanar: true }),
    105,
  );
});

test("mortos-vivos usam Nd6 + 2N + INT uma vez", () => {
  const count = 6;
  const bonus = count * 2 + character.attributes.intelligence;
  assert.equal(bonus, 18);
  assert.equal(damage({ count, sides: 6, bonus, profanar: true }), 54);
});

test("invocações respeitam o limite suportado e o parceiro cobra o custo declarado", () => {
  assert.match(runtime, /summons\.undeadCount, 0, 6, 6/);
  assert.match(runtime, /CHARACTER\.powers\.animateCorpse\.veteranCost/);
  assert.match(runtime, /CHARACTER\.powers\.animateCorpse\.noviceCost/);
});

test("catálogo completo distingue dano seguro de resolução por referência", () => {
  assert.deepEqual(Object.keys(character.spells).sort(), [
    "animate_dead", "arcane_armor", "arcane_bolt", "ballistic_spirit",
    "curse", "dimensional_step", "fear", "inflict_wounds",
    "phantom_vitality", "profane",
  ]);
  for (const spell of Object.values(character.spells)) {
    assert.equal(typeof spell.name, "string");
    assert.equal(typeof spell.summary, "string");
    for (const field of ["action", "range", "target", "duration", "resistance",
      "damageType", "upgrades", "consequences"]) {
      assert.ok(Object.hasOwn(spell, field), `${spell.name} sem ${field}`);
    }
    assert.ok(["damage", "effect", "reference", "toggle", "undead"].includes(spell.automation));
  }
  assert.equal(character.spells.inflict_wounds.damageType, "trevas");
  assert.equal(character.spells.arcane_bolt.damageType, "essencia");
});

test("runtime usa core, envelope isolado, host opt-in e rollback transacional", () => {
  assert.match(runtime, /SpentarRules = \{\}/);
  assert.match(runtime, /CharacterRuntimeCore|RuntimeCore/);
  assert.match(runtime, /AdapterApi\.state\.envelope\(state, coreState\)/);
  assert.match(runtime, /AdapterApi\.state\.unwrap\(payload\)/);
  assert.match(runtime, /allowLegacyIdentity = false/);
  assert.match(runtime, /TtsRuntimeHost\.create/);
  assert.match(runtime, /transactionId=transaction\.id/);
  assert.match(runtime, /onRollback=function\(_, reason\) rollbackRoll/);
  assert.match(runtime, /onFailure=function\(reason\) rejectionReason = reason end/);
  assert.doesNotMatch(runtime, /onFailure=function\(reason\) rollbackRoll/);
  assert.match(runtime, /state\.resources\.temporaryHp = state\.resources\.temporaryHp/);
  assert.match(runtime, /state\.resources\.temporaryHp = 0/);
});

test("runtime reconhece o contrato prefixado de navegação e conjuração", () => {
  for (const id of [
    "nav_combat", "nav_casting", "nav_necromancy", "nav_sheet", "nav_settings",
    "resource_hp", "resource_mp", "resource_temp_hp", "resource_temp_mp",
    "toggle_staff", "toggle_profanar", "souls_add", "souls_sub",
    "cast_configure", "cast_now", "cast_confirm", "resolution_apply",
    "connection_off", "connection_normal", "connection_doubled",
    "undead_roll", "ballistic_roll", "end_turn", "end_scene", "end_day",
    "undo", "clear_dice", "reset_state",
    "skill_initiative", "skill_will", "skill_archery", "calibrate_roll",
    "toggle_auto_spend", "toggle_physical_dice", "toggle_detailed_chat",
    "health_check",
  ]) {
    assert.match(runtime, new RegExp(id));
  }
  assert.match(runtime, /\^offset_\(\[xyz\]\)_/);
  assert.match(runtime, /SKILL_IDS\[id\]/);
  assert.match(runtime, /else\s+return false\s+end\s+state\.casting\.lastConfigurations/s);
});

test("todo ID literal atualizado pelo runtime existe na UI do Spentar", () => {
  const ids = [...runtime.matchAll(/safeSet\("([^"]+)"\s*,/g)].map((match) => match[1]);
  for (const id of ids) {
    assert.match(ui, new RegExp(`\\bid=["']${id}["']`), `ID ausente na UI: ${id}`);
  }
  for (const page of ["combat", "casting", "necromancy", "sheet", "settings"]) {
    assert.match(ui, new RegExp(`\\bid=["']page_${page}["']`));
  }
  assert.doesNotMatch(runtime, /spell_dc_value/);
});

test("reload durante rolagem restaura o snapshot anterior ao custo", () => {
  assert.match(runtime, /characterState\.casting\.transaction/);
  assert.match(runtime, /characterState = pending\.snapshot\.character/);
  assert.match(runtime, /nextCore = pending\.snapshot\.core/);
});

test("uma resolução pendente não pode ser descartada por nova seleção ou atalho", () => {
  assert.match(runtime, /string\.match\(id, "\^cast_select_"\) then\s+if state\.casting\.phase ~= "configure" then return false end/s);
  assert.match(runtime, /quick_animate_dead" then\s+if state\.casting\.phase ~= "configure" then return false end/s);
  assert.match(runtime, /state\.casting\.transaction ~= nil and not NAVIGATION\[id\]/);
});

test("reset remove primeiro os dados físicos próprios persistidos", () => {
  assert.match(runtime, /id == "reset_state" then\s+local host = createDiceHost\(\)/s);
  assert.match(runtime, /host\.clear\(coreState\.ownedDice\)/);
});

test("atalho abre a resolução e uma rolagem presa pode ser cancelada", () => {
  assert.match(runtime, /coreState\.page = "casting"\s+return beginSelectedCast/);
  assert.match(runtime, /transaction\.plan\.kind ~= "check" then coreState\.page = "casting"/);
  assert.match(runtime, /id ~= "clear_dice" and id ~= "roll_cancel"/);
  assert.match(runtime, /return host\.cancel\("rolagem cancelada pelo jogador"\)/);
});
