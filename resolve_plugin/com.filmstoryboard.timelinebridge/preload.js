'use strict';

const { contextBridge, ipcRenderer } = require('electron/renderer');

contextBridge.exposeInMainWorld('filmStoryboardBridge', {
  getStatus: () => ipcRenderer.invoke('bridge:getStatus'),
  refresh: () => ipcRenderer.invoke('bridge:refresh'),
  onStatusChanged: (callback) => {
    const listener = (_event, status) => callback(status);
    ipcRenderer.on('bridge:statusChanged', listener);
    return () => ipcRenderer.removeListener('bridge:statusChanged', listener);
  },
});
