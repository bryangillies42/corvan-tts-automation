import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import {
  loadRegistry,
  loadRegistryValue,
  main,
  parseReleaseTag,
  resolveRelease,
  selectPreviousStableVersion,
  selectStableReleaseCatalog,
  versionFromReleaseTag,
} from "../scripts/resolve-release.mjs";

function release({ tagMode, productionEnabled = true, prerelease = false, globalLatest = false, artifacts }) {
  return { productionEnabled, prerelease, tagMode, globalLatest, artifacts };
}

function profile({ id, version, status = "active", tagMode, productionEnabled = true, prerelease = false, globalLatest = false }) {
  return {
    id,
    displayName: id,
    shortName: id,
    runtimeMarker: `${id.toUpperCase().replaceAll("-", "_")}_RUNTIME`,
    minBootstrapVersion: "1.0.2",
    version,
    status,
    sourceDir: `characters/${id}`,
    release: release({
      tagMode,
      productionEnabled,
      prerelease,
      globalLatest,
      artifacts: {
        runtime: `${id}-runtime.lua`,
        manifest: `${id}-manifest.json`,
        savedObject: `${id}_Console.json`,
      },
    }),
  };
}

test("mapeia tags legacy e namespaced para o perfil correto", () => {
  const profiles = loadRegistryValue({
    characters: [
      profile({ id: "corvan", version: "0.2.1", tagMode: "legacy", globalLatest: true }),
      profile({ id: "arcane-test", version: "1.4.0", tagMode: "namespaced" }),
    ],
  });

  assert.deepEqual(parseReleaseTag("v0.2.1"), { id: "corvan", version: "0.2.1", tagMode: "legacy" });
  assert.deepEqual(parseReleaseTag("arcane-test-v1.4.0"), { id: "arcane-test", version: "1.4.0", tagMode: "namespaced" });

  const corvan = resolveRelease({ tag: "v0.2.1", profiles });
  assert.equal(corvan.id, "corvan");
  assert.equal(corvan.latest, true);
  assert.equal(corvan.minBootstrapVersion, "1.0.2");
  assert.equal(corvan.savedObjectName, "corvan Console");
  assert.equal(corvan.savedObjectDescription, "Console atualizável • corvan v0.2.1");
  assert.equal(corvan.artifactPaths.runtime, "dist/corvan/corvan-runtime.lua");

  const fixture = resolveRelease({ tag: "arcane-test-v1.4.0", profiles });
  assert.equal(fixture.id, "arcane-test");
  assert.equal(fixture.latest, false);
  assert.equal(fixture.tagMode, "namespaced");
});

test("recusa perfil scaffold, produção desabilitada, versão divergente e tag incompatível", () => {
  const profiles = loadRegistryValue({
    characters: [
      profile({ id: "corvan", version: "0.2.1", tagMode: "legacy", globalLatest: true }),
      profile({ id: "spentar", version: null, status: "scaffold", tagMode: "namespaced", productionEnabled: false, prerelease: true }),
      profile({ id: "disabled", version: "1.0.0", status: "disabled", tagMode: "namespaced", productionEnabled: false }),
    ],
  });

  assert.throws(() => resolveRelease({ tag: "spentar-v0.2.1", profiles }), /scaffold/);
  assert.throws(() => resolveRelease({ tag: "disabled-v1.0.0", profiles }), /desabilitado|produção/);
  assert.throws(() => resolveRelease({ tag: "v0.2.0", profiles }), /diverge/);
  assert.throws(() => resolveRelease({ tag: "corvan-v0.2.1", profiles }), /incompatível|legacy/);
  assert.throws(() => resolveRelease({ tag: "disabled-v1.0.1", profiles }), /desabilitado|produção/);
  assert.throws(() => parseReleaseTag("v1.0.0-beta.1"), /não usa/);
  assert.throws(() => parseReleaseTag("arcane-test-1.0.0"), /não usa/);
});

test("registry real bloqueia tecnicamente qualquer release do Spentar", async () => {
  const profiles = await loadRegistry();
  assert.throws(
    () => resolveRelease({tag: "spentar-v0.0.1", profiles}),
    /scaffold|produção/,
  );
});

test("catálogo estável filtra identidade inteira, ruído e ordena por SemVer entre páginas", () => {
  const releaseProfile = {id: "arcane-test", tagMode: "namespaced"};
  const pages = [
    [
      {tag_name: "arcane-test-v1.2.0", draft: false, prerelease: false},
      {tag_name: "arcane-test-v9.0.0", draft: true, prerelease: false},
      {tag_name: "arcane-test-v8.0.0", draft: false, prerelease: true},
      {tag_name: "arcane-testing-v7.0.0", draft: false, prerelease: false},
      {tag_name: "arcane-test-v01.3.0", draft: false, prerelease: false},
    ],
    [
      {tag_name: "arcane-test-v1.10.0", draft: false, prerelease: false},
      {tag_name: "v99.0.0", draft: false, prerelease: false},
      {tag_name: "arcane-test-v1.3.0", draft: false, prerelease: false},
    ],
  ];
  assert.equal(versionFromReleaseTag(releaseProfile, "arcane-test-v1.2.3"), "1.2.3");
  assert.equal(versionFromReleaseTag(releaseProfile, "arcane-testing-v1.2.3"), null);
  assert.deepEqual(
    selectStableReleaseCatalog({profile: releaseProfile, pages}).map(({version}) => version),
    ["1.2.0", "1.3.0", "1.10.0"],
  );
  assert.equal(selectPreviousStableVersion({
    profile: releaseProfile,
    currentVersion: "2.0.0",
    pages,
  }), "1.10.0");
  assert.equal(selectPreviousStableVersion({
    profile: releaseProfile,
    currentVersion: "1.3.0",
    pages,
  }), "1.2.0");
});

test("catálogo falha fechado quando a décima página também está cheia", () => {
  const fullPage = Array.from({length: 100}, (_, index) => ({
    tag_name: `arcane-test-v0.0.${index}`,
    draft: false,
    prerelease: false,
  }));
  assert.throws(
    () => selectStableReleaseCatalog({
      profile: {id: "arcane-test", tagMode: "namespaced"},
      pages: Array.from({length: 10}, () => fullPage),
    }),
    /10 páginas completas/,
  );
});

test("emite outputs simples e JSON para o GitHub Actions", async () => {
  const rootDir = await mkdtemp(join(tmpdir(), "corvan-release-"));
  await mkdir(join(rootDir, "characters"), { recursive: true });
  await writeFile(join(rootDir, "characters", "registry.json"), JSON.stringify({
    schemaVersion: 1,
    characters: [profile({ id: "corvan", version: "0.2.1", tagMode: "legacy", globalLatest: true })],
  }));
  const outputPath = join(rootDir, "github-output.txt");
  const resolved = await main([
    "--root", rootDir,
    "--tag", "v0.2.1",
    "--github-output", outputPath,
  ], {stdout: false});
  const output = await readFile(outputPath, "utf8");
  assert.equal(resolved.id, "corvan");
  assert.match(output, /id=corvan/);
  assert.match(output, /latest=true/);
  assert.match(output, /minBootstrapVersion=1\.0\.2/);
  assert.match(output, /savedObjectDescription=Console atualizável • corvan v0\.2\.1/);
  assert.match(output, /releaseJson=\{"id":"corvan"/);
});
