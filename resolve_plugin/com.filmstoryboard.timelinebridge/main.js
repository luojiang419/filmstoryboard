'use strict';

const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('node:path');

const { createBridgeServer } = require('./bridge_server');
const { ResolveGateway } = require('./resolve_gateway');
const { loadOrCreateBridgeToken } = require('./resolve_bridge_token');
const { loadWorkflowIntegration } = require('./workflow_integration_loader');
const {
  keepWindowResidentOnClose,
  showOrCreatePluginWindow,
} = require('./plugin_window_lifecycle');
const packageJson = require('./package.json');

const PLUGIN_ID = 'com.filmstoryboard.timelinebridge';
const BRIDGE_HOST = '127.0.0.1';
const BRIDGE_PORT = 47861;

let mainWindow = null;
let bridgeServer = null;
let gateway = null;
let shuttingDown = false;
let runtimeStatus = {
  state: 'starting',
  message: '正在初始化 Resolve 接口…',
  pluginVersion: packageJson.version,
  resolveVersion: '',
  projectName: '',
  projectId: '',
  bridgeAddress: `${BRIDGE_HOST}:${BRIDGE_PORT}`,
  lastRequest: null,
};

function publishStatus(patch) {
  runtimeStatus = { ...runtimeStatus, ...patch };
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send('bridge:statusChanged', runtimeStatus);
  }
}

async function refreshResolveStatus() {
  if (!gateway) {
    return runtimeStatus;
  }
  try {
    const health = await gateway.health();
    publishStatus({
      state: health.projectId ? 'ready' : 'waiting-project',
      message: health.projectId
        ? '已连接，可接收 FilmStoryboard 时间线'
        : '已连接 Resolve，请先打开一个项目',
      ...health,
    });
  } catch (error) {
    publishStatus({
      state: 'error',
      message: error.message || 'Resolve 接口初始化失败',
    });
  }
  return runtimeStatus;
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 560,
    height: 520,
    minWidth: 500,
    minHeight: 460,
    useContentSize: true,
    backgroundColor: '#111318',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  mainWindow.setMenu(null);
  mainWindow.loadFile('index.html');
  keepWindowResidentOnClose(mainWindow, {
    isShuttingDown: () => shuttingDown,
  });
  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

function registerIpcHandlers() {
  ipcMain.handle('bridge:getStatus', () => runtimeStatus);
  ipcMain.handle('bridge:refresh', () => refreshResolveStatus());
}

async function startBridge() {
  try {
    const workflowIntegration = loadWorkflowIntegration();
    gateway = new ResolveGateway({
      workflowIntegration,
      pluginId: PLUGIN_ID,
    });
    await gateway.initialize();

    const token = loadOrCreateBridgeToken();
    bridgeServer = createBridgeServer({
      token,
      gateway,
      pluginVersion: packageJson.version,
      onRequest: (requestStatus) => {
        publishStatus({ lastRequest: requestStatus });
        void refreshResolveStatus();
      },
    });
    await listen(bridgeServer, BRIDGE_PORT, BRIDGE_HOST);
    await refreshResolveStatus();
  } catch (error) {
    publishStatus({
      state: 'error',
      message: error.message || '插件启动失败',
    });
  }
}

function listen(server, port, host) {
  return new Promise((resolve, reject) => {
    const onError = (error) => {
      server.off('listening', onListening);
      reject(error);
    };
    const onListening = () => {
      server.off('error', onError);
      resolve();
    };
    server.once('error', onError);
    server.once('listening', onListening);
    server.listen(port, host);
  });
}

function cleanup() {
  if (shuttingDown) {
    return;
  }
  shuttingDown = true;
  if (bridgeServer) {
    bridgeServer.close();
    bridgeServer = null;
  }
  if (gateway) {
    gateway.cleanup();
    gateway = null;
  }
}

app.whenReady().then(() => {
  registerIpcHandlers();
  createWindow();
  void startBridge();
});

app.on('before-quit', cleanup);

app.on('activate', () => {
  mainWindow = showOrCreatePluginWindow(mainWindow, () => {
    createWindow();
    return mainWindow;
  });
});
