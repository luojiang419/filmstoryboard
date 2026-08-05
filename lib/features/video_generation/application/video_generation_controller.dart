import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/file_explorer_service.dart';
import '../../../core/services/workspace_directories.dart';
import '../../replicate/application/replicate_controller.dart';
import '../../replicate/domain/replicate_models.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/app_settings.dart';
import '../../settings/domain/video_generation_api_config.dart';
import '../../shooting_script/application/shooting_script_controller.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../video_analysis/data/video_analysis_repository.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../data/kling_cli_models.dart';
import '../data/kling_cli_resolver.dart';
import '../data/kling_cli_service.dart';
import '../data/video_generation_directories.dart';
import '../data/video_generation_repository.dart';
import '../domain/kling_duration_matcher.dart';
import '../domain/kling_video_prompt_adapter.dart';
import '../domain/source_video_preview_range.dart';
import '../domain/video_action_sequence.dart';
import '../domain/video_generation_models.dart';
import 'video_generation_task_service.dart';

final videoGenerationControllerProvider = Provider<VideoGenerationController>(
  (ref) {
    final database = ref.watch(appDatabaseProvider);
    final controller = VideoGenerationController(
      repository: VideoGenerationRepository(database),
      videoRepository: VideoAnalysisRepository(database),
      shootingScriptController: ref.watch(shootingScriptControllerProvider),
      replicateController: ref.watch(replicateControllerProvider),
      directories: ref.watch(projectDirectoriesProvider),
      settingsController: ref.watch(settingsControllerProvider),
    );
    ref.onDispose(controller.dispose);
    unawaited(controller.initializeEnvironment());
    return controller;
  },
  dependencies: [
    appDatabaseProvider,
    projectDirectoriesProvider,
    replicateControllerProvider,
    shootingScriptControllerProvider,
    settingsControllerProvider,
  ],
);

enum KlingLoginAuthorizationStatus {
  idle,
  waiting,
  completed,
  failed,
  canceled,
  timedOut,
}

class VideoGenerationState {
  const VideoGenerationState({
    this.scripts = const [],
    this.shots = const [],
    this.selectedScriptId = '',
    this.profile,
    this.drafts = const {},
    this.tasks = const [],
    this.replicatedImages = const [],
    this.environment,
    this.identity,
    this.account,
    this.isLoadingEnvironment = false,
    this.isBusy = false,
    this.isGeneratingAll = false,
    this.loginAuthorizationStatus = KlingLoginAuthorizationStatus.idle,
    this.loginAuthorizationMessage = '',
    this.message = '',
    this.errorMessage = '',
  });

  final List<ShootingScript> scripts;
  final List<ScriptShot> shots;
  final String selectedScriptId;
  final VideoGenerationProfile? profile;
  final Map<String, VideoGenerationDraft> drafts;
  final List<VideoGenerationTask> tasks;
  final List<ReplicatedShotImage> replicatedImages;
  final KlingCliEnvironment? environment;
  final KlingIdentity? identity;
  final KlingAccount? account;
  final bool isLoadingEnvironment;
  final bool isBusy;
  final bool isGeneratingAll;
  final KlingLoginAuthorizationStatus loginAuthorizationStatus;
  final String loginAuthorizationMessage;
  final String message;
  final String errorMessage;

  ShootingScript? get selectedScript {
    for (final script in scripts) {
      if (script.id == selectedScriptId) return script;
    }
    return null;
  }

  VideoGenerationState copyWith({
    List<ShootingScript>? scripts,
    List<ScriptShot>? shots,
    String? selectedScriptId,
    Object? profile = _sentinel,
    Map<String, VideoGenerationDraft>? drafts,
    List<VideoGenerationTask>? tasks,
    List<ReplicatedShotImage>? replicatedImages,
    Object? environment = _sentinel,
    Object? identity = _sentinel,
    Object? account = _sentinel,
    bool? isLoadingEnvironment,
    bool? isBusy,
    bool? isGeneratingAll,
    KlingLoginAuthorizationStatus? loginAuthorizationStatus,
    String? loginAuthorizationMessage,
    String? message,
    String? errorMessage,
  }) => VideoGenerationState(
    scripts: scripts ?? this.scripts,
    shots: shots ?? this.shots,
    selectedScriptId: selectedScriptId ?? this.selectedScriptId,
    profile: identical(profile, _sentinel)
        ? this.profile
        : profile as VideoGenerationProfile?,
    drafts: drafts ?? this.drafts,
    tasks: tasks ?? this.tasks,
    replicatedImages: replicatedImages ?? this.replicatedImages,
    environment: identical(environment, _sentinel)
        ? this.environment
        : environment as KlingCliEnvironment?,
    identity: identical(identity, _sentinel)
        ? this.identity
        : identity as KlingIdentity?,
    account: identical(account, _sentinel)
        ? this.account
        : account as KlingAccount?,
    isLoadingEnvironment: isLoadingEnvironment ?? this.isLoadingEnvironment,
    isBusy: isBusy ?? this.isBusy,
    isGeneratingAll: isGeneratingAll ?? this.isGeneratingAll,
    loginAuthorizationStatus:
        loginAuthorizationStatus ?? this.loginAuthorizationStatus,
    loginAuthorizationMessage:
        loginAuthorizationMessage ?? this.loginAuthorizationMessage,
    message: message ?? this.message,
    errorMessage: errorMessage ?? this.errorMessage,
  );
}

class VideoGenerationController extends ValueNotifier<VideoGenerationState> {
  VideoGenerationController({
    required VideoGenerationRepository repository,
    required VideoAnalysisRepository videoRepository,
    required ShootingScriptController shootingScriptController,
    required ReplicateController replicateController,
    required WorkspaceDirectories directories,
    required SettingsController settingsController,
    KlingCliResolver cliResolver = const KlingCliResolver(),
    KlingCliService cliService = const KlingCliService(),
    Duration loginAuthorizationTimeout = const Duration(minutes: 5),
    Duration loginAuthorizationPollInterval = const Duration(seconds: 2),
    Uuid uuid = const Uuid(),
  }) : _repository = repository,
       _videoRepository = videoRepository,
       _shootingScriptController = shootingScriptController,
       _replicateController = replicateController,
       _directories = directories,
       _settingsController = settingsController,
       _cliResolver = cliResolver,
       _cliService = cliService,
       _loginAuthorizationTimeout = loginAuthorizationTimeout,
       _loginAuthorizationPollInterval = loginAuthorizationPollInterval,
       _uuid = uuid,
       super(const VideoGenerationState()) {
    _shootingScriptController.addListener(_handleSourcesChanged);
    _replicateController.addListener(_handleSourcesChanged);
    _settingsController.addListener(_handleSettingsChanged);
    _refreshData();
  }

