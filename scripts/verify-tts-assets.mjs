import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_PATH = fileURLToPath(import.meta.url);
const SHA_40 = /^[0-9a-f]{40}$/i;
const IMAGE_URL_KEYS = new Set([
  "URL",
  "ImageURL",
  "ImageSecondaryURL",
  "DiffuseURL",
  "NormalURL",
  "ColliderURL",
]);
const SUPPORTED_MIME = new Set(["image/png", "image/jpeg", "image/webp"]);
const MAX_IMAGE_BYTES = 32 * 1024 * 1024;
const MIN_DIMENSION = 64;
const MAX_DIMENSION = 16_384;

function fail(message) {
  throw new Error(message);
}

function readUint24LE(bytes, offset) {
  return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16);
}

function isPng(bytes) {
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  return bytes.length >= 24 && signature.every((value, index) => bytes[index] === value);
}

function pngDimensions(bytes) {
  if (!isPng(bytes) || String.fromCharCode(...bytes.subarray(12, 16)) !== "IHDR") {
    fail("PNG não possui assinatura/IHDR válidos.");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  return { type: "image/png", width: view.getUint32(16), height: view.getUint32(20) };
}

function jpegDimensions(bytes) {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) fail("JPEG não possui assinatura válida.");
  let offset = 2;
  while (offset + 3 < bytes.length) {
    while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
    if (offset >= bytes.length) break;
    const marker = bytes[offset];
    offset += 1;
    if (marker === 0xd8 || marker === 0xd9 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 1 >= bytes.length) break;
    const length = (bytes[offset] << 8) | bytes[offset + 1];
    if (length < 2 || offset + length > bytes.length) break;
    const isStartOfFrame = (marker >= 0xc0 && marker <= 0xcf)
      && ![0xc4, 0xc8, 0xcc].includes(marker);
    if (isStartOfFrame) {
      if (length < 7) break;
      return {
        type: "image/jpeg",
        height: (bytes[offset + 3] << 8) | bytes[offset + 4],
        width: (bytes[offset + 5] << 8) | bytes[offset + 6],
      };
    }
    offset += length;
  }
  fail("JPEG não contém dimensões em um marcador SOF válido.");
}

function webpDimensions(bytes) {
  const ascii = (start, end) => String.fromCharCode(...bytes.subarray(start, end));
  if (bytes.length < 20 || ascii(0, 4) !== "RIFF" || ascii(8, 12) !== "WEBP") {
    fail("WebP não possui assinatura válida.");
  }
  const chunk = ascii(12, 16);
  if (chunk === "VP8X") {
    if (bytes.length < 30) fail("WebP VP8X não contém frame válido.");
    return {
      type: "image/webp",
      width: readUint24LE(bytes, 24) + 1,
      height: readUint24LE(bytes, 27) + 1,
    };
  }
  if (chunk === "VP8 ") {
    if (bytes.length < 30 || bytes[23] !== 0x9d || bytes[24] !== 0x01 || bytes[25] !== 0x2a) {
      fail("WebP VP8 não contém frame válido.");
    }
    return {
      type: "image/webp",
      width: (bytes[26] | (bytes[27] << 8)) & 0x3fff,
      height: (bytes[28] | (bytes[29] << 8)) & 0x3fff,
    };
  }
  if (chunk === "VP8L") {
    if (bytes.length < 25 || bytes[20] !== 0x2f) fail("WebP VP8L não contém frame válido.");
    const bits = bytes[21] | (bytes[22] << 8) | (bytes[23] << 16) | (bytes[24] << 24);
    return {
      type: "image/webp",
      width: (bits & 0x3fff) + 1,
      height: ((bits >>> 14) & 0x3fff) + 1,
    };
  }
  fail(`Chunk WebP não suportado: ${chunk || "ausente"}.`);
}

