import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const core = await readFile(new URL("../shared/runtime-core.lua", import.meta.url), "utf8");
const corvan = await readFile(new URL("../characters/corvan/runtime.lua", import.meta.url), "utf8");
const fixture = await readFile(new URL("../fixtures/characters/arcane-test/runtime.lua", import.meta.url), "utf8");

test("core compartilhado não contém regras, callbacks TTS ou execução dinâmica", () => {
  assert.match(core, /CharacterRuntimeCore = \{\}/);
  for (const contract of [
    "deepCopy", "chatSafeRichText", "formatChatRollResult", "envelopeState",
    "unwrapState", "metadata", "metadataMatches", "createRuntimeApi",
  ]) {
    assert.match(core, new RegExp(`function Core\\.${contract}\\(`));
  }
  assert.doesNotMatch(core, /CorvanRules|Espada|Baluarte|Arcane Test/);
  assert.doesNotMatch(core, /function (?:onLoad|onSave|registerParent|handleUiEvent)\s*\(/);
  assert.doesNotMatch(core, /\b(?:load|loadstring|require)\s*\(/);
});

test("adaptadores usam o envelope e o isolamento fornecidos pelo core", () => {
  assert.match(corvan, /RuntimeCore\.createRuntimeApi\(CORE_CONFIG\)/);
  assert.match(corvan, /AdapterApi\.state\.envelope\(/);
  assert.match(corvan, /AdapterApi\.state\.unwrap\(/);
  assert.match(corvan, /allowLegacyIdentity = CHARACTER_ID == "corvan"/);
  assert.match(fixture, /CharacterRuntimeCore\.createRuntimeApi\(CONFIG\)/);
  assert.match(fixture, /AdapterApi\.state\.envelope\(/);
  assert.match(fixture, /AdapterApi\.state\.unwrap\(/);
  assert.match(fixture, /allowLegacyIdentity = false/);
});

test("chat do core destaca somente nome, resultado e crítico", () => {
  assert.match(core, /colorSegment\("FF6464", shortName\)/);
  assert.match(core, /colorSegment\("62B8FF", total\)/);
  assert.match(core, /suffix == "CRÍTICO"/);
  assert.match(core, /formatChatDice\(count, sides, values\)/);
  assert.doesNotMatch(core, /\[E8EDF2\]|\[63E6A5\]|\[FFD166\]|\[b\]|\[\/b\]/);
});
