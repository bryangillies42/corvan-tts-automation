import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const PROJECT_ROOT = resolve(dirname(SCRIPT_PATH), "..");

// Refresh consulta apenas a release estável mais recente. Manter a versão em
// X.Y.Z evita gerar artefatos prerelease que o bootstrap deliberadamente ignora.
const VERSION_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const SHA_PATTERN = /^[0-9a-f]{7,40}$/i;
const DEFAULT_COMMIT_SHA = "0000000000000000000000000000000000000000";
const RAW_ASSET_BASE_URL = "https://raw.githubusercontent.com/bryangillies42/corvan-tts-automation";
const RELEASE_BASE_URL = "https://github.com/bryangillies42/corvan-tts-automation/releases/download";

const PLACEHOLDERS = Object.freeze({
  ui: "__UI_XML_LITERAL__",
  character: "__CHARACTER_JSON_LITERAL__",
  seedUi: "__SEED_UI_LITERAL__",
  seedRuntime: "__SEED_RUNTIME_LITERAL__",
});

function fail(message) {
  throw new Error(message);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function assertString(value, path) {
  assert(typeof value === "string" && value.trim().length > 0, `${path} deve ser uma string não vazia.`);
}

function assertNumber(value, path) {
  assert(typeof value === "number" && Number.isFinite(value), `${path} deve ser um número finito.`);
}

function assertInteger(value, path, minimum = Number.MIN_SAFE_INTEGER) {
  assert(Number.isInteger(value) && value >= minimum, `${path} deve ser um inteiro maior ou igual a ${minimum}.`);
}

function normalizeText(value) {
  return value.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n");
}

function withFinalNewline(value) {
  return `${value.replace(/\n*$/, "")}\n`;
}

function sortJsonValue(value) {
  if (Array.isArray(value)) return value.map(sortJsonValue);
  if (!isObject(value)) return value;

  const sorted = {};
  for (const key of Object.keys(value).sort()) {
    sorted[key] = sortJsonValue(value[key]);
  }
  return sorted;
}

function stableJson(value) {
  return `${JSON.stringify(sortJsonValue(value), null, 2)}\n`;
}

function sha256(value) {
  return createHash("sha256").update(value, "utf8").digest("hex");
}

/**
 * Produz uma long string Lua que não conflita com o conteúdo. Lua remove a
 * primeira quebra logo após `[[`; por isso ela é preservada explicitamente.
 */
export function luaLongString(input) {
  const value = normalizeText(String(input));
  let equals = "";
  while (value.includes(`]${equals}]`)) equals += "=";

  const openingNewline = value.startsWith("\n");
  const body = openingNewline ? value.slice(1) : value;
  const literal = `[${equals}[${body}]${equals}]`;
  return openingNewline ? `"\\n" .. ${literal}` : literal;
}

export function replaceSinglePlaceholder(source, placeholder, replacement, label = placeholder) {
  const first = source.indexOf(placeholder);
  if (first === -1) fail(`Placeholder obrigatório ${label} não encontrado.`);
  if (source.indexOf(placeholder, first + placeholder.length) !== -1) {
    fail(`Placeholder ${label} deve aparecer exatamente uma vez.`);
  }
  return `${source.slice(0, first)}${replacement}${source.slice(first + placeholder.length)}`;
}

export function validateCharacter(character, expectedVersion) {
  assert(isObject(character), "src/character.json deve conter um objeto JSON.");
  assert(character.schemaVersion === 1, "character.schemaVersion deve ser 1.");
  assertString(character.version, "character.version");
  assert(VERSION_PATTERN.test(character.version), "character.version deve usar SemVer estável X.Y.Z.");
  assert(character.version === expectedVersion, "character.version deve ser igual à versão do package.json.");
  assertString(character.name, "character.name");

  assert(isObject(character.resources), "character.resources deve ser um objeto.");
  for (const id of ["hp", "mp"]) {
    const resource = character.resources[id];
    assert(isObject(resource), `character.resources.${id} deve ser um objeto.`);
    assertString(resource.label, `character.resources.${id}.label`);
    assertInteger(resource.max, `character.resources.${id}.max`, 1);
  }

  assertNumber(character.defense, "character.defense");
  assert(character.defense >= 0, "character.defense não pode ser negativa.");
  assertNumber(character.damageReduction, "character.damageReduction");
  assert(character.damageReduction >= 0, "character.damageReduction não pode ser negativa.");

  assert(isObject(character.weapons), "character.weapons deve ser um objeto.");
  for (const id of ["sword", "shield"]) {
    const weapon = character.weapons[id];
    assert(isObject(weapon), `character.weapons.${id} deve ser um objeto.`);
    assertString(weapon.name, `character.weapons.${id}.name`);
    assertString(weapon.chatName, `character.weapons.${id}.chatName`);
    assertNumber(weapon.attack, `character.weapons.${id}.attack`);
    assertString(weapon.type, `character.weapons.${id}.type`);
    assertString(weapon.range, `character.weapons.${id}.range`);

    assert(isObject(weapon.damage), `character.weapons.${id}.damage deve ser um objeto.`);
    assertInteger(weapon.damage.count, `character.weapons.${id}.damage.count`, 1);
    assertInteger(weapon.damage.sides, `character.weapons.${id}.damage.sides`, 2);
    assertNumber(weapon.damage.bonus, `character.weapons.${id}.damage.bonus`);

    assert(isObject(weapon.critical), `character.weapons.${id}.critical deve ser um objeto.`);
    assertInteger(weapon.critical.min, `character.weapons.${id}.critical.min`, 1);
    assert(weapon.critical.min <= 20, `character.weapons.${id}.critical.min não pode exceder 20.`);
    assertInteger(weapon.critical.multiplier, `character.weapons.${id}.critical.multiplier`, 2);
  }

  assert(isObject(character.skills), "character.skills deve ser um objeto.");
  for (const id of ["initiative", "fight", "intimidation", "perception", "fortitude", "reflex", "will"]) {
    const skill = character.skills[id];
    assert(isObject(skill), `character.skills.${id} deve ser um objeto.`);
    assertString(skill.name, `character.skills.${id}.name`);
    assertNumber(skill.modifier, `character.skills.${id}.modifier`);
    assert(typeof skill.resistance === "boolean", `character.skills.${id}.resistance deve ser booleano.`);
  }

  assert(isObject(character.powers), "character.powers deve ser um objeto.");
  for (const id of ["combatDefensive", "duel", "baluarte", "armedTower", "provocation", "solidity", "platesOfWrath"]) {
    const power = character.powers[id];
    assert(isObject(power), `character.powers.${id} deve ser um objeto.`);
    assertString(power.name, `character.powers.${id}.name`);
    if (power.cost !== undefined) assertInteger(power.cost, `character.powers.${id}.cost`, 0);
    if (power.duration !== undefined) assertString(power.duration, `character.powers.${id}.duration`);
    if (power.passive !== undefined) {
      assert(typeof power.passive === "boolean", `character.powers.${id}.passive deve ser booleano.`);
    }
    for (const field of [
      "attackModifier",
      "defenseModifier",
      "damageModifier",
      "resistanceModifier",
      "willDifficulty",
      "damageReduction",
    ]) {
      if (power[field] !== undefined) assertNumber(power[field], `character.powers.${id}.${field}`);
    }
  }

  assert(isObject(character.diceOffset), "character.diceOffset deve ser um objeto.");
  for (const axis of ["x", "y", "z"]) assertNumber(character.diceOffset[axis], `character.diceOffset.${axis}`);
  return character;
}

function markupEnd(xml, start) {
  let quote = null;
  for (let index = start + 1; index < xml.length; index += 1) {
    const character = xml[index];
    if (quote !== null) {
      if (character === quote) quote = null;
    } else if (character === '"' || character === "'") {
      quote = character;
    } else if (character === ">") {
      return index;
    }
  }
  return -1;
}

export function validateUi(input) {
  const xml = normalizeText(input);
  assert(xml.trim().length > 0, "src/ui.xml não pode estar vazio.");

  const stack = [];
  const roots = [];
  const ids = new Set();
  let cursor = 0;
  let tagCount = 0;

  while (cursor < xml.length) {
    const start = xml.indexOf("<", cursor);
    if (start === -1) break;

    if (xml.startsWith("<!--", start)) {
      const end = xml.indexOf("-->", start + 4);
      assert(end !== -1, "src/ui.xml contém um comentário não fechado.");
      cursor = end + 3;
      continue;
    }
    if (xml.startsWith("<![CDATA[", start)) {
      const end = xml.indexOf("]]>", start + 9);
      assert(end !== -1, "src/ui.xml contém CDATA não fechado.");
      cursor = end + 3;
      continue;
    }
    if (xml.startsWith("<?", start)) {
      const end = xml.indexOf("?>", start + 2);
      assert(end !== -1, "src/ui.xml contém uma instrução não fechada.");
      cursor = end + 2;
      continue;
    }

    const end = markupEnd(xml, start);
    assert(end !== -1, "src/ui.xml contém uma tag não fechada.");
    const raw = xml.slice(start + 1, end).trim();
    assert(raw.length > 0, "src/ui.xml contém uma tag vazia.");
    if (raw.startsWith("!")) {
      cursor = end + 1;
      continue;
    }

    const closing = raw.startsWith("/");
    const selfClosing = !closing && /\/\s*$/.test(raw);
    const nameMatch = (closing ? raw.slice(1) : raw).match(/^([A-Za-z_][\w:.-]*)/);
    assert(nameMatch !== null, `src/ui.xml contém uma tag inválida: <${raw}>.`);
    const name = nameMatch[1];
    tagCount += 1;

    if (closing) {
      assert(/^\/[A-Za-z_][\w:.-]*\s*$/.test(raw), `Fechamento XML inválido: <${raw}>.`);
      const expected = stack.pop();
      assert(expected === name, `Tag XML </${name}> não corresponde a <${expected ?? "nenhuma"}>.`);
    } else {
      const idMatch = raw.match(/\sid\s*=\s*(["'])(.*?)\1/);
      if (idMatch !== null) {
        const id = idMatch[2];
        assert(id.length > 0, "IDs da UI não podem ser vazios.");
        assert(!ids.has(id), `ID duplicado em src/ui.xml: ${id}.`);
        ids.add(id);
      }
      if (stack.length === 0) roots.push(name);
      if (!selfClosing) stack.push(name);
    }
    cursor = end + 1;
  }

  assert(tagCount > 0, "src/ui.xml não contém elementos.");
  assert(stack.length === 0, `Tag XML <${stack.at(-1)}> não foi fechada.`);
  const visualRoots = roots.filter((name) => name !== "Defaults");
  assert(
    roots.every((name) => name === "Defaults" || name === "Panel"),
    "src/ui.xml pode declarar somente Defaults e o Panel visual no nível raiz.",
  );
  assert(
    roots.filter((name) => name === "Defaults").length <= 1,
    "src/ui.xml pode declarar no máximo um bloco Defaults raiz.",
  );
  assert(
    visualRoots.length === 1 && visualRoots[0] === "Panel",
    "src/ui.xml deve possuir um único Panel visual raiz.",
  );
  assert(ids.has("corvanConsole"), "src/ui.xml deve declarar o painel raiz corvanConsole.");
  for (const requiredId of [
    "pvCurrent", "pvMax", "pmCurrent", "pmMax", "defenseValue", "rdValue",
    "weapon_sword", "weapon_shield", "roll_attack", "roll_damage", "roll_critical",
    "power_combat_defensive", "power_duel", "power_baluarte", "power_torre_armada", "power_provocacao",
    "skill_iniciativa", "skill_luta", "skill_intimidacao", "skill_percepcao",
    "skill_fortitude", "skill_reflexos", "skill_vontade",
    "end_turn", "end_scene", "undo", "toggle_settings", "settingsPanel",
    "offset_x", "offset_y", "offset_z", "calibrate_roll", "reset_state", "refresh",
    "refreshStatus",
  ]) {
    assert(ids.has(requiredId), `src/ui.xml não declara o ID obrigatório ${requiredId}.`);
  }
  return xml;
}

function validateCommitSha(value) {
  assert(SHA_PATTERN.test(value), "CORVAN_COMMIT_SHA deve ter entre 7 e 40 caracteres hexadecimais.");
  return value.toLowerCase();
}

function validatePreviousVersion(value, currentVersion) {
  if (value === undefined || value === null || value === "") return null;
  assert(VERSION_PATTERN.test(value), "CORVAN_PREVIOUS_VERSION deve usar SemVer estável X.Y.Z.");
  const previous = value.split(".").map(Number);
  const current = currentVersion.split(".").map(Number);
  const isOlder = previous.some((part, index) =>
    part < current[index] && previous.slice(0, index).every((prior, priorIndex) => prior === current[priorIndex]),
  );
  assert(isOlder, "CORVAN_PREVIOUS_VERSION deve ser anterior à versão atual.");
  return value;
}

async function loadPackage(rootDir) {
  let parsed;
  try {
    parsed = JSON.parse(normalizeText(await readFile(join(rootDir, "package.json"), "utf8")));
  } catch (error) {
    fail(`Não foi possível ler package.json: ${error.message}`);
  }
  assert(isObject(parsed) && VERSION_PATTERN.test(parsed.version ?? ""), "package.json deve declarar uma versão SemVer estável X.Y.Z.");
  return parsed;
}

async function readSource(path, label) {
  try {
    return withFinalNewline(normalizeText(await readFile(path, "utf8")));
  } catch (error) {
    fail(`Não foi possível ler ${label}: ${error.message}`);
  }
}

function createManifest(version, commitSha, runtime, previousVersion) {
  return {
    schemaVersion: 1,
    version,
    minBootstrapVersion: "1.0.2",
    commitSha,
    runtime: {
      url: `${RELEASE_BASE_URL}/v${version}/corvan-runtime.lua`,
      size: Buffer.byteLength(runtime, "utf8"),
      sha256: sha256(runtime),
    },
    previousVersion,
  };
}

function createSavedObject(bootstrap, ui, version, commitSha, assetUrlOverride = null) {
  // Release builds pin the board art to the exact source commit. A local build
  // without CORVAN_COMMIT_SHA keeps using main so it remains directly importable.
  const assetRef = commitSha === DEFAULT_COMMIT_SHA ? "main" : commitSha;
  const assetUrl = assetUrlOverride || `${RAW_ASSET_BASE_URL}/${assetRef}/assets/panel-board.png`;
  return {
    SaveName: "Corvan Duras Console",
    GameMode: "",
    Gravity: 0.5,
    PlayArea: 0.5,
    Date: "",
    Table: "",
    Sky: "",
    Note: "Console de combate do Corvan Duras",
    Rules: "",
    XmlUI: "",
    LuaScript: "",
    LuaScriptState: "",
    ObjectStates: [
      {
        Name: "Custom_Tile",
        Transform: {
          posX: 0,
          posY: 1.1,
          posZ: 0,
          rotX: 0,
          rotY: 180,
          rotZ: 0,
          scaleX: 1,
          scaleY: 1,
          scaleZ: 1,
        },
        Nickname: "Corvan Duras Console",
        Description: `Console de combate atualizável • v${version}`,
        GMNotes: stableJson({ project: "corvan-tts-automation", version, aspectRatio: "2.22:1" }).trim(),
        ColorDiffuse: { r: 1, g: 1, b: 1 },
        Locked: false,
        Grid: true,
        Snap: true,
        IgnoreFoW: false,
        MeasureMovement: false,
        DragSelectable: true,
        Autoraise: true,
        Sticky: true,
        Tooltip: true,
        GridProjection: false,
        HideWhenFaceDown: false,
        Hands: false,
        CustomImage: {
          ImageURL: assetUrl,
          ImageSecondaryURL: "",
          ImageScalar: 1,
          WidthScale: 0,
          CustomTile: {
            Type: 0,
            Thickness: 0.2,
            Stackable: false,
            Stretch: true,
          },
        },
        LuaScript: bootstrap,
        LuaScriptState: "",
        XmlUI: ui,
        GUID: "c0a4a1",
      },
    ],
    TabStates: {},
    VersionNumber: "",
  };
}

export async function buildProject({
  rootDir = PROJECT_ROOT,
  outDir = join(rootDir, "dist"),
  commitSha = process.env.CORVAN_COMMIT_SHA || DEFAULT_COMMIT_SHA,
  previousVersion = process.env.CORVAN_PREVIOUS_VERSION || null,
  assetUrl = null,
} = {}) {
  const absoluteRoot = resolve(rootDir);
  const absoluteOut = resolve(outDir);
  const packageJson = await loadPackage(absoluteRoot);
  const sourceDir = join(absoluteRoot, "src");

  const [runtimeTemplate, bootstrapTemplate, uiSource, characterSource] = await Promise.all([
    readSource(join(sourceDir, "runtime.lua"), "src/runtime.lua"),
    readSource(join(sourceDir, "bootstrap.lua"), "src/bootstrap.lua"),
    readSource(join(sourceDir, "ui.xml"), "src/ui.xml"),
    readSource(join(sourceDir, "character.json"), "src/character.json"),
  ]);

  let character;
  try {
    character = JSON.parse(characterSource);
  } catch (error) {
    fail(`src/character.json não é JSON válido: ${error.message}`);
  }
  validateCharacter(character, packageJson.version);
  const ui = withFinalNewline(validateUi(uiSource));
  const characterJson = stableJson(character);

  let runtime = replaceSinglePlaceholder(
    runtimeTemplate,
    PLACEHOLDERS.ui,
    luaLongString(ui),
    PLACEHOLDERS.ui,
  );
  runtime = replaceSinglePlaceholder(
    runtime,
    PLACEHOLDERS.character,
    luaLongString(characterJson),
    PLACEHOLDERS.character,
  );
  runtime = withFinalNewline(runtime);
  assert(runtime.includes("CORVAN_RUNTIME"), "O runtime gerado deve conter o marcador CORVAN_RUNTIME.");

  let bootstrap = replaceSinglePlaceholder(
    bootstrapTemplate,
    PLACEHOLDERS.seedRuntime,
    luaLongString(runtime),
    PLACEHOLDERS.seedRuntime,
  );
  bootstrap = replaceSinglePlaceholder(
    bootstrap,
    PLACEHOLDERS.seedUi,
    luaLongString(ui),
    PLACEHOLDERS.seedUi,
  );
  bootstrap = withFinalNewline(bootstrap);

  for (const placeholder of Object.values(PLACEHOLDERS)) {
    assert(!runtime.includes(placeholder), `O runtime gerado ainda contém ${placeholder}.`);
    assert(!bootstrap.includes(placeholder), `O bootstrap gerado ainda contém ${placeholder}.`);
  }

  const manifest = createManifest(
    packageJson.version,
    validateCommitSha(commitSha),
    runtime,
    validatePreviousVersion(previousVersion, packageJson.version),
  );
  if (assetUrl !== null) assertString(assetUrl, "assetUrl");
  const savedObject = createSavedObject(bootstrap, ui, packageJson.version, manifest.commitSha, assetUrl);
  const files = {
    "corvan-runtime.lua": runtime,
    "manifest.json": stableJson(manifest),
    "Corvan_Duras_Console.json": stableJson(savedObject),
  };

  await mkdir(absoluteOut, { recursive: true });
  await Promise.all(
    Object.entries(files).map(([name, contents]) => writeFile(join(absoluteOut, name), contents, "utf8")),
  );

  return {
    outDir: absoluteOut,
    version: packageJson.version,
    manifest,
    savedObject,
    files,
  };
}

function parseCliArguments(argv) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[index + 1];
    if (argument === "--root" && value) {
      options.rootDir = resolve(value);
      index += 1;
    } else if (argument === "--out" && value) {
      options.outDir = resolve(value);
      index += 1;
    } else if (argument === "--commit" && value) {
      options.commitSha = value;
      index += 1;
    } else if (argument === "--previous" && value) {
      options.previousVersion = value;
      index += 1;
    } else if (argument === "--asset-url" && value) {
      options.assetUrl = value;
      index += 1;
    } else {
      fail(`Argumento desconhecido ou sem valor: ${argument}`);
    }
  }
  return options;
}

async function main() {
  try {
    const result = await buildProject(parseCliArguments(process.argv.slice(2)));
    process.stdout.write(`Artefatos v${result.version} gerados em ${result.outDir}\n`);
  } catch (error) {
    process.stderr.write(`Build falhou: ${error.message}\n`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(SCRIPT_PATH)) {
  await main();
}
