import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { cp, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  buildAllCharacters,
  buildFixture,
  buildProject,
  loadCharacterRegistry,
  luaLongString,
  replaceSinglePlaceholder,
  validateCharacter,
  validateRegistry,
  validateUi,
} from "../scripts/build.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const FIXED_SHA = "0123456789abcdef0123456789abcdef01234567";
const PLACEHOLDERS = [
  "__UI_XML_LITERAL__",
  "__CHARACTER_JSON_LITERAL__",
  "__PANEL_IMAGE_URL_LITERAL__",
  "__PANEL_UI_IMAGE_URL_LITERAL__",
  "__PANEL_UI_IMAGE_URL_XML__",
  "__SEED_UI_LITERAL__",
  "__SEED_RUNTIME_LITERAL__",
];

test("a v0.2.3 preserva a política de canal e Latest definida no registry", async () => {
  const packageJson = JSON.parse(await readFile(join(ROOT, "package.json"), "utf8"));
  const registry = await loadCharacterRegistry(ROOT);
  const corvan = registry.characters.find((profile) => profile.id === "corvan");
  const workflow = await readFile(join(ROOT, ".github", "workflows", "release.yml"), "utf8");

  assert.equal(packageJson.version, undefined);
  assert.equal(packageJson.release, undefined);
  assert.equal(corvan.version, "0.2.3");
  assert.equal(corvan.prerelease, false);
  assert.equal(corvan.globalLatest, true);
  assert.equal(corvan.tagMode, "legacy");
  assert.match(workflow, /group: release-\$\{\{ github\.ref \}\}/);
  assert.match(workflow, /scripts\/resolve-release\.mjs/);
  assert.match(workflow, /--character "\$\{RELEASE_ID\}"/);
  assert.match(workflow, /latest=false/);
  assert.match(workflow, /gh release edit "\$\{RELEASE_TAG\}" --draft=false --latest/);
  assert.match(workflow, /RELEASE_PRERELEASE/);
});

