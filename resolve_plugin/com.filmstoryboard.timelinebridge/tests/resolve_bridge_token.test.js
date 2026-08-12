'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { afterEach, test } = require('node:test');

const {
  TOKEN_FILE_NAME,
  loadOrCreateBridgeToken,
} = require('../resolve_bridge_token');

const temporaryDirectories = [];

afterEach(() => {
  for (const directory of temporaryDirectories.splice(0)) {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

test('creates and then reuses the same 256-bit bridge token', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'fsb-token-'));
  temporaryDirectories.push(directory);

  const first = loadOrCreateBridgeToken({ rootDirectory: directory });
  const second = loadOrCreateBridgeToken({ rootDirectory: directory });

  assert.match(first, /^[a-f0-9]{64}$/);
  assert.equal(second, first);
  assert.equal(
    fs.readFileSync(path.join(directory, TOKEN_FILE_NAME), 'utf8'),
    first,
  );
});
