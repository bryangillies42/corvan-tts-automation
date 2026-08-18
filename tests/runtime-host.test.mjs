import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const host = await readFile(new URL("../shared/tts-runtime-host.lua", import.meta.url), "utf8");

test("host físico expõe o contrato agnóstico esperado pelo adaptador", () => {
  for (const symbol of [
    "TtsRuntimeHost.create", "host.roll", "host.clear", "host.cancel",
    "host.isRolling", "host.getOwnedGuids", "host.getActiveTransactionId",
    "onComplete", "onRollback", "onFailure",
  ]) assert.match(host, new RegExp(symbol.replace(".", "\\.")));

  for (const [sides, objectType] of [[4, "Die_4"], [6, "Die_6"], [8, "Die_8"], [10, "Die_10"], [12, "Die_12"], [20, "Die_20"]]) {
    assert.match(host, new RegExp(`\\[${sides}\\] = "${objectType}"`));
  }
  for (const metadata of ["characterId", "ownerPanelGuid", "transactionId", "groupId", "dieIndex"]) {
    assert.match(host, new RegExp(metadata));
  }
});

test("host mantém regras de personagem fora da infraestrutura", () => {
  assert.doesNotMatch(host, /SpentarRules|CorvanRules|Profanar|Necropot[eê]ncia|Agrilhoar|Infligir/i);
  assert.match(host, /group\.maximized/);
  assert.match(host, /lastTransactionId == transactionId/);
  assert.match(host, /host\.clear\(\)/);
  assert.match(host, /for guid, _ in pairs\(requested\)/);
  assert.match(host, /if object and belongsToHost\(object\) and destroy\(object\)/);
  assert.doesNotMatch(host, /type\(Wait\) ~= "table"/);
  for (const operation of ["time", "frames", "condition"]) {
    assert.match(host, new RegExp(`type\\(Wait\\.${operation}\\) ~= "function"`));
  }
});
