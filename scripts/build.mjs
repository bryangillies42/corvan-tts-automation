import { createHash } from "node:crypto";
import { access, mkdir, readFile, writeFile } from "node:fs/promises";
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
  panelImageUrl: "__PANEL_IMAGE_URL_LITERAL__",
  panelUiImageUrlLiteral: "__PANEL_UI_IMAGE_URL_LITERAL__",
  panelUiImageUrl: "__PANEL_UI_IMAGE_URL_XML__",
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

function escapeXmlAttribute(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
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

function fingerprintedAssetUrl(baseUrl, contents) {
  return `${baseUrl}?sha256=${sha256(contents)}`;
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
    if (weapon.defenseModifier !== undefined) {
      assertNumber(weapon.defenseModifier, `character.weapons.${id}.defenseModifier`);
    }

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
  for (const id of [
    "initiative", "fight", "intimidation", "perception", "fortitude", "reflex", "will",
    "riding", "diplomacy", "warfare", "aim",
  ]) {
    const skill = character.skills[id];
    assert(isObject(skill), `character.skills.${id} deve ser um objeto.`);
    assertString(skill.name, `character.skills.${id}.name`);
    assertNumber(skill.modifier, `character.skills.${id}.modifier`);
    assert(typeof skill.resistance === "boolean", `character.skills.${id}.resistance deve ser booleano.`);
  }

  assert(isObject(character.powers), "character.powers deve ser um objeto.");
  for (const id of [
    "combatDefensive", "duel", "baluarte", "provocation", "solidity",
    "duelistShielded", "weaponAndShieldStyle", "ambitionWeapons", "armored", "platesOfWrath", "bastion",
  ]) {
    const power = character.powers[id];
    assert(isObject(power), `character.powers.${id} deve ser um objeto.`);
    assertString(power.name, `character.powers.${id}.name`);
    if (power.cost !== undefined) assertInteger(power.cost, `character.powers.${id}.cost`, 0);
    if (power.upgradeCost !== undefined) {
      assertInteger(power.upgradeCost, `character.powers.${id}.upgradeCost`, 0);
    }
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
      "upgradedDefenseModifier",
      "upgradedResistanceModifier",
      "upgradedAttackModifier",
      "upgradedDamageModifier",
      "upgradedDamageReduction",
      "sharedCost",
      "shieldDefenseModifier",
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

const CORVAN_REQUIRED_UI_IDS = [
  "pvCurrent", "pvMax", "pv_adjust", "pv_subtract", "pv_add",
  "pmCurrent", "pmMax", "pm_adjust", "pm_subtract", "pm_add",
  "automatic_resource_spending", "panelBoardArt", "defenseValue", "rdValue",
  "weapon_sword", "weapon_shield", "roll_attack", "roll_damage", "roll_critical",
  "power_combat_defensive", "power_duel", "power_baluarte", "power_baluarte_allies",
  "passive_duelist_shielded", "power_provocacao",
  "skill_cavalgar", "skill_diplomacia", "skill_guerra", "skill_pontaria",
  "skill_iniciativa", "skill_luta", "skill_intimidacao", "skill_percepcao",
  "skill_fortitude", "skill_reflexos", "skill_vontade",
  "end_turn", "end_scene", "undo", "clear_dice", "toggle_settings", "settingsPanel",
  "offset_x", "offset_y", "offset_z", "calibrate_roll", "reset_state", "refresh",
  "refreshStatus",
];

export function validateUi(input, contract = {}) {
  const xml = normalizeText(input);
  const uiContract = contract.uiContract || "panel-board";
  const uiRootId = contract.uiRootId || "corvanConsole";
  const panelArtId = contract.panelArtId || "panelBoardArt";
  const geometry = contract.geometry || {
    canvasWidth: 1870,
    canvasHeight: 841,
    panelWidth: 1700,
    panelHeight: 750,
  };
  const requiredUiIds = contract.requiredUiIds || (uiContract === "generic" ? [] : CORVAN_REQUIRED_UI_IDS);
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
  assert(ids.has(uiRootId), `ui.xml deve declarar o painel raiz ${uiRootId}.`);
  for (const requiredId of requiredUiIds) {
    assert(ids.has(requiredId), `src/ui.xml não declara o ID obrigatório ${requiredId}.`);
  }
  if (uiContract === "generic") return xml;
  assert(uiContract === "panel-board", `Contrato de UI desconhecido: ${uiContract}.`);

  const visualRoots = roots.filter((name) => name !== "Defaults");
  assert(
    roots.every((name) => name === "Defaults" || name === "Image" || name === "Panel"),
    "src/ui.xml pode declarar somente Defaults, Image e Panel no nível raiz.",
  );
  assert(
    roots.filter((name) => name === "Defaults").length <= 1,
    "src/ui.xml pode declarar no máximo um bloco Defaults raiz.",
  );
  assert(
    visualRoots.length === 2 && visualRoots[0] === "Image" && visualRoots[1] === "Panel",
    "src/ui.xml deve possuir a Image da moldura antes do Panel visual raiz.",
  );
  const rootGeometry = (id) => {
    const tag = xml.match(new RegExp(`<(?:Image|Panel)\\b[^>]*\\bid=["']${id}["'][^>]*>`, "s"));
    assert(tag !== null, `src/ui.xml não declara a raiz ${id}.`);
    const attribute = (name) => {
      const match = tag[0].match(new RegExp(`\\b${name}\\s*=\\s*(["'])(.*?)\\1`, "s"));
      assert(match !== null, `A raiz ${id} não declara ${name}.`);
      return match[2];
    };
    return {
      transform: ["position", "rotation", "scale"].map(attribute),
      dimensions: ["width", "height"].map(attribute),
    };
  };
  const panelBoardGeometry = rootGeometry(panelArtId);
  const consoleGeometry = rootGeometry(uiRootId);
  assert(
    panelBoardGeometry.transform.every(
      (value, index) => value === consoleGeometry.transform[index],
    ),
    "A moldura e os controles da UI devem compartilhar a mesma transformação 3D.",
  );
  assert(
    panelBoardGeometry.dimensions[0] === String(geometry.canvasWidth)
      && panelBoardGeometry.dimensions[1] === String(geometry.canvasHeight)
      && consoleGeometry.dimensions[0] === String(geometry.panelWidth)
      && consoleGeometry.dimensions[1] === String(geometry.panelHeight),
    `A moldura e o painel devem preservar a geometria declarada por ${uiRootId}.`,
  );
  return xml;
}

function validateCommitSha(value) {
  assert(SHA_PATTERN.test(value), "RELEASE_COMMIT_SHA deve ter entre 7 e 40 caracteres hexadecimais.");
  return value.toLowerCase();
}

function validatePreviousVersion(value, currentVersion) {
  if (value === undefined || value === null || value === "") return null;
  assert(VERSION_PATTERN.test(value), "RELEASE_PREVIOUS_VERSION deve usar SemVer estável X.Y.Z.");
  const previous = value.split(".").map(Number);
  const current = currentVersion.split(".").map(Number);
  const isOlder = previous.some((part, index) =>
    part < current[index] && previous.slice(0, index).every((prior, priorIndex) => prior === current[priorIndex]),
  );
  assert(isOlder, "RELEASE_PREVIOUS_VERSION deve ser anterior à versão atual.");
  return value;
}

async function readSource(path, label) {
  try {
    return withFinalNewline(normalizeText(await readFile(path, "utf8")));
  } catch (error) {
    fail(`Não foi possível ler ${label}: ${error.message}`);
  }
}

const REGISTRY_FILE = "characters/registry.json";
const ID_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const SAFE_RELATIVE_PATH = /^(?![\\/])(?:[^\\/:*?"<>|]+[\\/]?)+$/;
const RELEASE_TAG_MODES = new Set(["legacy", "namespaced"]);
const UI_CONTRACTS = new Set(["panel-board", "generic"]);
const DISCOVERY_MODES = new Set(["repository-latest", "character-releases"]);

function assertRelativePath(value, path) {
  assertString(value, path);
  assert(!value.includes("\\") && !value.startsWith("/") && !value.includes(".."), `${path} deve ser um caminho relativo seguro.`);
  assert(SAFE_RELATIVE_PATH.test(value), `${path} contém caracteres inválidos.`);
}

function releaseTagFor(profile, version = profile.version) {
  assertString(profile.id, "profile.id");
  assertString(version, "profile.version");
  return profile.tagMode === "legacy" ? `v${version}` : `${profile.id}-v${version}`;
}

function validateArtifactName(value, path) {
  assertString(value, path);
  assert(
    value !== "." && value !== ".." && /^[^\\/:*?"<>|]+$/.test(value) && !value.includes(".."),
    `${path} deve ser apenas um nome de arquivo seguro.`,
  );
}

function rawArtifactNamesDiffer(files, artifacts) {
  return ["runtime", "manifest", "savedObject"].some(
    (field) => files?.[field] !== artifacts?.[field],
  );
}

function normalizeBuildProfile(raw) {
  const release = isObject(raw?.release) ? raw.release : {};
  const artifacts = release.artifacts || raw?.files || {};
  const declaredTagMode = raw?.tagMode || release.tagMode;
  return {
    ...raw,
    tagMode: declaredTagMode === "character" ? "namespaced" : declaredTagMode,
    discovery: raw?.discovery || "character-releases",
    prerelease: raw?.prerelease ?? release.prerelease,
    globalLatest: raw?.globalLatest ?? release.globalLatest,
    productionEnabled: raw?.productionEnabled ?? release.productionEnabled,
    files: raw?.files || artifacts,
  };
}

export function validateCharacterProfile(profile, { allowScaffold = true } = {}) {
  profile = normalizeBuildProfile(profile);
  assert(isObject(profile), "Perfil de personagem deve ser um objeto.");
  assert(typeof profile.id === "string" && ID_PATTERN.test(profile.id), "character.id deve ser um slug kebab-case.");
  assertString(profile.displayName, `${profile.id}.displayName`);
  assertString(profile.shortName, `${profile.id}.shortName`);
  assert(["active", "scaffold", "disabled"].includes(profile.status), `${profile.id}.status inválido.`);
  assert(allowScaffold || profile.status !== "scaffold", `${profile.id} ainda é um scaffold.`);
  if (profile.version !== null && profile.version !== undefined && profile.version !== "") {
    assert(VERSION_PATTERN.test(profile.version), `${profile.id}.version deve usar SemVer estável X.Y.Z.`);
  } else {
    assert(profile.status === "scaffold", `${profile.id}.version é obrigatório para um personagem publicável.`);
  }
  assertRelativePath(profile.sourceDir, `${profile.id}.sourceDir`);
  if (profile.assetsDir !== null && profile.assetsDir !== undefined) assertRelativePath(profile.assetsDir, `${profile.id}.assetsDir`);
  if (profile.assets !== undefined) {
    assert(isObject(profile.assets), `${profile.id}.assets deve ser um objeto.`);
    for (const field of ["panelImage", "panelUiImage"]) {
      if (profile.assets[field] !== undefined) validateArtifactName(profile.assets[field], `${profile.id}.assets.${field}`);
    }
  }
  if (profile.sourceFiles !== undefined) {
    assert(isObject(profile.sourceFiles), `${profile.id}.sourceFiles deve ser um objeto.`);
    for (const [field, fileName] of Object.entries(profile.sourceFiles)) {
      validateArtifactName(fileName, `${profile.id}.sourceFiles.${field}`);
    }
  }
  assert(RELEASE_TAG_MODES.has(profile.tagMode), `${profile.id}.tagMode inválido.`);
  assert(DISCOVERY_MODES.has(profile.discovery), `${profile.id}.discovery inválido.`);
  for (const flag of ["prerelease", "globalLatest", "productionEnabled"]) {
    assert(typeof profile[flag] === "boolean", `${profile.id}.${flag} deve ser booleano.`);
  }
  assertString(profile.minBootstrapVersion, `${profile.id}.minBootstrapVersion`);
  assert(VERSION_PATTERN.test(profile.minBootstrapVersion), `${profile.id}.minBootstrapVersion inválido.`);
  assert(isObject(profile.files), `${profile.id}.files deve ser um objeto.`);
  for (const field of ["runtime", "bootstrap", "ui", "character", "manifest", "savedObject"]) {
    if (profile.files[field] !== undefined) validateArtifactName(profile.files[field], `${profile.id}.files.${field}`);
  }
  if (isObject(profile.release?.artifacts) && rawArtifactNamesDiffer(profile.files, profile.release.artifacts)) {
    fail(`${profile.id}.files e ${profile.id}.release.artifacts devem declarar os mesmos artefatos.`);
  }
  assertString(profile.runtimeMarker, `${profile.id}.runtimeMarker`);
  assertString(profile.uiRootId, `${profile.id}.uiRootId`);
  assert(UI_CONTRACTS.has(profile.uiContract), `${profile.id}.uiContract deve ser panel-board ou generic.`);
  if (profile.status === "active") {
    assert(typeof profile.guid === "string" && /^[0-9a-f]{6}$/i.test(profile.guid), `${profile.id}.guid deve ter 6 caracteres hexadecimais.`);
  }
  for (const field of ["savedObjectName", "savedObjectNote", "savedObjectDescription", "aspectRatio"]) {
    if (profile[field] !== undefined) assertString(profile[field], `${profile.id}.${field}`);
  }
  if (profile.panelArtId !== undefined) assertString(profile.panelArtId, `${profile.id}.panelArtId`);
  if (profile.uiContract === "panel-board") {
    assertString(profile.panelArtId, `${profile.id}.panelArtId`);
    assert(isObject(profile.geometry), `${profile.id}.geometry deve ser um objeto no contrato panel-board.`);
  }
  if (profile.requiredUiIds !== undefined) {
    assert(Array.isArray(profile.requiredUiIds), `${profile.id}.requiredUiIds deve ser uma lista.`);
    const requiredIds = new Set();
    for (const id of profile.requiredUiIds) {
      assertString(id, `${profile.id}.requiredUiIds[]`);
      assert(!requiredIds.has(id), `${profile.id}.requiredUiIds contém ID duplicado: ${id}.`);
      requiredIds.add(id);
    }
  }
  if (profile.geometry !== undefined) {
    assert(isObject(profile.geometry), `${profile.id}.geometry deve ser um objeto.`);
    for (const field of ["canvasWidth", "canvasHeight", "panelWidth", "panelHeight"]) {
      if (profile.geometry[field] !== undefined) assertNumber(profile.geometry[field], `${profile.id}.geometry.${field}`);
    }
  }
  return profile;
}

export function validateRegistry(registry) {
  assert(isObject(registry), "characters/registry.json deve conter um objeto.");
  assert(registry.schemaVersion === 1, "registry.schemaVersion deve ser 1.");
  assert(Array.isArray(registry.characters), "registry.characters deve ser uma lista.");
  const ids = new Set();
  const artifactNames = new Set();
  const guids = new Set();
  const uiRootIds = new Set();
  const runtimeMarkers = new Set();
  const assetDirectories = new Set();
  const normalizedCharacters = registry.characters.map((entry) => {
    const profile = normalizeBuildProfile(entry);
    validateCharacterProfile(profile);
    assert(!ids.has(profile.id), `ID de personagem duplicado: ${profile.id}.`);
    ids.add(profile.id);
    const characterRoot = `characters/${profile.id}`;
    assert(profile.sourceDir === characterRoot, `${profile.id}.sourceDir deve ser ${characterRoot}.`);
    assert(
      profile.id === "corvan" ? profile.tagMode === "legacy" : profile.tagMode === "namespaced",
      profile.id === "corvan"
        ? "Corvan deve preservar tagMode legacy."
        : `${profile.id}.tagMode deve ser namespaced.`,
    );
    if (profile.assetsDir !== null && profile.assetsDir !== undefined) {
      assert(
        profile.assetsDir === `${characterRoot}/assets`
          || profile.assetsDir.startsWith(`${characterRoot}/assets/`),
        `${profile.id}.assetsDir deve permanecer dentro de ${characterRoot}/assets.`,
      );
    }
    if (profile.status === "active") {
      for (const artifact of [profile.files.runtime, profile.files.manifest, profile.files.savedObject]) {
        assert(!artifactNames.has(artifact), `Artefato duplicado entre personagens ativos: ${artifact}.`);
        artifactNames.add(artifact);
      }
      if (profile.guid) {
        assert(!guids.has(profile.guid), `GUID duplicado entre personagens ativos: ${profile.guid}.`);
        guids.add(profile.guid);
      }
      assert(!uiRootIds.has(profile.uiRootId), `Raiz de UI duplicada entre personagens ativos: ${profile.uiRootId}.`);
      uiRootIds.add(profile.uiRootId);
      assert(!runtimeMarkers.has(profile.runtimeMarker), `Marker duplicado entre personagens ativos: ${profile.runtimeMarker}.`);
      runtimeMarkers.add(profile.runtimeMarker);
      if (profile.assetsDir) {
        assert(!assetDirectories.has(profile.assetsDir), `Diretório de assets duplicado entre personagens ativos: ${profile.assetsDir}.`);
        assetDirectories.add(profile.assetsDir);
      }
    }
    if (profile.globalLatest) {
      assert(profile.id === "corvan" && profile.tagMode === "legacy", "Somente o Corvan legacy pode usar globalLatest.");
    }
    return profile;
  });
  return { ...registry, characters: normalizedCharacters };
}

async function loadRegistry(rootDir) {
  let parsed;
  try {
    parsed = JSON.parse(normalizeText(await readFile(join(rootDir, REGISTRY_FILE), "utf8")));
  } catch (error) {
    fail(`Não foi possível ler ${REGISTRY_FILE}: ${error.message}`);
  }
  return validateRegistry(parsed);
}

async function pathExists(path) {
  try {
    await access(path);
    return true;
  } catch {
    return false;
  }
}

function filesForProfile(profile) {
  return {
    runtime: profile.files?.runtime || `${profile.id}-runtime.lua`,
    bootstrap: profile.files?.bootstrap || "bootstrap.lua",
    ui: profile.files?.ui || "ui.xml",
    character: profile.files?.character || "character.json",
    manifest: profile.files?.manifest || `${profile.id}-manifest.json`,
    savedObject: profile.files?.savedObject || `${profile.displayName.replace(/[^A-Za-z0-9]+/g, "_")}_Console.json`,
  };
}

function profileTag(profile) {
  assert(profile.version, `${profile.id} não possui versão publicável.`);
  return releaseTagFor(profile);
}

function luaStringLiteral(value) {
  return JSON.stringify(String(value));
}

function replaceOptionalPlaceholders(source, profile, manifestAssetName, runtimeAssetName) {
  const profileJson = stableJson(profile);
  const values = {
    __PROFILE_JSON_LITERAL__: luaLongString(profileJson),
    __CHARACTER_ID_LITERAL__: luaStringLiteral(profile.id),
    __CHARACTER_VERSION_LITERAL__: luaStringLiteral(profile.version || ""),
    __DISPLAY_NAME_LITERAL__: luaStringLiteral(profile.displayName),
    __SHORT_NAME_LITERAL__: luaStringLiteral(profile.shortName),
    __RELEASE_DISCOVERY_MODE_LITERAL__: luaStringLiteral(profile.discovery),
    __RELEASE_TAG_PREFIX_LITERAL__: luaStringLiteral(profile.tagMode === "legacy" ? "v" : `${profile.id}-v`),
    __MANIFEST_ASSET_NAME_LITERAL__: luaStringLiteral(manifestAssetName),
    __RUNTIME_ASSET_NAME_LITERAL__: luaStringLiteral(runtimeAssetName),
    __RUNTIME_MARKER_LITERAL__: luaStringLiteral(profile.runtimeMarker),
  };
  let result = source.replaceAll("__RUNTIME_MARKER__", profile.runtimeMarker);
  for (const [placeholder, replacement] of Object.entries(values)) {
    if (result.includes(placeholder)) result = replaceSinglePlaceholder(result, placeholder, replacement, placeholder);
  }
  return result;
}

function sourcePathFor(profile, rootDir, fileName) {
  return join(rootDir, profile.sourceDir, fileName);
}

function normalizeAssetReference(value, label) {
  assertString(value, label);
  return value;
}

function createGenericManifest(profile, version, commitSha, runtime, previousVersion, files) {
  const tag = releaseTagFor(profile, version);
  return {
    schemaVersion: 1,
    characterId: profile.id,
    releaseTag: tag,
    version,
    minBootstrapVersion: profile.minBootstrapVersion,
    commitSha,
    runtime: {
      url: `${RELEASE_BASE_URL}/${tag}/${files.runtime}`,
      size: Buffer.byteLength(runtime, "utf8"),
      sha256: sha256(runtime),
    },
    previousVersion: previousVersion || null,
  };
}

function createGenericSavedObject(profile, bootstrap, ui, version, imageUrl, savedObjectName) {
  const name = savedObjectName || `${profile.displayName} Console`;
  return {
    SaveName: name,
    GameMode: "",
    Gravity: 0.5,
    PlayArea: 0.5,
    Date: "",
    Table: "",
    Sky: "",
    Note: profile.savedObjectNote || `${profile.displayName} Console`,
    Rules: "",
    XmlUI: "",
    LuaScript: "",
    LuaScriptState: "",
    ObjectStates: [{
      Name: "Custom_Tile",
      Transform: { posX: 0, posY: 1.1, posZ: 0, rotX: 0, rotY: 180, rotZ: 0, scaleX: 1, scaleY: 1, scaleZ: 1 },
      Nickname: name,
      Description: profile.savedObjectDescription
        ? profile.savedObjectDescription.replaceAll("{version}", version)
        : `Console atualizável • ${profile.displayName} v${version}`,
      GMNotes: stableJson({
        project: "corvan-tts-automation",
        characterId: profile.id,
        version,
        ...(profile.aspectRatio ? { aspectRatio: profile.aspectRatio } : {}),
      }).trim(),
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
        ImageURL: imageUrl,
        ImageSecondaryURL: "",
        ImageScalar: 1,
        WidthScale: 0,
        CustomTile: { Type: 0, Thickness: 0.2, Stackable: false, Stretch: true },
      },
      LuaScript: bootstrap,
      LuaScriptState: "",
      XmlUI: ui,
      GUID: profile.guid || undefined,
    }],
    TabStates: {},
    VersionNumber: "",
  };
}

async function buildRegisteredCharacter({
  rootDir = PROJECT_ROOT,
  outDir = null,
  characterId,
  profileOverride = null,
  commitSha = process.env.RELEASE_COMMIT_SHA || process.env.CORVAN_COMMIT_SHA || DEFAULT_COMMIT_SHA,
  previousVersion = process.env.RELEASE_PREVIOUS_VERSION || process.env.CORVAN_PREVIOUS_VERSION || null,
  assetUrl = null,
  uiAssetUrl = null,
  savedObjectAssetUrl = null,
  savedObjectName = null,
} = {}) {
  const absoluteRoot = resolve(rootDir);
  const registry = profileOverride ? null : await loadRegistry(absoluteRoot);
  const profile = profileOverride || registry.characters.find((candidate) => candidate.id === characterId);
  assert(profile, `Personagem não registrado: ${characterId}.`);
  assert(profile.status === "active", `Personagem ${characterId} não está ativo.`);
  assert(profile.version, `Personagem ${characterId} não possui versão.`);
  const files = filesForProfile(profile);
  const absoluteOut = resolve(outDir || join(absoluteRoot, "dist", profile.id));
  const validatedCommitSha = validateCommitSha(commitSha);
  const assetRef = validatedCommitSha === DEFAULT_COMMIT_SHA ? "main" : validatedCommitSha;
  const sourceFiles = {
    runtime: await readSource(sourcePathFor(profile, absoluteRoot, profile.sourceFiles?.runtime || "runtime.lua"), `${profile.sourceDir}/runtime.lua`),
    ui: await readSource(sourcePathFor(profile, absoluteRoot, profile.sourceFiles?.ui || "ui.xml"), `${profile.sourceDir}/ui.xml`),
    character: await readSource(sourcePathFor(profile, absoluteRoot, profile.sourceFiles?.character || "character.json"), `${profile.sourceDir}/character.json`),
  };
  const sharedBootstrapPath = join(absoluteRoot, "shared", "bootstrap.lua");
  const bootstrap = await readSource(sharedBootstrapPath, "shared/bootstrap.lua");
  let character;
  try {
    character = JSON.parse(sourceFiles.character);
  } catch (error) {
    fail(`${profile.sourceDir}/character.json não é JSON válido: ${error.message}`);
  }
  assert(isObject(character), `${profile.id} character.json deve conter um objeto.`);
  assert(character.schemaVersion === 1, `${profile.id} character.schemaVersion deve ser 1.`);
  assertString(character.name, `${profile.id}.character.name`);
  if (character.id !== undefined) assert(character.id === profile.id, `${profile.id}.character.id deve corresponder ao registry.`);
  character.id = profile.id;
  character.version = profile.version;
  if (profile.id === "corvan") validateCharacter(character, profile.version);
  else if (character.version !== undefined && character.version !== null) assert(character.version === profile.version, `${profile.id}.character.version deve ser igual ao registry.`);

  const assets = profile.assets || {};
  const panelImagePath = assets.panelImage ? join(absoluteRoot, profile.assetsDir || "", assets.panelImage) : null;
  const panelUiImagePath = assets.panelUiImage ? join(absoluteRoot, profile.assetsDir || "", assets.panelUiImage) : null;
  const panelImageContents = assetUrl || !panelImagePath || !(await pathExists(panelImagePath)) ? null : await readFile(panelImagePath);
  const panelUiImageContents = uiAssetUrl || !panelUiImagePath || !(await pathExists(panelUiImagePath)) ? null : await readFile(panelUiImagePath);
  assert(
    assetUrl || assets.panelImageUrl || panelImageContents,
    `${profile.id} deve declarar assets.panelImage existente ou assets.panelImageUrl.`,
  );
  if (profile.uiContract === "panel-board") {
    assert(
      uiAssetUrl || assets.panelUiImageUrl || panelUiImageContents,
      `${profile.id} deve declarar assets.panelUiImage existente ou assets.panelUiImageUrl.`,
    );
  }
  const panelImageUrl = normalizeAssetReference(assetUrl || assets.panelImageUrl || fingerprintedAssetUrl(`${RAW_ASSET_BASE_URL}/${assetRef}/${profile.assetsDir}/${assets.panelImage}`, panelImageContents), "assetUrl");
  const panelUiImageUrl = profile.uiContract === "panel-board"
    ? normalizeAssetReference(uiAssetUrl || assets.panelUiImageUrl || fingerprintedAssetUrl(`${RAW_ASSET_BASE_URL}/${assetRef}/${profile.assetsDir}/${assets.panelUiImage}`, panelUiImageContents), "uiAssetUrl")
    : null;
  const savedImageUrl = normalizeAssetReference(savedObjectAssetUrl || panelImageUrl, "savedObjectAssetUrl");
  const uiTokens = {
    "__CHARACTER_ID__": profile.id,
    "__CHARACTER_NAME__": profile.displayName,
    "__CHARACTER_SHORT_NAME__": profile.shortName,
    "__CHARACTER_VERSION__": profile.version,
  };
  let uiSource = sourceFiles.ui;
  for (const [token, value] of Object.entries(uiTokens)) uiSource = uiSource.replaceAll(token, escapeXmlAttribute(value));
  if (profile.uiContract === "panel-board") {
    uiSource = replaceSinglePlaceholder(uiSource, PLACEHOLDERS.panelUiImageUrl, escapeXmlAttribute(panelUiImageUrl), PLACEHOLDERS.panelUiImageUrl);
  } else {
    assert(!uiSource.includes(PLACEHOLDERS.panelUiImageUrl), `${profile.id} UI generic não deve depender da moldura panel-board.`);
  }
  const ui = withFinalNewline(validateUi(uiSource, {
    uiContract: profile.uiContract,
    uiRootId: profile.uiRootId,
    panelArtId: profile.panelArtId,
    geometry: profile.geometry,
    requiredUiIds: profile.requiredUiIds,
  }));
  const characterJson = stableJson(character);
  const runtimeSharedPath = join(absoluteRoot, "shared", "runtime-core.lua");
  let runtime = sourceFiles.runtime;
  if (await pathExists(runtimeSharedPath)) {
    const sharedRuntime = await readSource(runtimeSharedPath, "shared/runtime-core.lua");
    if (runtime.includes("__RUNTIME_CORE_LITERAL__")) {
      runtime = replaceSinglePlaceholder(runtime, "__RUNTIME_CORE_LITERAL__", sharedRuntime, "__RUNTIME_CORE_LITERAL__");
    } else {
      runtime = `${sharedRuntime}\n${runtime}`;
    }
  }
  runtime = replaceSinglePlaceholder(runtime, PLACEHOLDERS.ui, luaLongString(ui), PLACEHOLDERS.ui);
  runtime = replaceSinglePlaceholder(runtime, PLACEHOLDERS.character, luaLongString(characterJson), PLACEHOLDERS.character);
  if (runtime.includes(PLACEHOLDERS.panelImageUrl)) {
    runtime = replaceSinglePlaceholder(runtime, PLACEHOLDERS.panelImageUrl, luaLongString(panelImageUrl), PLACEHOLDERS.panelImageUrl);
  }
  if (runtime.includes(PLACEHOLDERS.panelUiImageUrlLiteral)) {
    runtime = replaceSinglePlaceholder(runtime, PLACEHOLDERS.panelUiImageUrlLiteral, luaLongString(panelUiImageUrl || ""), PLACEHOLDERS.panelUiImageUrlLiteral);
  }
  runtime = replaceOptionalPlaceholders(runtime, profile, files.manifest, files.runtime);
  runtime = withFinalNewline(runtime);
  assert(runtime.includes(profile.runtimeMarker), `${profile.id} runtime não contém o marcador ${profile.runtimeMarker}.`);
  let generatedBootstrap = replaceSinglePlaceholder(bootstrap, PLACEHOLDERS.seedRuntime, luaLongString(runtime), PLACEHOLDERS.seedRuntime);
  generatedBootstrap = replaceSinglePlaceholder(generatedBootstrap, PLACEHOLDERS.seedUi, luaLongString(ui), PLACEHOLDERS.seedUi);
  generatedBootstrap = replaceOptionalPlaceholders(generatedBootstrap, profile, files.manifest, files.runtime);
  generatedBootstrap = withFinalNewline(generatedBootstrap);
  for (const placeholder of Object.values(PLACEHOLDERS)) {
    assert(!runtime.includes(placeholder), `${profile.id} runtime ainda contém ${placeholder}.`);
    assert(!generatedBootstrap.includes(placeholder), `${profile.id} bootstrap ainda contém ${placeholder}.`);
  }
  const unresolvedRuntime = runtime.match(/__[A-Z][A-Z0-9_]*__/);
  const unresolvedBootstrap = generatedBootstrap.match(/__[A-Z][A-Z0-9_]*__/);
  const unresolvedUi = ui.match(/__[A-Z][A-Z0-9_]*__/);
  assert(unresolvedRuntime === null, `${profile.id} runtime ainda contém ${unresolvedRuntime?.[0]}.`);
  assert(unresolvedBootstrap === null, `${profile.id} bootstrap ainda contém ${unresolvedBootstrap?.[0]}.`);
  assert(unresolvedUi === null, `${profile.id} UI ainda contém ${unresolvedUi?.[0]}.`);
  const manifest = createGenericManifest(profile, profile.version, validatedCommitSha, runtime, validatePreviousVersion(previousVersion, profile.version), files);
  const savedObject = createGenericSavedObject(profile, generatedBootstrap, ui, profile.version, savedImageUrl, savedObjectName || profile.savedObjectName);
  const output = {
    [files.runtime]: runtime,
    [files.manifest]: stableJson(manifest),
    [files.savedObject]: stableJson(savedObject),
  };
  await mkdir(absoluteOut, { recursive: true });
  await Promise.all(Object.entries(output).map(([name, contents]) => writeFile(join(absoluteOut, name), contents, "utf8")));
  return { outDir: absoluteOut, profile, version: profile.version, manifest, savedObject, files: output, panelImageUrl, panelUiImageUrl };
}

export async function loadCharacterRegistry(rootDir = PROJECT_ROOT) {
  return loadRegistry(resolve(rootDir));
}

export async function buildProject(options = {}) {
  return buildRegisteredCharacter({
    ...options,
    characterId: options.characterId || options.character || "corvan",
  });
}

export async function buildAllCharacters({ rootDir = PROJECT_ROOT, outDir = null, ...options } = {}) {
  const absoluteRoot = resolve(rootDir);
  const registry = await loadRegistry(absoluteRoot);
  const results = [];
  for (const profile of registry.characters.filter((candidate) => candidate.status === "active")) {
    results.push(await buildRegisteredCharacter({ rootDir: absoluteRoot, outDir: outDir ? join(outDir, profile.id) : join(absoluteRoot, "dist", profile.id), characterId: profile.id, ...options }));
  }
  return results;
}

export async function buildFixture({ rootDir = PROJECT_ROOT, fixtureId = "arcane-test", outDir = null, ...options } = {}) {
  const fixtureRoot = join(resolve(rootDir), "fixtures", "characters", fixtureId);
  assert(await pathExists(fixtureRoot), `Fixture não encontrada: ${fixtureId}.`);
  const fixtureRegistryPath = join(fixtureRoot, "profile.json");
  let profile;
  try { profile = JSON.parse(normalizeText(await readFile(fixtureRegistryPath, "utf8"))); } catch (error) { fail(`Fixture inválida: ${error.message}`); }
  profile = normalizeBuildProfile(profile);
  validateCharacterProfile(profile);
  const fixtureBuildRoot = resolve(rootDir);
  const virtual = { ...profile, sourceDir: `fixtures/characters/${fixtureId}`, assetsDir: `fixtures/characters/${fixtureId}/assets` };
  // Não escreva no repositório: o builder interno recebe um perfil diretamente.
  return buildRegisteredCharacter({ rootDir: fixtureBuildRoot, profileOverride: virtual, characterId: fixtureId, outDir: outDir || join(fixtureBuildRoot, "dist", fixtureId), ...options });
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
    } else if (argument === "--ui-asset-url" && value) {
      options.uiAssetUrl = value;
      index += 1;
    } else if (argument === "--saved-object-asset-url" && value) {
      options.savedObjectAssetUrl = value;
      index += 1;
    } else if (argument === "--saved-object-name" && value) {
      options.savedObjectName = value;
      index += 1;
    } else if (argument === "--character" && value) {
      options.characterId = value;
      index += 1;
    } else if (argument === "--fixture" && value) {
      options.fixtureId = value;
      options.fixture = true;
      index += 1;
    } else {
      fail(`Argumento desconhecido ou sem valor: ${argument}`);
    }
  }
  return options;
}

async function main() {
  try {
    const options = parseCliArguments(process.argv.slice(2));
    if (options.fixture) {
      const result = await buildFixture(options);
      process.stdout.write(`Fixture ${result.profile.id} v${result.version} gerada em ${result.outDir}\n`);
    } else if (options.characterId) {
      const result = await buildProject(options);
      process.stdout.write(`Artefatos ${result.profile.id} v${result.version} gerados em ${result.outDir}\n`);
    } else {
      const results = await buildAllCharacters(options);
      process.stdout.write(`${results.length} personagem(ns) gerado(s):\n${results.map((result) => `- ${result.profile.id} v${result.version}: ${result.outDir}`).join("\n")}\n`);
    }
  } catch (error) {
    process.stderr.write(`Build falhou: ${error.message}\n`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(SCRIPT_PATH)) {
  await main();
}
