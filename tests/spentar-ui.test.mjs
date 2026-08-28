import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
import test from 'node:test';

const ui = await readFile(join(process.cwd(), 'characters', 'spentar', 'ui.xml'), 'utf8');
const navigationIds = ['nav_combat', 'nav_casting', 'nav_necromancy',
  'nav_sheet', 'nav_settings'];
const pageIds = ['page_combat', 'page_casting', 'page_necromancy',
  'page_sheet', 'page_settings'];
const persistentIds = ['resource_hp', 'resource_mp', 'resource_temp_hp',
  'resource_temp_mp', 'defense_value', 'fortitude_value', 'reflex_value',
  'will_value', 'general_dc', 'necro_dc', 'souls_value', 'profanar_value',
  'connection_value', 'last_result'];

test('Spentar UI é um console opaco, autocontido e com cinco páginas', () => {
  assert.match(ui, /<Panel id="spentarConsole"[^>]*width="1600" height="1000"/s);
  assert.match(ui, /<Panel id="spentarConsole"[^>]*color="#[0-9A-Fa-f]{8}"/s);
  assert.match(ui, /<Panel id="spentarConsole"[^>]*raycastTarget="false"/s);
  assert.match(ui, /<Panel raycastTarget="false"\s*\/>/);
  assert.match(ui, /<Text[^>]*raycastTarget="false"/);
  assert.doesNotMatch(ui, /<Image\b/);
  assert.doesNotMatch(ui, /\bimage="https?:\/\//i);
  for (const id of [...navigationIds, ...pageIds, ...persistentIds]) {
    assert.match(ui, new RegExp(`\\bid="${id}"`), `missing UI id ${id}`);
  }
  for (const id of navigationIds) {
    assert.match(ui, new RegExp(`<Button id="${id}"[^>]*onClick="dispatch"`));
  }
  assert.match(ui, /id="page_combat" active="true"/);
  for (const id of pageIds.slice(1)) assert.match(ui, new RegExp(`id="${id}" active="false"`));
});

test('Spentar UI IDs são globalmente únicos', () => {
  const ids = [...ui.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
  const duplicates = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))];
  assert.deepEqual(duplicates, []);
});

test('bancada expõe inputs digitáveis e quatro ações sem wizard', () => {
  for (const id of ['prepare_cost', 'prepare_targets', 'prepare_dice_count',
    'prepare_dice_sides', 'prepare_bonus', 'prepare_souls', 'prepare_effect',
    'prepare_note']) {
    assert.match(ui, new RegExp(`<InputField id="${id}"[^>]*onEndEdit="dispatch"`),
      `${id} must route edits through dispatch`);
  }
  for (const id of ['prepare_darkness', 'prepare_profane_targets', 'prepare_save',
    'prepare_roll', 'prepare_apply', 'prepare_reset']) {
    assert.match(ui, new RegExp(`<Button id="${id}"[^>]*onClick="dispatch"`));
  }
  assert.match(ui, /id="prepare_save"[^>]*text="SALVAR PREPARO"/s);
  assert.match(ui, /id="prepare_roll"[^>]*text="ROLAR"/s);
  assert.match(ui, /id="prepare_apply"[^>]*text="APLICAR SEM ROLAR"/s);
  assert.match(ui, /id="prepare_reset"[^>]*text="RESTAURAR PADRÃO"/s);
  for (const obsolete of ['casting_config_panel', 'casting_review_panel',
    'casting_rolling_panel', 'casting_resolution_panel', 'cast_review', 'cast_edit']) {
    assert.doesNotMatch(ui, new RegExp(`\\bid="${obsolete}"`));
  }
});

test('ações rápidas separam rolar último de editar', () => {
  for (const action of ['inflict', 'arcane_bolt', 'undead', 'ballistic']) {
    for (const verb of ['roll', 'edit']) {
      const id = `quick_${action}_${verb}`;
      assert.match(ui, new RegExp(`<Button id="${id}"[^>]*onClick="dispatch"`));
    }
  }
  assert.match(ui, /id="quick_inflict_roll"[^>]*text="ROLAR ÚLTIMO"/s);
  assert.match(ui, /<Button id="combat_edit_last"[^>]*onClick="dispatch"/);
});

test('resolução pendente é uma faixa não bloqueante', () => {
  assert.match(ui, /<Panel id="pending_resolution" active="false"/);
  for (const id of ['pending_failed', 'pending_defeated']) {
    assert.match(ui, new RegExp(`<InputField id="${id}"[^>]*onEndEdit="dispatch"`));
  }
  for (const id of ['pending_apply', 'pending_discard']) {
    assert.match(ui, new RegExp(`<Button id="${id}"[^>]*onClick="dispatch"`));
  }
  assert.match(ui, /O painel continua livre/);
});

test('Necromancia separa corpos, invocações e comandos', () => {
  for (const id of ['bodies_available', 'undead_count', 'ballistic_count',
    'ballistic_dice', 'corpse_partner']) {
    assert.match(ui, new RegExp(`<InputField id="${id}"[^>]*onEndEdit="dispatch"`));
  }
  for (const id of ['necro_undead_roll', 'necro_ballistic_roll']) {
    assert.match(ui, new RegExp(`<Button id="${id}"[^>]*onClick="dispatch"`));
  }
  assert.match(ui, /<Button id="mark_command_used"[^>]*onClick="dispatch"/);
});

test('controles globais de ciclo de vida e diagnóstico continuam ligados', () => {
  for (const id of ['connection_off', 'connection_normal', 'connection_doubled',
    'end_turn', 'end_scene', 'end_day', 'undo', 'clear_dice', 'reset_state']) {
    assert.match(ui, new RegExp(`<Button id="${id}"[^>]*onClick="dispatch"`));
  }
  assert.match(ui, /<Button id="refresh"[^>]*onClick="refresh"/);
  assert.match(ui, /<Text id="refreshStatus"/);
});

test('todos os InputFields despacham somente ao confirmar edição', () => {
  const inputTags = [...ui.matchAll(/<InputField\b[^>]*>/g)].map((match) => match[0])
    .filter((tag) => /\bid=/.test(tag));
  assert.ok(inputTags.length >= 13);
  for (const tag of inputTags) {
    assert.match(tag, /onEndEdit="dispatch"/, `input sem onEndEdit: ${tag}`);
    assert.doesNotMatch(tag, /onValueChanged=/, `input dispara durante digitação: ${tag}`);
  }
});
