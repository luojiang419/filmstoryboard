'use strict';

const fs = require('node:fs');
const path = require('node:path');

const MANAGED_VIDEO_TRACK_NAME = 'FilmStoryboard Video [Managed]';
const MANAGED_AUDIO_TRACK_NAME = 'FilmStoryboard Audio [Managed]';
const ROOT_BIN_NAME = 'FilmStoryboard';
const SOURCE_END_INCLUSIVE = 'inclusive';
const SOURCE_END_EXCLUSIVE = 'exclusive';
const sourceEndModeByProject = new WeakMap();

class TimelineSyncError extends Error {
  constructor(statusCode, message) {
    super(message);
    this.name = 'TimelineSyncError';
    this.statusCode = statusCode;
    this.expose = true;
  }
}

class TimelineSyncService {
  constructor({ resolve, bindingStore, mediaFileValidator = validateMediaFiles }) {
    this.resolve = resolve;
    this.bindingStore = bindingStore;
    this.mediaFileValidator = mediaFileValidator;
  }

  async sync(snapshot) {
    validateSnapshotForResolve(snapshot);
    this.mediaFileValidator(snapshot.clips);

    const projectManager = await this.resolve.GetProjectManager();
    const project = projectManager
      ? await projectManager.GetCurrentProject()
      : null;
    if (!project) {
      throw new TimelineSyncError(409, '达芬奇当前没有打开项目');
    }

    const projectId = text(await project.GetUniqueId());
    if (!projectId) {
      throw new TimelineSyncError(500, '无法读取当前达芬奇项目 ID');
    }
    const mediaPool = await project.GetMediaPool();
    if (!mediaPool) {
      throw new TimelineSyncError(500, '无法访问当前项目媒体池');
    }

    const previousTimeline = await project.GetCurrentTimeline();
    const timelines = await listTimelines(project);
    const binding = this.bindingStore.get(projectId, snapshot.scriptId);
    let timeline = findBoundTimeline(timelines, binding);
    let created = false;
    let projectSaved = false;
    let failureStage = '写入时间线';

    if (!timeline) {
      const conflict = timelines.find(
        (entry) => entry.name === snapshot.scriptName,
      );
      if (conflict) {
        throw new TimelineSyncError(
          409,
          `已存在同名时间线“${snapshot.scriptName}”，但它不属于 FilmStoryboard，未执行覆盖`,
        );
      }
      timeline = await mediaPool.CreateEmptyTimeline(snapshot.scriptName);
      if (!timeline) {
        throw new TimelineSyncError(500, '创建达芬奇时间线失败');
      }
      created = true;
    } else {
      await ensureTimelineName(timeline, snapshot.scriptName, timelines);
    }

    try {
      if (!(await project.SetCurrentTimeline(timeline))) {
        throw new TimelineSyncError(500, '无法切换到 FilmStoryboard 时间线');
      }
      await configureTimeline(timeline, snapshot.timeline);
      const tracks = created
        ? await prepareNewManagedTracks(timeline)
        : await validateBoundTracks(timeline, binding);

      if (
        !created &&
        binding.revision === snapshot.revision &&
        (await managedContentMatches(timeline, tracks, snapshot))
      ) {
        return syncResult({
          snapshot,
          created: false,
          unchanged: true,
          importedClipCount: 0,
          syncedClipCount: snapshot.clips.length,
          removedClipCount: 0,
        });
      }

      const media = await importOrReuseMedia(mediaPool, snapshot);
      const removedClipCount = created
        ? 0
        : await clearManagedTracks(timeline, tracks);
      await appendSnapshotClips({
        project,
        mediaPool,
        timeline,
        tracks,
        snapshot,
        mediaByPath: media.mediaByPath,
      });

      failureStage = '保存达芬奇项目';
      const saved = await projectManager.SaveProject();
      if (!saved) {
        throw new TimelineSyncError(500, '时间线已写入，但达芬奇项目保存失败');
      }
      projectSaved = true;

      failureStage = '记录时间线绑定';
      const timelineId = await safeTimelineId(timeline);
      this.bindingStore.set({
        projectId,
        scriptId: snapshot.scriptId,
        timelineId,
        timelineName: snapshot.scriptName,
        revision: snapshot.revision,
        videoTrackIndex: tracks.video,
        audioTrackIndex: tracks.audio,
        updatedAt: new Date().toISOString(),
      });

      return syncResult({
        snapshot,
        created,
        unchanged: false,
        importedClipCount: media.importedClipCount,
        syncedClipCount: snapshot.clips.length,
        removedClipCount,
      });
    } catch (error) {
      if (created && !projectSaved) {
        try {
          await mediaPool.DeleteTimelines([timeline]);
          if (previousTimeline) {
            await project.SetCurrentTimeline(previousTimeline);
          }
        } catch (_) {
          // 保留原始同步错误；Resolve 清理失败可由用户在媒体池中手动删除空时间线。
        }
      }
      if (error instanceof TimelineSyncError) {
        throw error;
      }
      throw new TimelineSyncError(
        500,
        `达芬奇同步在“${failureStage}”阶段失败：${errorMessage(error)}`,
      );
    }
  }
}

