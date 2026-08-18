import { appendFile, readFile } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const PROJECT_ROOT = resolve(dirname(SCRIPT_PATH), "..");
const VERSION_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const ID_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const TAG_PATTERN = /^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const NAMESPACED_TAG_PATTERN = /^([a-z0-9]+(?:-[a-z0-9]+)*)-v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const ARTIFACT_KEYS = Object.freeze(["runtime", "manifest", "savedObject"]);

function fail(message) {
  throw new Error(message);
}

function assert(condition, message) {
  if (!condition) fail(message);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function assertString(value, path) {
  assert(typeof value === "string" && value.trim().length > 0, `${path} deve ser uma string não vazia.`);
}

function assertBoolean(value, path) {
  assert(typeof value === "boolean", `${path} deve ser booleano.`);
}

function normalizeText(value) {
  return value.replace(/^\uFEFF/, "").replace(/\r\n?/g, "\n");
}

function stableJson(value) {
  return JSON.stringify(value);
}

function normalizeArtifactName(value, path) {
  let name = value;
  if (isObject(value)) name = value.file ?? value.path ?? value.name;
  assertString(name, path);
  assert(!isAbsolute(name), `${path} não pode ser um caminho absoluto.`);
  const normalized = name.replaceAll("\\", "/");
  assert(!normalized.split("/").includes(".."), `${path} não pode subir diretórios.`);
  assert(normalized !== "." && normalized !== "", `${path} não pode ser vazio.`);
  return normalized;
}

function normalizeRegistryEntries(parsed) {
  if (Array.isArray(parsed)) return parsed;
  assert(isObject(parsed), "characters/registry.json deve conter um objeto ou uma lista.");
  const entries = parsed.characters ?? parsed.profiles ?? parsed.entries;
  if (Array.isArray(entries)) return entries;
  if (isObject(entries)) {
    return Object.entries(entries).map(([id, profile]) => ({ id, ...profile }));
  }
  fail("characters/registry.json deve declarar characters como lista ou objeto.");
}

function normalizeProfile(raw, index) {
  const prefix = `characters/registry.json[${index}]`;
  assert(isObject(raw), `${prefix} deve ser um objeto.`);
  assertString(raw.id, `${prefix}.id`);
  assert(ID_PATTERN.test(raw.id), `${prefix}.id deve ser um slug kebab-case minúsculo.`);
  assertString(raw.displayName, `${prefix}.displayName`);
  assertString(raw.status, `${prefix}.status`);
  assert(["active", "scaffold", "disabled"].includes(raw.status), `${prefix}.status inválido.`);
  assertString(raw.sourceDir, `${prefix}.sourceDir`);
  assert(!isAbsolute(raw.sourceDir), `${prefix}.sourceDir não pode ser absoluto.`);
  assert(!raw.sourceDir.split(/[\\/]/).includes(".."), `${prefix}.sourceDir não pode subir diretórios.`);
  const runtimeMarker = raw.runtimeMarker ?? raw.release?.runtimeMarker;
  assertString(runtimeMarker, `${prefix}.runtimeMarker`);
  assertString(raw.minBootstrapVersion, `${prefix}.minBootstrapVersion`);
  assert(VERSION_PATTERN.test(raw.minBootstrapVersion), `${prefix}.minBootstrapVersion deve usar X.Y.Z.`);

  // The v0.2.1 registry contract is nested under `release`. During the
  // migration, accept the flat shape used by the initial multi-character
  // builder as well; the normalized output remains the nested contract.
  const release = raw.release ?? {
    productionEnabled: raw.productionEnabled,
    prerelease: raw.prerelease,
    tagMode: raw.tagMode === "character" ? "namespaced" : raw.tagMode,
    globalLatest: raw.globalLatest,
    artifacts: raw.artifacts ?? raw.files,
  };
  assert(isObject(release), `${prefix}.release deve ser um objeto.`);
  assertBoolean(release.productionEnabled, `${prefix}.release.productionEnabled`);
  assertBoolean(release.prerelease, `${prefix}.release.prerelease`);
  assert(release.tagMode === "legacy" || release.tagMode === "namespaced", `${prefix}.release.tagMode deve ser legacy ou namespaced.`);
  assertBoolean(release.globalLatest, `${prefix}.release.globalLatest`);

  const version = raw.version;
  if (version !== null && version !== undefined) {
    assertString(version, `${prefix}.version`);
    assert(VERSION_PATTERN.test(version), `${prefix}.version deve usar SemVer estável X.Y.Z.`);
  }

  const artifacts = release.artifacts;
  assert(isObject(artifacts), `${prefix}.release.artifacts deve ser um objeto.`);
  const normalizedArtifacts = {};
  for (const key of ARTIFACT_KEYS) {
    normalizedArtifacts[key] = normalizeArtifactName(artifacts[key], `${prefix}.release.artifacts.${key}`);
  }

  return Object.freeze({
    id: raw.id,
    displayName: raw.displayName,
    shortName: raw.shortName ?? raw.id,
    status: raw.status,
    runtimeMarker,
    minBootstrapVersion: raw.minBootstrapVersion,
    savedObjectName: raw.savedObjectName ?? `${raw.displayName} Console`,
    savedObjectNote: raw.savedObjectNote ?? `${raw.displayName} Console`,
    savedObjectDescription: (raw.savedObjectDescription
      ?? `Console atualizável • ${raw.displayName} v{version}`).replaceAll("{version}", version ?? ""),
    version: version ?? null,
    sourceDir: raw.sourceDir.replaceAll("\\", "/"),
    release: Object.freeze({
      productionEnabled: release.productionEnabled,
      prerelease: release.prerelease,
      tagMode: release.tagMode,
      globalLatest: release.globalLatest,
      artifacts: Object.freeze(normalizedArtifacts),
    }),
  });
}

export function parseReleaseTag(tag) {
  assertString(tag, "tag");
  const legacy = tag.match(TAG_PATTERN);
  if (legacy) return { id: "corvan", version: legacy.slice(1).join("."), tagMode: "legacy" };
  const namespaced = tag.match(NAMESPACED_TAG_PATTERN);
  if (namespaced) return { id: namespaced[1], version: namespaced.slice(2).join("."), tagMode: "namespaced" };
  fail(`Tag ${tag} não usa vX.Y.Z ou <id>-vX.Y.Z.`);
}

export function compareSemverVersions(left, right) {
  assert(VERSION_PATTERN.test(left), `Versão inválida: ${left}.`);
  assert(VERSION_PATTERN.test(right), `Versão inválida: ${right}.`);
  const a = left.split(".").map(Number);
  const b = right.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}

export function versionFromReleaseTag({ id, tagMode }, tag) {
  if (typeof tag !== "string") return null;
  const escapedId = String(id).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = tagMode === "legacy"
    ? /^v((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))$/
    : new RegExp(`^${escapedId}-v((?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*))$`);
  return tag.match(pattern)?.[1] ?? null;
}

export function selectStableReleaseCatalog({ profile, pages, maxPages = 10 }) {
  assert(isObject(profile), "profile deve ser um objeto.");
  assert(Array.isArray(pages) && pages.length > 0, "pages deve conter ao menos uma página.");
  assert(Number.isInteger(maxPages) && maxPages > 0, "maxPages deve ser positivo.");
  assert(pages.length <= maxPages, `A busca excedeu ${maxPages} páginas.`);
  for (const page of pages) assert(Array.isArray(page), "Cada página de releases deve ser uma lista.");
  if (pages.length === maxPages && pages.at(-1).length >= 100) {
    fail(`A busca atingiu ${maxPages} páginas completas e não é segura.`);
  }
  const selected = [];
  for (const page of pages) {
    for (const release of page) {
      if (!isObject(release) || release.draft === true || release.prerelease === true) continue;
      const version = versionFromReleaseTag(profile, release.tag_name);
      if (version !== null) selected.push({ release, version });
    }
  }
  return selected.sort((left, right) => compareSemverVersions(left.version, right.version));
}

export function selectPreviousStableVersion({ profile, currentVersion, pages, maxPages = 10 }) {
  assert(VERSION_PATTERN.test(currentVersion), "currentVersion deve usar SemVer estável X.Y.Z.");
  const older = selectStableReleaseCatalog({ profile, pages, maxPages })
    .filter(({ version }) => compareSemverVersions(version, currentVersion) < 0);
  return older.at(-1)?.version ?? null;
}

export function loadRegistryValue(parsed) {
  const entries = normalizeRegistryEntries(parsed);
  const profiles = new Map();
  const artifacts = new Set();
  entries.forEach((raw, index) => {
    const profile = normalizeProfile(raw, index);
    assert(!profiles.has(profile.id), `ID duplicado no registry: ${profile.id}.`);
    if (profile.release.globalLatest) {
      assert(
        profile.id === "corvan" && profile.release.tagMode === "legacy",
        "Somente o Corvan legacy pode ser Latest global.",
      );
    }
    if (profile.status === "active") {
      for (const artifact of Object.values(profile.release.artifacts)) {
        assert(!artifacts.has(artifact), `Artefato duplicado no registry: ${artifact}.`);
        artifacts.add(artifact);
      }
    }
    profiles.set(profile.id, profile);
  });
  assert(profiles.size > 0, "characters/registry.json não pode estar vazio.");
  return profiles;
}

export async function loadRegistry({ rootDir = PROJECT_ROOT } = {}) {
  const registryPath = join(resolve(rootDir), "characters", "registry.json");
  let contents;
  try {
    contents = await readFile(registryPath, "utf8");
  } catch (error) {
    fail(`Não foi possível ler ${registryPath}: ${error.message}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(normalizeText(contents));
  } catch (error) {
    fail(`characters/registry.json não é JSON válido: ${error.message}`);
  }
  return loadRegistryValue(parsed);
}

function assertPublishable(profile, parsedTag) {
  assert(profile.status !== "scaffold", `O personagem ${profile.id} está em scaffold e não pode publicar.`);
  assert(profile.status !== "disabled", `O personagem ${profile.id} está desabilitado e não pode publicar.`);
  assert(profile.release.productionEnabled === true, `O personagem ${profile.id} não está habilitado para produção.`);
  assert(profile.version !== null, `O personagem ${profile.id} não possui versão publicável.`);
  assert(profile.version === parsedTag.version, `A tag ${parsedTag.version} diverge da versão registrada de ${profile.id} (${profile.version}).`);
  assert(profile.release.tagMode === parsedTag.tagMode, `A tag ${parsedTag.tagMode} é incompatível com o tagMode ${profile.release.tagMode} de ${profile.id}.`);
  if (parsedTag.tagMode === "legacy") assert(parsedTag.id === "corvan", "Somente o Corvan pode usar tags legacy.");
  if (parsedTag.tagMode === "namespaced") assert(parsedTag.id !== "corvan", "O Corvan deve usar a tag legacy vX.Y.Z.");
  if (profile.release.globalLatest) {
    assert(profile.id === "corvan" && profile.release.tagMode === "legacy", "Somente o Corvan legacy pode ser Latest global.");
  }
}

export function resolveRelease({ tag, profiles }) {
  const parsedTag = parseReleaseTag(tag);
  const profile = profiles.get(parsedTag.id);
  assert(profile !== undefined, `Nenhum perfil registrado para a tag ${tag}.`);
  assertPublishable(profile, parsedTag);

  const artifacts = profile.release.artifacts;
  const distDir = `dist/${profile.id}`;
  const artifactPaths = Object.fromEntries(
    ARTIFACT_KEYS.map((key) => [key, `${distDir}/${artifacts[key]}`]),
  );
  const latest = profile.id === "corvan"
    && profile.release.tagMode === "legacy"
    && profile.release.globalLatest === true
    && profile.release.prerelease === false;

  return Object.freeze({
    id: profile.id,
    displayName: profile.displayName,
    shortName: profile.shortName,
    status: profile.status,
    runtimeMarker: profile.runtimeMarker,
    minBootstrapVersion: profile.minBootstrapVersion,
    savedObjectName: profile.savedObjectName,
    savedObjectNote: profile.savedObjectNote,
    savedObjectDescription: profile.savedObjectDescription,
    sourceDir: profile.sourceDir,
    version: parsedTag.version,
    tag,
    tagMode: profile.release.tagMode,
    productionEnabled: profile.release.productionEnabled,
    prerelease: profile.release.prerelease,
    globalLatest: profile.release.globalLatest,
    latest,
    title: `${profile.displayName} ${tag}`,
    distDir,
    artifacts: Object.freeze({ ...artifacts }),
    artifactPaths: Object.freeze(artifactPaths),
  });
}

function parseArguments(argv) {
  const options = { rootDir: PROJECT_ROOT, tag: process.env.GITHUB_REF_NAME };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[index + 1];
    if (argument === "--root" && value) {
      options.rootDir = resolve(value);
      index += 1;
    } else if (argument === "--tag" && value) {
      options.tag = value;
      index += 1;
    } else if ((argument === "--github-output" || argument === "--output") && value) {
      options.githubOutput = resolve(value);
      index += 1;
    } else if (argument === "--json") {
      options.jsonOnly = true;
    } else {
      fail(`Argumento desconhecido ou sem valor: ${argument}`);
    }
  }
  assertString(options.tag, "--tag ou GITHUB_REF_NAME");
  return options;
}

async function writeGithubOutputs(path, release) {
  if (!path) return;
  const values = {
    id: release.id,
    displayName: release.displayName,
    shortName: release.shortName,
    status: release.status,
    runtimeMarker: release.runtimeMarker,
    minBootstrapVersion: release.minBootstrapVersion,
    savedObjectName: release.savedObjectName,
    savedObjectNote: release.savedObjectNote,
    savedObjectDescription: release.savedObjectDescription,
    sourceDir: release.sourceDir,
    version: release.version,
    tag: release.tag,
    tagMode: release.tagMode,
    productionEnabled: String(release.productionEnabled),
    prerelease: String(release.prerelease),
    globalLatest: String(release.globalLatest),
    latest: String(release.latest),
    title: release.title,
    distDir: release.distDir,
    runtime: release.artifacts.runtime,
    manifest: release.artifacts.manifest,
    savedObject: release.artifacts.savedObject,
    runtimePath: release.artifactPaths.runtime,
    manifestPath: release.artifactPaths.manifest,
    savedObjectPath: release.artifactPaths.savedObject,
    releaseJson: stableJson(release),
  };
  const lines = [];
  for (const [key, value] of Object.entries(values)) {
    const text = String(value);
    if (text.includes("\n") || text.includes("\r")) {
      const delimiter = `RELEASE_${key.toUpperCase()}_${process.pid}`;
      lines.push(`${key}<<${delimiter}\n${text}\n${delimiter}`);
    } else {
      lines.push(`${key}=${text}`);
    }
  }
  await appendFile(path, `${lines.join("\n")}\n`, "utf8");
}

export async function main(argv = process.argv.slice(2), {stdout = true} = {}) {
  const options = parseArguments(argv);
  const profiles = await loadRegistry({ rootDir: options.rootDir });
  const release = resolveRelease({ tag: options.tag, profiles });
  await writeGithubOutputs(options.githubOutput, release);
  if (stdout) process.stdout.write(`${JSON.stringify(release)}\n`);
  return release;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(SCRIPT_PATH)) {
  try {
    await main();
  } catch (error) {
    process.stderr.write(`Release inválida: ${error.message}\n`);
    process.exitCode = 1;
  }
}
