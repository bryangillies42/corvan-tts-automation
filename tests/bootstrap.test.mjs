import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const bootstrapUrl = new URL('../src/bootstrap.lua', import.meta.url);
const source = await readFile(bootstrapUrl, 'utf8');
const runtimeSource = await readFile(new URL('../src/runtime.lua', import.meta.url), 'utf8');
const uiSource = await readFile(new URL('../src/ui.xml', import.meta.url), 'utf8');

test('keeps a single build-time seed runtime placeholder', () => {
  assert.equal((source.match(/__SEED_RUNTIME_LITERAL__/g) ?? []).length, 1);
  assert.match(source, /local BOOTSTRAP_VERSION = "1\.0\.1"/);
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
    'setRuntimeUiAttribute',
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
  assert.match(source, /setUiAttribute\(\s*"refreshStatus",\s*"text"/);
});

test('waits for object UI loading and only targets IDs declared by the XML', () => {
  const uiIds = new Set(
    [...uiSource.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]),
  );
  const bootstrapTargets = [
    ...source.matchAll(/setUiAttribute\(\s*"([^"]+)"/g),
  ].map((match) => match[1]);
  const runtimeTargets = [
    ...runtimeSource.matchAll(/safeSetAttribute\(\s*"([^"]+)"/g),
  ].map((match) => match[1]);

  assert.deepEqual(
    [...new Set([...bootstrapTargets, ...runtimeTargets].filter((id) => !uiIds.has(id)))],
    [],
    'Lua must never call UI.setAttribute for a missing XML id because TTS raises an uncatchable Unity error',
  );
  assert.match(source, /local uiReady = false/);
  assert.match(source, /local uiAttributeValues = \{\}/);
  assert.match(source, /if not uiReady or uiIds\[id\] ~= true then\s+return false/);
  assert.match(source, /return self\.UI\.loading/);
  assert.match(source, /Wait\.condition\(finishLoading, hasFinishedLoading/);
  assert.match(source, /uiIds\[id\] ~= true/);
  assert.match(runtimeSource, /safeParentCall\("setRuntimeUiAttribute"/);
  assert.doesNotMatch(runtimeSource, /parent\.UI\.setAttribute/);
  assert.doesNotMatch(source, /setUiAttribute\("(?:update_status|settings_refresh)"/);
});

test('uses the documented TTS WebRequest.custom argument order and validates HTTP status', () => {
  assert.match(
    source,
    /request = WebRequest\.custom\(url, "GET", true, "", requestHeaders, complete\)/,
  );
  assert.match(source, /request\.getResponseHeader\("ETag"\)/);
  assert.match(source, /headers\["If-None-Match"\] = state\.releaseEtag/);
  assert.match(source, /status == 304/);
  assert.match(source, /status ~= expectedStatus/);
  assert.match(source, /request\.is_error/);
  assert.match(source, /local WEB_REQUEST_TIMEOUT = 20/);
  assert.match(source, /request\.dispose\(\)/);
  assert.match(source, /error = "timeout de rede"/);
  assert.match(source, /if completed then\s+return/);
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
  assert.doesNotMatch(source, /helperGuid = snapshot\.helperGuid/);
  assert.match(source, /installUiXml\(snapshot\.uiXml\)/);
  assert.doesNotMatch(source, /self\.reload\s*\(/);
});

test('keeps persisted source, version, ETag, and commit as one coherent runtime bundle', () => {
  assert.match(source, /local persistedRuntimeIsValid = runtimeSourceIsValid\(decoded\.runtimeSource\)/);
  const bundleStart = source.indexOf('if persistedRuntimeIsValid then');
  const bundleEnd = source.indexOf('if type(decoded.runtimeState)', bundleStart);
  const bundle = source.slice(bundleStart, bundleEnd);
  for (const assignment of [
    'clean.runtimeSource = decoded.runtimeSource',
    'clean.runtimeVersion = decoded.runtimeVersion',
    'clean.runtimeCommitSha = decoded.runtimeCommitSha',
    'clean.releaseEtag = decoded.releaseEtag',
  ]) {
    assert.match(bundle, new RegExp(assignment.replaceAll('.', '\\.')));
  }
});

test('blocks refresh during duplicate requests and physical rolls', () => {
  assert.match(source, /if update\.active then/);
  assert.match(source, /exported\.rollInProgress == true/);
  assert.match(source, /exported\.busy == true/);
  assert.match(source, /interactable", pendingRefreshBusy and "false" or "true"/);
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