function findBoundTimeline(timelines, binding) {
  if (!binding) return null;
  if (binding.timelineId) {
    const byId = timelines.find((entry) => entry.id === binding.timelineId);
    if (byId) return byId.timeline;
  }
  if (!binding.timelineName) return null;
  const byName = timelines.filter(
    (entry) => entry.name === binding.timelineName,
  );
  return byName.length === 1 ? byName[0].timeline : null;
}

async function listTimelines(project) {
  const count = Number(await project.GetTimelineCount()) || 0;
  const timelines = [];
  for (let index = 1; index <= count; index += 1) {
    const timeline = await project.GetTimelineByIndex(index);
    if (!timeline) continue;
    timelines.push({
      timeline,
      id: await safeTimelineId(timeline),
      name: text(await timeline.GetName()),
    });
  }
  return timelines;
}

async function safeTimelineId(timeline) {
  try {
    return text(await timeline.GetUniqueId());
  } catch (_) {
    return '';
  }
}

async function ensureTimelineName(timeline, expectedName, timelines) {
  const currentName = text(await timeline.GetName());
  if (currentName === expectedName) return;
  if (timelines.some((entry) => entry.timeline !== timeline && entry.name === expectedName)) {
    throw new TimelineSyncError(409, `已有其他时间线使用名称“${expectedName}”`);
  }
  if (!(await timeline.SetName(expectedName))) {
    throw new TimelineSyncError(409, `无法将受管时间线重命名为“${expectedName}”`);
  }
}

async function configureTimeline(timeline, timelineSpec) {
  const settings = [
    ['timelineResolutionWidth', String(timelineSpec.width)],
    ['timelineResolutionHeight', String(timelineSpec.height)],
    ['timelineFrameRate', formatFrameRate(timelineSpec.frameRate)],
  ];
  const pending = [];
  for (const [key, expected] of settings) {
    const current = text(await timeline.GetSetting(key));
    if (!settingValuesEqual(current, expected)) {
      pending.push([key, expected]);
    }
  }
  if (pending.length === 0) return;

  const customSettings = text(await timeline.GetSetting('useCustomSettings'));
  if (
    customSettings !== '1' &&
    !(await timeline.SetSetting('useCustomSettings', '1'))
  ) {
    throw new TimelineSyncError(409, '无法启用达芬奇时间线自定义设置');
  }
  for (const [key, expected] of pending) {
    if (!(await timeline.SetSetting(key, expected))) {
      throw new TimelineSyncError(409, `无法设置时间线参数 ${key}=${expected}`);
    }
  }
}

async function prepareNewManagedTracks(timeline) {
  const video = await ensureTrack(timeline, 'video');
  const audio = await ensureTrack(timeline, 'audio', 'stereo');
  if (!(await timeline.SetTrackName('video', video, MANAGED_VIDEO_TRACK_NAME))) {
    throw new TimelineSyncError(500, '无法命名 FilmStoryboard 视频轨道');
  }
  if (!(await timeline.SetTrackName('audio', audio, MANAGED_AUDIO_TRACK_NAME))) {
    throw new TimelineSyncError(500, '无法命名 FilmStoryboard 音频轨道');
  }
  return { video, audio };
}