  final VideoGenerationRepository _repository;
  final VideoAnalysisRepository _videoRepository;
  final ShootingScriptController _shootingScriptController;
  final ReplicateController _replicateController;
  final WorkspaceDirectories _directories;
  final SettingsController _settingsController;
  final KlingCliResolver _cliResolver;
  KlingCliService _cliService;
  final Duration _loginAuthorizationTimeout;
  final Duration _loginAuthorizationPollInterval;
  final Uuid _uuid;
  KlingCliEnvironment? _cachedKlingEnvironment;
  KlingIdentity? _cachedKlingIdentity;
  KlingAccount? _cachedKlingAccount;
  Future<void>? _activeEnvironmentInitialization;
  KlingLoginProcess? _loginProcess;
  Completer<void>? _loginCancelCompleter;
  Future<KlingLoginAuthorizationStatus>? _activeLoginAuthorization;
  Future<void> _generationQueue = Future<void>.value();
  var _disposed = false;

  Future<void> initializeEnvironment() async {
    final active = _activeEnvironmentInitialization;
    if (active != null) return active;
    final future = _initializeEnvironment();
    _activeEnvironmentInitialization = future;
    future.whenComplete(() => _activeEnvironmentInitialization = null);
    return future;
  }

  Future<void> _initializeEnvironment() async {
    if (usesConfiguredVideoGenerationApi) {
      _cacheKlingState();
      value = value.copyWith(
        environment: null,
        identity: null,
        account: null,
        isLoadingEnvironment: false,
        message: '视频生成 API 已就绪',
        errorMessage: '',
      );
      unawaited(_resumePendingTasks());
      return;
    }
    if (_restoreCachedKlingState()) {
      unawaited(_resumePendingTasks());
      return;
    }
    value = value.copyWith(isLoadingEnvironment: true, errorMessage: '');
    KlingCliEnvironment? environment;
    try {
      environment = await _cliResolver.resolve();
      if (!environment.isReady) {
        value = value.copyWith(
          environment: environment,
          identity: null,
          account: null,
          isLoadingEnvironment: false,
          errorMessage: environment.errorMessage,
        );
        return;
      }
      _cliService = KlingCliService(executable: environment.klingPath);
      value = value.copyWith(environment: environment, errorMessage: '');
      await _refreshKlingAccount(successMessage: '可灵账号已连接');
      unawaited(_resumePendingTasks());
    } catch (error) {
      value = value.copyWith(
        environment: environment ?? value.environment,
        isLoadingEnvironment: false,
        identity: null,
        account: null,
        errorMessage: '可灵未登录或连接失败：$error',
      );
    }
  }

  Future<void> login() async {
    value = value.copyWith(isLoadingEnvironment: true, errorMessage: '');
    try {
      await _cliService.login();
      await initializeEnvironment();
    } catch (error) {
      value = value.copyWith(
        isLoadingEnvironment: false,
        errorMessage: '可灵登录失败：$error',
      );
    }
  }

  Future<KlingLoginAuthorizationStatus> startLoginAuthorization() {
    final active = _activeLoginAuthorization;
    if (active != null) return active;
    final future = _runLoginAuthorization();
    _activeLoginAuthorization = future;
    future.whenComplete(() => _activeLoginAuthorization = null);
    return future;
  }

  Future<void> reopenLoginBrowser() async {
    if (value.loginAuthorizationStatus !=
        KlingLoginAuthorizationStatus.waiting) {
      return;
    }
    _loginProcess?.kill();
    try {
      _loginProcess = await _cliService.startLogin();
      value = value.copyWith(
        loginAuthorizationMessage: '已重新打开浏览器，请在浏览器中完成可灵授权。',
        errorMessage: '',
      );
    } catch (error) {
      value = value.copyWith(
        loginAuthorizationStatus: KlingLoginAuthorizationStatus.failed,
        loginAuthorizationMessage: '无法重新打开浏览器：$error',
        isLoadingEnvironment: false,
        errorMessage: '可灵登录失败：$error',
      );
      _completeLoginCancelSignal();
    }
  }

  void cancelLoginAuthorization() {
    if (value.loginAuthorizationStatus !=
        KlingLoginAuthorizationStatus.waiting) {
      return;
    }
    _completeLoginCancelSignal();
    _loginProcess?.kill();
    value = value.copyWith(
      loginAuthorizationStatus: KlingLoginAuthorizationStatus.canceled,
      loginAuthorizationMessage: '',
      isLoadingEnvironment: false,
      message: '已取消可灵登录授权',
      errorMessage: '',
    );
  }

  Future<KlingLoginAuthorizationStatus> _runLoginAuthorization() async {
    _loginCancelCompleter = Completer<void>();
    value = value.copyWith(
      isLoadingEnvironment: true,
      loginAuthorizationStatus: KlingLoginAuthorizationStatus.waiting,
      loginAuthorizationMessage: '正在打开浏览器，请在浏览器中完成可灵授权。',
      message: '',
      errorMessage: '',
    );
    try {
      _loginProcess = await _cliService.startLogin();
    } catch (error) {
      value = value.copyWith(
        isLoadingEnvironment: false,
        loginAuthorizationStatus: KlingLoginAuthorizationStatus.failed,
        loginAuthorizationMessage: '无法打开浏览器：$error',
        errorMessage: '可灵登录失败：$error',
      );
      _clearLoginSession();
      return KlingLoginAuthorizationStatus.failed;
    }

    Object? lastError;
    final deadline = DateTime.now().add(_loginAuthorizationTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_loginCancelCompleter?.isCompleted == true) {
        _clearLoginSession();
        return KlingLoginAuthorizationStatus.canceled;
      }
      try {
        await _refreshKlingAccount(successMessage: '可灵账号已连接');
        value = value.copyWith(
          isLoadingEnvironment: false,
          loginAuthorizationStatus: KlingLoginAuthorizationStatus.completed,
          loginAuthorizationMessage: '',
          errorMessage: '',
        );
        _clearLoginSession(killProcess: true);
        return KlingLoginAuthorizationStatus.completed;
      } catch (error) {
        lastError = error;
      }

      final waitResult = await Future.any<Object?>([
        if (_loginProcess != null)
          _loginProcess!.exitCode.then<Object?>((code) => code),
        Future<Object?>.delayed(_loginAuthorizationPollInterval),
        if (_loginCancelCompleter != null)
          _loginCancelCompleter!.future.then<Object?>(
            (_) => _loginCanceledSignal,
          ),
      ]);
      if (identical(waitResult, _loginCanceledSignal)) {
        _clearLoginSession();
        return KlingLoginAuthorizationStatus.canceled;
      }
      final exited = waitResult is int ? waitResult : null;
      if (exited != null && exited != 0) {
        final stderr = _loginProcess?.stderr().trim() ?? '';
        final detail = stderr.isEmpty ? '$lastError' : stderr;
        value = value.copyWith(
          isLoadingEnvironment: false,
          loginAuthorizationStatus: KlingLoginAuthorizationStatus.failed,
          loginAuthorizationMessage: '可灵授权窗口已退出，但登录未完成。',
          errorMessage: '可灵登录失败：$detail',
        );
        _clearLoginSession();
        return KlingLoginAuthorizationStatus.failed;
      }
    }

