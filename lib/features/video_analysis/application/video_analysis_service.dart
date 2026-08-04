import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../../core/services/vision_request_rate_limiter.dart';
import '../../settings/domain/app_settings.dart';
import '../../storyboard/data/vision_storyboard_service.dart';
import '../data/video_analysis_repository.dart';
import '../domain/video_analysis_models.dart';

class VideoAnalysisRunResult {
  const VideoAnalysisRunResult({
    required this.completedCount,
    required this.failedCount,
    required this.summary,
    this.interrupted = false,
  });

  final int completedCount;
  final int failedCount;
  final VideoSummary? summary;
  final bool interrupted;
}

class VideoFrameAnalysisFieldMapper {
  const VideoFrameAnalysisFieldMapper._();

  static Map<String, String> fromVision(VisionImageAnalysis analysis) => {
    'caption': analysis.caption,
    'detail': analysis.detail,
    'scene': analysis.scene,
    'props': analysis.props,
    'people': analysis.people,
    'expression': analysis.expression,
    'bodyAction': analysis.bodyAction,
    'movementTrend': analysis.movementTrend,
    'cameraMovement': analysis.cameraMovement,
    'shotSize': analysis.shotSize,
    'composition': analysis.composition,
    'subjectDirection': analysis.subjectDirection,
    'gazeDirection': analysis.gazeDirection,
    'actionStage': analysis.actionStage,
    'spatialRelation': analysis.spatialRelation,
    'chronologyCue': analysis.chronologyCue,
    'cameraAngle': analysis.cameraAngle,
    'visualFocus': analysis.visualFocus,
    'lightingMood': analysis.lightingMood,
    'colorPalette': analysis.colorPalette,
    'narrativeFunction': analysis.narrativeFunction,
    'transitionHint': analysis.transitionHint,
    'continuesFromPrevious': analysis.continuesFromPrevious.toString(),
    'continuesToNext': analysis.continuesToNext.toString(),
  };
}

class VideoAnalysisService {
  VideoAnalysisService({
    required this.repository,
    VisionStoryboardService? visionService,
    Uuid uuid = const Uuid(),
  }) : visionService = visionService ?? VisionStoryboardService(),
       _uuid = uuid;

  final VideoAnalysisRepository repository;
  final VisionStoryboardService visionService;
  final Uuid _uuid;

  /// 仅 MiniMax-M3 使用其允许的高并发额度；其他服务保持串行，避免限流。
  static int maxConcurrentFrameRequestsFor(AppSettings settings) {
    return VisionRequestRateLimiter.maxConcurrentRequestsFor(settings);
  }

