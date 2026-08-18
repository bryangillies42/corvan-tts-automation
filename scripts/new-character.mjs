import { access, cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const ID_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;

function fail(message) {
  throw new Error(message);
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
  if (await exists(characterDir)) fail(`O diretório do personagem já existe: ${characterDir}`);
  if (!(await exists(templateDir))) fail(`Template não encontrado: ${templateDir}`);
  const registry = JSON.parse(await readFile(registryPath, "utf8"));
  if (!Array.isArray(registry.characters)) fail("characters/registry.json não contém uma lista characters.");
  if (registry.characters.some((profile) => profile.id === options.id)) fail(`ID já registrado: ${options.id}`);

  await mkdir(dirname(characterDir), { recursive: true });
  await cp(templateDir, characterDir, { recursive: true });
  const replacements = {
    "__CHARACTER_ID__": options.id,
    "__CHARACTER_NAME__": options.name,
    "__CHARACTER_SHORT_NAME__": options.shortName,
    "__RUNTIME_MARKER__": `${options.id.toUpperCase().replaceAll("-", "_")}_RUNTIME`,
  };
  for (const file of ["README.md", "character.json", "runtime.lua", "ui.xml"]) {
    const path = join(characterDir, file);
    let content = await readFile(path, "utf8");
    for (const [token, replacement] of Object.entries(replacements)) content = content.replaceAll(token, replacement);
    await writeFile(path, content, "utf8");
  }
  await mkdir(join(characterDir, "assets"), { recursive: true });
  registry.characters.push({
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
    uiRootId: `${options.id}Console`,
    panelArtId: "panelBoardArt",
    requiredUiIds: ["panelBoardArt", `${options.id}Console`, "title"],
    runtimeMarker: `${options.id.toUpperCase().replaceAll("-", "_")}_RUNTIME`,
    minBootstrapVersion: "1.0.2",
    geometry: { canvasWidth: 900, canvasHeight: 500, panelWidth: 800, panelHeight: 400 },
  });
  await writeFile(registryPath, `${JSON.stringify(registry, null, 2)}\n`, "utf8");
  process.stdout.write(`Scaffold ${options.id} criado em ${characterDir} e registrado como scaffold.\n`);
}

try {
  await main();
} catch (error) {
  process.stderr.write(`Criação falhou: ${error.message}\n`);
  process.exitCode = 1;
}
