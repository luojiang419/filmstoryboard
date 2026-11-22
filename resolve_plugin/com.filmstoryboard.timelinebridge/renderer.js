'use strict';

const statusDot = document.getElementById('status-dot');
const statusLabel = document.getElementById('status-label');
const statusMessage = document.getElementById('status-message');
const projectName = document.getElementById('project-name');
const resolveVersion = document.getElementById('resolve-version');
const pluginVersion = document.getElementById('plugin-version');
const bridgeAddress = document.getElementById('bridge-address');
const lastRequest = document.getElementById('last-request');
const refreshButton = document.getElementById('refresh-button');

const statusLabels = {
  starting: '正在启动',
  ready: '已就绪',
  'waiting-project': '等待项目',
  error: '启动失败',
};

function renderStatus(status) {
  const state = status.state || 'starting';
  statusDot.className = `status-dot ${statusClass(state)}`;
  statusLabel.textContent = statusLabels[state] || '状态未知';
  statusMessage.textContent = status.message || '—';
  projectName.textContent = status.projectName || '未打开项目';
  resolveVersion.textContent = status.resolveVersion || '—';
  pluginVersion.textContent = status.pluginVersion || '—';
  bridgeAddress.textContent = status.bridgeAddress || '—';
  lastRequest.textContent = formatLastRequest(status.lastRequest);
}

function statusClass(state) {
  if (state === 'ready') return 'ready';
  if (state === 'error') return 'error';
  return 'starting';
}

function formatLastRequest(request) {
  if (!request) return '尚未收到请求';
  const localTime = new Date(request.timestamp).toLocaleTimeString('zh-CN', {
    hour12: false,
  });
  const summary = `${localTime} · ${request.method} ${request.path} · ${request.statusCode}`;
  return request.message ? `${summary} · ${request.message}` : summary;
}

refreshButton.addEventListener('click', async () => {
  refreshButton.disabled = true;
  try {
    renderStatus(await window.filmStoryboardBridge.refresh());
  } finally {
    refreshButton.disabled = false;
  }
});

window.filmStoryboardBridge.onStatusChanged(renderStatus);
window.filmStoryboardBridge.getStatus().then(renderStatus);
