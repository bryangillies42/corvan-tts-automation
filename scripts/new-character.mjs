import { access, cp, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const ID_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

function fail(message) {
  throw new Error(message);
}

function jsonStringContents(value) {
  return JSON.stringify(String(value)).slice(1, -1);
}

function xmlAttribute(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&apos;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

async function exists(path) {
  try { await access(path); return true; } catch { return false; }
}

function parseArgs(argv) {
  const options = { rootDir: ROOT };
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    const value = argv[index + 1];
    if (["--id", "--name", "--short-name", "--root"].includes(argument) && value) {
      options[{ "--id": "id", "--name": "name", "--short-name": "shortName", "--root": "rootDir" }[argument]] = value;
      index += 1;
    } else {
      fail(`Argumento desconhecido ou sem valor: ${argument}`);
    }
  }
  if (!options.id || !ID_PATTERN.test(options.id)) fail("--id deve ser um slug kebab-case.");
  if (!options.name || !options.name.trim()) fail("--name deve ser informado.");
  options.shortName ||= options.name;
  return options;
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const rootDir = resolve(options.rootDir);
  const characterDir = join(rootDir, "characters", options.id);
  const templateDir = join(rootDir, "templates", "character");
  const registryPath = join(rootDir, "characters", "registry.json");
  const charactersDir = dirname(registryPath);
  if (await exists(characterDir)) fail(`O diretório do personagem já existe: ${characterDir}`);
  if (!(await exists(templateDir))) fail(`Template não encontrado: ${templateDir}`);
  const registry = JSON.parse(await readFile(registryPath, "utf8"));
  if (!Array.isArray(registry.characters)) fail("characters/registry.json não contém uma lista characters.");
  if (registry.characters.some((profile) => profile.id === options.id)) fail(`ID já registrado: ${options.id}`);

  const rawReplacements = {
    "__CHARACTER_ID__": options.id,
    "__CHARACTER_NAME__": options.name,
    "__CHARACTER_SHORT_NAME__": options.shortName,
    "__RUNTIME_MARKER__": `${options.id.toUpperCase().replaceAll("-", "_")}_RUNTIME`,
  };
  const generatedFiles = new Map();
  for (const file of ["README.md", "character.json", "runtime.lua", "ui.xml"]) {
    const sourcePath = join(templateDir, file);
    if (!(await exists(sourcePath))) fail(`Arquivo obrigatório ausente no template: ${file}`);
    let content = await readFile(sourcePath, "utf8");
    const encode = file === "character.json" ? jsonStringContents
      : file === "ui.xml" ? xmlAttribute
        : String;
    for (const [token, replacement] of Object.entries(rawReplacements)) {
      content = content.replaceAll(token, encode(replacement));
    }
    if (/__CHARACTER_(?:ID|NAME|SHORT_NAME)__|__RUNTIME_MARKER__/.test(content)) {
      fail(`Token obrigatório não resolvido no template: ${file}`);
    }
    generatedFiles.set(file, content);
  }
  const generatedCharacter = JSON.parse(generatedFiles.get("character.json"));
  if (generatedCharacter.id !== options.id) fail("O template gerou character.json com identidade incompatível.");

  const profile = {
    id: options.id,
    displayName: options.name,
    shortName: options.shortName,
    version: null,
    status: "scaffold",
    sourceDir: `characters/${options.id}`,
    sourceFiles: { runtime: "runtime.lua", ui: "ui.xml", character: "character.json" },
    assetsDir: `characters/${options.id}/assets`,
    assets: {},
    files: {
      runtime: `${options.id}-runtime.lua`,
      manifest: `${options.id}-manifest.json`,
      savedObject: `${options.name.replace(/[^A-Za-z0-9]+/g, "_")}_Console.json`,
    },
    release: {
      tagMode: "namespaced",
      prerelease: true,
      globalLatest: false,
      productionEnabled: false,
      artifacts: {
        runtime: `${options.id}-runtime.lua`,
        manifest: `${options.id}-manifest.json`,
        savedObject: `${options.name.replace(/[^A-Za-z0-9]+/g, "_")}_Console.json`,
      },
    },
    discovery: "character-releases",
    uiContract: "generic",
    uiRootId: `${options.id}Console`,
    requiredUiIds: [`${options.id}Console`, "title"],
    runtimeMarker: `${options.id.toUpperCase().replaceAll("-", "_")}_RUNTIME`,
    minBootstrapVersion: "1.0.2",
  };
  const nextRegistry = {...registry, characters: [...registry.characters, profile]};
  const serializedRegistry = `${JSON.stringify(nextRegistry, null, 2)}\n`;
  JSON.parse(serializedRegistry);

  const transactionSuffix = `${process.pid}-${Date.now()}`;
  const stagingDir = join(charactersDir, `.${options.id}.scaffold-${transactionSuffix}`);
  const registryTempPath = join(charactersDir, `.registry.json.${transactionSuffix}.tmp`);
  const isExactChild = (path) => resolve(dirname(path)) === resolve(charactersDir)
    && resolve(path).startsWith(`${resolve(charactersDir)}${sep}`);
  const removeCreatedDirectory = async (path) => {
    if (!isExactChild(path) || ![basename(stagingDir), options.id].includes(basename(path))) {
      fail(`Rollback recusou caminho inesperado: ${path}`);
    }
    await rm(path, {recursive: true, force: true});
  };

  let finalDirectoryCreated = false;
  try {
    await mkdir(charactersDir, { recursive: true });
    await cp(templateDir, stagingDir, { recursive: true, errorOnExist: true, force: false });
    for (const [file, content] of generatedFiles) {
      await writeFile(join(stagingDir, file), content, "utf8");
    }
    await mkdir(join(stagingDir, "assets"), { recursive: true });
    if (await exists(characterDir)) fail(`O diretório do personagem já existe: ${characterDir}`);
    await rename(stagingDir, characterDir);
    finalDirectoryCreated = true;

    await writeFile(registryTempPath, serializedRegistry, {encoding: "utf8", flag: "wx"});
    await rename(registryTempPath, registryPath);
  } catch (error) {
    await rm(registryTempPath, {force: true}).catch(() => {});
    if (finalDirectoryCreated) await removeCreatedDirectory(characterDir);
    else if (await exists(stagingDir)) await removeCreatedDirectory(stagingDir);
    throw error;
  }
  process.stdout.write(`Scaffold ${options.id} criado em ${characterDir} e registrado como scaffold.\n`);
}

try {
  await main();
} catch (error) {
  process.stderr.write(`Criação falhou: ${error.message}\n`);
  process.exitCode = 1;
}
