'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { afterEach, test } = require('node:test');

const { TimelineBindingStore } = require('../timeline_binding_store');

const temporaryDirectories = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('persists independent bindings for each project and script', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fsb-binding-'));
  temporaryDirectories.push(directory);
  const filePath = path.join(directory, 'bindings.json');
  const store = new TimelineBindingStore({ filePath });

  store.set({
    projectId: 'project-1',
    scriptId: 'script-1',
    timelineId: 'timeline-1',
    revision: 'revision-1',
  });
  store.set({
    projectId: 'project-2',
    scriptId: 'script-1',
    timelineId: 'timeline-2',
    revision: 'revision-2',
  });

  const reopened = new TimelineBindingStore({ filePath });
  assert.equal(
    reopened.get('project-1', 'script-1').timelineId,
    'timeline-1',
  );
  assert.equal(
    reopened.get('project-2', 'script-1').timelineId,
    'timeline-2',
  );
  assert.equal(reopened.get('project-1', 'missing'), null);
});

test('refuses to overwrite a corrupt binding file', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fsb-binding-'));
  temporaryDirectories.push(directory);
  const filePath = path.join(directory, 'bindings.json');
  fs.writeFileSync(filePath, '{broken', 'utf8');
  const store = new TimelineBindingStore({ filePath });

  assert.throws(() => store.get('project-1', 'script-1'), /绑定文件损坏/);
  assert.equal(fs.readFileSync(filePath, 'utf8'), '{broken');
});
