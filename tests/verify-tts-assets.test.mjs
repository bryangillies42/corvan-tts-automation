import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";

import {
  assertImmutableAssetUrl,
  extractImageUrls,
  inspectImage,
  verifySavedObjectAssets,
} from "../scripts/verify-tts-assets.mjs";

const SHA = "0123456789abcdef0123456789abcdef01234567";

function png(width = 1600, height = 1000) {
  const bytes = Buffer.alloc(24);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]).copy(bytes);
  bytes.writeUInt32BE(13, 8);
  bytes.write("IHDR", 12, "ascii");
  bytes.writeUInt32BE(width, 16);
  bytes.writeUInt32BE(height, 20);
  return bytes;
}

function jpeg(width = 1600, height = 1000) {
  return Buffer.from([
    0xff, 0xd8,
    0xff, 0xc0, 0x00, 0x11, 0x08,
    (height >>> 8) & 0xff, height & 0xff,
    (width >>> 8) & 0xff, width & 0xff,
    0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
    0xff, 0xd9,
  ]);
}

function webp(width = 1600, height = 1000) {
  const bytes = Buffer.alloc(30);
  bytes.write("RIFF", 0, "ascii");
  bytes.writeUInt32LE(22, 4);
  bytes.write("WEBP", 8, "ascii");
  bytes.write("VP8X", 12, "ascii");
  bytes.writeUInt32LE(10, 16);
  bytes.writeUIntLE(width - 1, 24, 3);
  bytes.writeUIntLE(height - 1, 27, 3);
  return bytes;
}

async function localImageServer(t, routes) {
  const server = createServer((request, response) => {
    const route = routes[new URL(request.url, "http://localhost").pathname];
    if (!route) {
      response.writeHead(404).end("missing");
      return;
    }
    response.writeHead(route.status ?? 200, { "Content-Type": route.mime });
    response.end(route.body);
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const { port } = server.address();
  return `http://127.0.0.1:${port}`;
}

test("extrai, deduplica e informa os caminhos das imagens do Saved Object", () => {
  const url = `https://raw.githubusercontent.com/example/repo/${SHA}/panel.png`;
  const entries = extractImageUrls({
    ObjectStates: [{ CustomImage: { ImageURL: url, ImageSecondaryURL: "" } }],
    CustomUIAssets: [{ Name: "panel", URL: url }],
  });
  assert.deepEqual(entries, [{
    url,
    locations: ["ObjectStates[0].CustomImage.ImageURL", "CustomUIAssets[0].URL"],
  }]);
});

test("aceita somente URLs HTTPS imutáveis por SHA-40 (localhost é liberado para o harness)", () => {
  assert.equal(assertImmutableAssetUrl(`https://example.test/${SHA}/panel.png`).hostname, "example.test");
  assert.equal(assertImmutableAssetUrl(`http://127.0.0.1/${SHA}/panel.png`).hostname, "127.0.0.1");
  assert.throws(() => assertImmutableAssetUrl("https://example.test/main/panel.png"), /SHA de 40/);
  assert.throws(() => assertImmutableAssetUrl(`http://example.test/${SHA}/panel.png`), /HTTPS/);
});

test("inspeciona dimensões pelos magic bytes de PNG, JPEG e WebP", () => {
  assert.deepEqual(inspectImage(png()), { type: "image/png", width: 1600, height: 1000 });
  assert.deepEqual(inspectImage(jpeg()), { type: "image/jpeg", width: 1600, height: 1000 });
  assert.deepEqual(inspectImage(webp()), { type: "image/webp", width: 1600, height: 1000 });
  assert.throws(() => inspectImage(Buffer.from("not-an-image")), /Magic bytes/);
});

test("valida HTTP 200, MIME, magic bytes e dimensões sem rede externa", async (t) => {
  const base = await localImageServer(t, {
    [`/${SHA}/panel.png`]: { mime: "image/png; charset=binary", body: png() },
    [`/${SHA}/portrait.jpg`]: { mime: "image/jpeg", body: jpeg() },
    [`/${SHA}/overlay.webp`]: { mime: "image/webp", body: webp() },
  });
  const results = await verifySavedObjectAssets({
    ObjectStates: [{
      CustomImage: {
        ImageURL: `${base}/${SHA}/panel.png`,
        ImageSecondaryURL: `${base}/${SHA}/portrait.jpg`,
      },
    }],
    CustomUIAssets: [{ URL: `${base}/${SHA}/overlay.webp` }],
  });
  assert.deepEqual(results.map(({ type }) => type).sort(), ["image/jpeg", "image/png", "image/webp"]);
  assert.ok(results.every(({ width, height }) => width === 1600 && height === 1000));
});

test("falha fechado para HTTP, MIME, bytes e dimensões inválidos", async (t) => {
  const base = await localImageServer(t, {
    [`/${SHA}/wrong-mime.png`]: { mime: "text/plain", body: png() },
    [`/${SHA}/wrong-bytes.png`]: { mime: "image/png", body: Buffer.from("not png") },
    [`/${SHA}/tiny.png`]: { mime: "image/png", body: png(32, 32) },
  });
  const savedObject = (url) => ({ ObjectStates: [{ CustomImage: { ImageURL: url } }] });
  await assert.rejects(
    verifySavedObjectAssets(savedObject(`${base}/${SHA}/missing.png`)),
    /HTTP 404/,
  );
  await assert.rejects(
    verifySavedObjectAssets(savedObject(`${base}/${SHA}/wrong-mime.png`)),
    /MIME não suportado/,
  );
  await assert.rejects(
    verifySavedObjectAssets(savedObject(`${base}/${SHA}/wrong-bytes.png`)),
    /Magic bytes/,
  );
  await assert.rejects(
    verifySavedObjectAssets(savedObject(`${base}/${SHA}/tiny.png`)),
    /Dimensões não sensatas/,
  );
});

test("recusa Saved Object sem imagens e URL presa ao branch main", async () => {
  await assert.rejects(verifySavedObjectAssets({ ObjectStates: [] }), /não contém URLs/);
  await assert.rejects(verifySavedObjectAssets({
    ObjectStates: [{
      CustomImage: {
        ImageURL: "https://raw.githubusercontent.com/example/repo/main/panel.png?sha256=abc",
      },
    }],
  }), /SHA de 40/);
});
