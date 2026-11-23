'use strict';

const fs = require('node:fs');
const path = require('node:path');

const { resolveBridgeSharedDirectory } = require('./resolve_bridge_token');

const BINDING_SCHEMA_VERSION = 1;
const BINDING_FILE_NAME = 'timeline-bindings.json';

class TimelineBindingStore {
  constructor(options = {}) {
    this.filePath =
      options.filePath ||
      path.join(resolveBridgeSharedDirectory(), BINDING_FILE_NAME);
  }

  get(projectId, scriptId) {
    const state = this.#read();
    const binding = state.bindings[bindingKey(projectId, scriptId)];
    return binding ? { ...binding } : null;
  }

  set(binding) {
    const state = this.#read();
    state.bindings[bindingKey(binding.projectId, binding.scriptId)] = {
      ...binding,
    };
    this.#write(state);
  }

  delete(projectId, scriptId) {
    const state = this.#read();
    const key = bindingKey(projectId, scriptId);
    if (!Object.hasOwn(state.bindings, key)) {
      return;
    }
    delete state.bindings[key];
    this.#write(state);
  }

  #read() {
    if (!fs.existsSync(this.filePath)) {
      return emptyState();
    }
    let decoded;
    try {
      decoded = JSON.parse(fs.readFileSync(this.filePath, 'utf8'));
    } catch (error) {
      throw new Error(`时间线绑定文件损坏：${error.message}`);
    }
    if (
      !decoded ||
      decoded.schemaVersion !== BINDING_SCHEMA_VERSION ||
      !decoded.bindings ||
      typeof decoded.bindings !== 'object' ||
      Array.isArray(decoded.bindings)
    ) {
      throw new Error('时间线绑定文件版本或结构无效');
    }
    return decoded;
  }

  #write(state) {
    const directory = path.dirname(this.filePath);
    fs.mkdirSync(directory, { recursive: true });
    const temporaryPath = `${this.filePath}.${process.pid}.tmp`;
    try {
      fs.writeFileSync(temporaryPath, JSON.stringify(state, null, 2), {
        encoding: 'utf8',
        mode: 0o600,
      });
      fs.renameSync(temporaryPath, this.filePath);
    } finally {
      if (fs.existsSync(temporaryPath)) {
        fs.unlinkSync(temporaryPath);
      }
    }
  }
}

function bindingKey(projectId, scriptId) {
  return JSON.stringify([String(projectId), String(scriptId)]);
}

function emptyState() {
  return {
    schemaVersion: BINDING_SCHEMA_VERSION,
    bindings: {},
  };
}

module.exports = {
  BINDING_FILE_NAME,
  TimelineBindingStore,
};
