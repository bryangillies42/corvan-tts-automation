import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const bootstrapUrl = new URL('../src/bootstrap.lua', import.meta.url);
const source = await readFile(bootstrapUrl, 'utf8');

test('keeps a single build-time seed runtime placeholder', () => {
  assert.equal((source.match(/__SEED_RUNTIME_LITERAL__/g) ?? []).length, 1);
  assert.match(source, /local BOOTSTRAP_VERSION = "1\.0\.0"/);
  assert.match(source, /local SEED_RUNTIME = __SEED_RUNTIME_LITERAL__/);
});

test('exposes the complete stable panel callback contract', () => {
  for (const callback of [
    'onLoad',
    'onSave',
    'onDestroy',
    'dispatch',
    'refresh',
    'runtimeReady',
    'cacheRuntimeState',
    'applyRuntimeUi',
  ]) {
    assert.match(source, new RegExp(`function ${callback}\\(`), callback);
  }

  assert.match(source, /"handleUiEvent", \{/);
  assert.match(source, /playerColor = playerColor/);
  assert.match(source, /value = value/);
  assert.match(source, /id = id/);
});

test('uses copy-safe helper ownership and a non-interactive hidden scripting zone', () => {
  assert.match(source, /notes\.parentGuid == self\.getGUID\(\)/);
  assert.match(source, /type = "ScriptingTrigger"/);
  assert.match(source, /helper\.setLock\(true\)/);
  assert.match(source, /helper\.setInvisibleTo\(PLAYER_COLORS\)/);
  assert.match(source, /helper\.interactable = false/);
  assert.match(source, /helper\.drag_selectable = false/);
  assert.match(source, /self\.positionToWorld\(\{0, -2\.5, 0\}\)/);
  assert.match(source, /setUiAttribute\("refreshStatus", "text"/);
});

test('uses the documented TTS WebRequest.custom argument order and validates HTTP status', () => {
  assert.match(
    source,
    /WebRequest\.custom\(url, "GET", true, "", requestHeaders, callback\)/,
  );
  assert.match(source, /request\.getResponseHeader\("ETag"\)/);
  assert.match(source, /headers\["If-None-Match"\] = state\.releaseEtag/);
  assert.match(source, /status == 304/);
  assert.match(source, /status ~= expectedStatus/);
  assert.match(source, /request\.is_error/);
});

test('pins updates to public GitHub release assets and validates the manifest/runtime', () => {
  assert.match(
    source,
    /https:\/\/api\.github\.com\/repos\/bryangillies42\/corvan-tts-automation\/releases\/latest/,
  );
  assert.match(
    source,
    /https:\/\/github\.com\/bryangillies42\/corvan-tts-automation\/releases\/download\//,
  );
  for (const field of [
    'schemaVersion',
    'version',
    'minBootstrapVersion',
    'commitSha',
  ]) {
    assert.match(source, new RegExp(`manifest\\.${field}`), field);
  }
  assert.match(source, /job\.encodedLength ~= expectedSize/);
  assert.match(source, /string\.find\(source, RUNTIME_MARKER, 1, true\)/);
  assert.match(source, /manifest\.runtime\.sha256/);
  assert.match(source, /#runtimeSha256 ~= 64/);
  assert.match(
    source,
    /TRUSTED_RUNTIME_PREFIX \..*"v" \..*manifest\.version \..*"\/corvan-runtime\.lua"/,
  );
  assert.match(source, /local actualSha256 = sha256Digest\(job\.hash\)/);
  assert.match(source, /string\.lower\(actualSha256\) ~= string\.lower\(expectedSha256\)/);
  assert.match(source, /Wait\.frames\(/);
  assert.match(source, /job\.frames > 3600/);
  assert.match(source, /not isCurrentUpdate\(serial\)/);
  assert.ok(
    source.indexOf('verifyRuntimeIntegrityAsync(serial, source, runtimeSize')
      < source.indexOf('installCandidate(serial, {manifest = manifest'),
    'hash verification must happen before candidate installation',
  );
});

test('snapshots state and source before reload, health-checks, and has rollback', () => {
  const snapshotIndex = source.indexOf('update.snapshot = {');
  const candidateReloadIndex = source.indexOf(
    'reloadHelperForUpdate(serial, candidate.source, "install"',
  );
  assert.ok(snapshotIndex > -1, 'missing update snapshot');
  assert.ok(candidateReloadIndex > snapshotIndex, 'candidate reload must happen after snapshot');

  assert.match(source, /"exportState"/);
  assert.match(source, /"importState"/);
  assert.match(source, /"healthCheck"/);
  assert.match(source, /rollbackUpdate\(serial/);
  assert.match(
    source,
    /reloadHelperForUpdate\(serial, snapshot\.runtimeSource, "rollback", snapshot\.runtimeVersion\)/,
  );
  assert.doesNotMatch(source, /self\.reload\s*\(/);
});

test('blocks refresh during duplicate requests and physical rolls', () => {
  assert.match(source, /if update\.active then/);
  assert.match(source, /exported\.rollInProgress == true/);
  assert.match(source, /exported\.busy == true/);
  assert.match(source, /interactable", busy and "false" or "true"/);
  assert.match(source, /pcall\(printToColor,/);
  assert.doesNotMatch(source, /\bbroadcastTo(?:All|Color)\s*\(/);
});

test('does not use dynamic Lua execution or local filesystem APIs', () => {
  assert.doesNotMatch(source, /\bload\s*\(/);
  assert.doesNotMatch(source, /\bloadstring\s*\(/);
  assert.doesNotMatch(source, /\brequire\s*\(/);
  assert.doesNotMatch(source, /\bio\s*\./);
  assert.doesNotMatch(source, /\bos\s*\./);
});
