import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const run = promisify(execFile);
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const SCRIPT = join(ROOT, "scripts", "new-character.mjs");

test("character:new cria scaffold sem regras fictícias e recusa duplicatas", async (t) => {
  const workspace = await mkdtemp(join(tmpdir(), "character-scaffold-"));
  t.after(() => rm(workspace, {recursive: true, force: true}));
  await mkdir(join(workspace, "characters"), {recursive: true});
  await cp(join(ROOT, "characters", "registry.json"), join(workspace, "characters", "registry.json"));
  await cp(join(ROOT, "templates"), join(workspace, "templates"), {recursive: true});

  await run(process.execPath, [
    SCRIPT, "--root", workspace,
    "--id", "novo-heroi",
    "--name", "Novo Herói",
    "--short-name", "Herói",
  ]);

  const profileRegistry = JSON.parse(await readFile(join(workspace, "characters", "registry.json"), "utf8"));
  const profile = profileRegistry.characters.find(({id}) => id === "novo-heroi");
  const character = JSON.parse(await readFile(join(workspace, "characters", "novo-heroi", "character.json"), "utf8"));
  const runtime = await readFile(join(workspace, "characters", "novo-heroi", "runtime.lua"), "utf8");

  assert.equal(profile.status, "scaffold");
  assert.equal(profile.version, null);
  assert.equal(profile.release.productionEnabled, false);
  assert.equal(character.id, "novo-heroi");
  assert.deepEqual(character.resources, {});
  assert.deepEqual(character.actions, {});
  assert.doesNotMatch(runtime, /Corvan|Espada|Baluarte/);
  assert.equal(profile.sourceFiles.bootstrap, undefined);

  await assert.rejects(
    run(process.execPath, [SCRIPT, "--root", workspace, "--id", "novo-heroi", "--name", "Duplicado"]),
    /já existe|já registrado/,
  );
});
