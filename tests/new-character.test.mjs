import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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
  const ui = await readFile(join(workspace, "characters", "novo-heroi", "ui.xml"), "utf8");

  assert.equal(profile.status, "scaffold");
  assert.equal(profile.version, null);
  assert.equal(profile.release.productionEnabled, false);
  assert.equal(profile.uiContract, "generic");
  assert.equal(profile.panelArtId, undefined);
  assert.deepEqual(profile.requiredUiIds, ["novo-heroiConsole", "title"]);
  assert.equal(character.id, "novo-heroi");
  assert.deepEqual(character.resources, {});
  assert.deepEqual(character.actions, {});
  assert.doesNotMatch(runtime, /Corvan|Espada|Baluarte/);
  assert.doesNotMatch(ui, /panelBoardArt|__PANEL_UI_IMAGE_URL_XML__/);
  assert.equal(profile.sourceFiles.bootstrap, undefined);

  await assert.rejects(
    run(process.execPath, [SCRIPT, "--root", workspace, "--id", "novo-heroi", "--name", "Duplicado"]),
    /já existe|já registrado/,
  );
});

test("character:new valida o template antes de criar diretório ou alterar o registry", async (t) => {
  const workspace = await mkdtemp(join(tmpdir(), "character-scaffold-invalid-"));
  t.after(() => rm(workspace, {recursive: true, force: true}));
  await mkdir(join(workspace, "characters"), {recursive: true});
  await cp(join(ROOT, "characters", "registry.json"), join(workspace, "characters", "registry.json"));
  await cp(join(ROOT, "templates"), join(workspace, "templates"), {recursive: true});
  const registryPath = join(workspace, "characters", "registry.json");
  const originalRegistry = await readFile(registryPath, "utf8");
  await writeFile(join(workspace, "templates", "character", "character.json"), "{ inválido", "utf8");

  await assert.rejects(
    run(process.execPath, [SCRIPT, "--root", workspace, "--id", "nao-criado", "--name", "Não Criado"]),
    /Criação falhou/,
  );
  await assert.rejects(readFile(join(workspace, "characters", "nao-criado", "character.json"), "utf8"));
  assert.equal(await readFile(registryPath, "utf8"), originalRegistry);
});

test("character:new escapa nomes em JSON e XML sem alterar a identidade registrada", async (t) => {
  const workspace = await mkdtemp(join(tmpdir(), "character-scaffold-escaped-"));
  t.after(() => rm(workspace, {recursive: true, force: true}));
  await mkdir(join(workspace, "characters"), {recursive: true});
  await cp(join(ROOT, "characters", "registry.json"), join(workspace, "characters", "registry.json"));
  await cp(join(ROOT, "templates"), join(workspace, "templates"), {recursive: true});

  const name = 'Mago & "Lua" <Norte>';
  const shortName = "Mago d'Água";
  await run(process.execPath, [
    SCRIPT, "--root", workspace,
    "--id", "mago-lua",
    "--name", name,
    "--short-name", shortName,
  ]);

  const registry = JSON.parse(await readFile(join(workspace, "characters", "registry.json"), "utf8"));
  const profile = registry.characters.find(({id}) => id === "mago-lua");
  const character = JSON.parse(await readFile(join(workspace, "characters", "mago-lua", "character.json"), "utf8"));
  const ui = await readFile(join(workspace, "characters", "mago-lua", "ui.xml"), "utf8");

  assert.equal(profile.displayName, name);
  assert.equal(profile.shortName, shortName);
  assert.equal(character.name, name);
  assert.equal(character.shortName, shortName);
  assert.match(ui, /text="Mago &amp; &quot;Lua&quot; &lt;Norte&gt;"/);
  assert.doesNotMatch(ui, /text="Mago & "Lua"/);
});
