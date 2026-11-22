'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const test = require('node:test');

const {
  keepWindowResidentOnClose,
  showOrCreatePluginWindow,
} = require('../plugin_window_lifecycle');

class FakeWindow extends EventEmitter {
  constructor() {
    super();
    this.hideCount = 0;
    this.showCount = 0;
    this.destroyed = false;
  }

  hide() {
    this.hideCount += 1;
  }

  show() {
    this.showCount += 1;
  }

  isDestroyed() {
    return this.destroyed;
  }
}

test('用户关闭插件窗口时隐藏窗口而不退出桥接', () => {
  const window = new FakeWindow();
  let prevented = false;
  keepWindowResidentOnClose(window, { isShuttingDown: () => false });

  window.emit('close', {
    preventDefault() {
      prevented = true;
    },
  });

  assert.equal(prevented, true);
  assert.equal(window.hideCount, 1);
});

test('插件应用真正退出时允许窗口关闭', () => {
  const window = new FakeWindow();
  let prevented = false;
  keepWindowResidentOnClose(window, { isShuttingDown: () => true });

  window.emit('close', {
    preventDefault() {
      prevented = true;
    },
  });

  assert.equal(prevented, false);
  assert.equal(window.hideCount, 0);
});

test('插件再次激活时显示已隐藏窗口', () => {
  const window = new FakeWindow();
  let createCount = 0;

  const result = showOrCreatePluginWindow(window, () => {
    createCount += 1;
    return new FakeWindow();
  });

  assert.equal(result, window);
  assert.equal(window.showCount, 1);
  assert.equal(createCount, 0);
});

test('插件窗口已销毁时重新创建', () => {
  const window = new FakeWindow();
  window.destroyed = true;
  const replacement = new FakeWindow();

  const result = showOrCreatePluginWindow(window, () => replacement);

  assert.equal(result, replacement);
  assert.equal(window.showCount, 0);
});
