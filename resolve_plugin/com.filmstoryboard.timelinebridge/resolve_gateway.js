'use strict';

const { TimelineBindingStore } = require('./timeline_binding_store');
const {
  TimelineSyncService,
  validateMediaFiles,
} = require('./timeline_sync_service');

class ResolveGateway {
  constructor({
    workflowIntegration,
    pluginId,
    bindingStore = new TimelineBindingStore(),
    mediaFileValidator = validateMediaFiles,
  }) {
    if (!workflowIntegration) {
      throw new TypeError('workflowIntegration is required');
    }
    if (!pluginId) {
      throw new TypeError('pluginId is required');
    }

    this.workflowIntegration = workflowIntegration;
    this.pluginId = pluginId;
    this.bindingStore = bindingStore;
    this.mediaFileValidator = mediaFileValidator;
    this.initializationPromise = null;
    this.resolve = null;
    this.syncQueue = Promise.resolve();
  }

  async initialize() {
    if (this.resolve) {
      return this.resolve;
    }
    if (!this.initializationPromise) {
      this.initializationPromise = this.#initializeOnce();
    }

    try {
      return await this.initializationPromise;
    } catch (error) {
      this.initializationPromise = null;
      throw error;
    }
  }

  async #initializeOnce() {
    const initialized = await this.workflowIntegration.InitializePromise(
      this.pluginId,
    );
    if (!initialized) {
      throw new Error('Resolve Workflow Integration 初始化失败');
    }

    if (typeof this.workflowIntegration.SetAPITimeout === 'function') {
      this.workflowIntegration.SetAPITimeout(10);
    }

    const resolve = await this.workflowIntegration.GetResolvePromise();
    if (!resolve) {
      throw new Error('无法取得 Resolve Promise API');
    }
    this.resolve = resolve;
    return resolve;
  }

  async health() {
    const resolve = await this.initialize();
    const resolveVersion = text(await resolve.GetVersionString());
    const projectManager = await resolve.GetProjectManager();
    const project = projectManager
      ? await projectManager.GetCurrentProject()
      : null;

    if (!project) {
      return {
        resolveVersion,
        projectName: '',
        projectId: '',
      };
    }

    return {
      resolveVersion,
      projectName: text(await project.GetName()),
      projectId: text(await project.GetUniqueId()),
    };
  }

  syncTimeline(snapshot) {
    const task = this.syncQueue.then(async () => {
      const resolve = await this.initialize();
      const service = new TimelineSyncService({
        resolve,
        bindingStore: this.bindingStore,
        mediaFileValidator: this.mediaFileValidator,
      });
      return service.sync(snapshot);
    });
    this.syncQueue = task.catch(() => {});
    return task;
  }

  cleanup() {
    this.resolve = null;
    this.initializationPromise = null;
    if (typeof this.workflowIntegration.CleanUp === 'function') {
      return this.workflowIntegration.CleanUp();
    }
    return true;
  }
}

function text(value) {
  return value == null ? '' : String(value).trim();
}

module.exports = {
  ResolveGateway,
};
