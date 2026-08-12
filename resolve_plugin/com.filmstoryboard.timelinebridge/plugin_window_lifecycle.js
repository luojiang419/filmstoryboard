'use strict';

function keepWindowResidentOnClose(window, { isShuttingDown }) {
  window.on('close', (event) => {
    if (isShuttingDown()) {
      return;
    }
    event.preventDefault();
    window.hide();
  });
}

function showOrCreatePluginWindow(window, createWindow) {
  if (window && !window.isDestroyed()) {
    window.show();
    return window;
  }
  return createWindow();
}

module.exports = {
  keepWindowResidentOnClose,
  showOrCreatePluginWindow,
};
