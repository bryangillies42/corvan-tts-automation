import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const workflow = readFileSync(new URL('../.github/workflows/release.yml', import.meta.url), 'utf8');

test('release aceita somente commits integrados ao main e valida a fixture compartilhada', () => {
  const mainGateIndex = workflow.indexOf('- name: Verify tagged commit belongs to main');
  const testIndex = workflow.indexOf('- name: Test');
  const fixtureIndex = workflow.indexOf('- name: Build divergent fixture');
  const stageIndex = workflow.indexOf('- name: Validate and stage release assets in a draft');

  assert.ok(mainGateIndex >= 0, 'gate de ancestralidade no main ausente');
  assert.ok(testIndex > mainGateIndex, 'testes devem rodar após validar o commit tagueado');
  assert.ok(fixtureIndex > testIndex, 'fixture deve ser construída depois dos testes');
  assert.ok(stageIndex > fixtureIndex, 'draft não pode existir antes do build da fixture');
  assert.match(workflow, /git merge-base --is-ancestor "\$\{GITHUB_SHA\}" refs\/remotes\/origin\/main/);
  assert.match(workflow, /npm run build:fixture/);
});

test('release verifica integralmente a draft antes de publicar', () => {
  const stageIndex = workflow.indexOf('- name: Validate and stage release assets in a draft');
  const verifyIndex = workflow.indexOf('- name: Verify draft assets before publication');
  const publishIndex = workflow.indexOf('- name: Publish verified release');
  const confirmIndex = workflow.indexOf('- name: Confirm published state and global Latest');

  assert.ok(stageIndex >= 0, 'etapa de criação/upload da draft ausente');
  assert.ok(verifyIndex > stageIndex, 'a draft deve ser verificada depois do upload');
  assert.ok(publishIndex > verifyIndex, 'a publicação deve ocorrer somente depois da verificação');
  assert.ok(confirmIndex > publishIndex, 'a confirmação deve ocorrer depois da publicação');

  const draftVerification = workflow.slice(verifyIndex, publishIndex);
  assert.match(draftVerification, /\.isDraft == true/);
  assert.match(draftVerification, /actual_assets.*!=.*expected_assets/s);
  assert.match(draftVerification, /gh release download/);
  assert.equal((draftVerification.match(/cmp --silent/g) ?? []).length, 3);
  assert.match(draftVerification, /RELEASE_RUNTIME_MARKER/);
  assert.match(draftVerification, /sha256sum/);
  assert.match(draftVerification, /\.runtime\.url == \$runtimeUrl/);
  assert.match(draftVerification, /\.runtime\.sha256 == \$runtimeSha256/);
  assert.match(draftVerification, /\.runtime\.size == \$runtimeSize/);
  assert.match(draftVerification, /\.commitSha == \$commitSha/);
  assert.match(draftVerification, /\.minBootstrapVersion == \$minBootstrapVersion/);
  assert.match(draftVerification, /\.previousVersion ==/);
  assert.match(draftVerification, /ObjectStates\[0\]\.Nickname == \$name/);
  assert.match(draftVerification, /ObjectStates\[0\]\.Description == \$description/);
  assert.match(draftVerification, /\.Note == \$note/);
  assert.match(draftVerification, /GMNotes \| fromjson/);
  assert.match(draftVerification, /\.characterId == \$id/);
  assert.match(draftVerification, /\.releaseTag == \$tag/);
  assert.match(draftVerification, /\.version == \$version/);

  const beforePublish = workflow.slice(0, publishIndex);
  assert.doesNotMatch(beforePublish, /gh release edit .*--draft=false/);
});

test('pós-publicação confirma somente estado, canal e Latest', () => {
  const confirmIndex = workflow.indexOf('- name: Confirm published state and global Latest');
  const confirmation = workflow.slice(confirmIndex);

  assert.match(confirmation, /\.isDraft == false/);
  assert.match(confirmation, /\.isPrerelease == \$prerelease/);
  assert.match(confirmation, /releases\/latest/);
  assert.doesNotMatch(confirmation, /gh release download/);
  assert.doesNotMatch(confirmation, /cmp --silent/);
  assert.doesNotMatch(confirmation, /\.assets/);
});

test('política de Latest permanece isolada por perfil e canal', () => {
  const publishIndex = workflow.indexOf('- name: Publish verified release');
  const confirmIndex = workflow.indexOf('- name: Confirm published state and global Latest');
  const publication = workflow.slice(publishIndex, confirmIndex);

  assert.match(publication, /RELEASE_PRERELEASE.*==.*true/s);
  assert.match(publication, /--draft=false --prerelease --latest=false/);
  assert.match(publication, /RELEASE_LATEST.*==.*true/s);
  assert.match(publication, /--draft=false --latest\s*$/m);
  assert.match(publication, /--draft=false --latest=false/);
});
