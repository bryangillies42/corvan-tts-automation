import assert from "node:assert/strict";
import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  buildFixture,
  buildProject,
  loadCharacterRegistry,
  validateCharacterProfile,
} from "../scripts/build.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const RELEASE_SHA = "c8e7cd2a35eb60e56fcc5587d09fdfdab90528c7";

async function temporaryProject(t) {
  const directory = await mkdtemp(join(tmpdir(), "runtime-libraries-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  for (const name of ["characters", "shared", "fixtures"]) {
    await cp(join(ROOT, name), join(directory, name), { recursive: true });
  }
  return directory;
}

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

test("runtimeLibraries entra entre o core e o adaptador na ordem declarada", async (t) => {
  const project = await temporaryProject(t);
  const profilePath = join(project, "fixtures", "characters", "arcane-test", "profile.json");
  const profile = JSON.parse(await readFile(profilePath, "utf8"));
  profile.runtimeLibraries = ["shared/tts-runtime-host.lua", "shared/test-second-library.lua"];
  await writeFile(profilePath, `${JSON.stringify(profile, null, 2)}\n`, "utf8");
  await writeFile(join(project, "shared", "test-second-library.lua"), "SECOND_RUNTIME_LIBRARY = true\n", "utf8");

  const result = await buildFixture({
    rootDir: project,
    outDir: join(project, "dist-arcane"),
    commitSha: RELEASE_SHA,
  });
  const runtime = result.files["arcane-test-runtime.lua"];
  const coreIndex = runtime.indexOf("CharacterRuntimeCore = {}");
  const hostIndex = runtime.indexOf("TtsRuntimeHost = TtsRuntimeHost or {}");
  const secondIndex = runtime.indexOf("SECOND_RUNTIME_LIBRARY = true");
  const adapterIndex = runtime.indexOf("-- ARCANE_TEST_RUNTIME");

  assert.ok(coreIndex >= 0);
  assert.ok(hostIndex > coreIndex);
  assert.ok(secondIndex > hostIndex);
  assert.ok(adapterIndex > secondIndex);
  assert.equal((runtime.match(/TtsRuntimeHost = TtsRuntimeHost or \{\}/g) || []).length, 1);
});

test("runtimeLibraries rejeita caminhos inseguros, duplicados e componentes reservados", () => {
  const base = {
    id: "test", displayName: "Test", shortName: "Test", version: "0.1.0", status: "active",
    sourceDir: "characters/test", tagMode: "namespaced", discovery: "character-releases",
    prerelease: true, globalLatest: false, productionEnabled: false,
    files: {}, runtimeMarker: "TEST_RUNTIME", uiRootId: "testRoot", uiContract: "generic",
    minBootstrapVersion: "1.0.2", guid: "abc123",
  };
  for (const [paths, pattern] of [
    [["../outside.lua"], /caminho relativo seguro/],
    [["characters/test/library.lua"], /dentro de shared/],
    [["shared/library.txt"], /arquivo Lua/],
    [["shared/bootstrap.lua"], /não pode repetir/],
    [["shared/runtime-core.lua"], /não pode repetir/],
    [["shared/library.lua", "shared/library.lua"], /duplicado/],
  ]) {
    assert.throws(() => validateCharacterProfile({ ...base, runtimeLibraries: paths }), pattern);
  }
});

test("build falha de forma explícita quando uma biblioteca declarada não existe", async (t) => {
  const project = await temporaryProject(t);
  const profilePath = join(project, "fixtures", "characters", "arcane-test", "profile.json");
  const profile = JSON.parse(await readFile(profilePath, "utf8"));
  profile.runtimeLibraries = ["shared/missing.lua"];
  await writeFile(profilePath, `${JSON.stringify(profile, null, 2)}\n`, "utf8");

  await assert.rejects(
    buildFixture({ rootDir: project, outDir: join(project, "dist-missing") }),
    /Não foi possível ler shared\/missing\.lua/,
  );
});
