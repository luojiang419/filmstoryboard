'use strict';

const assert = require('node:assert/strict');
const { beforeEach, test } = require('node:test');

const {
  MANAGED_AUDIO_TRACK_NAME,
  MANAGED_VIDEO_TRACK_NAME,
  TimelineSyncService,
  formatFrameRate,
  sourceFrameRange,
} = require('../timeline_sync_service');

let environment;

beforeEach(() => {
  environment = createEnvironment();
});

test('first sync creates a configured timeline and applies source I/O points', async () => {
  const snapshot = createSnapshot();

  const result = await environment.service.sync(snapshot);

  assert.deepEqual(result, {
    timelineName: '第一场',
    revision: 'revision-1',
    created: true,
    unchanged: false,
    importedClipCount: 2,
    syncedClipCount: 2,
    removedClipCount: 0,
  });
  const timeline = environment.project.timelines[0];
  assert.equal(timeline.settings.timelineResolutionWidth, '3840');
  assert.equal(timeline.settings.timelineResolutionHeight, '2160');
  assert.equal(timeline.settings.timelineFrameRate, '30');
  assert.equal(timeline.settings.useCustomSettings, '1');
  assert.equal(await timeline.GetTrackName('video', 1), MANAGED_VIDEO_TRACK_NAME);
  assert.equal(await timeline.GetTrackName('audio', 1), MANAGED_AUDIO_TRACK_NAME);
  assert.equal(timeline.videoTracks[0].length, 2);
  assert.equal(timeline.audioTracks[0].length, 1);
  assert.equal(timeline.videoTracks[0][0].start, 100);
  assert.equal(timeline.videoTracks[0][0].sourceStart, 30);
  assert.equal(timeline.videoTracks[0][0].sourceEnd, 59);
  assert.equal(timeline.videoTracks[0][1].start, 130);
  assert.equal(timeline.linkedPairs.length, 1);
  assert.equal(environment.projectManager.saveCount, 1);
  assert.equal(
    environment.bindingStore.get('project-1', 'script-1').timelineId,
    timeline.id,
  );
});

test('same revision with matching managed content is unchanged', async () => {
  const snapshot = createSnapshot();
  await environment.service.sync(snapshot);
  const timeline = environment.project.timelines[0];
  const appendCount = environment.mediaPool.appendCount;

  const result = await environment.service.sync(snapshot);

  assert.equal(result.unchanged, true);
  assert.equal(result.created, false);
  assert.equal(environment.mediaPool.appendCount, appendCount);
  assert.equal(timeline.deletedItems.length, 0);
  assert.equal(environment.projectManager.saveCount, 1);
});

test('one-frame shortened Resolve item is resynced instead of accepted', async () => {
  const snapshot = createSnapshot();
  await environment.service.sync(snapshot);
  const timeline = environment.project.timelines[0];
  timeline.videoTracks[0][0].duration -= 1;

  const result = await environment.service.sync(snapshot);

  assert.equal(result.unchanged, false);
  assert.equal(result.removedClipCount, 3);
  assert.equal(timeline.videoTracks[0][0].duration, 30);
});

test('missing timeline unique ID keeps the saved timeline and reuses its binding by name', async () => {
  environment.mediaPool.timelineFactory = (name) => {
    const timeline = new FakeTimeline(name);
    timeline.uniqueIdError = new Error('Nil ScriptVal detected for key:result');
    return timeline;
  };
  const snapshot = createSnapshot();

  const firstResult = await environment.service.sync(snapshot);
  const timeline = environment.project.timelines[0];
  const binding = environment.bindingStore.get('project-1', 'script-1');

  assert.equal(firstResult.created, true);
  assert.equal(environment.project.timelines.length, 1);
  assert.equal(environment.project.currentTimeline, timeline);
  assert.equal(binding.timelineId, '');
  assert.equal(binding.timelineName, '第一场');

  const secondResult = await environment.service.sync(snapshot);

  assert.equal(secondResult.created, false);
  assert.equal(secondResult.unchanged, true);
  assert.equal(environment.project.timelines.length, 1);
});

