'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const TOKEN_FILE_NAME = 'bridge-token.txt';

function resolveBridgeSharedDirectory(options = {}) {
  if (options.rootDirectory) {
    return options.rootDirectory;
  }

  const environmentRoot =
    process.env.LOCALAPPDATA || process.env.APPDATA || os.tmpdir();
  return path.join(environmentRoot, 'FilmStoryboard', 'ResolveBridge');
}

function loadOrCreateBridgeToken(options = {}) {
  const directory = resolveBridgeSharedDirectory(options);
  const filePath = path.join(directory, TOKEN_FILE_NAME);
  const existing = readValidToken(filePath);
  if (existing) {
    return existing;
  }

  fs.mkdirSync(directory, { recursive: true });
  if (fs.existsSync(filePath)) {
    fs.unlinkSync(filePath);
  }

  const token = crypto.randomBytes(32).toString('hex');
  try {
    fs.writeFileSync(filePath, token, {
      encoding: 'utf8',
      flag: 'wx',
      mode: 0o600,
    });
    return token;
  } catch (error) {
    if (error && error.code === 'EEXIST') {
      const racedToken = readValidToken(filePath);
      if (racedToken) {
        return racedToken;
      }
    }
    throw error;
  }
}

function readValidToken(filePath) {
  if (!fs.existsSync(filePath)) {
    return '';
  }
  const token = fs.readFileSync(filePath, 'utf8').trim();
  return token.length >= 32 ? token : '';
}

module.exports = {
  TOKEN_FILE_NAME,
  loadOrCreateBridgeToken,
  resolveBridgeSharedDirectory,
};