async function ensureTrack(timeline, trackType, subTrackType) {
  let count = Number(await timeline.GetTrackCount(trackType)) || 0;
  if (count === 0) {
    const added = subTrackType
      ? await timeline.AddTrack(trackType, subTrackType)
      : await timeline.AddTrack(trackType);
    if (!added) {
      throw new TimelineSyncError(500, `无法创建 ${trackType} 轨道`);
    }
    count = Number(await timeline.GetTrackCount(trackType)) || 0;
  }
  if (count === 0) {
    throw new TimelineSyncError(500, `${trackType} 轨道创建后不可用`);
  }
  return 1;
}

async function validateBoundTracks(timeline, binding) {
  if (!binding) {
    throw new TimelineSyncError(409, '时间线绑定状态缺失，未执行覆盖');
  }
  const tracks = {
    video: positiveInteger(binding.videoTrackIndex),
    audio: positiveInteger(binding.audioTrackIndex),
  };
  if (!tracks.video || !tracks.audio) {
    throw new TimelineSyncError(409, '时间线绑定的受管轨道索引无效');
  }
  const videoName = text(await timeline.GetTrackName('video', tracks.video));
  const audioName = text(await timeline.GetTrackName('audio', tracks.audio));
  if (
    videoName !== MANAGED_VIDEO_TRACK_NAME ||
    audioName !== MANAGED_AUDIO_TRACK_NAME
  ) {
    throw new TimelineSyncError(
      409,
      'FilmStoryboard 受管轨道已被重命名或删除，为避免误删内容已停止同步',
    );
  }
  return tracks;
}

async function importOrReuseMedia(mediaPool, snapshot) {
  const previousFolder = await mediaPool.GetCurrentFolder();
  try {
    const root = await mediaPool.GetRootFolder();
    const managedRoot = await findOrCreateFolder(mediaPool, root, ROOT_BIN_NAME);
    const scriptFolder = await findOrCreateFolder(
      mediaPool,
      managedRoot,
      snapshot.scriptName,
    );
    if (!(await mediaPool.SetCurrentFolder(scriptFolder))) {
      throw new TimelineSyncError(500, '无法切换到 FilmStoryboard 素材文件夹');
    }

    const mediaByPath = new Map();
    const existingClips = (await scriptFolder.GetClipList()) || [];
    for (const mediaPoolItem of existingClips) {
      const filePath = text(await mediaPoolItem.GetClipProperty('File Path'));
      if (filePath) {
        mediaByPath.set(normalizeFilePath(filePath), mediaPoolItem);
      }
    }

    let importedClipCount = 0;
    for (const clip of snapshot.clips) {
      const key = normalizeFilePath(clip.filePath);
      if (mediaByPath.has(key)) continue;
      const imported = await mediaPool.ImportMedia([clip.filePath]);
      const mediaPoolItem = Array.isArray(imported) ? imported[0] : null;
      if (!mediaPoolItem) {
        throw new TimelineSyncError(422, `达芬奇无法导入素材：${clip.filePath}`);
      }
      mediaByPath.set(key, mediaPoolItem);
      importedClipCount += 1;
    }
    return { mediaByPath, importedClipCount };
  } finally {
    if (previousFolder) {
      await mediaPool.SetCurrentFolder(previousFolder);
    }
  }
}

async function findOrCreateFolder(mediaPool, parent, name) {
  const children = (await parent.GetSubFolderList()) || [];
  for (const child of children) {
    if (text(await child.GetName()) === name) {
      return child;
    }
  }
  const folder = await mediaPool.AddSubFolder(parent, name);
  if (!folder) {
    throw new TimelineSyncError(500, `无法创建媒体池文件夹“${name}”`);
  }
  return folder;
}

async function clearManagedTracks(timeline, tracks) {
  const videoItems =
    (await timeline.GetItemListInTrack('video', tracks.video)) || [];
  const audioItems =
    (await timeline.GetItemListInTrack('audio', tracks.audio)) || [];
  const items = [...videoItems, ...audioItems];
  if (items.length > 0 && !(await timeline.DeleteClips(items, false))) {
    throw new TimelineSyncError(500, '无法清理 FilmStoryboard 受管轨道');
  }
  return items.length;
}