test('new revision replaces only managed tracks and preserves user tracks', async () => {
  await environment.service.sync(createSnapshot());
  const timeline = environment.project.timelines[0];
  await timeline.AddTrack('video');
  const userItem = new FakeTimelineItem({
    mediaPoolItem: new FakeMediaPoolItem('C:\\user\\overlay.mov'),
    startFrame: 250,
    endFrame: 279,
    recordFrame: 250,
  });
  timeline.videoTracks[1].push(userItem);

  const updated = createSnapshot({ revision: 'revision-2' });
  updated.clips[0].trimInMs = 2000;
  updated.clips[0].trimOutMs = 3000;
  const result = await environment.service.sync(updated);

  assert.equal(result.created, false);
  assert.equal(result.unchanged, false);
  assert.equal(result.removedClipCount, 3);
  assert.equal(timeline.videoTracks[0].length, 2);
  assert.equal(timeline.audioTracks[0].length, 1);
  assert.deepEqual(timeline.videoTracks[1], [userItem]);
  assert.equal(timeline.videoTracks[0][0].sourceStart, 60);
});

test('same-name timeline without a binding is never overwritten', async () => {
  environment.project.timelines.push(new FakeTimeline('第一场'));

  await assert.rejects(
    environment.service.sync(createSnapshot()),
    (error) => error.statusCode === 409 && /不属于 FilmStoryboard/.test(error.message),
  );

  assert.equal(environment.project.timelines.length, 1);
  assert.equal(environment.mediaPool.appendCount, 0);
});

test('renamed managed track stops resync before deleting any clip', async () => {
  await environment.service.sync(createSnapshot());
  const timeline = environment.project.timelines[0];
  await timeline.SetTrackName('video', 1, '用户重命名轨道');

  await assert.rejects(
    environment.service.sync(createSnapshot({ revision: 'revision-2' })),
    (error) => error.statusCode === 409 && /受管轨道/.test(error.message),
  );

  assert.equal(timeline.videoTracks[0].length, 2);
  assert.equal(timeline.audioTracks[0].length, 1);
  assert.equal(timeline.deletedItems.length, 0);
});

test('frame helpers use inclusive Resolve source end frames', () => {
  assert.equal(formatFrameRate({ framesPerSecond: 29.97002997 }), '29.97');
  assert.deepEqual(
    sourceFrameRange({ sourceFrameRate: 30, trimInMs: 1000, trimOutMs: 2000 }),
    { start: 30, end: 59 },
  );
  assert.deepEqual(
    sourceFrameRange({
      sourceFrameRate: 24,
      sourceFrameCount: 175,
      trimInMs: 0,
      trimOutMs: 7323,
    }),
    { start: 0, end: 174 },
  );
});

test('exclusive Promise API retries end boundary and removes one-frame gaps', async () => {
  environment = createEnvironment({ sourceEndMode: 'exclusive' });
  const snapshot = createRealGapSnapshot();

  const result = await environment.service.sync(snapshot);

  assert.equal(result.created, true);
  assert.equal(environment.mediaPool.appendCount, 2);
  const timeline = environment.project.timelines[0];
  assert.deepEqual(
    timeline.videoTracks[0].map((item) => ({
      start: item.start,
      duration: item.duration,
      sourceEnd: item.sourceEnd,
    })),
    [
      { start: 100, duration: 72, sourceEnd: 72 },
      { start: 172, duration: 120, sourceEnd: 120 },
      { start: 292, duration: 96, sourceEnd: 96 },
    ],
  );
  assert.equal(timeline.deletedItems.length, 6);

  const updated = createRealGapSnapshot({ revision: 'revision-real-2' });
  const updatedResult = await environment.service.sync(updated);

  assert.equal(updatedResult.unchanged, false);
  assert.equal(environment.mediaPool.appendCount, 3);
  assert.deepEqual(
    timeline.videoTracks[0].map((item) => item.duration),
    [72, 120, 96],
  );
});

