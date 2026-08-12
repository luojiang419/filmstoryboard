'use strict';

const crypto = require('node:crypto');
const http = require('node:http');

const DEFAULT_MAX_BODY_BYTES = 5 * 1024 * 1024;

class BridgeHttpError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.name = 'BridgeHttpError';
    this.statusCode = statusCode;
    this.expose = true;
  }
}

function createBridgeServer({
  token,
  gateway,
  pluginVersion,
  maxBodyBytes = DEFAULT_MAX_BODY_BYTES,
  onRequest = () => {},
}) {
  if (typeof token !== 'string' || token.length < 32) {
    throw new TypeError('Bridge token must contain at least 32 characters');
  }
  if (!gateway || typeof gateway.health !== 'function') {
    throw new TypeError('A Resolve gateway is required');
  }

  return http.createServer(async (request, response) => {
    const requestUrl = new URL(request.url || '/', 'http://127.0.0.1');
    let statusCode = 500;
    let statusMessage = '请求失败';

    try {
      assertAuthorized(request, token);

      if (request.method === 'GET' && requestUrl.pathname === '/v1/health') {
        const health = await gateway.health();
        statusCode = 200;
        statusMessage = 'Bridge 已连接';
        sendJson(response, statusCode, {
          status: 'ok',
          pluginVersion,
          ...health,
        });
        return;
      }

      if (
        request.method === 'POST' &&
        requestUrl.pathname === '/v1/timelines/sync'
      ) {
        assertJsonContentType(request);
        const snapshot = await readJsonBody(request, maxBodyBytes);
        validateTimelineSnapshot(snapshot);
        const result = await gateway.syncTimeline(snapshot);
        statusCode = 200;
        statusMessage = result.unchanged
          ? '时间线已是最新状态'
          : '时间线同步完成';
        sendJson(response, statusCode, { status: 'ok', ...result });
        return;
      }

      if (
        requestUrl.pathname === '/v1/health' ||
        requestUrl.pathname === '/v1/timelines/sync'
      ) {
        throw new BridgeHttpError(405, '请求方法不受支持');
      }
      throw new BridgeHttpError(404, 'Bridge 接口不存在');
    } catch (error) {
      statusCode = Number.isInteger(error.statusCode)
        ? error.statusCode
        : 500;
      statusMessage = error.expose
        ? error.message
        : '达芬奇插件处理请求失败';
      sendJson(response, statusCode, {
        status: 'error',
        message: statusMessage,
      });
    } finally {
      onRequest({
        method: request.method || '',
        path: requestUrl.pathname,
        statusCode,
        message: statusMessage,
        timestamp: new Date().toISOString(),
      });
    }
  });
}

function assertAuthorized(request, expectedToken) {
  const provided = request.headers['x-filmstoryboard-token'];
  if (typeof provided !== 'string' || !tokensEqual(provided, expectedToken)) {
    throw new BridgeHttpError(401, 'Bridge 令牌无效');
  }
}

function tokensEqual(provided, expected) {
  const providedBuffer = Buffer.from(provided, 'utf8');
  const expectedBuffer = Buffer.from(expected, 'utf8');
  return (
    providedBuffer.length === expectedBuffer.length &&
    crypto.timingSafeEqual(providedBuffer, expectedBuffer)
  );
}

function assertJsonContentType(request) {
  const contentType = request.headers['content-type'] || '';
  if (!String(contentType).toLowerCase().startsWith('application/json')) {
    throw new BridgeHttpError(415, '请求必须使用 application/json');
  }
}

async function readJsonBody(request, maxBodyBytes) {
  const chunks = [];
  let totalBytes = 0;
  for await (const chunk of request) {
    totalBytes += chunk.length;
    if (totalBytes > maxBodyBytes) {
      throw new BridgeHttpError(413, '时间线快照超过大小限制');
    }
    chunks.push(chunk);
  }

  if (chunks.length === 0) {
    throw new BridgeHttpError(400, '缺少时间线快照');
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch (_) {
    throw new BridgeHttpError(400, '时间线快照不是有效 JSON');
  }
}

function validateTimelineSnapshot(snapshot) {
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) {
    throw new BridgeHttpError(400, '时间线快照必须是 JSON 对象');
  }
  if (snapshot.schemaVersion !== 1) {
    throw new BridgeHttpError(400, '不支持的时间线快照版本');
  }
  for (const field of ['scriptId', 'scriptName', 'revision']) {
    if (typeof snapshot[field] !== 'string' || !snapshot[field].trim()) {
      throw new BridgeHttpError(400, `时间线快照缺少 ${field}`);
    }
  }
  if (
    !snapshot.timeline ||
    typeof snapshot.timeline !== 'object' ||
    Array.isArray(snapshot.timeline)
  ) {
    throw new BridgeHttpError(400, '时间线快照缺少 timeline');
  }
  if (!Array.isArray(snapshot.clips)) {
    throw new BridgeHttpError(400, '时间线快照缺少 clips');
  }
}

function sendJson(response, statusCode, payload) {
  if (response.headersSent || response.destroyed) {
    return;
  }
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  response.writeHead(statusCode, {
    'Cache-Control': 'no-store',
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'X-Content-Type-Options': 'nosniff',
  });
  response.end(body);
}

module.exports = {
  BridgeHttpError,
  createBridgeServer,
  validateTimelineSnapshot,
};
