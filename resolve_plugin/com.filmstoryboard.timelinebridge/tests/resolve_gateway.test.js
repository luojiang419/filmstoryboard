'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');

const { ResolveGateway } = require('../resolve_gateway');

test('initializes the Promise API once and returns the current project', async () => {
  let initializeCalls = 0;
  const workflowIntegration = {
    InitializePromise: async (pluginId) => {
      initializeCalls += 1;
      assert.equal(pluginId, 'com.filmstoryboard.timelinebridge');
      return true;
    },
    GetResolvePromise: async () => ({
      GetVersionString: async () => '21.0.0.47',
      GetProjectManager: async () => ({
        GetCurrentProject: async () => ({
          GetName: async () => '广告样片',
          GetUniqueId: async () => 'project-42',
        }),
      }),
    }),
    SetAPITimeout: () => true,
    CleanUp: () => true,
  };
  const gateway = new ResolveGateway({
    workflowIntegration,
    pluginId: 'com.filmstoryboard.timelinebridge',
  });

  const [first, second] = await Promise.all([gateway.health(), gateway.health()]);

  assert.deepEqual(first, {
    resolveVersion: '21.0.0.47',
    projectName: '广告样片',
    projectId: 'project-42',
  });
  assert.deepEqual(second, first);
  assert.equal(initializeCalls, 1);
});

test('health remains successful when Resolve has no open project', async () => {
  const gateway = new ResolveGateway({
    pluginId: 'com.filmstoryboard.timelinebridge',
    workflowIntegration: {
      InitializePromise: async () => true,
      GetResolvePromise: async () => ({
        GetVersionString: async () => '21.0.0.47',
        GetProjectManager: async () => ({
          GetCurrentProject: async () => null,
        }),
      }),
    },
  });

  assert.deepEqual(await gateway.health(), {
    resolveVersion: '21.0.0.47',
    projectName: '',
    projectId: '',
  });
});
