import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {join} from 'node:path';
import test from 'node:test';

const ROOT = process.cwd();
const UI_PATH = join(ROOT, 'characters', 'spentar', 'ui.xml');

const navigationIds = [
  'nav_combat',
  'nav_casting',
  'nav_necromancy',
  'nav_sheet',
  'nav_settings',
];

const pageIds = [
  'page_combat',
  'page_casting',
  'page_necromancy',
  'page_sheet',
  'page_settings',
];

const persistentIds = [
  'resource_hp',
  'resource_mp',
  'resource_temp_hp',
  'resource_temp_mp',
  'defense_value',
  'fortitude_value',
  'reflex_value',
  'will_value',
  'general_dc',
  'necro_dc',
  'souls_value',
  'profanar_value',
  'connection_value',
  'last_result',
];

const spellIds = [
  'arcane_armor',
  'fear',
  'ballistic_spirit',
  'inflict_wounds',
  'phantom_vitality',
  'profane',
  'animate_dead',
  'dimensional_step',
  'curse',
  'arcane_bolt',
].map((id) => `cast_select_${id}`);

test('Spentar UI is an opaque self-contained five-page console', async () => {
  const ui = await readFile(UI_PATH, 'utf8');

  assert.match(ui, /<Panel id="spentarConsole"[^>]*width="1600" height="1000"/s);
  assert.match(ui, /<Panel id="spentarConsole"[^>]*color="#[0-9A-Fa-f]{8}"/s);
  assert.doesNotMatch(ui, /<Image\b/);
  assert.doesNotMatch(ui, /\bimage="https?:\/\//i);

  for (const id of [...navigationIds, ...pageIds, ...persistentIds, ...spellIds]) {
    assert.match(ui, new RegExp(`\\bid="${id}"`), `missing UI id ${id}`);
  }

  for (const id of navigationIds) {
    assert.match(ui, new RegExp(`<Button id="${id}"[^>]*onClick="dispatch"`), `${id} must dispatch`);
  }

  assert.match(ui, /id="page_combat" active="true"/);
  for (const id of pageIds.slice(1)) {
    assert.match(ui, new RegExp(`id="${id}" active="false"`));
  }
});

test('Spentar UI IDs are globally unique', async () => {
  const ui = await readFile(UI_PATH, 'utf8');
  const ids = [...ui.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
  const duplicates = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))];

  assert.deepEqual(duplicates, []);
});

test('Spentar guided casting and lifecycle controls remain wired', async () => {
  const ui = await readFile(UI_PATH, 'utf8');
  const actionIds = [
    'cast_configure', 'cast_now', 'cast_confirm',
    'cast_upgrade_add', 'cast_upgrade_sub',
    'cast_targets_add', 'cast_targets_sub',
    'cast_souls_add', 'cast_souls_sub',
    'resolution_failed_add', 'resolution_failed_sub',
    'resolution_defeated_add', 'resolution_defeated_sub', 'resolution_apply',
    'connection_off', 'connection_normal', 'connection_doubled',
    'undead_roll', 'ballistic_roll',
    'end_turn', 'end_scene', 'end_day', 'undo', 'clear_dice', 'reset_state',
  ];

  for (const id of actionIds) {
    assert.match(
      ui,
      new RegExp(`<Button id="${id}"[^>]*onClick="dispatch"`),
      `${id} must route through dispatch`,
    );
  }

  assert.match(ui, /<Button id="refresh"[^>]*onClick="refresh"/);
  assert.match(ui, /<Text id="refreshStatus"/);
});