    value = value.copyWith(
      isLoadingEnvironment: false,
      loginAuthorizationStatus: KlingLoginAuthorizationStatus.timedOut,
      loginAuthorizationMessage: '未检测到授权完成，请重新打开浏览器或稍后再试。',
      errorMessage: '未检测到可灵授权完成：$lastError',
    );
    _clearLoginSession(killProcess: true);
    return KlingLoginAuthorizationStatus.timedOut;
  }

  Future<void> _refreshKlingAccount({required String successMessage}) async {
    final identity = await _cliService.whoAmI();
    final account = await _cliService.account();
    final environment = value.environment;
    if (environment != null && environment.isReady) {
      _cachedKlingEnvironment = environment;
    }
    _cachedKlingIdentity = identity;
    _cachedKlingAccount = account;
    value = value.copyWith(
      identity: identity,
      account: account,
      isLoadingEnvironment: false,
      message: successMessage,
      errorMessage: '',
    );
    _ensureProfileModel();
  }

  void _completeLoginCancelSignal() {
    final completer = _loginCancelCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _clearLoginSession({bool killProcess = false}) {
    if (killProcess) _loginProcess?.kill();
    _loginProcess = null;
    _loginCancelCompleter = null;
  }

  void selectScript(String scriptId) {
    _shootingScriptController.selectScript(scriptId);
  }

  void selectModel(String model) {
    final profile = value.profile;
    final spec = _model(model);
    if (profile == null || spec == null) return;
    final updated = profile.copyWith(
      model: model,
      parameters: _defaultParameters(spec),
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertProfile(updated);
    value = value.copyWith(profile: updated, message: '已切换可灵模型');
  }

  void updateParameter(String name, String parameterValue) {
    final profile = value.profile;
    if (profile == null) return;
    final updated = profile.copyWith(
      parameters: {...profile.parameters, name: parameterValue},
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertProfile(updated);
    value = value.copyWith(profile: updated);
  }

  void updatePromptMode(String shotId, VideoPromptMode mode) {
    final draft = value.drafts[shotId];
    if (draft == null) return;
    final updated = VideoGenerationDraft(
      id: draft.id,
      scriptId: draft.scriptId,
      shotId: draft.shotId,
      sourcePrompt: draft.sourcePrompt,
      klingPrompt: draft.klingPrompt,
      editedPrompt: draft.editedPrompt,
      promptMode: mode,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertDraft(updated);
    value = value.copyWith(drafts: {...value.drafts, shotId: updated});
  }

  void updateEditedPrompt(String shotId, String prompt) {
    final draft = value.drafts[shotId];
    if (draft == null) return;
    final updated = VideoGenerationDraft(
      id: draft.id,
      scriptId: draft.scriptId,
      shotId: draft.shotId,
      sourcePrompt: draft.sourcePrompt,
      klingPrompt: draft.klingPrompt,
      editedPrompt: prompt,
      promptMode: VideoPromptMode.edited,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertDraft(updated);
    value = value.copyWith(drafts: {...value.drafts, shotId: updated});
  }

  SourceVideoPreviewRange? sourcePreviewFor(ScriptShot shot) {
    final script = value.selectedScript;
    if (script?.sourceVideoId == null) return null;
    final video = _videoRepository.getSourceVideo(script!.sourceVideoId!);
    if (video == null) return null;
    return const SourceVideoPreviewResolver().resolve(
      video: video,
      frames: _videoRepository.listVideoFrames(script.sourceVideoId!),
      shot: shot,
      workspaceRoot: _directories.workspaceRoot,
      paddingSeconds: _settingsController.value.videoPreviewPaddingSeconds,
    );
  }

  ReplicatedShotImage? replicatedImageFor(String shotId) {
    for (final image in value.replicatedImages.reversed) {
      if (image.scriptShotId == shotId &&
          image.status == ProcessingStatus.completed) {
        return image;
      }
    }
    return null;
  }

  File replicatedImageFile(ReplicatedShotImage image) =>
      _runtimeFile(image.generatedFramePath);

  File? sourceImageFileFor(ScriptShot shot) {
    final replicated = replicatedImageFor(shot.id);
    if (replicated != null) {
      final file = replicatedImageFile(replicated);
      if (file.existsSync()) return file;
    }
    final framePath = shot.framePath.trim();
    if (framePath.isEmpty) return null;
    final file = _runtimeFile(framePath);
    if (file.existsSync()) return file;
    final directFile = File(framePath);
    return directFile.existsSync() ? directFile : null;
  }

  bool usesReplicatedImageFor(ScriptShot shot) {
    final replicated = replicatedImageFor(shot.id);
    if (replicated == null) return false;
    return replicatedImageFile(replicated).existsSync();
  }

  List<VideoGenerationTask> tasksForShot(String shotId) => value.tasks
      .where((task) => task.shotId == shotId)
      .toList(growable: false);

  bool get startEndFrameModeEnabled =>
      _settingsController.value.videoStartEndFrameModeEnabled;

  bool get usesConfiguredVideoGenerationApi =>
      _settingsController.value.activeVideoGenerationApiConfig?.isHttpApi ==
          true &&
      _settingsController.value.activeVideoGenerationApiConfig?.baseUrl
              .trim()
              .isNotEmpty ==
          true;

  VideoGenerationApiConfig? get activeVideoGenerationApiConfig =>
      _settingsController.value.activeVideoGenerationApiConfig;

  String get activeVideoGenerationApiModel {
    final model = activeVideoGenerationApiConfig?.model.trim() ?? '';
    return model.isEmpty ? AppSettings.defaultVideoGenerationModel : model;
  }

  List<String> get videoApiAspectRatios => _minimaxApiAspectRatios;

  String get selectedVideoApiAspectRatio {
    final parameters = value.profile?.parameters ?? const <String, String>{};
    final stored = _allowedMiniMaxAspectRatio(
      parameters[_minimaxApiAspectRatioKey],
    );
    if (stored != null) return stored;
    final resolution = selectedVideoApiResolution;
    return _aspectRatioForMiniMaxResolution(resolution) ?? '16:9';
  }

  String get selectedVideoApiResolution {
    final parameters = value.profile?.parameters ?? const <String, String>{};
    final stored =
        parameters[_minimaxApiResolutionKey] ?? parameters['resolution'];
    if (_isMiniMaxResolution(stored)) return stored!;
    return '0.2MP 16:9 - 608x352';
  }

  int get selectedVideoApiSteps {
    final parameters = value.profile?.parameters ?? const <String, String>{};
    return _normalizeMiniMaxSteps(
      parameters[_minimaxApiStepsKey] ?? parameters['steps'],
    );
  }

  List<String> videoApiResolutionsForAspect(String aspectRatio) {
    final normalized = _allowedMiniMaxAspectRatio(aspectRatio) ?? '16:9';
    return [
      for (final preset in _minimaxApiResolutionPresets)
        if (preset.aspectRatio == normalized) preset.label,
    ];
  }

  void updateVideoApiAspectRatio(String aspectRatio) {
    final profile = value.profile;
    final normalized = _allowedMiniMaxAspectRatio(aspectRatio);
    if (profile == null || normalized == null) return;
    final resolution = _defaultMiniMaxResolutionForAspect(normalized);
    final updated = profile.copyWith(
      parameters: {
        ...profile.parameters,
        _minimaxApiAspectRatioKey: normalized,
        _minimaxApiResolutionKey: resolution,
      },
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertProfile(updated);
    value = value.copyWith(profile: updated);
  }

  void updateVideoApiResolution(String resolution) {
    final profile = value.profile;
    if (profile == null || !_isMiniMaxResolution(resolution)) return;
    final updated = profile.copyWith(
      parameters: {
        ...profile.parameters,
        _minimaxApiAspectRatioKey:
            _aspectRatioForMiniMaxResolution(resolution) ?? '16:9',
        _minimaxApiResolutionKey: resolution,
      },
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertProfile(updated);
    value = value.copyWith(profile: updated);
  }

  void updateVideoApiSteps(int steps) {
    final profile = value.profile;
    if (profile == null) return;
    final updated = profile.copyWith(
      parameters: {
        ...profile.parameters,
        _minimaxApiStepsKey: '${steps.clamp(4, 30)}',
      },
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertProfile(updated);
    value = value.copyWith(profile: updated);
  }

  String get videoApiParameterSummary =>
      '生成比例：$selectedVideoApiAspectRatio\n'
      '分辨率：$selectedVideoApiResolution\n'
      '步数：$selectedVideoApiSteps';

  Map<String, String> get selectedVideoApiSubmissionParameters =>
      _miniMaxApiParametersForSubmission(
        value.profile?.parameters ?? const <String, String>{},
      );

  VideoActionSequence actionSequenceFor(ScriptShot shot) {
    if (!startEndFrameModeEnabled) return VideoActionSequence([shot]);
    return const VideoActionSequenceResolver().manualSequenceFor(
      value.shots,
      _replicateController.value.run?.startEndPairs ?? const [],
      shot.id,
    );
  }

  ScriptShot generationOwnerFor(ScriptShot shot) =>
      actionSequenceFor(shot).head;

  double desiredDurationFor(ScriptShot shot) => actionSequenceFor(
    shot,
  ).shots.fold(0, (total, item) => total + item.durationSeconds);

  bool canGenerateShot(ScriptShot shot) {
    final sequence = actionSequenceFor(shot);
    if (sequence.head.id != shot.id) return false;
    if (sourceImageFileFor(sequence.head) == null) return false;
    return !sequence.hasDistinctTail ||
        sourceImageFileFor(sequence.tail) != null;
  }

  List<ScriptShot> generationTargets() {
    int compareShotNumber(ScriptShot first, ScriptShot second) {
      final byNumber = first.shotNumber.compareTo(second.shotNumber);
      return byNumber != 0 ? byNumber : first.id.compareTo(second.id);
    }

    if (!startEndFrameModeEnabled) {
      return value.shots.where(canGenerateShot).toList(growable: false)
        ..sort(compareShotNumber);
    }
    return (_replicateController
        .startEndSequencesFor(value.shots)
        .map((sequence) => sequence.head)
        .where(canGenerateShot)
        .toList(growable: false)
      ..sort(compareShotNumber));
  }

  Future<void> generateShot(ScriptShot shot) async {
    final submissions = await _prepareGenerationSubmissions([
      generationOwnerFor(shot),
    ]);
    if (submissions.isEmpty) return;
    await _enqueueGeneration(
      submissions,
      isBatch: false,
      queuedMessage: '已加入生成队列，等待前序任务完成',
    );
  }

  Future<void> generateAll() async {
    final submissions = await _prepareGenerationSubmissions(
      generationTargets(),
    );
    if (submissions.isEmpty) return;
    await _enqueueGeneration(
      submissions,
      isBatch: true,
      queuedMessage: usesConfiguredVideoGenerationApi
          ? '已按镜号排队，正在串行生成 ${submissions.length} 个视频…'
          : '已按镜号排队，正在并发生成 ${submissions.length} 个可灵视频…',
    );
  }

  Future<void> openOutputDirectory() async {
    final directories = await _generationDirectories();
    await const FileExplorerService().openDirectory(directories.results.path);
  }

  Future<void> previewTask(VideoGenerationTask task) async {
    await previewFile(File(task.localPath));
  }

  Future<void> previewFile(File file) async {
    if (!file.existsSync()) return;
    await Process.start('explorer.exe', [file.path]);
  }

  Future<void> deleteTask(VideoGenerationTask task) async {
    final file = File(task.localPath);
    if (file.existsSync()) await file.delete();
    _repository.deleteTask(task.id);
    _refreshData();
  }

  Future<void> renameTask(VideoGenerationTask task, String name) async {
    final source = File(task.localPath);
    if (!source.existsSync()) return;
    final safe = name
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty) return;
    final target = File(p.join(source.parent.path, '$safe.mp4'));
    final renamed = await source.rename(target.path);
    _repository.upsertTask(
      task.copyWith(localPath: renamed.path, updatedAt: DateTime.now().toUtc()),
    );
    _refreshData();
  }

  Future<File?> saveGeneratedVideoCopy(
    VideoGenerationTask task,
    String targetPath,
  ) async {
    final source = File(task.localPath);
    if (!source.existsSync()) {
      value = value.copyWith(errorMessage: '本地生成视频不存在，无法下载保存');
      return null;
    }
    final requested = targetPath.trim();
    if (requested.isEmpty) return null;
    final normalizedPath = p.extension(requested).isEmpty
        ? '$requested.mp4'
        : requested;
    final target = File(normalizedPath);
    if (p.normalize(source.absolute.path) ==
        p.normalize(target.absolute.path)) {
      value = value.copyWith(message: '视频已在该位置，无需重复保存', errorMessage: '');
      return target;
    }
    try {
      await target.parent.create(recursive: true);
      final saved = await source.copy(target.path);
      value = value.copyWith(message: '视频已保存到：${saved.path}', errorMessage: '');
      return saved;
    } catch (error) {
      value = value.copyWith(errorMessage: '保存视频失败：$error');
      return null;
    }
  }

  Future<void> retryDownload(VideoGenerationTask task) async {
    final preferred = task.resultWithoutWatermarkUrl.trim();
    final fallback = task.resultUrl.trim();
    final url = preferred.isNotEmpty ? preferred : fallback;
    if (url.isEmpty) {
      value = value.copyWith(errorMessage: '该任务没有可重新下载的视频地址');
      return;
    }
    value = value.copyWith(isBusy: true, message: '正在重新下载生成结果…');
    try {
      final directories = await _generationDirectories();
      final shot = value.shots
          .where((item) => item.id == task.shotId)
          .firstOrNull;
      final output = _outputFile(
        directories,
        shotNumber: shot?.shotNumber ?? 0,
        version: _versionForTask(task),
      );
      final file = await const KlingResultDownloader().download(url, output);
      _repository.upsertTask(
        task.copyWith(
          status: VideoGenerationTaskStatus.completed,
          localPath: file.path,
          usedWatermarkedFallback: preferred.isEmpty,
          errorMessage: '',
          updatedAt: DateTime.now().toUtc(),
          completedAt: DateTime.now().toUtc(),
        ),
      );
      _refreshData();
      value = value.copyWith(
        isBusy: false,
        message: '视频已重新下载到本地，不会重复扣费',
        errorMessage: '',
      );
    } catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '重新下载失败：$error\n可灵官方结果 URL 仅 24 小时有效，请及时重试。',
      );
    }
  }

  Future<List<VideoGenerationSubmission>> _prepareGenerationSubmissions(
    List<ScriptShot> shots,
  ) async {
    final profile = value.profile;
    final videoApiConfig =
        _settingsController.value.activeVideoGenerationApiConfig;
    final usesVideoApi =
        videoApiConfig != null &&
        videoApiConfig.isHttpApi &&
        videoApiConfig.baseUrl.trim().isNotEmpty;
    final model = profile == null ? null : _model(profile.model);
    if (shots.isEmpty) {
      value = value.copyWith(errorMessage: '没有具备首帧图的可生成镜头');
      return const [];
    }
    if (!usesVideoApi &&
        (profile == null || model == null || value.identity == null)) {
      value = value.copyWith(errorMessage: '请先登录可灵并选择可用模型');
      return const [];
    }
    final hasStartEndSequence = shots.any(
      (shot) => actionSequenceFor(shot).hasDistinctTail,
    );
    if (!usesVideoApi &&
        hasStartEndSequence &&
        model != null &&
        !model.supportsStartEndFrames) {
      value = value.copyWith(
        errorMessage: '当前模型不支持首尾帧输入，请切换到可灵 3.0 Omni 或支持尾帧图的模型后再提交。',
      );
      return const [];
    }
    final directories = await _generationDirectories();
    final submissions = <VideoGenerationSubmission>[];
    final now = DateTime.now().toUtc();
    for (final shot in shots) {
      final sequence = actionSequenceFor(shot);
      final imageFile = sourceImageFileFor(shot);
      final draft = value.drafts[shot.id];
      if (imageFile == null ||
          draft == null ||
          draft.selectedPrompt.trim().isEmpty) {
        continue;
      }
      var tailImagePath = '';
      if (sequence.hasDistinctTail) {
        final tailFile = sourceImageFileFor(sequence.tail);
        if (tailFile == null) continue;
        tailImagePath = tailFile.path;
      }
      final duration = usesVideoApi
          ? desiredDurationFor(shot).round().clamp(1, 15).toInt()
          : const KlingDurationMatcher().forModel(
              desiredSeconds: desiredDurationFor(shot),
              model: model!,
            );
      final taskId = _uuid.v4();
      final output = _outputFile(
        directories,
        shotNumber: shot.shotNumber,
        version: _nextVersionForShot(shot.id),
      );
      submissions.add(
        VideoGenerationSubmission(
          task: VideoGenerationTask(
            id: taskId,
            scriptId: shot.scriptId,
            shotId: shot.id,
            model: usesVideoApi
                ? activeVideoGenerationApiModel
                : profile!.model,
            parameters: usesVideoApi
                ? _miniMaxApiParametersForSubmission(
                    profile?.parameters ?? const <String, String>{},
                  )
                : _parametersForSubmission(
                    profile!.parameters,
                    model: model!,
                    hasTailImage: tailImagePath.isNotEmpty,
                  ),
            durationSeconds: duration,
            promptMode: draft.promptMode,
            prompt: draft.selectedPrompt,
            tailImagePath: tailImagePath,
            status: VideoGenerationTaskStatus.draft,
            createdAt: now,
            updatedAt: now,
          ),
          sourceImagePath: imageFile.path,
          tailImagePath: tailImagePath,
          outputFile: output,
        ),
      );
    }
    if (submissions.isEmpty) {
      value = value.copyWith(errorMessage: '所选镜头缺少本地首帧图或提示词');
      return const [];
    }
    return submissions;
  }

  Future<void> _enqueueGeneration(
    List<VideoGenerationSubmission> submissions, {
    required bool isBatch,
    required String queuedMessage,
  }) async {
    final videoApiConfig =
        _settingsController.value.activeVideoGenerationApiConfig;
    final usesVideoApi =
        videoApiConfig != null &&
        videoApiConfig.isHttpApi &&
        videoApiConfig.baseUrl.trim().isNotEmpty;
    final activeTasks = [
      for (final submission in submissions)
        submission.task.copyWith(
          localPath: submission.outputFile.path,
          updatedAt: DateTime.now().toUtc(),
        ),
    ];
    final activeTaskIds = activeTasks.map((task) => task.id).toSet();
    for (final task in activeTasks) {
      _repository.upsertTask(task);
    }
    value = value.copyWith(
      isBusy: isBatch ? true : value.isBusy,
      isGeneratingAll: isBatch ? true : value.isGeneratingAll,
      tasks: [
        ...activeTasks,
        for (final task in value.tasks)
          if (!activeTaskIds.contains(task.id)) task,
      ],
      message: queuedMessage,
      errorMessage: '',
    );
    _replicateController.updateVideoGenerationStatus(ProcessingStatus.running);
    final run = _generationQueue.then(
      (_) => _runQueuedGeneration(
        submissions,
        usesVideoApi: usesVideoApi,
        videoApiConfig: videoApiConfig,
        isBatch: isBatch,
      ),
    );
    _generationQueue = run.catchError((_) {});
    await run;
  }

  Future<void> _runQueuedGeneration(
    List<VideoGenerationSubmission> submissions, {
    required bool usesVideoApi,
    required VideoGenerationApiConfig? videoApiConfig,
    required bool isBatch,
  }) async {
    final concurrency = submissions.length == 1
        ? 1
        : usesVideoApi
        ? localVideoApiBatchConcurrency
        : klingCliBatchConcurrency;
    try {
      final results = await VideoGenerationTaskService(
        repository: _repository,
        cliService: _cliService,
        onTaskChanged: _handleTaskChanged,
        videoApiConfig: usesVideoApi ? videoApiConfig : null,
      ).submitBatch(submissions, concurrency: concurrency);
      if (_disposed) return;
      final completed = results
          .where(
            (task) =>
                task.status == VideoGenerationTaskStatus.completed ||
                task.status == VideoGenerationTaskStatus.partialCompleted,
          )
          .length;
      final status = completed == results.length
          ? ProcessingStatus.completed
          : (completed > 0
                ? ProcessingStatus.partial
                : ProcessingStatus.failed);
      _replicateController.updateVideoGenerationStatus(
        status,
        message: '视频生成完成 $completed/${results.length}',
      );
      _refreshData();
      value = value.copyWith(
        isBusy: isBatch ? false : value.isBusy,
        isGeneratingAll: isBatch ? false : value.isGeneratingAll,
        message: '视频生成完成 $completed/${results.length}',
        errorMessage: status == ProcessingStatus.failed ? '本批任务均未完成' : '',
      );
    } catch (error) {
      if (_disposed) return;
      _replicateController.updateVideoGenerationStatus(
        ProcessingStatus.failed,
        message: '$error',
      );
      value = value.copyWith(
        isBusy: isBatch ? false : value.isBusy,
        isGeneratingAll: isBatch ? false : value.isGeneratingAll,
        errorMessage: '视频生成失败：$error',
      );
    }
  }

  Future<void> _resumePendingTasks() async {
    final pending = _repository.listRecoverableTasks(includeTimedOut: false);
    if (pending.isEmpty) return;
    final videoApiConfig =
        _settingsController.value.activeVideoGenerationApiConfig;
    value = value.copyWith(
      isBusy: true,
      message: usesConfiguredVideoGenerationApi
          ? '正在恢复查询 ${pending.length} 个视频 API 任务…'
          : '正在恢复查询 ${pending.length} 个可灵任务…',
    );
    try {
      final recovered =
          await VideoGenerationTaskService(
            repository: _repository,
            cliService: _cliService,
            onTaskChanged: _handleTaskChanged,
            videoApiConfig: usesConfiguredVideoGenerationApi
                ? videoApiConfig
                : null,
          ).resumePending(
            outputForTask: (task) => File(task.localPath),
            includeTimedOut: false,
            concurrency: usesConfiguredVideoGenerationApi
                ? localVideoApiBatchConcurrency
                : klingCliBatchConcurrency,
          );
      if (_disposed) return;
      _refreshData();
      if (usesConfiguredVideoGenerationApi) {
        final retryShots = _shotsForMissingVideoApiTasks(recovered);
        if (retryShots.isNotEmpty) {
          value = value.copyWith(isBusy: false);
          final submissions = await _prepareGenerationSubmissions(retryShots);
          if (submissions.isNotEmpty) {
            await _enqueueGeneration(
              submissions,
              isBatch: false,
              queuedMessage: '历史视频 API 任务不存在，已重新加入生成队列',
            );
          }
          return;
        }
      }
      value = value.copyWith(
        isBusy: false,
        message: usesConfiguredVideoGenerationApi
            ? '已恢复查询 ${pending.length} 个视频 API 任务'
            : '已恢复查询 ${pending.length} 个可灵任务',
      );
    } catch (error) {
      if (_disposed) return;
      value = value.copyWith(
        isBusy: false,
        errorMessage: usesConfiguredVideoGenerationApi
            ? '恢复视频 API 任务查询失败：$error'
            : '恢复可灵任务查询失败：$error',
      );
    }
  }

  List<ScriptShot> _shotsForMissingVideoApiTasks(
    List<VideoGenerationTask> tasks,
  ) {
    final retryShotIds = tasks
        .where(VideoGenerationTaskService.shouldRetryMissingVideoApiTask)
        .map((task) => task.shotId)
        .toSet();
    if (retryShotIds.isEmpty) return const [];
    return [
      for (final shot in value.shots)
        if (retryShotIds.contains(shot.id)) shot,
    ];
  }

  void _handleTaskChanged(VideoGenerationTask updated) {
    if (_disposed) return;
    final tasks = [
      updated,
      for (final task in value.tasks)
        if (task.id != updated.id) task,
    ];
    value = value.copyWith(tasks: tasks);
  }

  void _handleSourcesChanged() => _refreshData();

  void _handleSettingsChanged() {
    if (usesConfiguredVideoGenerationApi) {
      _cacheKlingState();
      value = value.copyWith(
        environment: null,
        identity: null,
        account: null,
        isLoadingEnvironment: false,
        message: '视频生成 API 已就绪',
        errorMessage: '',
      );
      return;
    }
    unawaited(initializeEnvironment());
    if (_restoreCachedKlingState()) return;
    value = value.copyWith();
  }

  void _cacheKlingState() {
    final environment = value.environment;
    if (environment != null && environment.isReady) {
      _cachedKlingEnvironment = environment;
    }
    final identity = value.identity;
    if (identity != null) _cachedKlingIdentity = identity;
    final account = value.account;
    if (account != null) _cachedKlingAccount = account;
  }

  bool _restoreCachedKlingState() {
    final environment = _cachedKlingEnvironment;
    final identity = _cachedKlingIdentity;
    final account = _cachedKlingAccount;
    if (environment == null ||
        !environment.isReady ||
        identity == null ||
        account == null) {
      return false;
    }
    _cliService = KlingCliService(executable: environment.klingPath);
    value = value.copyWith(
      environment: environment,
      identity: identity,
      account: account,
      isLoadingEnvironment: false,
      message: '可灵账号已连接',
      errorMessage: '',
    );
    _ensureProfileModel();
    return true;
  }

  void _refreshData() {
    final shooting = _shootingScriptController.value;
    final script = shooting.selectedScript;
    if (script == null) {
      value = value.copyWith(
        scripts: shooting.scripts,
        shots: const [],
        selectedScriptId: '',
        profile: null,
        drafts: const {},
        tasks: const [],
        replicatedImages: const [],
      );
      return;
    }
    var profile = _repository.getProfile(script.id);
    if (profile == null) {
      final now = DateTime.now().toUtc();
      final resolved = VideoGenerationDirectories.resolve(
        projectDirectories: _directories,
        scriptName: script.name,
        scriptId: script.id,
      );
      profile = VideoGenerationProfile(
        scriptId: script.id,
        directoryName: p.basename(resolved.root.path),
        createdAt: now,
        updatedAt: now,
      );
      _repository.upsertProfile(profile);
    }
    final storedDrafts = {
      for (final draft in _repository.listDrafts(script.id))
        draft.shotId: draft,
    };
    final sequences = startEndFrameModeEnabled
        ? _replicateController.startEndSequencesFor(shooting.shots)
        : const <VideoActionSequence>[];
    final drafts = <String, VideoGenerationDraft>{};
    for (final shot in shooting.shots) {
      final sourcePrompt = shot.prompt;
      final existing = storedDrafts[shot.id];
      final actionSequence = _actionSequenceForPrompt(shot, sequences);
      final klingPrompt = const KlingVideoPromptAdapter().adapt(
        shot,
        sourcePrompt: sourcePrompt,
        actionSequence: actionSequence,
        availableImageReferences: actionSequence.length > 1 ? 2 : 1,
      );
      if (existing == null ||
          existing.sourcePrompt != sourcePrompt ||
          existing.klingPrompt != klingPrompt) {
        final updated = VideoGenerationDraft(
          id: existing?.id ?? _uuid.v4(),
          scriptId: script.id,
          shotId: shot.id,
          sourcePrompt: sourcePrompt,
          klingPrompt: klingPrompt,
          editedPrompt: existing?.editedPrompt ?? '',
          promptMode: existing?.promptMode ?? profile.promptMode,
          updatedAt: DateTime.now().toUtc(),
        );
        _repository.upsertDraft(updated);
        drafts[shot.id] = updated;
      } else {
        drafts[shot.id] = existing;
      }
    }
    final shotIds = shooting.shots.map((shot) => shot.id).toSet();
    value = value.copyWith(
      scripts: shooting.scripts,
      shots: shooting.shots,
      selectedScriptId: script.id,
      profile: profile,
      drafts: drafts,
      tasks: _repository.listTasks(scriptId: script.id),
      replicatedImages: _replicateController.value.replicatedImages
          .where((image) => shotIds.contains(image.scriptShotId))
          .toList(),
    );
    _ensureProfileModel();
  }

  void _ensureProfileModel() {
    final profile = value.profile;
    final models = value.identity?.imageToVideoModels ?? const [];
    if (profile == null || models.isEmpty) return;
    if (models.any((model) => model.model == profile.model)) return;
    selectModel(_preferredDefaultModel(models).model);
  }

  List<ScriptShot> _actionSequenceForPrompt(
    ScriptShot shot,
    List<VideoActionSequence> sequences,
  ) {
    if (sequences.isEmpty) return const [];
    for (final sequence in sequences) {
      if (sequence.contains(shot.id)) return sequence.shots;
    }
    return const [];
  }

  KlingModelSpec _preferredDefaultModel(List<KlingModelSpec> models) {
    for (final model in models) {
      final searchable = '${model.model} ${model.alias} ${model.description}'
          .toLowerCase();
      if (RegExp(r'(^|[^a-z0-9])o3([^a-z0-9]|$)').hasMatch(searchable)) {
        return model;
      }
    }
    return models.first;
  }

  KlingModelSpec? _model(String name) {
    for (final model in value.identity?.imageToVideoModels ?? const []) {
      if (model.model == name) return model;
    }
    return null;
  }

  Map<String, String> _defaultParameters(KlingModelSpec model) {
    final parameters = <String, String>{};
    for (final argument in model.arguments) {
      if (argument.name == 'prompt' || argument.name == 'duration') continue;
      var parameterValue = argument.defaultValue;
      final normalizedName = argument.name
          .replaceAll(RegExp(r'[^a-zA-Z0-9]'), '')
          .toLowerCase();
      if (normalizedName == 'aspectratio' || normalizedName == 'ratio') {
        parameterValue = _allowedDefault(argument, '16:9', parameterValue);
      } else if (normalizedName == 'resolution') {
        parameterValue = _allowedDefault(argument, '1080p', parameterValue);
      }
      if (parameterValue.isNotEmpty) {
        parameters[argument.name] = parameterValue;
      }
    }
    return parameters;
  }

  String _allowedDefault(
    KlingArgumentSpec argument,
    String preferred,
    String fallback,
  ) {
    if (argument.allowedValues.isEmpty) return preferred;
    final normalizedPreferred = preferred.replaceAll(' ', '').toLowerCase();
    for (final allowed in argument.allowedValues) {
      if (allowed.replaceAll(' ', '').toLowerCase() == normalizedPreferred) {
        return allowed;
      }
    }
    return fallback;
  }

  Map<String, String> _parametersForSubmission(
    Map<String, String> parameters, {
    required KlingModelSpec model,
    required bool hasTailImage,
  }) {
    if (!hasTailImage) return parameters;
    final adjusted = {...parameters};
    final resolution = model.argument('resolution');
    if (resolution != null &&
        resolution.allowedValues.any(
          (value) => value.replaceAll(' ', '').toLowerCase() == '1080p',
        )) {
      adjusted['resolution'] = _allowedDefault(
        resolution,
        '1080p',
        adjusted['resolution'] ?? resolution.defaultValue,
      );
    }
    final enableAudio = model.argument('enable_audio');
    final audioUnsupportedWithTail = (enableAudio?.description ?? '')
        .toLowerCase()
        .contains('tail image');
    if (audioUnsupportedWithTail) {
      adjusted['enable_audio'] = 'false';
    }
    return adjusted;
  }

  Map<String, String> _miniMaxApiParametersForSubmission(
    Map<String, String> parameters,
  ) {
    final resolution =
        parameters[_minimaxApiResolutionKey] ?? parameters['resolution'];
    return {
      'resolution': _isMiniMaxResolution(resolution)
          ? resolution!
          : '0.2MP 16:9 - 608x352',
      'steps':
          '${_normalizeMiniMaxSteps(parameters[_minimaxApiStepsKey] ?? parameters['steps'])}',
    };
  }

  Future<VideoGenerationDirectories> _generationDirectories() async {
    final script = value.selectedScript;
    if (script == null) throw StateError('尚未选择拍摄脚本');
    final directories = VideoGenerationDirectories.resolve(
      projectDirectories: _directories,
      scriptName: script.name,
      scriptId: script.id,
      stableDirectoryName: value.profile?.directoryName,
    );
    await directories.create();
    final profile = value.profile;
    final normalizedDirectoryName = p.basename(directories.root.path);
    if (profile != null && profile.directoryName != normalizedDirectoryName) {
      final updated = profile.copyWith(
        directoryName: normalizedDirectoryName,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertProfile(updated);
      value = value.copyWith(profile: updated);
    }
    return directories;
  }

  File _outputFile(
    VideoGenerationDirectories directories, {
    required int shotNumber,
    required int version,
  }) {
    final number = shotNumber > 0
        ? shotNumber.toString().padLeft(3, '0')
        : '000';
    return File(
      p.join(
        directories.results.path,
        '镜头$number-v${version.clamp(1, 9999)}.mp4',
      ),
    );
  }

  int _nextVersionForShot(String shotId) =>
      value.tasks.where((task) => task.shotId == shotId).length + 1;

  int _versionForTask(VideoGenerationTask task) {
    final versions =
        value.tasks.where((item) => item.shotId == task.shotId).toList()..sort((
          first,
          second,
        ) {
          final byCreatedAt = first.createdAt.compareTo(second.createdAt);
          return byCreatedAt != 0 ? byCreatedAt : first.id.compareTo(second.id);
        });
    final index = versions.indexWhere((item) => item.id == task.id);
    return index < 0 ? 1 : index + 1;
  }

  File _runtimeFile(String path) {
    final normalized = path.replaceAll('/', Platform.pathSeparator);
    return File(
      p.isAbsolute(normalized)
          ? normalized
          : p.join(_directories.workspaceRoot.path, normalized),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _loginProcess?.kill();
    _completeLoginCancelSignal();
    _shootingScriptController.removeListener(_handleSourcesChanged);
    _replicateController.removeListener(_handleSourcesChanged);
    _settingsController.removeListener(_handleSettingsChanged);
    super.dispose();
  }
}

class _MiniMaxResolutionPreset {
  const _MiniMaxResolutionPreset(this.label, this.aspectRatio);

  final String label;
  final String aspectRatio;
}

const _minimaxApiAspectRatioKey = 'minimax_api_aspect_ratio';
const _minimaxApiResolutionKey = 'minimax_api_resolution';
const _minimaxApiStepsKey = 'minimax_api_steps';

const _minimaxApiAspectRatios = ['16:9', '9:16', '1:1'];
const _minimaxApiResolutionPresets = [
  _MiniMaxResolutionPreset('0.2MP 16:9 - 608x352', '16:9'),
  _MiniMaxResolutionPreset('0.3MP 16:9 - 736x416', '16:9'),
  _MiniMaxResolutionPreset('0.4MP 16:9 - 864x480', '16:9'),
  _MiniMaxResolutionPreset('0.5MP 16:9 - 960x544', '16:9'),
  _MiniMaxResolutionPreset('0.6MP 16:9 - 1056x608', '16:9'),
  _MiniMaxResolutionPreset('0.2MP 9:16 - 352x608', '9:16'),
  _MiniMaxResolutionPreset('0.3MP 9:16 - 416x736', '9:16'),
  _MiniMaxResolutionPreset('0.4MP 9:16 - 480x864', '9:16'),
  _MiniMaxResolutionPreset('Square 512x512', '1:1'),
];

String? _allowedMiniMaxAspectRatio(String? value) {
  final normalized = value?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  for (final aspectRatio in _minimaxApiAspectRatios) {
    if (aspectRatio == normalized) return aspectRatio;
  }
  return null;
}

bool _isMiniMaxResolution(String? value) {
  if (value == null || value.trim().isEmpty) return false;
  for (final preset in _minimaxApiResolutionPresets) {
    if (preset.label == value.trim()) return true;
  }
  return false;
}

String? _aspectRatioForMiniMaxResolution(String resolution) {
  for (final preset in _minimaxApiResolutionPresets) {
    if (preset.label == resolution.trim()) return preset.aspectRatio;
  }
  return null;
}

String _defaultMiniMaxResolutionForAspect(String aspectRatio) {
  for (final preset in _minimaxApiResolutionPresets) {
    if (preset.aspectRatio == aspectRatio) return preset.label;
  }
  return '0.2MP 16:9 - 608x352';
}

int _normalizeMiniMaxSteps(String? value) {
  final parsed = int.tryParse(value?.trim() ?? '') ?? 12;
  return parsed.clamp(4, 30).toInt();
}

const _sentinel = Object();
const _loginCanceledSignal = Object();
