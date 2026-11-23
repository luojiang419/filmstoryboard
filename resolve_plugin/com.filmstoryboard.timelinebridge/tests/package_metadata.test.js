'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const pluginRoot = path.join(__dirname, '..');

test('package and Resolve manifest expose the same plugin version', () => {
  const packageJson = JSON.parse(
    fs.readFileSync(path.join(pluginRoot, 'package.json'), 'utf8'),
  );
  const manifest = fs.readFileSync(
    path.join(pluginRoot, 'manifest.xml'),
    'utf8',
  );
  const versionMatch = manifest.match(/<Version>([^<]+)<\/Version>/);

  assert.ok(versionMatch, 'manifest.xml must contain a Version element');
  assert.equal(versionMatch[1], packageJson.version);
});