async function readResponseBytes(response, url) {
  if (!response.body || typeof response.body.getReader !== "function") {
    const bytes = new Uint8Array(await response.arrayBuffer());
    if (bytes.length > MAX_IMAGE_BYTES) fail(`Asset excede ${MAX_IMAGE_BYTES} bytes: ${url}`);
    return bytes;
  }
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_IMAGE_BYTES) {
      await reader.cancel();
      fail(`Asset excede ${MAX_IMAGE_BYTES} bytes: ${url}`);
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

export function inspectImage(bytes) {
  if (!(bytes instanceof Uint8Array)) fail("A imagem deve ser fornecida como bytes.");
  if (isPng(bytes)) return pngDimensions(bytes);
  if (bytes.length >= 2 && bytes[0] === 0xff && bytes[1] === 0xd8) return jpegDimensions(bytes);
  if (bytes.length >= 12
    && String.fromCharCode(...bytes.subarray(0, 4)) === "RIFF"
    && String.fromCharCode(...bytes.subarray(8, 12)) === "WEBP") return webpDimensions(bytes);
  fail("Magic bytes não correspondem a PNG, JPEG ou WebP.");
}

export function extractImageUrls(savedObject) {
  const found = new Map();
  function visit(value, path) {
    if (Array.isArray(value)) {
      value.forEach((entry, index) => visit(entry, `${path}[${index}]`));
      return;
    }
    if (value === null || typeof value !== "object") return;
    for (const [key, entry] of Object.entries(value)) {
      const entryPath = path ? `${path}.${key}` : key;
      if (IMAGE_URL_KEYS.has(key) && typeof entry === "string" && entry.trim() !== "") {
        const url = entry.trim();
        const locations = found.get(url) ?? [];
        locations.push(entryPath);
        found.set(url, locations);
      }
      visit(entry, entryPath);
    }
  }
  visit(savedObject, "");
  return [...found.entries()].map(([url, locations]) => ({ url, locations }));
}

export function assertImmutableAssetUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    fail(`URL de asset inválida: ${value}`);
  }
  const isLocalHttp = url.protocol === "http:"
    && (url.hostname === "127.0.0.1" || url.hostname === "localhost");
  if (url.protocol !== "https:" && !isLocalHttp) {
    fail(`Asset deve usar HTTPS: ${value}`);
  }
  const hasFullSha = url.pathname.split("/").some((segment) => SHA_40.test(segment));
  if (!hasFullSha) fail(`URL de asset não contém revisão SHA de 40 caracteres: ${value}`);
  return url;
}

export async function verifyImageUrl(entry, { fetchImpl = globalThis.fetch } = {}) {
  if (typeof fetchImpl !== "function") fail("fetch não está disponível.");
  assertImmutableAssetUrl(entry.url);
  let response;
  try {
    response = await fetchImpl(entry.url, {
      headers: { Accept: "image/png,image/jpeg,image/webp" },
      signal: AbortSignal.timeout(15_000),
    });
  } catch (error) {
    fail(`Falha ao baixar ${entry.url}: ${error.message}`);
  }
  if (response.status !== 200) fail(`Asset respondeu HTTP ${response.status}: ${entry.url}`);
  if (response.url) assertImmutableAssetUrl(response.url);
  const mime = (response.headers.get("content-type") ?? "").split(";", 1)[0].trim().toLowerCase();
  if (!SUPPORTED_MIME.has(mime)) fail(`MIME não suportado (${mime || "ausente"}): ${entry.url}`);
  const declaredLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_IMAGE_BYTES) {
    fail(`Asset excede ${MAX_IMAGE_BYTES} bytes: ${entry.url}`);
  }
  const bytes = await readResponseBytes(response, entry.url);
  if (bytes.length === 0) fail(`Tamanho de asset inválido (0 bytes): ${entry.url}`);
  const image = inspectImage(bytes);
  if (image.type !== mime) fail(`MIME ${mime} não corresponde aos bytes ${image.type}: ${entry.url}`);
  if (!Number.isInteger(image.width) || !Number.isInteger(image.height)
    || image.width < MIN_DIMENSION || image.height < MIN_DIMENSION
    || image.width > MAX_DIMENSION || image.height > MAX_DIMENSION) {
    fail(`Dimensões não sensatas (${image.width}x${image.height}): ${entry.url}`);
  }
  return { ...entry, ...image, bytes: bytes.length };
}

export async function verifySavedObjectAssets(savedObject, options = {}) {
  if (savedObject === null || typeof savedObject !== "object" || Array.isArray(savedObject)) {
    fail("Saved Object deve ser um objeto JSON.");
  }
  const entries = extractImageUrls(savedObject);
  if (entries.length === 0) fail("Saved Object não contém URLs de imagem.");
  return Promise.all(entries.map((entry) => verifyImageUrl(entry, options)));
}

function parseArguments(argv) {
  let savedObjectPath = null;
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--saved-object" && argv[index + 1]) {
      savedObjectPath = argv[index + 1];
      index += 1;
    } else if (!argv[index].startsWith("-") && savedObjectPath === null) {
      savedObjectPath = argv[index];
    } else {
      fail(`Argumento desconhecido ou sem valor: ${argv[index]}`);
    }
  }
  if (!savedObjectPath) fail("Informe --saved-object <arquivo.json>.");
  return resolve(savedObjectPath);
}

export async function main(argv = process.argv.slice(2)) {
  const path = parseArguments(argv);
  let savedObject;
  try {
    savedObject = JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    fail(`Não foi possível ler o Saved Object ${path}: ${error.message}`);
  }
  const results = await verifySavedObjectAssets(savedObject);
  for (const result of results) {
    process.stdout.write(`OK ${result.width}x${result.height} ${result.type} ${result.url}\n`);
  }
  return results;
}

if (process.argv[1] && resolve(process.argv[1]) === resolve(SCRIPT_PATH)) {
  main().catch((error) => {
    process.stderr.write(`Assets TTS inválidos: ${error.message}\n`);
    process.exitCode = 1;
  });
}