async function appendSnapshotClips({
  project,
  mediaPool,
  timeline,
  tracks,
  snapshot,
  mediaByPath,
}) {
  if (!(await project.SetCurrentTimeline(timeline))) {
    throw new TimelineSyncError(500, '追加素材前无法激活目标时间线');
  }
  const timelineStart = Number(await timeline.GetStartFrame()) || 0;
  const clipInfoSpecs = [];
  const linkPairs = [];

  for (const clip of snapshot.clips) {
    const mediaPoolItem = mediaByPath.get(normalizeFilePath(clip.filePath));
    if (!mediaPoolItem) {
      throw new TimelineSyncError(500, `素材池映射缺失：${clip.filePath}`);
    }
    const sourceRange = sourceFrameRange(clip);
    const expectedDuration = clip.recordEndFrame - clip.recordStartFrame;
    const videoResultIndex = clipInfoSpecs.length;
    clipInfoSpecs.push({
      expectedDuration,
      sourceEndInclusive: sourceRange.end,
      clipInfo: {
        mediaPoolItem,
        startFrame: sourceRange.start,
        mediaType: 1,
        trackIndex: tracks.video,
        recordFrame: timelineStart + clip.recordStartFrame,
      },
    });
    if (clip.hasAudio) {
      const audioResultIndex = clipInfoSpecs.length;
      clipInfoSpecs.push({
        expectedDuration,
        sourceEndInclusive: sourceRange.end,
        clipInfo: {
          mediaPoolItem,
          startFrame: sourceRange.start,
          mediaType: 2,
          trackIndex: tracks.audio,
          recordFrame: timelineStart + clip.recordStartFrame,
        },
      });
      linkPairs.push([videoResultIndex, audioResultIndex]);
    }
  }

  let sourceEndMode = sourceEndModeByProject.get(project) || SOURCE_END_INCLUSIVE;
  let appended = await appendWithSourceEndMode(
    mediaPool,
    clipInfoSpecs,
    sourceEndMode,
  );
  let durationCheck = await checkAppendedDurations(appended, clipInfoSpecs);
  if (!durationCheck.matches) {
    const alternateMode = alternateSourceEndMode(
      sourceEndMode,
      durationCheck.differences,
    );
    await deleteAppendedAttempt(timeline, appended);
    if (!alternateMode) {
      throw appendedDurationError(durationCheck);
    }
    sourceEndMode = alternateMode;
    appended = await appendWithSourceEndMode(
      mediaPool,
      clipInfoSpecs,
      sourceEndMode,
    );
    durationCheck = await checkAppendedDurations(appended, clipInfoSpecs);
    if (!durationCheck.matches) {
      await deleteAppendedAttempt(timeline, appended);
      throw appendedDurationError(durationCheck);
    }
  }
  sourceEndModeByProject.set(project, sourceEndMode);

  for (const [videoIndex, audioIndex] of linkPairs) {
    if (
      !(await timeline.SetClipsLinked(
        [appended[videoIndex], appended[audioIndex]],
        true,
      ))
    ) {
      throw new TimelineSyncError(500, '视频和音频片段链接失败');
    }
  }
}

async function appendWithSourceEndMode(mediaPool, specs, sourceEndMode) {
  const endAdjustment = sourceEndMode === SOURCE_END_EXCLUSIVE ? 1 : 0;
  const clipInfos = specs.map((spec) => ({
    ...spec.clipInfo,
    endFrame: spec.sourceEndInclusive + endAdjustment,
  }));
  const appended = await mediaPool.AppendToTimeline(clipInfos);
  if (!Array.isArray(appended) || appended.length !== clipInfos.length) {
    throw new TimelineSyncError(500, '达芬奇未能完整追加所有时间线素材');
  }
  return appended;
}