function createSnapshot(overrides = {}) {
  return {
    schemaVersion: 1,
    scriptId: 'script-1',
    scriptName: '第一场',
    revision: overrides.revision || 'revision-1',
    timeline: {
      width: 3840,
      height: 2160,
      frameRate: {
        framesPerSecond: 30,
        timebase: 30,
        ntsc: false,
      },
    },
    clips: [
      {
        filePath: 'C:\\media\\shot-1.mp4',
        fileSize: 100,
        fileModifiedAtMs: 1,
        sourceFrameRate: 30,
        trimInMs: 1000,
        trimOutMs: 2000,
        recordStartFrame: 0,
        recordEndFrame: 30,
        hasAudio: true,
      },
      {
        filePath: 'C:\\media\\shot-2.mp4',
        fileSize: 200,
        fileModifiedAtMs: 2,
        sourceFrameRate: 30,
        trimInMs: 0,
        trimOutMs: 1000,
        recordStartFrame: 30,
        recordEndFrame: 60,
        hasAudio: false,
      },
    ],
  };
}

function createRealGapSnapshot(overrides = {}) {
  const sourceFrames = [73, 124, 107];
  const requestedFrames = [72, 120, 96];
  let cursor = 0;
  return {
    schemaVersion: 1,
    scriptId: 'script-real-gap',
    scriptName: '实机一帧间隔回归',
    revision: overrides.revision || 'revision-real-1',
    timeline: {
      width: 1920,
      height: 1080,
      frameRate: {
        framesPerSecond: 24,
        timebase: 24,
        ntsc: false,
      },
    },
    clips: sourceFrames.map((sourceFrameCount, index) => {
      const durationFrames = requestedFrames[index];
      const recordStartFrame = cursor;
      cursor += durationFrames;
      return {
        filePath: `C:\\media\\镜头${index + 1}.mp4`,
        fileSize: 100 + index,
        fileModifiedAtMs: index + 1,
        sourceFrameRate: 24,
        sourceFrameCount,
        trimInMs: 0,
        trimOutMs: (durationFrames * 1000) / 24,
        recordStartFrame,
        recordEndFrame: cursor,
        hasAudio: true,
      };
    }),
  };
}

function createEnvironment({ sourceEndMode = 'inclusive' } = {}) {
  const project = new FakeProject();
  const mediaPool = new FakeMediaPool(project, sourceEndMode);
  project.mediaPool = mediaPool;
  const projectManager = {
    saveCount: 0,
    GetCurrentProject: async () => project,
    SaveProject: async function () {
      this.saveCount += 1;
      return true;
    },
  };
  const bindingStore = new MemoryBindingStore();
  const service = new TimelineSyncService({
    resolve: { GetProjectManager: async () => projectManager },
    bindingStore,
    mediaFileValidator: () => {},
  });
  return { service, project, projectManager, mediaPool, bindingStore };
}

class MemoryBindingStore {
  constructor() {
    this.bindings = new Map();
  }

  get(projectId, scriptId) {
    return this.bindings.get(`${projectId}:${scriptId}`) || null;
  }

  set(binding) {
    this.bindings.set(`${binding.projectId}:${binding.scriptId}`, { ...binding });
  }
}

class FakeProject {
  constructor() {
    this.timelines = [];
    this.currentTimeline = null;
    this.mediaPool = null;
  }

  async GetUniqueId() { return 'project-1'; }
  async GetMediaPool() { return this.mediaPool; }
  async GetCurrentTimeline() { return this.currentTimeline; }
  async SetCurrentTimeline(timeline) {
    this.currentTimeline = timeline;
    return true;
  }
  async GetTimelineCount() { return this.timelines.length; }
  async GetTimelineByIndex(index) { return this.timelines[index - 1] || null; }
}

class FakeMediaPool {
  constructor(project, sourceEndMode) {
    this.project = project;
    this.sourceEndMode = sourceEndMode;
    this.root = new FakeFolder('Root');
    this.currentFolder = this.root;
    this.appendCount = 0;
    this.timelineFactory = (name) => new FakeTimeline(name);
  }

