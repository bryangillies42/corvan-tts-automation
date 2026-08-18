import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cp, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { buildFixture, buildProject, validateCharacterProfile } from "../scripts/build.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const RELEASE_SHA = "c8e7cd2a35eb60e56fcc5587d09fdfdab90528c7";
const GOLDEN = {
  "corvan-runtime.lua": "65218ea9ffb302275d7c520628fd9cc5cf23b40c412f3dc4f33d69fa28abb91a",
  "manifest.json": "9f11d8cc3aa599bd04eab89ccd8c90880ffddd8f3e9040d016f698abef30432c",
  "Corvan_Duras_Console.json": "da4c280173600ad6e54bbc1b0a12cc2b5eb26d17fb8f1f73d623c325b01ed548",
};

async function temporaryProject(t) {
  const directory = await mkdtemp(join(tmpdir(), "runtime-libraries-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  for (const name of ["characters", "shared", "fixtures"]) {
    await cp(join(ROOT, name), join(directory, name), { recursive: true });
  }
  return directory;
}

function hash(contents) {
  return createHash("sha256").update(contents, "utf8").digest("hex");
}

test("perfil sem runtimeLibraries preserva os três artefatos oficiais do Corvan v0.2.1 byte a byte", async (t) => {
  const project = await temporaryProject(t);
  const result = await buildProject({
    rootDir: project,
    outDir: join(project, "dist-corvan"),
    characterId: "corvan",
    commitSha: RELEASE_SHA,
    previousVersion: "0.2.0",
  });

  for (const [name, expected] of Object.entries(GOLDEN)) {
    assert.equal(hash(result.files[name]), expected, `${name} divergiu da release v0.2.1`);
  }
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