async function checkAppendedDurations(appended, specs) {
  const differences = [];
  const actualDurations = [];
  for (let index = 0; index < appended.length; index += 1) {
    const actual = Number(await appended[index].GetDuration(false));
    const expected = specs[index].expectedDuration;
    actualDurations.push(actual);
    differences.push(actual - expected);
  }
  return {
    matches: differences.every((difference) => difference === 0),
    differences,
    actualDurations,
    expectedDurations: specs.map((spec) => spec.expectedDuration),
  };
}

function alternateSourceEndMode(sourceEndMode, differences) {
  if (
    sourceEndMode === SOURCE_END_INCLUSIVE &&
    differences.length > 0 &&
    differences.every((difference) => difference === -1)
  ) {
    return SOURCE_END_EXCLUSIVE;
  }
  if (
    sourceEndMode === SOURCE_END_EXCLUSIVE &&
    differences.length > 0 &&
    differences.every((difference) => difference === 1)
  ) {
    return SOURCE_END_INCLUSIVE;
  }
  return '';
}

async function deleteAppendedAttempt(timeline, appended) {
  if (appended.length > 0 && !(await timeline.DeleteClips(appended, false))) {
    throw new TimelineSyncError(500, '无法清理时长不正确的达芬奇时间线素材');
  }
}

function appendedDurationError(durationCheck) {
  const mismatchIndex = durationCheck.differences.findIndex(
    (difference) => difference !== 0,
  );
  const expected = durationCheck.expectedDurations[mismatchIndex];
  const actual = durationCheck.actualDurations[mismatchIndex];
  return new TimelineSyncError(
    500,
    `达芬奇追加素材后时长不一致：第 ${mismatchIndex + 1} 项计划 ${expected} 帧，实际 ${actual} 帧`,
  );
}

async function managedContentMatches(timeline, tracks, snapshot) {
  try {
    const videoItems =
      (await timeline.GetItemListInTrack('video', tracks.video)) || [];
    const audioItems =
      (await timeline.GetItemListInTrack('audio', tracks.audio)) || [];
    if (videoItems.length !== snapshot.clips.length) return false;
    if (audioItems.length !== snapshot.clips.filter((clip) => clip.hasAudio).length) {
      return false;
    }
    const timelineStart = Number(await timeline.GetStartFrame()) || 0;
    return (
      (await itemListMatches(videoItems, snapshot.clips, timelineStart)) &&
      (await itemListMatches(
        audioItems,
        snapshot.clips.filter((clip) => clip.hasAudio),
        timelineStart,
      ))
    );
  } catch (_) {
    return false;
  }
}

async function itemListMatches(items, clips, timelineStart) {
  const sortedItems = [];
  for (const item of items) {
    sortedItems.push({
      item,
      start: Number(await item.GetStart(false)),
    });
  }
  sortedItems.sort((left, right) => left.start - right.start);

  for (let index = 0; index < clips.length; index += 1) {
    const clip = clips[index];
    const entry = sortedItems[index];
    const duration = Number(await entry.item.GetDuration(false));
    const sourceStart = Number(await entry.item.GetSourceStartFrame());
    const mediaPoolItem = await entry.item.GetMediaPoolItem();
    const filePath = mediaPoolItem
      ? text(await mediaPoolItem.GetClipProperty('File Path'))
      : '';
    const expectedSource = sourceFrameRange(clip);
    if (
      entry.start !== timelineStart + clip.recordStartFrame ||
      duration !== clip.recordEndFrame - clip.recordStartFrame ||
      sourceStart !== expectedSource.start ||
      normalizeFilePath(filePath) !== normalizeFilePath(clip.filePath)
    ) {
      return false;
    }
  }
  return true;
}

function sourceFrameRange(clip) {
  const framesPerSecond = Number(clip.sourceFrameRate);
  const sourceFrameCount = positiveInteger(clip.sourceFrameCount);
  const requestedStart = Math.max(
    0,
    Math.round((clip.trimInMs * framesPerSecond) / 1000),
  );
  const start = sourceFrameCount
    ? Math.min(requestedStart, sourceFrameCount - 1)
    : requestedStart;
  let endExclusive = Math.max(
    start + 1,
    Math.round((clip.trimOutMs * framesPerSecond) / 1000),
  );
  if (sourceFrameCount) {
    endExclusive = Math.min(endExclusive, sourceFrameCount);
  }
  return { start, end: endExclusive - 1 };
}

