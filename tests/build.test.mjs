import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cp, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  buildProject,
  luaLongString,
  replaceSinglePlaceholder,
  validateCharacter,
  validateUi,
} from "../scripts/build.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const FIXED_SHA = "0123456789abcdef0123456789abcdef01234567";
const PLACEHOLDERS = [
  "__UI_XML_LITERAL__",
  "__CHARACTER_JSON_LITERAL__",
  "__SEED_UI_LITERAL__",
  "__SEED_RUNTIME_LITERAL__",
];

async function temporaryProject(t) {
  const directory = await mkdtemp(join(tmpdir(), "corvan-build-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await cp(join(ROOT, "src"), join(directory, "src"), { recursive: true });
  await cp(join(ROOT, "package.json"), join(directory, "package.json"));
  return directory;
}

async function readOutputs(directory) {
  const names = (await readdir(directory)).sort();
  const files = {};
  for (const name of names) files[name] = await readFile(join(directory, name), "utf8");
  return { names, files };
}

test("o build é determinístico para os mesmos fontes e commit", async (t) => {
  const project = await temporaryProject(t);
  const firstDirectory = join(project, "dist-a");
  const secondDirectory = join(project, "dist-b");

  await buildProject({ rootDir: project, outDir: firstDirectory, commitSha: FIXED_SHA });
  await buildProject({ rootDir: project, outDir: secondDirectory, commitSha: FIXED_SHA });

  const first = await readOutputs(firstDirectory);
  const second = await readOutputs(secondDirectory);
  assert.deepEqual(first.names, ["Corvan_Duras_Console.json", "corvan-runtime.lua", "manifest.json"]);
  assert.deepEqual(first, second);
});

test("placeholders obrigatórios precisam aparecer exatamente uma vez", async (t) => {
  const project = await temporaryProject(t);
  const cases = [
    { file: "runtime.lua", placeholder: "__UI_XML_LITERAL__" },
    { file: "runtime.lua", placeholder: "__CHARACTER_JSON_LITERAL__" },
    { file: "bootstrap.lua", placeholder: "__SEED_UI_LITERAL__" },
    { file: "bootstrap.lua", placeholder: "__SEED_RUNTIME_LITERAL__" },
  ];

  for (const fixture of cases) {
    await t.test(`rejeita ${fixture.placeholder} ausente`, async () => {
      const path = join(project, "src", fixture.file);
      const original = await readFile(path, "utf8");
      await writeFile(path, original.replace(fixture.placeholder, "nil"), "utf8");
      try {
        await assert.rejects(
          buildProject({ rootDir: project, outDir: join(project, `out-${fixture.placeholder}`) }),
          new RegExp(`Placeholder obrigatório ${fixture.placeholder} não encontrado`),
        );
      } finally {
        await writeFile(path, original, "utf8");
      }
    });
  }

  assert.throws(
    () => replaceSinglePlaceholder("X token token", "token", "value"),
    /deve aparecer exatamente uma vez/,
  );
});

test("literal Lua escolhe delimitador sem colidir com o conteúdo", () => {
  const literal = luaLongString("primeira ]] segunda ]=] terceira\n");
  assert.match(literal, /^\[==\[/);
  assert.match(literal, /\]==\]$/);
  assert.equal(luaLongString("\ncomeça em nova linha").startsWith('"\\n" .. ['), true);
});

test("a ficha possui o schema e os valores canônicos do Corvan", async () => {
  const character = JSON.parse(await readFile(join(ROOT, "src", "character.json"), "utf8"));
  validateCharacter(character, "0.1.6");

  assert.equal(character.schemaVersion, 1);
  assert.equal(character.name, "Corvan Duras");
  assert.deepEqual(
    { hp: character.resources.hp.max, mp: character.resources.mp.max },
    { hp: 55, mp: 15 },
  );
  assert.equal(character.defense, 20);
  assert.equal(character.damageReduction, 8);
  assert.deepEqual(character.weapons.sword, {
    name: "Espada Longa",
    chatName: "Espada",
    attack: 9,
    damage: { count: 1, sides: 8, bonus: 5 },
    critical: { min: 19, multiplier: 2 },
    type: "Corte",
    range: "Curto",
  });
  assert.deepEqual(character.weapons.shield, {
    name: "Escudo Pesado",
    chatName: "Escudo",
    attack: 9,
    damage: { count: 1, sides: 6, bonus: 5 },
    critical: { min: 20, multiplier: 2 },
    type: "Impacto",
    range: "Curto",
  });
  assert.deepEqual(
    Object.fromEntries(Object.entries(character.skills).map(([id, skill]) => [id, skill.modifier])),
    { initiative: 3, fight: 9, intimidation: 7, perception: 3, fortitude: 9, reflex: 5, will: 5 },
  );
  assert.deepEqual(
    Object.fromEntries(Object.entries(character.powers).map(([id, power]) => [id, power.cost ?? 0])),
    { combatDefensive: 0, duel: 2, baluarte: 1, armedTower: 1, provocation: 2, solidity: 0, platesOfWrath: 0, bastion: 0 },
  );
  assert.equal(
    character.powers.bastion.damageReduction + character.powers.platesOfWrath.damageReduction,
    character.damageReduction,
  );
  assert.deepEqual(
    {
      base: character.powers.baluarte.defenseModifier,
      upgraded: character.powers.baluarte.upgradedDefenseModifier,
      totalUpgradeCost: character.powers.baluarte.cost + character.powers.baluarte.upgradeCost,
    },
    { base: 2, upgraded: 4, totalUpgradeCost: 2 },
  );
});

test("validadores rejeitam character e UI estruturalmente inválidos", async () => {
  const character = JSON.parse(await readFile(join(ROOT, "src", "character.json"), "utf8"));
  const invalidCharacter = structuredClone(character);
  invalidCharacter.weapons.sword.damage.sides = 1;
  assert.throws(() => validateCharacter(invalidCharacter, "0.1.6"), /damage\.sides/);

  const prereleaseCharacter = structuredClone(character);
  prereleaseCharacter.version = "0.1.0-rc.1";
  assert.throws(
    () => validateCharacter(prereleaseCharacter, "0.1.0-rc.1"),
    /SemVer estável X\.Y\.Z/,
  );

  const ui = await readFile(join(ROOT, "src", "ui.xml"), "utf8");
  validateUi(ui);
  assert.match(ui, /<Panel id="corvanConsole"[^>]*position="[^"]+"[^>]*rotation="[^"]+"[^>]*scale="[^"]+"/s);
  assert.doesNotMatch(ui, /\btooltip(?:Position|FontSize|TextColor|BackgroundColor|BorderColor)?\s*=/i);
  assert.ok(ui.indexOf("<Defaults>") < ui.indexOf('<Panel id="corvanConsole"'));
  assert.throws(() => validateUi(ui.replace(/<\/Panel>\s*$/, "")), /não foi fechada/);
});

test("manifesto e Saved Object possuem o contrato publicável", async (t) => {
  const project = await temporaryProject(t);
  const outDir = join(project, "dist");
  await buildProject({ rootDir: project, outDir, commitSha: FIXED_SHA });

  const runtime = await readFile(join(outDir, "corvan-runtime.lua"), "utf8");
  const manifest = JSON.parse(await readFile(join(outDir, "manifest.json"), "utf8"));
  const saved = JSON.parse(await readFile(join(outDir, "Corvan_Duras_Console.json"), "utf8"));

  assert.equal(manifest.schemaVersion, 1);
  assert.equal(manifest.version, "0.1.6");
  assert.equal(manifest.minBootstrapVersion, "1.0.2");
  assert.equal(manifest.commitSha, FIXED_SHA);
  assert.equal(
    manifest.runtime.url,
    "https://github.com/bryangillies42/corvan-tts-automation/releases/download/v0.1.6/corvan-runtime.lua",
  );
  assert.equal(manifest.runtime.size, Buffer.byteLength(runtime, "utf8"));
  assert.equal(manifest.runtime.sha256, createHash("sha256").update(runtime, "utf8").digest("hex"));
  assert.equal(manifest.previousVersion, null);

  for (const placeholder of PLACEHOLDERS) {
    assert.equal(runtime.includes(placeholder), false);
  }
  assert.match(runtime, /CORVAN_RUNTIME/);
  assert.match(runtime, /<Panel id="corvanConsole"/);
  assert.match(runtime, /Corvan Duras/);

  assert.equal(saved.SaveName, "Corvan Duras Console");
  assert.equal(saved.ObjectStates.length, 1);
  const object = saved.ObjectStates[0];
  assert.equal(object.Name, "Custom_Tile");
  assert.equal(object.Transform.scaleX, 1);
  assert.equal(object.Transform.scaleZ, 1);
  assert.equal(object.Locked, false);
  assert.equal(
    object.CustomImage.ImageURL,
    `https://raw.githubusercontent.com/bryangillies42/corvan-tts-automation/${FIXED_SHA}/assets/panel-board.png`,
  );
  assert.deepEqual(object.CustomImage.CustomTile, {
    Type: 0,
    Thickness: 0.2,
    Stackable: false,
    Stretch: true,
  });
  assert.match(object.XmlUI, /<Defaults>[\s\S]*<Panel id="corvanConsole"/);
  assert.match(object.XmlUI, /position="0 0 -50"/);
  assert.match(object.XmlUI, /rotation="0 0 180"/);
  assert.match(object.XmlUI, /scale="0\.25 0\.25 1"/);
  assert.match(object.LuaScript, /CORVAN_RUNTIME/);
  assert.match(object.LuaScript, /<Panel id="corvanConsole"/);
  for (const placeholder of PLACEHOLDERS) assert.equal(object.LuaScript.includes(placeholder), false);
});

test("manifesto aceita somente uma versão anterior estável e realmente menor", async (t) => {
  const project = await temporaryProject(t);
  const valid = await buildProject({
    rootDir: project,
    outDir: join(project, "dist-previous"),
    commitSha: FIXED_SHA,
    previousVersion: "0.1.5",
  });
  assert.equal(valid.manifest.previousVersion, "0.1.5");

  await assert.rejects(
    buildProject({
      rootDir: project,
      outDir: join(project, "dist-invalid-previous"),
      commitSha: FIXED_SHA,
      previousVersion: "0.1.6",
    }),
    /deve ser anterior/,
  );
});