  Future<VideoAnalysisRunResult> analyzeFrames({
    required AppSettings settings,
    required SourceVideo video,
    required List<VideoFrame> frames,
    File Function(VideoFrame frame)? resolveFrame,
    void Function(int completed, int total)? onProgress,
    void Function(VideoFrameAnalysis analysis)? onFrameCompleted,
    bool Function()? shouldContinue,
  }) async {
    var completed = 0;
    var failed = 0;
    var processed = 0;
    var nextIndex = 0;
    var interrupted = false;

    Future<void> processFrames() async {
      while (nextIndex < frames.length) {
        if (shouldContinue?.call() == false) {
          interrupted = true;
          return;
        }
        final index = nextIndex++;
        final frame = frames[index];
        final now = DateTime.now().toUtc();
        try {
          final analysis = await visionService.analyzeImage(
            settings: settings,
            imageFile: resolveFrame?.call(frame) ?? File(frame.path),
            sequenceNo: index + 1,
            rowIndex: 0,
            columnIndex: index,
            allowThinking: settings.videoAnalysisThinkingEnabled,
            previousImageFile: index == 0
                ? null
                : resolveFrame?.call(frames[index - 1]) ??
                      File(frames[index - 1].path),
            nextImageFile: index + 1 >= frames.length
                ? null
                : resolveFrame?.call(frames[index + 1]) ??
                      File(frames[index + 1].path),
          );
          final record = VideoFrameAnalysis(
            id: '${video.id}-${frame.id}',
            videoId: video.id,
            frameId: frame.id,
            sequenceNo: frame.index + 1,
            dimensions: VideoFrameAnalysisFieldMapper.fromVision(analysis),
            rawResponse: analysis.rawResponse,
            status: ProcessingStatus.completed,
            errorMessage: '',
            createdAt: now,
            updatedAt: DateTime.now().toUtc(),
          );
          repository
            ..upsertVideoFrameAnalysis(record)
            ..upsertVideoFrame(
              frame.copyWith(
                status: ProcessingStatus.completed,
                errorMessage: '',
              ),
            );
          onFrameCompleted?.call(record);
          completed++;
        } catch (error) {
          if (shouldContinue?.call() == false) {
            interrupted = true;
            return;
          }
          failed++;
          final record = VideoFrameAnalysis(
            id: '${video.id}-${frame.id}',
            videoId: video.id,
            frameId: frame.id,
            sequenceNo: frame.index + 1,
            dimensions: const {},
            rawResponse: '',
            errorMessage: '$error',
            status: ProcessingStatus.failed,
            createdAt: now,
            updatedAt: DateTime.now().toUtc(),
          );
          repository
            ..upsertVideoFrameAnalysis(record)
            ..upsertVideoFrame(
              frame.copyWith(
                status: ProcessingStatus.failed,
                errorMessage: '$error',
              ),
            );
          onFrameCompleted?.call(record);
        }
        processed++;
        onProgress?.call(processed, frames.length);
      }
    }

    final workerCount = maxConcurrentFrameRequestsFor(
      settings,
    ).clamp(1, frames.isEmpty ? 1 : frames.length);
    await Future.wait([
      for (var worker = 0; worker < workerCount; worker++) processFrames(),
    ]);

    if (interrupted || shouldContinue?.call() == false) {
      return VideoAnalysisRunResult(
        completedCount: completed,
        failedCount: failed,
        summary: repository.getVideoSummary(video.id),
        interrupted: true,
      );
    }

    final storedAnalyses = repository
        .listVideoFrameAnalyses(video.id)
        .where((item) => item.status == ProcessingStatus.completed)
        .toList();
    final totalFailed = repository
        .listVideoFrameAnalyses(video.id)
        .where((item) => item.status == ProcessingStatus.failed)
        .length;
    final allFrames = repository.listVideoFrames(video.id);
    final refinedAnalyses = await _refineShotCameraMotion(
      settings: settings,
      video: video,
      frames: allFrames,
      analyses: storedAnalyses,
      resolveFrame: resolveFrame,
      onFrameCompleted: onFrameCompleted,
      shouldContinue: shouldContinue,
    );
    final analyses = refinedAnalyses.map(_visionFromStored).toList();
    final summary = await _saveSummary(video, settings, analyses, totalFailed);
    _saveShots(video, allFrames, refinedAnalyses);
    await _saveMarketingAnalysis(
      video,
      settings,
      allFrames,
      refinedAnalyses,
      summary,
      analyses,
    );
    repository.upsertSourceVideo(
      video.copyWith(
        successfulFrames: refinedAnalyses.length,
        failedFrames: totalFailed,
        status: totalFailed == 0
            ? ProcessingStatus.completed
            : ProcessingStatus.partial,
        errorMessage: totalFailed == 0 ? '' : '$totalFailed 个帧解析失败',
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    return VideoAnalysisRunResult(
      completedCount: completed,
      failedCount: failed,
      summary: summary,
    );
  }

  Future<List<VideoFrameAnalysis>> _refineShotCameraMotion({
    required AppSettings settings,
    required SourceVideo video,
    required List<VideoFrame> frames,
    required List<VideoFrameAnalysis> analyses,
    required File Function(VideoFrame frame)? resolveFrame,
    required void Function(VideoFrameAnalysis analysis)? onFrameCompleted,
    required bool Function()? shouldContinue,
  }) async {
    if (analyses.length < 2) {
      return analyses;
    }
    final groups = _buildShotFrameGroups(frames, analyses);
    if (groups.every((group) => group.frames.length < 2)) {
      return analyses;
    }
    final refinedByFrameId = {for (final item in analyses) item.frameId: item};
    for (var index = 0; index < groups.length; index++) {
      if (shouldContinue?.call() == false) {
        return refinedByFrameId.values.toList()..sort(
          (first, second) => first.sequenceNo.compareTo(second.sequenceNo),
        );
      }
      final group = groups[index];
      if (group.frames.length < 2) {
        continue;
      }
      final files = <File>[];
      for (final frame in group.frames) {
        final file = resolveFrame?.call(frame) ?? File(frame.path);
        if (file.existsSync()) {
          files.add(file);
        }
      }
      if (files.length < 2) {
        continue;
      }
      try {
        final motion = await visionService.analyzeShotMotion(
          settings: settings,
          imageFiles: files,
          analyses: group.analyses.map(_visionFromStored).toList(),
          shotNumber: index + 1,
          allowThinking: settings.videoAnalysisThinkingEnabled,
        );
        if (!motion.isSameShot) {
          continue;
        }
        for (final analysis in group.analyses) {
          final dimensions = Map<String, String>.from(analysis.dimensions);
          if (motion.cameraMovement.trim().isNotEmpty) {
            dimensions['cameraMovement'] = motion.cameraMovement.trim();
          }
          if (motion.cameraAngle.trim().isNotEmpty) {
            dimensions['cameraAngle'] = motion.cameraAngle.trim();
          }
          if (motion.evidence.trim().isNotEmpty) {
            dimensions['cameraMovementEvidence'] = motion.evidence.trim();
          }
          dimensions['shotGroupFrameIds'] = group.frames
              .map((frame) => frame.id)
              .join(',');
          final refined = VideoFrameAnalysis(
            id: analysis.id,
            videoId: analysis.videoId,
            frameId: analysis.frameId,
            sequenceNo: analysis.sequenceNo,
            dimensions: Map.unmodifiable(dimensions),
            rawResponse: [
              analysis.rawResponse,
              '[组级运镜复核]\n${motion.rawResponse}',
            ].where((item) => item.trim().isNotEmpty).join('\n\n'),
            status: analysis.status,
            errorMessage: analysis.errorMessage,
            createdAt: analysis.createdAt,
            updatedAt: DateTime.now().toUtc(),
          );
          refinedByFrameId[analysis.frameId] = refined;
          repository.upsertVideoFrameAnalysis(refined);
          onFrameCompleted?.call(refined);
        }
      } catch (_) {
        continue;
      }
    }
    return refinedByFrameId.values.toList()
      ..sort((first, second) => first.sequenceNo.compareTo(second.sequenceNo));
  }

  VisionImageAnalysis _visionFromStored(VideoFrameAnalysis analysis) {
    String value(String key) => analysis.dimensions[key] ?? '';
    return VisionImageAnalysis(
      caption: value('caption'),
      detail: value('detail'),
      scene: value('scene'),
      props: value('props'),
      people: value('people'),
      expression: value('expression'),
      bodyAction: value('bodyAction'),
      movementTrend: value('movementTrend'),
      cameraMovement: value('cameraMovement'),
      shotSize: value('shotSize'),
      composition: value('composition'),
      subjectDirection: value('subjectDirection'),
      gazeDirection: value('gazeDirection'),
      actionStage: value('actionStage'),
      spatialRelation: value('spatialRelation'),
      chronologyCue: value('chronologyCue'),
      cameraAngle: value('cameraAngle'),
      visualFocus: value('visualFocus'),
      lightingMood: value('lightingMood'),
      colorPalette: value('colorPalette'),
      narrativeFunction: value('narrativeFunction'),
      transitionHint: value('transitionHint'),
      continuesFromPrevious: value('continuesFromPrevious') == 'true',
      continuesToNext: value('continuesToNext') == 'true',
      rawResponse: analysis.rawResponse,
    );
  }

  void _saveShots(
    SourceVideo video,
    List<VideoFrame> frames,
    List<VideoFrameAnalysis> analyses,
  ) {
    final analysisByFrame = {for (final item in analyses) item.frameId: item};
    final groups = _buildShotFrameGroups(frames, analyses);
    var shotGroups = groups
        .where((group) => group.frames.any((frame) => frame.isFocus))
        .toList();
    if (shotGroups.isEmpty) {
      shotGroups = groups;
    }
    repository.deleteVideoShots(video.id);
    final now = DateTime.now().toUtc();
    for (var index = 0; index < shotGroups.length; index++) {
      final group = shotGroups[index];
      final frame = group.frames.firstWhere(
        (item) => item.isFocus,
        orElse: () => group.frames.first,
      );
      final analysis = analysisByFrame[frame.id]!;
      repository.upsertVideoShot(
        VideoShot(
          id: '${video.id}-shot-${index + 1}',
          videoId: video.id,
          shotNumber: index + 1,
          startMs: group.frames.first.timestampMs,
          endMs: index + 1 < shotGroups.length
              ? shotGroups[index + 1].frames.first.timestampMs
              : video.durationMs,
          primaryFrameId: frame.id,
          frameIds: group.frames.map((item) => item.id).toList(),
          description: analysis.dimensions['caption'] ?? '',
          storyFlow:
              analysis.dimensions['narrativeFunction'] ??
              analysis.dimensions['detail'] ??
              '',
          status: ProcessingStatus.completed,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
  }

  List<_ShotFrameGroup> _buildShotFrameGroups(
    List<VideoFrame> frames,
    List<VideoFrameAnalysis> analyses,
  ) {
    final analysisByFrame = {for (final item in analyses) item.frameId: item};
    final orderedFrames =
        frames.where((frame) => analysisByFrame.containsKey(frame.id)).toList()
          ..sort((first, second) {
            final byIndex = first.index.compareTo(second.index);
            return byIndex != 0
                ? byIndex
                : first.timestampMs.compareTo(second.timestampMs);
          });
    final groups = <_ShotFrameGroup>[];
    var currentFrames = <VideoFrame>[];
    var currentAnalyses = <VideoFrameAnalysis>[];
    for (final frame in orderedFrames) {
      final analysis = analysisByFrame[frame.id]!;
      if (currentFrames.isNotEmpty &&
          !_isSameShotCandidate(
            currentFrames.last,
            frame,
            currentAnalyses.last,
            analysis,
          )) {
        groups.add(
          _ShotFrameGroup(
            frames: List.unmodifiable(currentFrames),
            analyses: List.unmodifiable(currentAnalyses),
          ),
        );
        currentFrames = <VideoFrame>[];
        currentAnalyses = <VideoFrameAnalysis>[];
      }
      currentFrames.add(frame);
      currentAnalyses.add(analysis);
    }
    if (currentFrames.isNotEmpty) {
      groups.add(
        _ShotFrameGroup(
          frames: List.unmodifiable(currentFrames),
          analyses: List.unmodifiable(currentAnalyses),
        ),
      );
    }
    return groups;
  }

  bool _isSameShotCandidate(
    VideoFrame previousFrame,
    VideoFrame frame,
    VideoFrameAnalysis previousAnalysis,
    VideoFrameAnalysis analysis,
  ) {
    final previous = previousAnalysis.dimensions;
    final current = analysis.dimensions;
    if (current['continuesFromPrevious'] == 'true' ||
        previous['continuesToNext'] == 'true') {
      return true;
    }
    if (_hasShotBoundaryCue(previous, current)) {
      return false;
    }
    final hashDistance = _hashDistance(
      previousFrame.perceptualHash,
      frame.perceptualHash,
    );
    if (hashDistance != null && hashDistance <= 10) {
      return true;
    }
    if (frame.motionScore <= 0.35 &&
        _sameMeaningfulField(previous, current, 'scene')) {
      return true;
    }
    return _sameMeaningfulField(previous, current, 'scene') &&
        (_sameMeaningfulField(previous, current, 'props') ||
            _sameMeaningfulField(previous, current, 'spatialRelation') ||
            _sameMeaningfulField(previous, current, 'composition'));
  }

  bool _hasShotBoundaryCue(
    Map<String, String> previous,
    Map<String, String> current,
  ) {
    if (current['continuesFromPrevious'] == 'false' &&
        previous['continuesToNext'] == 'false' &&
        !_sameMeaningfulField(previous, current, 'scene')) {
      return true;
    }
    final text = [
      current['transitionHint'],
      current['chronologyCue'],
      current['narrativeFunction'],
    ].whereType<String>().join(' ');
    return text.contains('切入') ||
        text.contains('转场') ||
        text.contains('新场景') ||
        text.contains('切换');
  }

  bool _sameMeaningfulField(
    Map<String, String> previous,
    Map<String, String> current,
    String key,
  ) {
    final first = _normalizeComparableText(previous[key] ?? '');
    final second = _normalizeComparableText(current[key] ?? '');
    return first.length >= 2 && first == second;
  }

  String _normalizeComparableText(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'[，,。；;：:、]'), '')
        .trim();
  }

  int? _hashDistance(String first, String second) {
    final a = first.trim();
    final b = second.trim();
    if (a.isEmpty || b.isEmpty || a.length != b.length) {
      return null;
    }
    var distance = 0;
    for (var index = 0; index < a.length; index++) {
      final left = int.tryParse(a[index], radix: 16);
      final right = int.tryParse(b[index], radix: 16);
      if (left == null || right == null) {
        return null;
      }
      var xor = left ^ right;
      while (xor > 0) {
        distance += xor & 1;
        xor >>= 1;
      }
    }
    return distance;
  }

  Future<void> _saveMarketingAnalysis(
    SourceVideo video,
    AppSettings settings,
    List<VideoFrame> frames,
    List<VideoFrameAnalysis> storedAnalyses,
    VideoSummary summary,
    List<VisionImageAnalysis> visionAnalyses,
  ) async {
    String joinField(String key, {int limit = 6}) {
      final values = storedAnalyses
          .map((item) => item.dimensions[key]?.trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toSet()
          .take(limit)
          .toList();
      return values.join('；');
    }

    final openingFrameIds = frames
        .where((frame) => frame.timestampMs <= 3000)
        .map((frame) => frame.id)
        .toSet();
    final opening = storedAnalyses
        .where((item) => openingFrameIds.contains(item.frameId))
        .map((item) => item.dimensions['caption']?.trim() ?? '')
        .where((value) => value.isNotEmpty)
        .join('；');
    String firstField(String key) => storedAnalyses
        .map((item) => item.dimensions[key]?.trim() ?? '')
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    String lastField(String key) => storedAnalyses
        .map((item) => item.dimensions[key]?.trim() ?? '')
        .toList()
        .reversed
        .firstWhere((value) => value.isNotEmpty, orElse: () => '');
    final firstCaption = firstField('caption');
    final lastCaption = lastField('caption');
    final firstFocus = firstField('visualFocus');
    final lastFocus = lastField('visualFocus');
    final narrative = joinField('narrativeFunction');
    final movement = joinField('movementTrend');
    final transition = joinField('transitionHint');
    final people = joinField('people');
    final expressions = joinField('expression');
    final props = joinField('props');
    final scenes = joinField('scene');
    const pending = '画面信息不足，需人工确认';
    String withEvidence(String value, String businessImpact) =>
        value.isEmpty ? pending : '证据：$value\n商业作用：$businessImpact';
    final dimensions = <String, String>{
      '开场类型': storedAnalyses.isEmpty
          ? pending
          : (storedAnalyses.first.dimensions['narrativeFunction'] ?? '画面建立'),
      '黄金3秒内容': opening.isEmpty ? pending : opening,
      '留存钩子': firstFocus.isEmpty ? pending : '$firstFocus；后续动作/信息变化：$movement',
      '首帧冲击点': withEvidence(
        [firstCaption, firstFocus].where((item) => item.isNotEmpty).join('；'),
        '用于判断首屏是否能在静音浏览中传达核心信息',
      ),
      '中途留存机制': withEvidence(
        [movement, transition].where((item) => item.isNotEmpty).join('；'),
        '用于判断中段是否持续提供动作、信息或节奏变化',
      ),
      '视觉刺激手段': withEvidence(
        [
          movement,
          joinField('colorPalette'),
          joinField('lightingMood'),
        ].where((item) => item.isNotEmpty).join('；'),
        '用于判断动态、色彩和光线是否形成感官刺激',
      ),
      '视频结构': summary.fields['outline'] ?? pending,
      '镜头节奏': frames.length < 2
          ? pending
          : '共 ${frames.length} 个候选帧，平均间隔约 '
                '${(video.durationMs / (frames.length - 1) / 1000).toStringAsFixed(1)} 秒',
      '信息密度': '成功解析 ${storedAnalyses.length} 个焦点帧',
      '冲突/问题': pending,
      '叙事推进': narrative.isEmpty ? pending : narrative,
      '结果兑现': withEvidence(
        [lastCaption, lastFocus].where((item) => item.isNotEmpty).join('；'),
        '用于判断结尾是否落到可见结果或利益证明',
      ),
      '结尾记忆点': lastCaption.isEmpty ? pending : lastCaption,
      '品牌露出': pending,
      '出现时间': joinField('props').isEmpty ? pending : '见镜头道具与产品字段',
      '产品展示方式': props.isEmpty ? pending : props,
      '卖点表达': pending,
      '卖点证据': pending,
      '差异化记忆点': pending,
      '使用场景': scenes.isEmpty ? pending : scenes,
      '包装/Logo/品牌资产': pending,
      '场景': scenes.isEmpty ? pending : scenes,
      '画面风格': joinField('lightingMood').isEmpty
          ? pending
          : joinField('lightingMood'),
      '构图与主体': joinField('composition').isEmpty
          ? pending
          : joinField('composition'),
      '景别与机位': [
        joinField('shotSize'),
        joinField('cameraAngle'),
      ].where((item) => item.isNotEmpty).join('；'),
      '运镜与转场': [
        joinField('cameraMovement'),
        transition,
      ].where((item) => item.isNotEmpty).join('；'),
      '色彩': joinField('colorPalette').isEmpty
          ? pending
          : joinField('colorPalette'),
      '光线质感': joinField('lightingMood').isEmpty
          ? pending
          : joinField('lightingMood'),
      '字幕/屏显信息': pending,
      '声音与音乐': pending,
      '竖屏安全区': pending,
      '目标受众': pending,
      '用户痛点': pending,
      '情绪触发': [
        expressions,
        firstFocus,
      ].where((item) => item.isNotEmpty).join('；'),
      '购买理由': pending,
      '信任证据': pending,
      '异议/风险消除': pending,
      '人物/创作者角色': people.isEmpty ? pending : people,
      'CTA': pending,
      '福利': pending,
      '价格/优惠': pending,
      '紧迫感': pending,
      '评论引导': pending,
      '互动机制': pending,
      '转化路径': pending,
      '可分享话题': pending,
      '可模仿/UGC机制': pending,
      '社交货币': firstFocus.isEmpty ? pending : firstFocus,
      '品牌记忆资产': pending,
      '多版本测试建议': '建议至少测试开场钩子、首帧主体、产品露出时间和 CTA 文案四组变量',
      '平台适配建议': '需结合实际画幅、字幕、音频和投放平台安全区复核',
      '宣称/证明风险': pending,
      '信息缺口': '当前帧级解析未覆盖音频、完整字幕、落地页、价格、品牌名称和可验证的 CTA，需人工或模型结合原视频复核',
    };
    var rawResponse = summary.rawResponse;
    var marketingStatus = summary.status;
    var marketingError = summary.errorMessage;
    try {
      final modelResult = await visionService.analyzeVideoDimensions(
        settings: settings,
        analyses: visionAnalyses,
        summary: summary.fields,
        allowThinking: settings.videoAnalysisThinkingEnabled,
      );
      for (final entry in modelResult.dimensions.entries) {
        if (entry.value.trim().isNotEmpty) {
          dimensions[entry.key] = entry.value.trim();
        }
      }
      rawResponse = modelResult.rawResponse;
    } catch (error) {
      marketingStatus = ProcessingStatus.partial;
      marketingError = '多维度分析使用本地可追溯结果：$error';
    }
    final now = DateTime.now().toUtc();
    repository.upsertMarketingAnalysis(
      MarketingAnalysis(
        id: '${video.id}-video-dimensions',
        videoId: video.id,
        scope: 'video',
        dimensions: dimensions,
        rawResponse: rawResponse,
        status: marketingStatus,
        errorMessage: marketingError,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<VideoSummary> _saveSummary(
    SourceVideo video,
    AppSettings settings,
    List<VisionImageAnalysis> analyses,
    int failedCount,
  ) async {
    final now = DateTime.now().toUtc();
    if (analyses.isEmpty) {
      final summary = VideoSummary(
        id: _uuid.v4(),
        videoId: video.id,
        fields: const {'outline': '', 'content': ''},
        rawResponse: '',
        status: ProcessingStatus.failed,
        errorMessage: '没有成功的帧解析结果',
        updatedAt: now,
      );
      repository.upsertVideoSummary(summary);
      return summary;
    }
    try {
      final result = await visionService.summarizeStoryboard(
        settings: settings,
        analyses: analyses,
        allowThinking: settings.videoAnalysisThinkingEnabled,
      );
      final summary = VideoSummary(
        id: _uuid.v4(),
        videoId: video.id,
        fields: {
          'outline': result.outline,
          'content': result.content,
          'scenes': result.scenes,
          'props': result.props,
        },
        rawResponse: result.rawResponse,
        status: failedCount == 0
            ? ProcessingStatus.completed
            : ProcessingStatus.partial,
        errorMessage: failedCount == 0 ? '' : '$failedCount 个帧解析失败',
        updatedAt: now,
      );
      repository.upsertVideoSummary(summary);
      return summary;
    } catch (error) {
      final summary = VideoSummary(
        id: _uuid.v4(),
        videoId: video.id,
        fields: {
          'outline': composeVisionAnalysesOutline(analyses),
          'content': composeVisionAnalysesDescription(analyses),
        },
        rawResponse: '',
        status: failedCount == 0
            ? ProcessingStatus.partial
            : ProcessingStatus.failed,
        errorMessage: '$error',
        updatedAt: now,
      );
      repository.upsertVideoSummary(summary);
      return summary;
    }
  }
}

class _ShotFrameGroup {
  const _ShotFrameGroup({required this.frames, required this.analyses});

  final List<VideoFrame> frames;
  final List<VideoFrameAnalysis> analyses;
}