function validateSnapshotForResolve(snapshot) {
  if (!snapshot || snapshot.schemaVersion !== 1) {
    throw new TimelineSyncError(400, '不支持的时间线快照版本');
  }
  if (!snapshot.timeline || !Array.isArray(snapshot.clips) || snapshot.clips.length === 0) {
    throw new TimelineSyncError(400, '时间线快照没有可同步素材');
  }
  if (
    !positiveInteger(snapshot.timeline.width) ||
    !positiveInteger(snapshot.timeline.height) ||
    !snapshot.timeline.frameRate ||
    !(Number(snapshot.timeline.frameRate.framesPerSecond) > 0)
  ) {
    throw new TimelineSyncError(400, '时间线分辨率或帧率无效');
  }
  for (const clip of snapshot.clips) {
    if (
      !clip ||
      typeof clip.filePath !== 'string' ||
      !clip.filePath.trim() ||
      !(Number(clip.sourceFrameRate) > 0) ||
      !(Number(clip.trimInMs) >= 0) ||
      !(Number(clip.trimOutMs) > Number(clip.trimInMs)) ||
      !(Number(clip.recordEndFrame) > Number(clip.recordStartFrame))
    ) {
      throw new TimelineSyncError(400, '时间线快照包含无效素材或 I/O 点');
    }
  }
}

function validateMediaFiles(clips) {
  for (const clip of clips) {
    if (!path.isAbsolute(clip.filePath)) {
      throw new TimelineSyncError(400, `素材路径不是绝对路径：${clip.filePath}`);
    }
    let stat;
    try {
      stat = fs.statSync(clip.filePath);
    } catch (_) {
      throw new TimelineSyncError(409, `素材文件不存在：${clip.filePath}`);
    }
    if (!stat.isFile()) {
      throw new TimelineSyncError(409, `素材路径不是文件：${clip.filePath}`);
    }
    if (
      Number.isFinite(Number(clip.fileSize)) &&
      Number(clip.fileSize) >= 0 &&
      stat.size !== Number(clip.fileSize)
    ) {
      throw new TimelineSyncError(409, `素材已发生变化，请重新发送：${clip.filePath}`);
    }
    if (
      Number.isFinite(Number(clip.fileModifiedAtMs)) &&
      Number(clip.fileModifiedAtMs) > 0 &&
      Math.abs(stat.mtimeMs - Number(clip.fileModifiedAtMs)) > 1000
    ) {
      throw new TimelineSyncError(409, `素材已发生变化，请重新发送：${clip.filePath}`);
    }
  }
}

function formatFrameRate(frameRate) {
  const value = Number(frameRate.framesPerSecond);
  return value.toFixed(3).replace(/\.?0+$/, '');
}

function settingValuesEqual(current, expected) {
  const currentNumber = Number(current);
  const expectedNumber = Number(expected);
  if (Number.isFinite(currentNumber) && Number.isFinite(expectedNumber)) {
    return Math.abs(currentNumber - expectedNumber) < 0.001;
  }
  return current === expected;
}

function normalizeFilePath(filePath) {
  if (!filePath) return '';
  const normalized = path.normalize(filePath);
  return process.platform === 'win32' ? normalized.toLowerCase() : normalized;
}

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 0;
}

function text(value) {
  return value == null ? '' : String(value).trim();
}

function errorMessage(error) {
  const message = error && typeof error.message === 'string'
    ? error.message.trim()
    : '';
  return message || '未知错误';
}

function syncResult({
  snapshot,
  created,
  unchanged,
  importedClipCount,
  syncedClipCount,
  removedClipCount,
}) {
  return {
    timelineName: snapshot.scriptName,
    revision: snapshot.revision,
    created,
    unchanged,
    importedClipCount,
    syncedClipCount,
    removedClipCount,
  };
}

module.exports = {
  MANAGED_AUDIO_TRACK_NAME,
  MANAGED_VIDEO_TRACK_NAME,
  TimelineSyncError,
  TimelineSyncService,
  formatFrameRate,
  sourceFrameRange,
  validateMediaFiles,
  validateSnapshotForResolve,
};
