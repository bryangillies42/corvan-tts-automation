import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { buildProject, loadCharacterRegistry } from "../scripts/build.mjs";

const ROOT = fileURLToPath(new URL("..", import.meta.url));

test("Corvan v0.2.3 permanece independente do host físico opcional do Spentar", async (t) => {
  const registry = await loadCharacterRegistry(ROOT);
  const corvan = registry.characters.find((profile) => profile.id === "corvan");
  assert.ok(corvan);
  assert.equal(corvan.runtimeLibraries, undefined);

  const outDir = await mkdtemp(join(tmpdir(), "corvan-no-runtime-libraries-"));
  t.after(() => rm(outDir, { recursive: true, force: true }));
  await buildProject({
    rootDir: ROOT,
    outDir,
    characterId: "corvan",
    commitSha: "0123456789abcdef0123456789abcdef01234567",
  });

  const runtime = await readFile(join(outDir, "corvan-runtime.lua"), "utf8");
  assert.doesNotMatch(runtime, /TtsRuntimeHost/);
  assert.doesNotMatch(runtime, /SPENTAR_RUNTIME|SpentarRules/);
  assert.match(runtime, /CORVAN_RUNTIME/);
});