  async CreateEmptyTimeline(name) {
    const timeline = this.timelineFactory(name);
    this.project.timelines.push(timeline);
    return timeline;
  }
  async DeleteTimelines(timelines) {
    this.project.timelines = this.project.timelines.filter(
      (timeline) => !timelines.includes(timeline),
    );
    return true;
  }
  async GetRootFolder() { return this.root; }
  async GetCurrentFolder() { return this.currentFolder; }
  async SetCurrentFolder(folder) {
    this.currentFolder = folder;
    return true;
  }
  async AddSubFolder(parent, name) {
    const folder = new FakeFolder(name);
    parent.children.push(folder);
    return folder;
  }
  async ImportMedia(paths) {
    const items = paths.map((filePath) => new FakeMediaPoolItem(filePath));
    this.currentFolder.clips.push(...items);
    return items;
  }
  async AppendToTimeline(clipInfos) {
    this.appendCount += 1;
    const timeline = this.project.currentTimeline;
    return clipInfos.map((info) => {
      const item = new FakeTimelineItem(info, this.sourceEndMode);
      const tracks = info.mediaType === 1
        ? timeline.videoTracks
        : timeline.audioTracks;
      tracks[info.trackIndex - 1].push(item);
      return item;
    });
  }
}

class FakeFolder {
  constructor(name) {
    this.name = name;
    this.children = [];
    this.clips = [];
  }

  async GetName() { return this.name; }
  async GetSubFolderList() { return this.children; }
  async GetClipList() { return this.clips; }
}

class FakeMediaPoolItem {
  constructor(filePath) {
    this.filePath = filePath;
  }

  async GetClipProperty(name) {
    return name === 'File Path' ? this.filePath : '';
  }
}

let nextTimelineId = 1;

class FakeTimeline {
  constructor(name) {
    this.id = `timeline-${nextTimelineId++}`;
    this.name = name;
    this.settings = {
      useCustomSettings: '0',
      timelineResolutionWidth: '1920',
      timelineResolutionHeight: '1080',
      timelineFrameRate: '24',
    };
    this.videoTracks = [[]];
    this.audioTracks = [[]];
    this.videoTrackNames = ['Video 1'];
    this.audioTrackNames = ['Audio 1'];
    this.deletedItems = [];
    this.linkedPairs = [];
  }

  async GetUniqueId() {
    if (this.uniqueIdError) throw this.uniqueIdError;
    return this.id;
  }
  async GetName() { return this.name; }
  async SetName(name) {
    this.name = name;
    return true;
  }
  async GetSetting(key) { return this.settings[key] || ''; }
  async SetSetting(key, value) {
    if (key !== 'useCustomSettings' && this.settings.useCustomSettings !== '1') {
      throw new Error('useCustomSettings needs to be set to change timeline properties');
    }
    this.settings[key] = value;
    return true;
  }
  async GetStartFrame() { return 100; }
  async GetTrackCount(type) {
    return type === 'video' ? this.videoTracks.length : this.audioTracks.length;
  }
  async AddTrack(type) {
    if (type === 'video') {
      this.videoTracks.push([]);
      this.videoTrackNames.push(`Video ${this.videoTracks.length}`);
    } else {
      this.audioTracks.push([]);
      this.audioTrackNames.push(`Audio ${this.audioTracks.length}`);
    }
    return true;
  }
  async GetTrackName(type, index) {
    const names = type === 'video' ? this.videoTrackNames : this.audioTrackNames;
    return names[index - 1] || '';
  }
  async SetTrackName(type, index, name) {
    const names = type === 'video' ? this.videoTrackNames : this.audioTrackNames;
    names[index - 1] = name;
    return true;
  }
  async GetItemListInTrack(type, index) {
    const tracks = type === 'video' ? this.videoTracks : this.audioTracks;
    return tracks[index - 1] || [];
  }
  async DeleteClips(items) {
    this.deletedItems.push(...items);
    for (const tracks of [this.videoTracks, this.audioTracks]) {
      for (let index = 0; index < tracks.length; index += 1) {
        tracks[index] = tracks[index].filter((item) => !items.includes(item));
      }
    }
    return true;
  }
  async SetClipsLinked(items) {
    this.linkedPairs.push(items);
    return true;
  }
}

class FakeTimelineItem {
  constructor(info, sourceEndMode = 'inclusive') {
    this.mediaPoolItem = info.mediaPoolItem;
    this.start = info.recordFrame;
    this.sourceStart = info.startFrame;
    this.sourceEnd = info.endFrame;
    this.duration = info.endFrame - info.startFrame +
      (sourceEndMode === 'inclusive' ? 1 : 0);
  }

  async GetStart() { return this.start; }
  async GetDuration() { return this.duration; }
  async GetSourceStartFrame() { return this.sourceStart; }
  async GetMediaPoolItem() { return this.mediaPoolItem; }
}
