import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { buildProject } from "../scripts/build.mjs";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const contract = JSON.parse(await readFile(
  new URL("../fixtures/legacy/corvan-v0.2.0-contract.json", import.meta.url),
  "utf8",
));
const frozenBootstrap = await readFile(
  new URL("../fixtures/legacy/corvan-v0.2.0-bootstrap.lua", import.meta.url),
  "utf8",
);
const normalizedFrozenBootstrap = frozenBootstrap
  .replace(/^\uFEFF/, "")
  .replace(/\r\n?/g, "\n");

test("artefatos v0.2.1 preservam o protocolo congelado do bootstrap Corvan v0.2.0", async (t) => {
  const outDir = await mkdtemp(join(tmpdir(), "corvan-legacy-contract-"));
  t.after(() => rm(outDir, {recursive: true, force: true}));
  const result = await buildProject({
    rootDir: ROOT,
    outDir,
    characterId: "corvan",
    commitSha: "0123456789abcdef0123456789abcdef01234567",
  });
  const runtime = result.files[contract.runtimeAsset];

  assert.equal(contract.bootstrapVersion, "1.0.2");
  assert.equal(
    createHash("sha256").update(normalizedFrozenBootstrap).digest("hex"),
    contract.bootstrapSha256,
  );
  assert.match(frozenBootstrap, /local BOOTSTRAP_VERSION = "1\.0\.2"/);
  assert.match(frozenBootstrap, /releases\/latest/);
  assert.match(frozenBootstrap, /TRUSTED_RUNTIME_PREFIX \.\. "v" \.\. manifest\.version \.\. "\/corvan-runtime\.lua"/);
  assert.equal(result.manifest.schemaVersion, contract.manifestSchemaVersion);
  assert.equal(result.manifest.releaseTag, contract.releaseTag);
  assert.equal(result.manifest.minBootstrapVersion, contract.bootstrapVersion);
  assert.equal(result.manifest.runtime.url.endsWith(`/${contract.runtimeAsset}`), true);
  assert.match(runtime, new RegExp(contract.runtimeMarker));
  for (const callback of contract.requiredCallbacks) {
    assert.match(runtime, new RegExp(`function ${callback}\\(`));
  }
  assert.match(runtime, /allowLegacyIdentity = CHARACTER_ID == "corvan"/);
  assert.match(runtime, /AdapterApi\.state\.unwrap\(payload\)/);
});