async function temporaryProject(t) {
  const directory = await mkdtemp(join(tmpdir(), "corvan-build-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await cp(join(ROOT, "characters"), join(directory, "characters"), { recursive: true });
  await cp(join(ROOT, "shared"), join(directory, "shared"), { recursive: true });
  await cp(join(ROOT, "fixtures"), join(directory, "fixtures"), { recursive: true });
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
    { file: "ui.xml", placeholder: "__PANEL_UI_IMAGE_URL_XML__" },
    { file: "bootstrap.lua", placeholder: "__SEED_UI_LITERAL__" },
    { file: "bootstrap.lua", placeholder: "__SEED_RUNTIME_LITERAL__" },
  ];

  for (const fixture of cases) {
    await t.test(`rejeita ${fixture.placeholder} ausente`, async () => {
      const path = fixture.file === "bootstrap.lua"
        ? join(project, "shared", fixture.file)
        : join(project, "characters", "corvan", fixture.file);
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
  const character = JSON.parse(await readFile(join(ROOT, "characters", "corvan", "character.json"), "utf8"));
  validateCharacter(character, "0.2.3");

  assert.equal(character.schemaVersion, 1);
  assert.equal(character.name, "Corvan Duras");
  assert.deepEqual(
    { hp: character.resources.hp.max, mp: character.resources.mp.max },
    { hp: 78, mp: 21 },
  );
  assert.equal(character.defense, 24);
  assert.equal(character.damageReduction, 10);
  assert.deepEqual(character.weapons.sword, {
    name: "Espada Maculada pela Ira",
    chatName: "Espada",
    attack: 13,
    damage: { count: 2, sides: 8, bonus: 10 },
    critical: { min: 18, multiplier: 2 },
    type: "Corte",
    range: "Corpo a corpo",
  });
  assert.deepEqual(character.weapons.shield, {
    name: "Escudo Pesado",
    chatName: "Escudo",
    attack: 12,
    defenseModifier: 4,
    damage: { count: 1, sides: 6, bonus: 5 },
    critical: { min: 20, multiplier: 2 },
    type: "Impacto",
    range: "Corpo a corpo",
  });
  assert.deepEqual(
    Object.fromEntries(Object.entries(character.skills).map(([id, skill]) => [id, skill.modifier])),
    {
      initiative: 3, fight: 12, intimidation: 6, perception: 8,
      fortitude: 15, reflex: 7, will: 8, riding: 7,
      diplomacy: 10, warfare: 8, aim: 7,
    },
  );
  assert.deepEqual(
    Object.fromEntries(Object.entries(character.powers).map(([id, power]) => [id, power.cost ?? 0])),
    {
      combatDefensive: 0, duel: 2, baluarte: 1, provocation: 2,
      solidity: 0, duelistShielded: 0, weaponAndShieldStyle: 0,
      ambitionWeapons: 0, armored: 0,
      platesOfWrath: 0, bastion: 0,
    },
  );
  assert.equal(
    character.powers.bastion.damageReduction + character.powers.platesOfWrath.damageReduction,
    character.damageReduction,
  );
  assert.equal(character.powers.platesOfWrath.damageReduction, 5);
  assert.equal(character.powers.duelistShielded.damageReduction, 2);
  assert.equal(character.powers.duelistShielded.upgradedDamageReduction, 3);
  assert.equal(character.powers.solidity.resistanceModifier, 4);
  assert.equal(character.powers.weaponAndShieldStyle.shieldDefenseModifier, 4);
  assert.deepEqual(
    {
      base: character.powers.duel.attackModifier,
      upgraded: character.powers.duel.upgradedAttackModifier,
      totalUpgradeCost: character.powers.duel.cost + character.powers.duel.upgradeCost,
    },
    { base: 2, upgraded: 3, totalUpgradeCost: 3 },
  );
  assert.deepEqual(
    {
      base: character.powers.baluarte.defenseModifier,
      upgraded: character.powers.baluarte.upgradedDefenseModifier,
      totalUpgradeCost: character.powers.baluarte.cost + character.powers.baluarte.upgradeCost,
    },
    { base: 2, upgraded: 4, totalUpgradeCost: 2 },
  );
  assert.equal(character.powers.baluarte.sharedCost, 2);
  const ui = await readFile(join(ROOT, "characters", "corvan", "ui.xml"), "utf8");
  assert.match(ui, /id="pvCurrent" text="78"/);
  assert.match(ui, /id="pmCurrent" text="21"/);
  assert.match(ui, /id="defenseValue" text="24"/);
  assert.match(ui, /id="attackValue" text="\+13"/);
  assert.match(ui, /id="damageValue" text="2d8\+10"/);
  assert.match(ui, /ESPADA MACULADA PELA IRA/);
  assert.match(ui, /CRÍTICO 18–20\/x2/);
  assert.match(ui, /id="rdValue" text="10"/);
  assert.match(ui, /RD 5 \+ 5 = 10/);
  assert.match(ui, /id="versionLabel" text="v0\.2\.3/);
  assert.match(ui, /id="calculatedDefenseValue" text="24"/);
});

test("validadores rejeitam character e UI estruturalmente inválidos", async () => {
  const character = JSON.parse(await readFile(join(ROOT, "characters", "corvan", "character.json"), "utf8"));
  const invalidCharacter = structuredClone(character);
  invalidCharacter.weapons.sword.damage.sides = 1;
  assert.throws(() => validateCharacter(invalidCharacter, "0.2.3"), /damage\.sides/);

  const prereleaseCharacter = structuredClone(character);
  prereleaseCharacter.version = "0.1.0-rc.1";
  assert.throws(
    () => validateCharacter(prereleaseCharacter, "0.1.0-rc.1"),
    /SemVer estável X\.Y\.Z/,
  );

  const ui = await readFile(join(ROOT, "characters", "corvan", "ui.xml"), "utf8");
  validateUi(ui);
  assert.match(ui, /<Image id="panelBoardArt"[^>]*position="0 0 -30"[^>]*rotation="0 0 180"[^>]*scale="0\.25 0\.25 1"/s);
  assert.match(ui, /<Panel id="corvanConsole"[^>]*position="0 0 -30"[^>]*rotation="0 0 180"[^>]*scale="0\.25 0\.25 1"/s);
  assert.match(ui, /<Image id="panelBoardArt"[^>]*width="1870" height="841"/s);
  assert.match(ui, /<Panel id="corvanConsole"[^>]*width="1700" height="750"/s);
  assert.ok(ui.indexOf('id="panelBoardArt"') < ui.indexOf('id="mainLayout"'));
  assert.doesNotMatch(ui, /\btooltip(?:Position|FontSize|TextColor|BackgroundColor|BorderColor)?\s*=/i);
  assert.ok(ui.indexOf("<Defaults>") < ui.indexOf('<Panel id="corvanConsole"'));
  assert.throws(() => validateUi(ui.replace(/<\/Panel>\s*$/, "")), /não foi fechada/);
  assert.throws(
    () => validateUi(ui.replace('position="0 0 -30"', 'position="0 0 -29"')),
    /mesma transformação 3D/,
  );
  assert.throws(
    () => validateUi(ui.replace('<Panel id="corvanConsole" width="1700"', '<Panel id="corvanConsole" width="1800"')),
    /preservar a geometria declarada/,
  );
  assert.throws(
    () => validateUi(ui.replace(' active="false"', "")),
    /active/,
  );
  assert.throws(
    () => validateUi(ui.replace(' raycastTarget="false"', "")),
    /raycastTarget/,
  );
  assert.throws(
    () => validateUi(ui.replace('color="#07090CD8"', "")),
    /color/,
  );
  assert.throws(
    () => validateUi(ui.replace('color="#07090CD8"', 'color=""')),
    /#RRGGBB/,
  );
  assert.throws(
    () => validateUi(ui.replace('color="#07090CD8"', 'color="#07090C00"')),
    /totalmente transparente/,
  );

  const genericUi = '<Panel id="customRoot"><VerticalLayout><Text id="customValue" /></VerticalLayout></Panel>';
  validateUi(genericUi, {
    uiContract: "generic",
    uiRootId: "customRoot",
    requiredUiIds: ["customValue"],
  });
  assert.throws(
    () => validateUi(genericUi.replace("</VerticalLayout>", ""), {
      uiContract: "generic",
      uiRootId: "customRoot",
      requiredUiIds: ["customValue"],
    }),
    /não corresponde|não foi fechada/,
  );
  assert.throws(
    () => validateUi(genericUi, {
      uiContract: "generic",
      uiRootId: "customRoot",
      requiredUiIds: ["missing"],
    }),
    /ID obrigatório missing/,
  );
});

test("build não depende da permissão de publicação", async (t) => {
  const project = await temporaryProject(t);
  const registryPath = join(project, "characters", "registry.json");
  const registry = JSON.parse(await readFile(registryPath, "utf8"));
  registry.characters[0].release.productionEnabled = false;
  await writeFile(registryPath, JSON.stringify(registry, null, 2), "utf8");

  const individual = await buildProject({
    rootDir: project,
    outDir: join(project, "dist-disabled-individual"),
    characterId: "corvan",
    commitSha: FIXED_SHA,
  });
  const all = await buildAllCharacters({
    rootDir: project,
    outDir: join(project, "dist-disabled-all"),
    commitSha: FIXED_SHA,
  });

  assert.equal(individual.profile.productionEnabled, false);
  assert.equal(all.some((result) => result.profile.id === "corvan"), true);
});

test("contrato generic builda uma UI estrutural sem moldura nem asset visual de UI", async (t) => {
  const project = await temporaryProject(t);
  const fixtureRoot = join(project, "fixtures", "characters", "arcane-test");
  const profilePath = join(fixtureRoot, "profile.json");
  const profile = JSON.parse(await readFile(profilePath, "utf8"));
  profile.uiContract = "generic";
  profile.tagMode = "namespaced";
  profile.requiredUiIds = ["arcaneTestConsole", "arcaneFocus", "cast"];
  delete profile.panelArtId;
  delete profile.geometry;
  delete profile.assets.panelUiImageUrl;
  await writeFile(profilePath, JSON.stringify(profile, null, 2), "utf8");
  await writeFile(
    join(fixtureRoot, "ui.xml"),
    '<Panel id="arcaneTestConsole"><Text id="arcaneFocus" /><Button id="cast" /></Panel>\n',
    "utf8",
  );

  const result = await buildFixture({
    rootDir: project,
    outDir: join(project, "dist-generic"),
    commitSha: FIXED_SHA,
  });

  assert.equal(result.panelUiImageUrl, null);
  assert.match(result.savedObject.ObjectStates[0].XmlUI, /^<Panel id="arcaneTestConsole">/);
  assert.doesNotMatch(result.savedObject.ObjectStates[0].XmlUI, /<Image\b|PANEL_UI_IMAGE/);
});

test("manifesto e Saved Object possuem o contrato publicável", async (t) => {
  const project = await temporaryProject(t);
  const outDir = join(project, "dist");
  await buildProject({ rootDir: project, outDir, commitSha: FIXED_SHA });

  const runtime = await readFile(join(outDir, "corvan-runtime.lua"), "utf8");
  const manifest = JSON.parse(await readFile(join(outDir, "manifest.json"), "utf8"));
  const saved = JSON.parse(await readFile(join(outDir, "Corvan_Duras_Console.json"), "utf8"));

  assert.equal(manifest.schemaVersion, 1);
  assert.equal(manifest.characterId, "corvan");
  assert.equal(manifest.releaseTag, "v0.2.3");
  assert.equal(manifest.version, "0.2.3");
  assert.equal(manifest.minBootstrapVersion, "1.0.2");
  assert.equal(manifest.commitSha, FIXED_SHA);
  assert.equal(
    manifest.runtime.url,
    "https://github.com/bryangillies42/corvan-tts-automation/releases/download/v0.2.3/corvan-runtime.lua",
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
  const panelHash = createHash("sha256")
    .update(await readFile(join(ROOT, "characters", "corvan", "assets", "panel-board.png")))
    .digest("hex");
  const uiPanelHash = createHash("sha256")
    .update(await readFile(join(ROOT, "characters", "corvan", "assets", "panel-board-ui.jpg")))
    .digest("hex");
  const expectedPanelUrl = `https://raw.githubusercontent.com/bryangillies42/corvan-tts-automation/${FIXED_SHA}/characters/corvan/assets/panel-board.png?sha256=${panelHash}`;
  const expectedUiPanelUrl = `https://raw.githubusercontent.com/bryangillies42/corvan-tts-automation/${FIXED_SHA}/characters/corvan/assets/panel-board-ui.jpg?sha256=${uiPanelHash}`;
  assert.ok(runtime.includes(expectedPanelUrl));
  assert.ok(runtime.includes(expectedUiPanelUrl));

  assert.equal(saved.SaveName, "Corvan Duras Console");
  assert.equal(saved.ObjectStates.length, 1);
  const object = saved.ObjectStates[0];
  assert.equal(object.Name, "Custom_Tile");
  assert.equal(object.Transform.scaleX, 1);
  assert.equal(object.Transform.scaleZ, 1);
  assert.equal(object.Locked, false);
  assert.equal(
    object.CustomImage.ImageURL,
    expectedPanelUrl,
  );
  assert.deepEqual(object.CustomImage.CustomTile, {
    Type: 0,
    Thickness: 0.2,
    Stackable: false,
    Stretch: true,
  });
  assert.match(object.XmlUI, /<Defaults>[\s\S]*<Panel id="corvanConsole"/);
  assert.doesNotMatch(object.XmlUI, /position="0 0 -50"/);
  assert.equal((object.XmlUI.match(/position="0 0 -30"/g) ?? []).length, 2);
  assert.match(object.XmlUI, /<Image id="panelBoardArt"[^>]*width="1870" height="841"/s);
  assert.match(object.XmlUI, /<Panel id="corvanConsole"[^>]*width="1700" height="750"/s);
  assert.match(object.XmlUI, /rotation="0 0 180"/);
  assert.match(object.XmlUI, /scale="0\.25 0\.25 1"/);
  assert.ok(object.XmlUI.includes(`image="${expectedUiPanelUrl}"`));
  assert.ok(object.XmlUI.indexOf('id="panelBoardArt"') < object.XmlUI.indexOf('id="mainLayout"'));
  assert.match(object.LuaScript, /CORVAN_RUNTIME/);
  assert.match(object.LuaScript, /<Panel id="corvanConsole"/);
  for (const placeholder of PLACEHOLDERS) assert.equal(object.LuaScript.includes(placeholder), false);
});

test("assets visuais usam fingerprint para invalidar o cache do TTS", async (t) => {
  const project = await temporaryProject(t);
  const first = await buildProject({
    rootDir: project,
    outDir: join(project, "dist-cache-a"),
  });

  const panelPath = join(project, "characters", "corvan", "assets", "panel-board.png");
  const originalPanel = await readFile(panelPath);
  await writeFile(panelPath, Buffer.concat([originalPanel, Buffer.from("cache-regression")]));

  const second = await buildProject({
    rootDir: project,
    outDir: join(project, "dist-cache-b"),
  });

  assert.match(first.panelImageUrl, /panel-board\.png\?sha256=[0-9a-f]{64}$/);
  assert.match(first.panelUiImageUrl, /panel-board-ui\.jpg\?sha256=[0-9a-f]{64}$/);
  assert.notEqual(second.panelImageUrl, first.panelImageUrl);
  assert.equal(second.panelUiImageUrl, first.panelUiImageUrl);
  assert.equal(first.savedObject.ObjectStates[0].CustomImage.ImageURL, first.panelImageUrl);
  assert.ok(first.savedObject.ObjectStates[0].XmlUI.includes(first.panelUiImageUrl));
});

test("a camada visual cobre as dimensões nativas da prancha física", async () => {
  const physical = await readFile(join(ROOT, "characters", "corvan", "assets", "panel-board.png"));
  assert.equal(physical.subarray(1, 4).toString("ascii"), "PNG");
  const physicalWidth = physical.readUInt32BE(16);
  const physicalHeight = physical.readUInt32BE(20);
  const ui = await readFile(join(ROOT, "characters", "corvan", "ui.xml"), "utf8");
  const overlay = ui.match(/<Image id="panelBoardArt"[^>]*width="(\d+)" height="(\d+)"/s);

  assert.ok(overlay);
  assert.equal(Number(overlay[1]), physicalWidth);
  assert.equal(Number(overlay[2]), physicalHeight);
  assert.deepEqual({ width: physicalWidth, height: physicalHeight }, { width: 1870, height: 841 });
});

test("espelho legado de assets preserva as URLs usadas por objetos Corvan v0.2.0", async () => {
  for (const file of ["panel-board.png", "panel-board-ui.jpg"]) {
    const legacy = await readFile(join(ROOT, "assets", file));
    const canonical = await readFile(join(ROOT, "characters", "corvan", "assets", file));
    assert.deepEqual(legacy, canonical, `${file} precisa permanecer byte a byte no caminho legado`);
  }
});

test("URLs locais de textura, camada e fixture legado permanecem independentes", async (t) => {
  const project = await temporaryProject(t);
  await rm(join(project, "characters", "corvan", "assets"), { recursive: true, force: true });
  const physicalUrl = "C:\\Teste\\painel atual.png";
  const uiUrl = 'https://example.test/painel.jpg?x=1&label="Corvan"';
  const legacyUrl = "https://example.test/painel-antigo.png";
  const result = await buildProject({
    rootDir: project,
    outDir: join(project, "dist-local"),
    commitSha: FIXED_SHA,
    assetUrl: physicalUrl,
    uiAssetUrl: uiUrl,
    savedObjectAssetUrl: legacyUrl,
    savedObjectName: "Corvan • teste legado",
  });

  const object = result.savedObject.ObjectStates[0];
  assert.equal(result.panelImageUrl, physicalUrl);
  assert.equal(result.panelUiImageUrl, uiUrl);
  assert.equal(object.CustomImage.ImageURL, legacyUrl);
  assert.equal(result.savedObject.SaveName, "Corvan • teste legado");
  assert.equal(object.Nickname, "Corvan • teste legado");
  assert.ok(result.files["corvan-runtime.lua"].includes(physicalUrl));
  assert.match(object.XmlUI, /image="https:\/\/example\.test\/painel\.jpg\?x=1&amp;label=&quot;Corvan&quot;"/);
  for (const placeholder of PLACEHOLDERS) {
    assert.equal(result.files["corvan-runtime.lua"].includes(placeholder), false);
    assert.equal(object.LuaScript.includes(placeholder), false);
    assert.equal(object.XmlUI.includes(placeholder), false);
  }
});

test("manifesto aceita somente uma versão anterior estável e realmente menor", async (t) => {
  const project = await temporaryProject(t);
  const valid = await buildProject({
    rootDir: project,
    outDir: join(project, "dist-previous"),
    commitSha: FIXED_SHA,
    previousVersion: "0.2.2",
  });
  assert.equal(valid.manifest.previousVersion, "0.2.2");

  await assert.rejects(
    buildProject({
      rootDir: project,
      outDir: join(project, "dist-invalid-previous"),
      commitSha: FIXED_SHA,
      previousVersion: "0.2.3",
    }),
    /deve ser anterior/,
  );
});

test("registry é a fonte única e recusa identidades, caminhos e canais conflitantes", async () => {
  const registry = await loadCharacterRegistry(ROOT);
  const corvan = registry.characters.find((profile) => profile.id === "corvan");
  const spentar = registry.characters.find((profile) => profile.id === "spentar");

  assert.equal(corvan.version, "0.2.3");
  assert.equal(corvan.sourceDir, "characters/corvan");
  assert.equal(spentar.status, "active");
  assert.equal(spentar.version, "0.1.0");
  assert.equal(spentar.productionEnabled, false);
  assert.equal(spentar.tagMode, "namespaced");
  assert.deepEqual(spentar.runtimeLibraries, ["shared/tts-runtime-host.lua"]);
  assert.equal(spentar.assets.panelImage, "panel-board.png");

  const duplicate = structuredClone(registry);
  duplicate.characters.push(structuredClone(corvan));
  assert.throws(() => validateRegistry(duplicate), /ID de personagem duplicado/);

  const externalPath = structuredClone(registry);
  externalPath.characters[0].sourceDir = "../fora";
  assert.throws(() => validateRegistry(externalPath), /caminho relativo seguro/);

  const wrongLatest = structuredClone(registry);
  wrongLatest.characters[1].globalLatest = true;
  assert.throws(() => validateRegistry(wrongLatest), /Somente o Corvan legacy/);

  const externalAsset = structuredClone(registry);
  externalAsset.characters[0].assets.panelImage = "../painel.png";
  assert.throws(() => validateRegistry(externalAsset), /apenas um nome de arquivo/);

  const divergentArtifacts = structuredClone(registry);
  divergentArtifacts.characters[0].release.artifacts.runtime = "outro-runtime.lua";
  assert.throws(() => validateRegistry(divergentArtifacts), /devem declarar os mesmos artefatos/);

  const wrongCorvanTagMode = structuredClone(registry);
  wrongCorvanTagMode.characters[0].tagMode = "namespaced";
  assert.throws(() => validateRegistry(wrongCorvanTagMode), /Corvan deve preservar tagMode legacy/);

  const legacySecondCharacter = structuredClone(registry);
  legacySecondCharacter.characters[1].tagMode = "legacy";
  assert.throws(() => validateRegistry(legacySecondCharacter), /tagMode deve ser namespaced/);
});

test("Corvan e fixture divergente geram produtos isolados sem colisão", async (t) => {
  const project = await temporaryProject(t);
  const productsRoot = join(project, "products");
  const [corvan] = await buildAllCharacters({
    rootDir: project,
    outDir: productsRoot,
    commitSha: FIXED_SHA,
  });
  const arcane = await buildFixture({
    rootDir: project,
    outDir: join(productsRoot, "arcane-test"),
    fixtureId: "arcane-test",
    commitSha: FIXED_SHA,
  });

  assert.deepEqual(Object.keys(corvan.files).sort(), [
    "Corvan_Duras_Console.json", "corvan-runtime.lua", "manifest.json",
  ]);
  assert.deepEqual(Object.keys(arcane.files).sort(), [
    "Arcane_Test_Console.json", "arcane-test-manifest.json", "arcane-test-runtime.lua",
  ]);
  assert.equal(corvan.manifest.characterId, "corvan");
  assert.equal(corvan.manifest.releaseTag, "v0.2.3");
  assert.equal(arcane.manifest.characterId, "arcane-test");
  assert.equal(arcane.manifest.releaseTag, "arcane-test-v0.1.0");
  assert.match(arcane.panelImageUrl, /fixtures\/characters\/arcane-test\/assets\/panel-board\.png\?sha256=[0-9a-f]{64}$/);
  assert.equal(arcane.panelUiImageUrl, arcane.panelImageUrl);
  assert.doesNotMatch(arcane.files["Arcane_Test_Console.json"], /example\.invalid/);
  assert.match(arcane.files["arcane-test-runtime.lua"], /CharacterRuntimeCore = \{\}/);
  assert.match(arcane.files["arcane-test-runtime.lua"], /ARCANE_TEST_RUNTIME/);
  assert.doesNotMatch(arcane.files["arcane-test-runtime.lua"], /CorvanRules/);
  assert.match(arcane.savedObject.ObjectStates[0].XmlUI, /<Image id="arcaneTestArt"[^>]*active="false"[^>]*raycastTarget="false"/s);
  assert.match(arcane.savedObject.ObjectStates[0].XmlUI, /<Panel id="arcaneTestConsole"[^>]*color="#100B20F2"/s);
  assert.match(arcane.savedObject.ObjectStates[0].XmlUI, /<VerticalLayout\b/);
  assert.equal(
    JSON.parse(arcane.savedObject.ObjectStates[0].GMNotes).characterId,
    "arcane-test",
  );
  assert.notEqual(
    corvan.savedObject.ObjectStates[0].GUID,
    arcane.savedObject.ObjectStates[0].GUID,
  );
});
