'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const { afterEach, test } = require('node:test');

const { createBridgeServer } = require('../bridge_server');

const TOKEN = 'a'.repeat(64);
const servers = [];

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise((resolve) => {
          server.close(resolve);
        }),
    ),
  );
});

test('health rejects a request without the shared token', async () => {
  let healthCalls = 0;
  const server = await startServer({
    health: async () => {
      healthCalls += 1;
      return {};
    },
    syncTimeline: async () => ({}),
  });

  const response = await request(server, { path: '/v1/health' });

  assert.equal(response.statusCode, 401);
  assert.equal(response.body.status, 'error');
  assert.equal(healthCalls, 0);
});

test('health returns Resolve and project status', async () => {
  const server = await startServer({
    health: async () => ({
      resolveVersion: '21.0.0.47',
      projectName: '样片项目',
      projectId: 'project-1',
    }),
    syncTimeline: async () => ({}),
  });

  const response = await request(server, {
    path: '/v1/health',
    token: TOKEN,
  });

  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.body, {
    status: 'ok',
    pluginVersion: '0.1.0',
    resolveVersion: '21.0.0.47',
    projectName: '样片项目',
    projectId: 'project-1',
  });
});

test('sync validates and forwards the timeline snapshot', async () => {
  let receivedSnapshot = null;
  const server = await startServer({
    health: async () => ({}),
    syncTimeline: async (snapshot) => {
      receivedSnapshot = snapshot;
      return {
        timelineName: snapshot.scriptName,
        revision: snapshot.revision,
        created: true,
        unchanged: false,
        importedClipCount: 1,
        syncedClipCount: 1,
        removedClipCount: 0,
      };
    },
  });
  const snapshot = {
    schemaVersion: 1,
    scriptId: 'script-1',
    scriptName: '第一场',
    revision: 'revision-1',
    timeline: { width: 1920, height: 1080 },
    clips: [],
  };

  const response = await request(server, {
    method: 'POST',
    path: '/v1/timelines/sync',
    token: TOKEN,
    body: snapshot,
  });

  assert.equal(response.statusCode, 200);
  assert.equal(response.body.status, 'ok');
  assert.equal(response.body.timelineName, '第一场');
  assert.deepEqual(receivedSnapshot, snapshot);
});

test('sync rejects an unsupported snapshot schema before calling Resolve', async () => {
  let syncCalls = 0;
  const server = await startServer({
    health: async () => ({}),
    syncTimeline: async () => {
      syncCalls += 1;
      return {};
    },
  });

  const response = await request(server, {
    method: 'POST',
    path: '/v1/timelines/sync',
    token: TOKEN,
    body: {
      schemaVersion: 2,
      scriptId: 'script-1',
      scriptName: '第一场',
      revision: 'revision-1',
      timeline: {},
      clips: [],
    },
  });

  assert.equal(response.statusCode, 400);
  assert.equal(syncCalls, 0);
});

async function startServer(gateway) {
  const server = createBridgeServer({
    token: TOKEN,
    gateway,
    pluginVersion: '0.1.0',
  });
  servers.push(server);
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  return server;
}

function request(server, options) {
  const address = server.address();
  const body = options.body == null
    ? null
    : Buffer.from(JSON.stringify(options.body), 'utf8');
  const headers = {};
  if (options.token) {
    headers['X-FilmStoryboard-Token'] = options.token;
  }
  if (body) {
    headers['Content-Type'] = 'application/json; charset=utf-8';
    headers['Content-Length'] = body.length;
  }

  return new Promise((resolve, reject) => {
    const outgoing = http.request(
      {
        host: '127.0.0.1',
        port: address.port,
        method: options.method || 'GET',
        path: options.path,
        headers,
      },
      (incoming) => {
        const chunks = [];
        incoming.on('data', (chunk) => chunks.push(chunk));
        incoming.on('end', () => {
          resolve({
            statusCode: incoming.statusCode,
            body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
          });
        });
      },
    );
    outgoing.on('error', reject);
    if (body) outgoing.write(body);
    outgoing.end();
  });
}
