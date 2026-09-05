import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/performance/performance_probe.dart';
import '../../../core/services/file_explorer_service.dart';
import '../../../core/services/workspace_directories.dart';
import '../../exporter/data/default_export_directories.dart';
import '../../replicate/application/replicate_controller.dart';
import '../../replicate/domain/replicate_models.dart';
import '../../projects/application/project_aspect_controller.dart';
import '../../settings/application/settings_controller.dart';
import '../../settings/domain/app_settings.dart';
import '../../settings/domain/video_generation_api_config.dart';
import '../../shooting_script/application/shooting_script_controller.dart';
import '../../shooting_script/data/shooting_script_workflow_repository.dart';
import '../../shooting_script/domain/script_shot_group.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../shooting_script/domain/shooting_script_workflow_models.dart';
import '../../video_analysis/data/ffmpeg_frame_extractor.dart';
import '../../video_analysis/data/video_analysis_repository.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../data/cli_dependency_installer.dart';
import '../data/davinci_resolve_bridge_client.dart';
import '../data/davinci_resolve_connection_service.dart';
import '../data/davinci_resolve_plugin_launcher.dart';
import '../data/generated_video_compose_service.dart';
import '../data/kling_cli_models.dart';
import '../data/kling_cli_resolver.dart';
import '../data/kling_cli_service.dart';
import '../data/libtv_cli_models.dart';
import '../data/libtv_cli_resolver.dart';
import '../data/libtv_cli_service.dart';
import '../data/minimax_video_api_service.dart';
import '../data/video_generation_directories.dart';
import '../data/video_generation_repository.dart';
import '../data/video_timeline_xml_export_service.dart';
import '../domain/h3_video_prompt_adapter.dart';
import '../domain/generated_video_trim_range.dart';
import '../domain/kling_duration_matcher.dart';
import '../domain/kling_video_prompt_adapter.dart';
import '../domain/video_multi_shot_intent.dart';
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
      workflowRepository: ShootingScriptWorkflowRepository(database),
      shootingScriptController: ref.watch(shootingScriptControllerProvider),
      replicateController: ref.watch(replicateControllerProvider),
      directories: ref.watch(projectDirectoriesProvider),
      settingsController: ref.watch(settingsControllerProvider),
      projectAspectController: ref.watch(projectAspectControllerProvider),
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
    projectAspectControllerProvider,
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

enum CliDependencyInstallStatus {
  idle,
  installingNode,
  installingCli,
  completed,
  failed;

  bool get isInstalling =>
      this == CliDependencyInstallStatus.installingNode ||
      this == CliDependencyInstallStatus.installingCli;
}

class VideoGenerationState {
  const VideoGenerationState({
    this.scripts = const [],
    this.shots = const [],
    this.selectedScriptId = '',
    this.profile,
    this.drafts = const {},
    this.tasks = const [],
    this.selectedPreviewTaskId = '',
    this.replicatedImages = const [],
    this.environment,
    this.identity,
    this.account,
    this.libTvEnvironment,
    this.libTvAccount,
    this.libTvModels = const [],
    this.libTvModel,
    this.isLoadingLibTvModel = false,
    this.isLoadingEnvironment = false,
    this.isBusy = false,
    this.isGeneratingAll = false,
    this.loginAuthorizationStatus = KlingLoginAuthorizationStatus.idle,
    this.loginAuthorizationMessage = '',
    this.cliInstallStatus = CliDependencyInstallStatus.idle,
    this.cliInstallMessage = '',
    this.message = '',
    this.errorMessage = '',
  });

  final List<ShootingScript> scripts;
  final List<ScriptShot> shots;
  final String selectedScriptId;
  final VideoGenerationProfile? profile;
  final Map<String, VideoGenerationDraft> drafts;
  final List<VideoGenerationTask> tasks;
  final String selectedPreviewTaskId;
  final List<ReplicatedShotImage> replicatedImages;
  final KlingCliEnvironment? environment;
  final KlingIdentity? identity;
  final KlingAccount? account;
  final LibTvCliEnvironment? libTvEnvironment;
  final LibTvAccountInfo? libTvAccount;
  final List<LibTvModelSummary> libTvModels;
  final LibTvModelSpec? libTvModel;
  final bool isLoadingLibTvModel;
  final bool isLoadingEnvironment;
  final bool isBusy;
  final bool isGeneratingAll;
  final KlingLoginAuthorizationStatus loginAuthorizationStatus;
  final String loginAuthorizationMessage;
  final CliDependencyInstallStatus cliInstallStatus;
  final String cliInstallMessage;
  final String message;
  final String errorMessage;

  ShootingScript? get selectedScript {
    for (final script in scripts) {
      if (script.id == selectedScriptId) return script;
    }
    return null;
  }

  VideoGenerationTask? get selectedPreviewTask {
    for (final task in tasks) {
      if (task.id == selectedPreviewTaskId) return task;
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
    String? selectedPreviewTaskId,
    List<ReplicatedShotImage>? replicatedImages,
    Object? environment = _sentinel,
    Object? identity = _sentinel,
    Object? account = _sentinel,
    Object? libTvEnvironment = _sentinel,
    Object? libTvAccount = _sentinel,
    List<LibTvModelSummary>? libTvModels,
    Object? libTvModel = _sentinel,
    bool? isLoadingLibTvModel,
    bool? isLoadingEnvironment,
    bool? isBusy,
    bool? isGeneratingAll,
    KlingLoginAuthorizationStatus? loginAuthorizationStatus,
    String? loginAuthorizationMessage,
    CliDependencyInstallStatus? cliInstallStatus,
    String? cliInstallMessage,
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
    selectedPreviewTaskId: selectedPreviewTaskId ?? this.selectedPreviewTaskId,
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
    libTvEnvironment: identical(libTvEnvironment, _sentinel)
        ? this.libTvEnvironment
        : libTvEnvironment as LibTvCliEnvironment?,
    libTvAccount: identical(libTvAccount, _sentinel)
        ? this.libTvAccount
        : libTvAccount as LibTvAccountInfo?,
    libTvModels: libTvModels ?? this.libTvModels,
    libTvModel: identical(libTvModel, _sentinel)
        ? this.libTvModel
        : libTvModel as LibTvModelSpec?,
    isLoadingLibTvModel: isLoadingLibTvModel ?? this.isLoadingLibTvModel,
    isLoadingEnvironment: isLoadingEnvironment ?? this.isLoadingEnvironment,
    isBusy: isBusy ?? this.isBusy,
    isGeneratingAll: isGeneratingAll ?? this.isGeneratingAll,
    loginAuthorizationStatus:
        loginAuthorizationStatus ?? this.loginAuthorizationStatus,
    loginAuthorizationMessage:
        loginAuthorizationMessage ?? this.loginAuthorizationMessage,
    cliInstallStatus: cliInstallStatus ?? this.cliInstallStatus,
    cliInstallMessage: cliInstallMessage ?? this.cliInstallMessage,
    message: message ?? this.message,
    errorMessage: errorMessage ?? this.errorMessage,
  );
}

class VideoGenerationController extends ValueNotifier<VideoGenerationState> {
  VideoGenerationController({
    required VideoGenerationRepository repository,
    required VideoAnalysisRepository videoRepository,
    ShootingScriptWorkflowRepository? workflowRepository,
    required ShootingScriptController shootingScriptController,
    required ReplicateController replicateController,
    required WorkspaceDirectories directories,
    required SettingsController settingsController,
    ProjectAspectController? projectAspectController,
    KlingCliResolver cliResolver = const KlingCliResolver(),
    KlingCliService cliService = const KlingCliService(),
    LibTvCliResolver libTvCliResolver = const LibTvCliResolver(),
    LibTvCliService libTvCliService = const LibTvCliService(),
    CliDependencyInstaller dependencyInstaller = const CliDependencyInstaller(),
    LibTvCliService Function(LibTvCliEnvironment environment)?
    libTvCliServiceFactory,
    MiniMaxVideoApiService? videoApiService,
    GeneratedVideoComposeService composeService =
        const GeneratedVideoComposeService(),
    DaVinciResolveBridgeClient daVinciBridgeClient =
        const DaVinciResolveBridgeClient(),
    DaVinciResolveConnectionService daVinciResolveConnectionService =
        const DaVinciResolveConnectionService(),
    DaVinciResolvePluginLauncher daVinciResolvePluginLauncher =
        const DaVinciResolvePluginLauncher(),
    Duration loginAuthorizationTimeout = const Duration(minutes: 5),
    Duration loginAuthorizationPollInterval = const Duration(seconds: 2),
    Uuid uuid = const Uuid(),
  }) : _repository = repository,
       _videoRepository = videoRepository,
       _workflowRepository = workflowRepository,
       _shootingScriptController = shootingScriptController,
       _replicateController = replicateController,
       _directories = directories,
       _settingsController = settingsController,
       _projectAspectController = projectAspectController,
       _cliResolver = cliResolver,
       _cliService = cliService,
       _libTvCliResolver = libTvCliResolver,
       _libTvCliService = libTvCliService,
       _dependencyInstaller = dependencyInstaller,
       _libTvCliServiceFactory =
           libTvCliServiceFactory ??
           ((environment) =>
               LibTvCliService(executable: environment.executablePath)),
       _videoApiService = videoApiService ?? MiniMaxVideoApiService(),
       _composeService = composeService,
       _daVinciBridgeClient = daVinciBridgeClient,
       _daVinciResolveConnectionService = daVinciResolveConnectionService,
       _daVinciResolvePluginLauncher = daVinciResolvePluginLauncher,
       _loginAuthorizationTimeout = loginAuthorizationTimeout,
       _loginAuthorizationPollInterval = loginAuthorizationPollInterval,
       _uuid = uuid,
       super(const VideoGenerationState()) {
    _shootingScriptController.addListener(_handleSourcesChanged);
    _replicateController.addListener(_handleSourcesChanged);
    _settingsController.addListener(_handleSettingsChanged);
    _projectAspectController?.addListener(_handleProjectAspectChanged);
    _refreshData();
  }

  final VideoGenerationRepository _repository;
  final VideoAnalysisRepository _videoRepository;
  final ShootingScriptWorkflowRepository? _workflowRepository;
  final ShootingScriptController _shootingScriptController;
  final ReplicateController _replicateController;
  final WorkspaceDirectories _directories;
  final SettingsController _settingsController;
  final ProjectAspectController? _projectAspectController;
  final KlingCliResolver _cliResolver;
  KlingCliService _cliService;
  final LibTvCliResolver _libTvCliResolver;
  LibTvCliService _libTvCliService;
  final CliDependencyInstaller _dependencyInstaller;
  final LibTvCliService Function(LibTvCliEnvironment environment)
  _libTvCliServiceFactory;
  final MiniMaxVideoApiService _videoApiService;
  final GeneratedVideoComposeService _composeService;
  final DaVinciResolveBridgeClient _daVinciBridgeClient;
  final DaVinciResolveConnectionService _daVinciResolveConnectionService;
  final DaVinciResolvePluginLauncher _daVinciResolvePluginLauncher;
  final Duration _loginAuthorizationTimeout;
  final Duration _loginAuthorizationPollInterval;
  final Uuid _uuid;
  KlingCliEnvironment? _cachedKlingEnvironment;
  KlingIdentity? _cachedKlingIdentity;
  KlingAccount? _cachedKlingAccount;
  LibTvCliEnvironment? _cachedLibTvEnvironment;
  LibTvAccountInfo? _cachedLibTvAccount;
  List<LibTvModelSummary> _cachedLibTvModels = const [];
  LibTvModelSpec? _cachedLibTvModel;
  Future<void>? _activeEnvironmentInitialization;
  Future<int>? _loginProcessExitCode;
  bool Function([ProcessSignal signal])? _killLoginProcessCallback;
  String Function()? _loginProcessStderr;
  Completer<void>? _loginCancelCompleter;
  Future<KlingLoginAuthorizationStatus>? _activeLoginAuthorization;
  Future<bool>? _activeCliInstallation;
  final _preparingShotIds = <String>{};
  final _canceledTaskIds = <String>{};
  var _activeBatchGenerationCount = 0;
  var _videoApiResolutionPresets = _fallbackMiniMaxApiResolutionPresets;
  var _videoApiDefaultResolution = _fallbackMiniMaxApiDefaultResolution;
  var _videoApiDefaultSteps = 12;
  var _videoApiConfigRequestToken = 0;
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
    if (_disposed) return;
    if (usesConfiguredVideoGenerationApi) {
      _cacheKlingState();
      _cacheLibTvState();
      final loadedConfig = await refreshVideoApiConfig();
      if (_disposed) return;
      value = value.copyWith(
        environment: null,
        identity: null,
        account: null,
        libTvEnvironment: null,
        libTvAccount: null,
        libTvModels: const [],
        libTvModel: null,
        isLoadingEnvironment: false,
        message: loadedConfig
            ? '视频生成 API 已就绪'
            : '视频生成 API 已就绪（分辨率配置读取失败，已使用内置列表）',
        errorMessage: '',
      );
      unawaited(_resumeStartupTasks());
      return;
    }
    if (usesLibTvCli) {
      _cacheKlingState();
      await _initializeLibTvEnvironment();
      return;
    }
    _cacheLibTvState();
    if (_restoreCachedKlingState()) {
      unawaited(_resumeStartupTasks());
      return;
    }
    value = value.copyWith(isLoadingEnvironment: true, errorMessage: '');
    KlingCliEnvironment? environment;
    try {
      environment = await _cliResolver.resolve();
      if (_disposed) return;
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
      _cliService = KlingCliService(
        executable: environment.commandExecutable,
        argumentPrefix: environment.commandArgumentsPrefix,
        runInShell: environment.commandRunInShell,
      );
      value = value.copyWith(environment: environment, errorMessage: '');
      await _refreshKlingAccount(successMessage: '可灵账号已连接');
      if (_disposed) return;
      unawaited(_resumeStartupTasks());
    } catch (error) {
      if (_disposed) return;
      value = value.copyWith(
        environment: environment ?? value.environment,
        isLoadingEnvironment: false,
        identity: null,
        account: null,
        errorMessage: '可灵未登录或连接失败：$error',
      );
    }
  }

  Future<void> _initializeLibTvEnvironment() async {
    if (_restoreCachedLibTvState()) {
      unawaited(_resumeStartupTasks());
      return;
    }
    value = value.copyWith(
      environment: null,
      identity: null,
      account: null,
      isLoadingEnvironment: true,
      errorMessage: '',
    );
    LibTvCliEnvironment? environment;
    try {
      environment = await _libTvCliResolver.resolve();
      if (_disposed || !usesLibTvCli) return;
      if (!environment.isReady) {
        value = value.copyWith(
          libTvEnvironment: environment,
          libTvAccount: null,
          libTvModels: const [],
          libTvModel: null,
          isLoadingEnvironment: false,
          errorMessage: environment.errorMessage,
        );
        return;
      }
      _libTvCliService = _libTvCliServiceFactory(environment);
      value = value.copyWith(
        libTvEnvironment: environment,
        libTvAccount: null,
        libTvModels: const [],
        libTvModel: null,
        errorMessage: '',
      );
      await _refreshLibTvAccount(successMessage: 'LibTV 账号已连接');
      if (_disposed || !usesLibTvCli) return;
      unawaited(_resumeStartupTasks());
    } catch (error) {
      if (_disposed || !usesLibTvCli) return;
      value = value.copyWith(
        libTvEnvironment: environment ?? value.libTvEnvironment,
        libTvAccount: null,
        libTvModels: const [],
        libTvModel: null,
        isLoadingEnvironment: false,
        errorMessage: 'LibTV 未登录或连接失败：$error',
      );
    }
  }

  Future<bool> installActiveCli({KlingCliInstallRegion? klingRegion}) {
    final active = _activeCliInstallation;
    if (active != null) return active;
    final future = _installActiveCli(klingRegion: klingRegion);
    _activeCliInstallation = future;
    future.whenComplete(() => _activeCliInstallation = null);
    return future;
  }

  Future<bool> _installActiveCli({KlingCliInstallRegion? klingRegion}) async {
    if (!usesCliVideoGeneration) return false;
    final providerName = activeCliProviderName;
    try {
      if (usesLibTvCli) {
        value = value.copyWith(
          cliInstallStatus: CliDependencyInstallStatus.installingCli,
          cliInstallMessage: '正在安装 LibTV CLI…',
          errorMessage: '',
        );
        await _dependencyInstaller.installLibTv();
        _cachedLibTvEnvironment = null;
        _cachedLibTvModels = const [];
        _cachedLibTvModel = null;
        value = value.copyWith(
          libTvEnvironment: null,
          libTvAccount: null,
          libTvModels: const [],
          libTvModel: null,
        );
      } else {
        final region =
            klingRegion ??
            KlingCliInstallRegion.fromName(
              activeVideoGenerationApiConfig?.klingCliRegion,
            );
        if (region == null) {
          throw const CliDependencyInstallException('请先选择可灵 CLI 的区域：中国区或海外区。');
        }
        var environment = value.environment ?? await _cliResolver.resolve();
        final needsNode =
            environment.nodePath.trim().isEmpty ||
            KlingCliResolver.parseNodeMajor(environment.nodeVersion) < 18 ||
            environment.npmPath.trim().isEmpty;
        if (needsNode) {
          value = value.copyWith(
            cliInstallStatus: CliDependencyInstallStatus.installingNode,
            cliInstallMessage: '未检测到 Node.js 18+，正在通过 winget 安装 Node.js LTS…',
            errorMessage: '',
          );
          await _dependencyInstaller.installNodeJsLts();
          environment = await _cliResolver.resolve();
        }
        if (environment.npmPath.trim().isEmpty) {
          throw const CliDependencyInstallException(
            'Node.js 安装完成后仍未检测到 npm，请重启软件后再试。',
          );
        }
        value = value.copyWith(
          cliInstallStatus: CliDependencyInstallStatus.installingCli,
          cliInstallMessage: '正在安装可灵 CLI（${region.label}）…',
          errorMessage: '',
        );
        await _dependencyInstaller.installKling(
          region: region,
          npmPath: environment.npmPath,
        );
        _cachedKlingEnvironment = null;
        value = value.copyWith(
          environment: null,
          identity: null,
          account: null,
        );
        await _settingsController.setActiveKlingCliRegion(region.name);
      }

      await initializeEnvironment();
      if (!activeCliEnvironmentReady) {
        throw CliDependencyInstallException(
          value.errorMessage.trim().isEmpty
              ? '$providerName CLI 安装后仍未被检测到，请重启软件后再试。'
              : value.errorMessage,
        );
      }
      value = value.copyWith(
        cliInstallStatus: CliDependencyInstallStatus.completed,
        cliInstallMessage: '$providerName CLI 安装完成',
        message: '$providerName CLI 安装完成，请继续浏览器授权',
      );
      return true;
    } catch (error) {
      if (_disposed) return false;
      value = value.copyWith(
        cliInstallStatus: CliDependencyInstallStatus.failed,
        cliInstallMessage: '$providerName CLI 安装失败',
        isLoadingEnvironment: false,
        errorMessage: error.toString(),
      );
      return false;
    }
  }

  Future<void> login() async {
    if (usesLibTvCli) {
      await startLoginAuthorization();
      return;
    }
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
    _killLoginProcess();
    try {
      await _startActiveLoginProcess();
      value = value.copyWith(
        loginAuthorizationMessage: '已重新打开浏览器，请在浏览器中完成$activeCliProviderName授权。',
        errorMessage: '',
      );
    } catch (error) {
      value = value.copyWith(
        loginAuthorizationStatus: KlingLoginAuthorizationStatus.failed,
        loginAuthorizationMessage: '无法重新打开浏览器：$error',
        isLoadingEnvironment: false,
        errorMessage: '$activeCliProviderName登录失败：$error',
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
    _killLoginProcess();
    value = value.copyWith(
      loginAuthorizationStatus: KlingLoginAuthorizationStatus.canceled,
      loginAuthorizationMessage: '',
      isLoadingEnvironment: false,
      message: '已取消$activeCliProviderName登录授权',
      errorMessage: '',
    );
  }

  Future<KlingLoginAuthorizationStatus> _runLoginAuthorization() async {
    _loginCancelCompleter = Completer<void>();
    value = value.copyWith(
      isLoadingEnvironment: true,
      loginAuthorizationStatus: KlingLoginAuthorizationStatus.waiting,
      loginAuthorizationMessage: '正在打开浏览器，请在浏览器中完成$activeCliProviderName授权。',
      message: '',
      errorMessage: '',
    );
    try {
      await _startActiveLoginProcess();
    } catch (error) {
      value = value.copyWith(
        isLoadingEnvironment: false,
        loginAuthorizationStatus: KlingLoginAuthorizationStatus.failed,
        loginAuthorizationMessage: '无法打开浏览器：$error',
        errorMessage: '$activeCliProviderName登录失败：$error',
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
        await _refreshActiveCliAccount();
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
        if (_loginProcessExitCode != null)
          _loginProcessExitCode!.then<Object?>((code) => code),
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
        final stderr = _loginProcessStderr?.call().trim() ?? '';
        final detail = stderr.isEmpty ? '$lastError' : stderr;
        value = value.copyWith(
          isLoadingEnvironment: false,
          loginAuthorizationStatus: KlingLoginAuthorizationStatus.failed,
          loginAuthorizationMessage: '$activeCliProviderName授权窗口已退出，但登录未完成。',
          errorMessage: '$activeCliProviderName登录失败：$detail',
        );
        _clearLoginSession();
        return KlingLoginAuthorizationStatus.failed;
      }
    }

    value = value.copyWith(
      isLoadingEnvironment: false,
      loginAuthorizationStatus: KlingLoginAuthorizationStatus.timedOut,
      loginAuthorizationMessage: '未检测到授权完成，请重新打开浏览器或稍后再试。',
      errorMessage: '未检测到$activeCliProviderName授权完成：$lastError',
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

  Future<void> _refreshLibTvAccount({required String successMessage}) async {
    final account = await _libTvCliService.accountInfo();
    final models = await _libTvCliService.videoModels();
    final selected = _preferredLibTvModel(models);
    value = value.copyWith(
      libTvAccount: account,
      libTvModels: models,
      isLoadingLibTvModel: true,
      errorMessage: '',
    );
    final model = await _libTvCliService.model(selected.modelKey);
    final environment = value.libTvEnvironment;
    if (environment != null && environment.isReady) {
      _cachedLibTvEnvironment = environment;
    }
    _cachedLibTvAccount = account;
    _cachedLibTvModels = models;
    _cachedLibTvModel = model;
    _applyLibTvModelProfile(model);
    value = value.copyWith(
      libTvAccount: account,
      libTvModels: models,
      libTvModel: model,
      isLoadingLibTvModel: false,
      isLoadingEnvironment: false,
      message: successMessage,
      errorMessage: '',
    );
  }

  Future<void> _refreshActiveCliAccount() => usesLibTvCli
      ? _refreshLibTvAccount(successMessage: 'LibTV 账号已连接')
      : _refreshKlingAccount(successMessage: '可灵账号已连接');

  Future<void> _startActiveLoginProcess() async {
    if (usesLibTvCli) {
      final process = await _libTvCliService.startLogin();
      _loginProcessExitCode = process.exitCode;
      _killLoginProcessCallback = process.kill;
      _loginProcessStderr = process.stderr;
      return;
    }
    final process = await _cliService.startLogin();
    _loginProcessExitCode = process.exitCode;
    _killLoginProcessCallback = process.kill;
    _loginProcessStderr = process.stderr;
  }

  void _completeLoginCancelSignal() {
    final completer = _loginCancelCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  void _clearLoginSession({bool killProcess = false}) {
    if (killProcess) _killLoginProcess();
    _loginProcessExitCode = null;
    _killLoginProcessCallback = null;
    _loginProcessStderr = null;
    _loginCancelCompleter = null;
  }

  void _killLoginProcess() => _killLoginProcessCallback?.call();

  void selectScript(String scriptId) {
    if (value.selectedScriptId != scriptId &&
        value.selectedPreviewTaskId.isNotEmpty) {
      value = value.copyWith(selectedPreviewTaskId: '');
    }
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

  Future<void> selectLibTvModel(String modelKey) async {
    if (!usesLibTvCli || value.isBusy || value.isLoadingLibTvModel) return;
    final summary = value.libTvModels
        .where((model) => model.modelKey == modelKey)
        .firstOrNull;
    if (summary == null || value.libTvModel?.modelKey == modelKey) return;
    value = value.copyWith(
      isLoadingLibTvModel: true,
      message: '',
      errorMessage: '',
    );
    try {
      final model = await _libTvCliService.model(modelKey);
      if (_disposed || !usesLibTvCli) return;
      _cachedLibTvModel = model;
      _applyLibTvModelProfile(model, resetParameters: true);
      value = value.copyWith(
        libTvModel: model,
        isLoadingLibTvModel: false,
        message: '已切换 LibTV 模型：${model.modelName}',
        errorMessage: '',
      );
    } catch (error) {
      if (_disposed) return;
      value = value.copyWith(
        isLoadingLibTvModel: false,
        errorMessage: '读取 LibTV 模型参数失败：$error',
      );
    }
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
      h3Prompt: draft.h3Prompt,
      editedPrompt: draft.editedPrompt,
      promptMode: mode,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertDraft(updated);
    value = value.copyWith(drafts: {...value.drafts, shotId: updated});
  }

  VideoPromptMode get _defaultPromptModeForActiveApi {
    final config = _settingsController.value.activeVideoGenerationApiConfig;
    final model = '${config?.name ?? ''} ${config?.model ?? ''}'
        .trim()
        .toLowerCase();
    if (RegExp(r'即梦|jimeng|seedance|doubao').hasMatch(model)) {
      return VideoPromptMode.original;
    }
    if (RegExp(r'\bh3\b|minimax|海螺').hasMatch(model)) {
      return VideoPromptMode.h3Optimized;
    }
    if (RegExp(r'可灵|kling').hasMatch(model)) {
      return VideoPromptMode.klingOptimized;
    }
    return config?.isHttpApi == true
        ? VideoPromptMode.h3Optimized
        : VideoPromptMode.klingOptimized;
  }

  void _syncPromptModeWithActiveApi() {
    final targetMode = _defaultPromptModeForActiveApi;
    final profile = value.profile;
    var updatedProfile = profile;
    if (profile != null && profile.promptMode != targetMode) {
      updatedProfile = profile.copyWith(
        promptMode: targetMode,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertProfile(updatedProfile);
    }

    var draftsChanged = false;
    final drafts = <String, VideoGenerationDraft>{};
    for (final entry in value.drafts.entries) {
      final draft = entry.value;
      if (_isApiManagedPromptMode(draft.promptMode) &&
          draft.promptMode != targetMode) {
        final updated = VideoGenerationDraft(
          id: draft.id,
          scriptId: draft.scriptId,
          shotId: draft.shotId,
          sourcePrompt: draft.sourcePrompt,
          klingPrompt: draft.klingPrompt,
          h3Prompt: draft.h3Prompt,
          editedPrompt: draft.editedPrompt,
          promptMode: targetMode,
          updatedAt: DateTime.now().toUtc(),
        );
        _repository.upsertDraft(updated);
        drafts[entry.key] = updated;
        draftsChanged = true;
      } else {
        drafts[entry.key] = draft;
      }
    }

    if (updatedProfile != profile || draftsChanged) {
      value = value.copyWith(profile: updatedProfile, drafts: drafts);
    }
  }

  static bool _isApiManagedPromptMode(VideoPromptMode mode) => switch (mode) {
    VideoPromptMode.klingOptimized ||
    VideoPromptMode.h3Optimized ||
    VideoPromptMode.original => true,
    VideoPromptMode.edited => false,
  };

  void updateEditedPrompt(String shotId, String prompt) {
    final draft = value.drafts[shotId];
    if (draft == null) return;
    final updated = VideoGenerationDraft(
      id: draft.id,
      scriptId: draft.scriptId,
      shotId: draft.shotId,
      sourcePrompt: draft.sourcePrompt,
      klingPrompt: draft.klingPrompt,
      h3Prompt: draft.h3Prompt,
      editedPrompt: prompt,
      promptMode: VideoPromptMode.edited,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertDraft(updated);
    value = value.copyWith(drafts: {...value.drafts, shotId: updated});
  }

  void updateDesiredDurationFor(ScriptShot shot, double seconds) {
    if (!seconds.isFinite || seconds <= 0) return;
    final normalizedSeconds = _normalizedManualDuration(seconds);
    final sequence = actionSequenceFor(shot);
    final owner = sequence.head;
    final draft = value.drafts[owner.id];
    if (draft != null && draft.editedPrompt.trim().isNotEmpty) {
      final synchronizedPrompt = _synchronizePromptDuration(
        draft.editedPrompt,
        normalizedSeconds,
      );
      if (synchronizedPrompt != draft.editedPrompt) {
        final updatedDraft = VideoGenerationDraft(
          id: draft.id,
          scriptId: draft.scriptId,
          shotId: draft.shotId,
          sourcePrompt: draft.sourcePrompt,
          klingPrompt: draft.klingPrompt,
          h3Prompt: draft.h3Prompt,
          editedPrompt: synchronizedPrompt,
          promptMode: draft.promptMode,
          updatedAt: DateTime.now().toUtc(),
        );
        _repository.upsertDraft(updatedDraft);
        value = value.copyWith(
          drafts: {...value.drafts, owner.id: updatedDraft},
        );
      }
    }

    _replicateController.synchronizeFreeCreationPromptDuration(
      owner.id,
      normalizedSeconds,
    );
    _updateShotDuration(sequence.tail.id, normalizedSeconds);
  }

  double _normalizedManualDuration(double seconds) {
    if (usesConfiguredVideoGenerationApi) {
      return seconds.round().clamp(1, 15).toDouble();
    }
    if (usesLibTvCli) {
      return _normalizedLibTvDuration(seconds).toDouble();
    }
    final profile = value.profile;
    final model = profile == null ? null : _model(profile.model);
    if (model != null) {
      return const KlingDurationMatcher()
          .forModel(desiredSeconds: seconds, model: model)
          .toDouble();
    }
    return seconds.round().clamp(1, 15).toDouble();
  }

  void _updateShotDuration(String shotId, double seconds) {
    final shot = _shootingScriptController.value.shots
        .where((item) => item.id == shotId)
        .firstOrNull;
    if (shot == null || shot.durationSeconds == seconds) return;
    _shootingScriptController.updateShot(
      shot.copyWith(durationSeconds: seconds),
    );
  }

  static String _synchronizePromptDuration(String prompt, double seconds) {
    final rounded = seconds.roundToDouble();
    final duration = seconds == rounded
        ? '${rounded.toInt()}'
        : seconds.toStringAsFixed(1);
    return prompt.replaceAll(RegExp(r'\d+(?:\.\d+)?\s*秒视频'), '$duration秒视频');
  }

  SourceVideoPreviewRange? sourcePreviewFor(
    ScriptShot shot, {
    ScriptShot? endShot,
    bool Function(File)? fileExists,
  }) {
    final script = value.selectedScript;
    if (script?.sourceVideoId == null) return null;
    final video = _previewVideo;
    if (video == null) return null;
    return const SourceVideoPreviewResolver().resolve(
      video: video,
      frames: _previewFrames,
      shot: shot,
      endShot: endShot,
      workspaceRoot: _directories.workspaceRoot,
      paddingSeconds: _settingsController.value.videoPreviewPaddingSeconds,
      fileExists: fileExists,
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
    return replicatedImageFileForShot(shot) ?? videoFrameFileForShot(shot);
  }

  File? replicatedImageFileForShot(ScriptShot shot) {
    final replicated = replicatedImageFor(shot.id);
    if (replicated == null) return null;
    final file = replicatedImageFile(replicated);
    return file.existsSync() ? file : null;
  }

  File? videoFrameFileForShot(ScriptShot shot) {
    final framePath = shot.framePath.trim();
    if (framePath.isEmpty) return null;
    final file = _runtimeFile(framePath);
    if (file.existsSync()) return file;
    final directFile = File(framePath);
    return directFile.existsSync() ? directFile : null;
  }

  File? generationReferenceImageFileFor(ScriptShot shot) {
    return sourceImageFileFor(shot);
  }

  bool usesReplicatedImageFor(ScriptShot shot) {
    return replicatedImageFileForShot(shot) != null;
  }

  List<VideoGenerationTask> tasksForShot(String shotId) => value.tasks
      .where((task) => task.shotId == shotId)
      .toList(growable: false);

  void selectWorkPreviewTask(VideoGenerationTask task) {
    if (task.scriptId != value.selectedScriptId ||
        !generatedVideoFileFor(task).existsSync()) {
      return;
    }
    value = value.copyWith(selectedPreviewTaskId: task.id);
  }

  void closeWorkPreview() {
    if (value.selectedPreviewTaskId.isEmpty) return;
    value = value.copyWith(selectedPreviewTaskId: '');
  }

  bool canNavigateWorkPreview(int offset) {
    final selected = value.selectedPreviewTask;
    if (selected == null || offset == 0) return false;
    final tasks = _workPreviewNavigationTasks();
    final index = tasks.indexWhere((task) => task.shotId == selected.shotId);
    final targetIndex = index + offset;
    return index >= 0 && targetIndex >= 0 && targetIndex < tasks.length;
  }

  void navigateWorkPreview(int offset) {
    if (offset == 0) return;
    final selected = value.selectedPreviewTask;
    if (selected == null) return;
    final tasks = _workPreviewNavigationTasks();
    final index = tasks.indexWhere((task) => task.shotId == selected.shotId);
    final targetIndex = index + offset;
    if (index < 0 || targetIndex < 0 || targetIndex >= tasks.length) return;
    value = value.copyWith(selectedPreviewTaskId: tasks[targetIndex].id);
  }

  List<VideoGenerationTask> _workPreviewNavigationTasks() {
    final result = <VideoGenerationTask>[];
    for (final group in ScriptShotGroup.group(value.shots)) {
      final head = group.shots.first;
      final candidates =
          value.tasks
              .where(
                (task) =>
                    task.shotId == head.id &&
                    (task.status == VideoGenerationTaskStatus.completed ||
                        task.status ==
                            VideoGenerationTaskStatus.partialCompleted) &&
                    generatedVideoFileFor(task).existsSync(),
              )
              .toList()
            ..sort(_compareTaskCreatedAt);
      if (candidates.isNotEmpty) result.add(candidates.last);
    }
    return result;
  }

  int _compareTaskCreatedAt(
    VideoGenerationTask first,
    VideoGenerationTask second,
  ) {
    final byCreatedAt = first.createdAt.compareTo(second.createdAt);
    return byCreatedAt != 0 ? byCreatedAt : first.id.compareTo(second.id);
  }

  void updateTaskTrimRange(
    VideoGenerationTask task,
    GeneratedVideoTrimRange range,
  ) {
    final current = _repository.getTask(task.id);
    if (current == null) return;
    final normalized = GeneratedVideoTrimRange.fromMilliseconds(
      sourceDurationMs: range.sourceDuration.inMilliseconds,
      trimInMs: range.inPoint.inMilliseconds,
      trimOutMs: range.outPoint.inMilliseconds,
      fallbackDurationMs: current.durationSeconds * 1000,
    );
    final updated = current.copyWith(
      sourceDurationMs: normalized.sourceDuration.inMilliseconds,
      trimInMs: normalized.inPoint.inMilliseconds,
      trimOutMs: normalized.outPoint.inMilliseconds,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertTask(updated);
    final taskWasVisible = value.tasks.any((item) => item.id == updated.id);
    value = value.copyWith(
      tasks: [
        if (!taskWasVisible) updated,
        for (final item in value.tasks)
          if (item.id == updated.id) updated else item,
      ],
    );
  }

  List<VideoGenerationTask> get projectTasks => _repository.listTasks();

  bool get usesConfiguredVideoGenerationApi =>
      _settingsController.value.activeVideoGenerationApiConfig?.isHttpApi ==
          true &&
      _settingsController.value.activeVideoGenerationApiConfig?.baseUrl
              .trim()
              .isNotEmpty ==
          true;

  bool get usesLibTvCli =>
      _settingsController.value.activeVideoGenerationApiConfig?.isLibTvCli ==
      true;

  bool get usesCliVideoGeneration =>
      usesLibTvCli ||
      _settingsController.value.activeVideoGenerationApiConfig?.isKlingCli ==
          true;

  String get activeCliProviderName => usesLibTvCli ? 'LibTV' : '可灵';

  String get activeVideoBackendName {
    final configName = activeVideoGenerationApiConfig?.name.trim() ?? '';
    if (configName.isNotEmpty) return configName;
    return usesCliVideoGeneration ? '$activeCliProviderName CLI' : '视频生成 API';
  }

  bool get activeCliEnvironmentReady => usesLibTvCli
      ? value.libTvEnvironment?.isReady == true
      : value.environment?.isReady == true;

  bool get activeCliAccountConnected =>
      usesLibTvCli ? value.libTvAccount != null : value.identity != null;

  bool get activeCliInstallInProgress => value.cliInstallStatus.isInstalling;

  KlingCliInstallRegion? get configuredKlingInstallRegion =>
      KlingCliInstallRegion.fromName(
        activeVideoGenerationApiConfig?.klingCliRegion,
      );

  bool get shouldRequestActiveCliInstall =>
      usesCliVideoGeneration &&
      !activeCliEnvironmentReady &&
      !value.isLoadingEnvironment &&
      !activeCliInstallInProgress;

  bool get shouldRequestActiveCliLogin =>
      usesCliVideoGeneration &&
      activeCliEnvironmentReady &&
      !activeCliAccountConnected;

  String get activeCliVersion => usesLibTvCli
      ? value.libTvEnvironment?.version ?? ''
      : value.environment?.klingVersion ?? '';

  VideoGenerationApiConfig? get activeVideoGenerationApiConfig =>
      _settingsController.value.activeVideoGenerationApiConfig;

  String get activeVideoGenerationApiModel {
    final model = activeVideoGenerationApiConfig?.model.trim() ?? '';
    return model.isEmpty ? AppSettings.defaultVideoGenerationModel : model;
  }

  String get projectAspectRatioLabel =>
      _projectAspectController?.state.effectiveRatio.label ?? '16:9';

  List<String> get videoApiAspectRatios {
    final ratios = <String>[];
    for (final preset in _videoApiResolutionPresets) {
      if (!ratios.contains(preset.aspectRatio)) ratios.add(preset.aspectRatio);
    }
    return List.unmodifiable(ratios);
  }

  String get selectedVideoApiAspectRatio {
    final parameters = value.profile?.parameters ?? const <String, String>{};
    final stored = _allowedMiniMaxAspectRatio(
      parameters[_minimaxApiAspectRatioKey],
    );
    if (stored != null) return stored;
    final preferred = _allowedMiniMaxAspectRatio(projectAspectRatioLabel);
    if (preferred != null) return preferred;
    final resolution = selectedVideoApiResolution;
    return _aspectRatioForMiniMaxResolution(resolution) ??
        projectAspectRatioLabel;
  }

  String get selectedVideoApiResolution {
    final parameters = value.profile?.parameters ?? const <String, String>{};
    final stored =
        parameters[_minimaxApiResolutionKey] ?? parameters['resolution'];
    if (_isMiniMaxResolution(stored)) return stored!;
    if (_allowedMiniMaxAspectRatio(projectAspectRatioLabel) != null) {
      return _defaultMiniMaxResolutionForAspect(projectAspectRatioLabel);
    }
    return _videoApiDefaultResolution;
  }

  int get selectedVideoApiSteps {
    final parameters = value.profile?.parameters ?? const <String, String>{};
    return _normalizeMiniMaxSteps(
      parameters[_minimaxApiStepsKey] ?? parameters['steps'],
      fallback: _videoApiDefaultSteps,
    );
  }

  List<String> videoApiResolutionsForAspect(String aspectRatio) {
    final normalized =
        _allowedMiniMaxAspectRatio(aspectRatio) ?? projectAspectRatioLabel;
    return [
      for (final preset in _videoApiResolutionPresets)
        if (preset.aspectRatio == normalized) preset.label,
    ];
  }

  Future<bool> refreshVideoApiConfig() async {
    final config = activeVideoGenerationApiConfig;
    final requestToken = ++_videoApiConfigRequestToken;
    if (config == null || !config.isHttpApi || config.baseUrl.trim().isEmpty) {
      _resetVideoApiConfig();
      return false;
    }
    try {
      final apiConfig = await _videoApiService.fetchConfig(config: config);
      if (_disposed || requestToken != _videoApiConfigRequestToken) {
        return false;
      }
      final activeConfig = activeVideoGenerationApiConfig;
      if (activeConfig?.id != config.id ||
          activeConfig?.baseUrl.trim() != config.baseUrl.trim()) {
        return false;
      }
      _videoApiResolutionPresets = List.unmodifiable([
        for (final resolution in apiConfig.resolutions)
          _MiniMaxResolutionPreset(
            resolution,
            _aspectRatioFromMiniMaxResolutionLabel(resolution) ?? '其他',
          ),
      ]);
      _videoApiDefaultResolution = apiConfig.defaultResolution;
      _videoApiDefaultSteps = apiConfig.defaultSteps;
      value = value.copyWith();
      return true;
    } catch (_) {
      if (_disposed || requestToken != _videoApiConfigRequestToken) {
        return false;
      }
      _resetVideoApiConfig(notify: true);
      return false;
    }
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
            _aspectRatioForMiniMaxResolution(resolution) ??
            projectAspectRatioLabel,
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

  List<LibTvModelSummary> get libTvModels => value.libTvModels;

  String get selectedLibTvModelKey => value.libTvModel?.modelKey ?? '';

  String get selectedLibTvModelName => value.libTvModel?.modelName ?? '';

  List<String> get libTvModeTypes =>
      value.libTvModel?.imageInputModeTypes ?? const [];

  String get selectedLibTvModeType {
    final model = value.libTvModel;
    if (model == null) return '';
    final stored = value.profile?.parameters[_libTvModeTypeKey] ?? '';
    if (model.imageInputModeTypes.contains(stored)) return stored;
    return _preferredLibTvModeType(model, imageCount: 1);
  }

  List<LibTvModelParameterSpec> get libTvParameterSpecs {
    final model = value.libTvModel;
    if (model == null) return const [];
    return model
        .parametersForMode(selectedLibTvModeType)
        .where((parameter) => parameter.key != 'duration')
        .toList(growable: false);
  }

  List<LibTvParameterOption> get libTvCountOptions {
    final options = value.libTvModel?.countOptions ?? const [];
    return options.isEmpty
        ? const [LibTvParameterOption(value: '1', label: '1')]
        : options;
  }

  String get selectedLibTvCount {
    final stored = value.profile?.parameters[_libTvCountKey] ?? '';
    if (libTvCountOptions.any((option) => option.value == stored)) {
      return stored;
    }
    return libTvCountOptions.first.value;
  }

  String selectedLibTvParameterValue(LibTvModelParameterSpec parameter) {
    final stored =
        value.profile?.parameters[_libTvStoredParameterKey(parameter.key)];
    if (stored != null && _isValidLibTvParameterValue(parameter, stored)) {
      return stored;
    }
    return _preferredLibTvParameterDefault(parameter);
  }

  List<String> get libTvAspectRatios {
    final options = _libTvParameter('ratio')?.options ?? const [];
    return options.isEmpty
        ? _fallbackLibTvAspectRatios
        : options.map((option) => option.value).toList(growable: false);
  }

  List<String> get libTvResolutions {
    final options = _libTvParameter('resolution')?.options ?? const [];
    return options.isEmpty
        ? _fallbackLibTvResolutions
        : options.map((option) => option.value).toList(growable: false);
  }

  String get selectedLibTvAspectRatio => _normalizedLibTvParameters()['ratio']!;

  String get selectedLibTvResolution =>
      _normalizedLibTvParameters()['resolution']!;

  bool get selectedLibTvSoundEnabled =>
      _libTvBoolValue(_normalizedLibTvParameters()['enableSound']);

  bool get selectedLibTvSearchEnabled =>
      _libTvBoolValue(_normalizedLibTvParameters()['search_enabled']);

  void updateLibTvModeType(String modeType) {
    final model = value.libTvModel;
    final profile = value.profile;
    if (model == null ||
        profile == null ||
        !model.imageInputModeTypes.contains(modeType)) {
      return;
    }
    final updated = profile.copyWith(
      parameters: {
        ..._defaultLibTvParameters(model),
        _libTvModeTypeKey: modeType,
        _libTvCountKey: selectedLibTvCount,
      },
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertProfile(updated);
    value = value.copyWith(profile: updated, message: '已切换 LibTV 生成模式');
  }

  void updateLibTvCount(String count) {
    if (!libTvCountOptions.any((option) => option.value == count)) return;
    updateParameter(_libTvCountKey, count);
  }

  void updateLibTvParameter(
    LibTvModelParameterSpec parameter,
    String parameterValue,
  ) {
    if (!_isValidLibTvParameterValue(parameter, parameterValue)) return;
    updateParameter(_libTvStoredParameterKey(parameter.key), parameterValue);
  }

  void updateLibTvSwitchParameter(
    LibTvModelParameterSpec parameter,
    bool enabled,
  ) {
    updateLibTvParameter(parameter, _libTvSwitchValue(parameter, enabled));
  }

  void updateLibTvAspectRatio(String ratio) {
    final parameter = _libTvParameter('ratio');
    if (parameter == null) {
      if (!_fallbackLibTvAspectRatios.contains(ratio)) return;
      updateParameter(_libTvRatioKey, ratio);
      return;
    }
    updateLibTvParameter(parameter, ratio);
  }

  void updateLibTvResolution(String resolution) {
    final parameter = _libTvParameter('resolution');
    if (parameter == null) {
      if (!_fallbackLibTvResolutions.contains(resolution)) return;
      updateParameter(_libTvResolutionKey, resolution);
      return;
    }
    updateLibTvParameter(parameter, resolution);
  }

  void updateLibTvSoundEnabled(bool enabled) {
    final parameter = _libTvParameter('enableSound');
    if (parameter == null) {
      updateParameter(_libTvEnableSoundKey, enabled ? 'on' : 'off');
      return;
    }
    updateLibTvParameter(parameter, _libTvSwitchValue(parameter, enabled));
  }

  void updateLibTvSearchEnabled(bool enabled) {
    final parameter = _libTvParameter('search_enabled');
    if (parameter == null) {
      updateParameter(_libTvSearchEnabledKey, enabled ? '1' : '0');
      return;
    }
    updateLibTvParameter(parameter, _libTvSwitchValue(parameter, enabled));
  }

  String get libTvParameterSummary {
    final parameters = _normalizedLibTvParameters();
    final lines = <String>[
      '模型：${selectedLibTvModelName.isEmpty ? '未选择' : selectedLibTvModelName}',
      '生成模式：${libTvModeTypeLabel(selectedLibTvModeType)}',
      '每镜头生成：${parameters['count'] ?? '1'} 条',
      for (final parameter in libTvParameterSpecs)
        '${parameter.displayName}：${_libTvParameterSummaryValue(parameter, parameters[parameter.key] ?? selectedLibTvParameterValue(parameter))}',
      '时长范围：$libTvDurationMin–$libTvDurationMax 秒（按镜头）',
    ];
    return lines.join('\n');
  }

  String _libTvParameterSummaryValue(
    LibTvModelParameterSpec parameter,
    String value,
  ) {
    if (parameter.isSwitch) return _libTvBoolValue(value) ? '开启' : '关闭';
    for (final option in parameter.options) {
      if (option.value == value) return option.label;
    }
    return value;
  }

  Map<String, String> _normalizedLibTvParameters() =>
      _libTvParametersForSubmission(
        value.profile?.parameters ?? const <String, String>{},
        imageInputCount: 1,
      );

  LibTvModelParameterSpec? _libTvParameter(String key) {
    for (final parameter in libTvParameterSpecs) {
      if (parameter.key == key) return parameter;
    }
    return null;
  }

  bool _isValidLibTvParameterValue(
    LibTvModelParameterSpec parameter,
    String value,
  ) {
    final normalized = value.trim();
    if (normalized.isEmpty) return false;
    if (parameter.options.isNotEmpty) {
      return parameter.options.any((option) => option.value == normalized);
    }
    if (parameter.hasNumericRange) {
      final number = num.tryParse(normalized);
      if (number == null) return false;
      return number >= parameter.min! && number <= parameter.max!;
    }
    return true;
  }

  String _libTvSwitchValue(LibTvModelParameterSpec parameter, bool enabled) {
    for (final option in parameter.options) {
      if (_libTvBoolValue(option.value) == enabled) return option.value;
    }
    final defaultValue = parameter.defaultValue.toLowerCase();
    if (defaultValue == 'true' || defaultValue == 'false') {
      return enabled ? 'true' : 'false';
    }
    if (defaultValue == 'on' || defaultValue == 'off') {
      return enabled ? 'on' : 'off';
    }
    return enabled ? '1' : '0';
  }

  bool _libTvBoolValue(String? value) =>
      const {'1', 'true', 'on', 'yes'}.contains(value?.trim().toLowerCase());

  int get libTvDurationMin {
    final duration = value.libTvModel?.parameter('duration');
    return duration?.min?.round() ?? 4;
  }

  int get libTvDurationMax {
    final duration = value.libTvModel?.parameter('duration');
    return duration?.max?.round() ?? 15;
  }

  String libTvModeTypeLabel(String modeType) => switch (modeType) {
    'text2video' => '文生视频',
    'singleImage2video' => '单图生视频',
    'frames2video' => '首尾帧',
    'image2video' => '多图参考',
    'video2video' => '视频参考',
    'videoEdit2video' => '视频编辑',
    'audio2video' => '音频驱动',
    'mixed2video' => '全能参考',
    _ => modeType.isEmpty ? '不支持图像输入' : modeType,
  };

  int _normalizedLibTvDuration(num seconds) {
    final duration = value.libTvModel?.parameter('duration');
    final allowed =
        duration?.options
            .map((option) => int.tryParse(option.value))
            .whereType<int>()
            .toList(growable: false) ??
        const [];
    if (allowed.isNotEmpty) {
      return allowed.reduce(
        (best, candidate) =>
            (candidate - seconds).abs() < (best - seconds).abs()
            ? candidate
            : best,
      );
    }
    return seconds.round().clamp(libTvDurationMin, libTvDurationMax).toInt();
  }

  Map<String, String> get selectedVideoApiSubmissionParameters =>
      _miniMaxApiParametersForSubmission(
        value.profile?.parameters ?? const <String, String>{},
      );

  VideoActionSequence actionSequenceFor(ScriptShot shot) {
    if (!identical(_sequenceShots, value.shots)) {
      _sequenceShots = value.shots;
      _sequencesByShot = {
        for (final sequence in const VideoActionSequenceResolver().resolve(
          value.shots,
        ))
          for (final member in sequence.shots) member.id: sequence,
      };
    }
    return _sequencesByShot[shot.id] ?? VideoActionSequence([shot]);
  }

  ScriptShot generationOwnerFor(ScriptShot shot) =>
      actionSequenceFor(shot).head;

  double desiredDurationFor(ScriptShot shot) {
    final sequence = actionSequenceFor(shot);
    return sequence.tail.durationSeconds;
  }

  bool canGenerateShot(ScriptShot shot) {
    final sequence = actionSequenceFor(shot);
    if (sequence.head.id != shot.id) return false;
    if (generationReferenceImageFileFor(sequence.head) == null) return false;
    if (sequence.hasDistinctTail) {
      return sequence.shots.every((item) => sourceImageFileFor(item) != null);
    }
    return true;
  }

  bool isGenerationActiveFor(ScriptShot shot) {
    final owner = generationOwnerFor(shot);
    return _preparingShotIds.contains(owner.id) ||
        value.tasks.any(
          (task) => task.shotId == owner.id && !task.status.isTerminal,
        );
  }

  List<ScriptShot> generationTargets() {
    int compareShotNumber(ScriptShot first, ScriptShot second) {
      final byNumber = first.shotNumber.compareTo(second.shotNumber);
      return byNumber != 0 ? byNumber : first.id.compareTo(second.id);
    }

    return (const VideoActionSequenceResolver()
        .resolve(value.shots)
        .map((sequence) => sequence.head)
        .where((shot) => canGenerateShot(shot) && !isGenerationActiveFor(shot))
        .toList(growable: false)
      ..sort(compareShotNumber));
  }

  Future<void> generateShot(ScriptShot shot) async {
    final owner = generationOwnerFor(shot);
    if (!_reserveGenerationPreparation(owner)) return;
    try {
      final submissions = await _prepareGenerationSubmissions([owner]);
      if (submissions.isEmpty) return;
      final generation = _enqueueGeneration(
        submissions,
        isBatch: false,
        queuedMessage: '已提交生成任务',
      );
      _preparingShotIds.remove(owner.id);
      await generation;
    } finally {
      _preparingShotIds.remove(owner.id);
    }
  }

  Future<void> generateAll() async {
    final targets = generationTargets()
        .where(_reserveGenerationPreparation)
        .toList(growable: false);
    if (targets.isEmpty) return;
    try {
      final submissions = await _prepareGenerationSubmissions(targets);
      if (submissions.isEmpty) return;
      final generation = _enqueueGeneration(
        submissions,
        isBatch: true,
        queuedMessage: usesConfiguredVideoGenerationApi
            ? '已按镜号提交 ${submissions.length} 个视频任务…'
            : usesLibTvCli
            ? '已按镜号顺序提交 ${submissions.length} 个 LibTV 视频…'
            : '已按镜号并发提交 ${submissions.length} 个可灵视频…',
      );
      _preparingShotIds.removeAll(targets.map((shot) => shot.id));
      await generation;
    } finally {
      _preparingShotIds.removeAll(targets.map((shot) => shot.id));
    }
  }

  Future<void> generateSelection(Iterable<ScriptShot> shots) async {
    final owners = <String, ScriptShot>{};
    for (final shot in shots) {
      final owner = generationOwnerFor(shot);
      owners[owner.id] = owner;
    }
    final targets = owners.values
        .where(canGenerateShot)
        .where(_reserveGenerationPreparation)
        .toList(growable: false);
    if (targets.isEmpty) return;
    try {
      final submissions = await _prepareGenerationSubmissions(targets);
      if (submissions.isEmpty) return;
      final generation = _enqueueGeneration(
        submissions,
        isBatch: targets.length > 1,
        queuedMessage: targets.length == 1
            ? '已提交生成任务'
            : '已按镜号提交 ${submissions.length} 个视频任务…',
      );
      _preparingShotIds.removeAll(targets.map((shot) => shot.id));
      await generation;
    } finally {
      _preparingShotIds.removeAll(targets.map((shot) => shot.id));
    }
  }

  bool _reserveGenerationPreparation(ScriptShot shot) {
    if (isGenerationActiveFor(shot)) return false;
    return _preparingShotIds.add(shot.id);
  }

  Future<void> openOutputDirectory() async {
    final directories = await _generationDirectories();
    await const FileExplorerService().openDirectory(directories.results.path);
  }

  bool get canExportTimelineXml {
    final script = value.selectedScript;
    if (script == null) return false;
    return const VideoTimelineXmlExportService()
        .timelineClips(
          script: script,
          shots: value.shots,
          tasks: value.tasks,
          fileForTask: generatedVideoFileFor,
        )
        .isNotEmpty;
  }

  bool get canExportVideo => canExportTimelineXml;

  /// A capability hint from metadata; export itself validates files once.
  bool get hasTimelineCandidates =>
      value.shots.isNotEmpty &&
      value.tasks.any(
        (task) =>
            (task.status == VideoGenerationTaskStatus.completed ||
                task.status == VideoGenerationTaskStatus.partialCompleted) &&
            task.localPath.trim().isNotEmpty,
      );

  Future<void> exportTimelineXml() async {
    final script = value.selectedScript;
    if (script == null) {
      value = value.copyWith(errorMessage: '尚未选择拍摄脚本', message: '');
      return;
    }
    value = value.copyWith(
      isBusy: true,
      message: '正在导出剪辑时间线…',
      errorMessage: '',
    );
    try {
      final settings = _settingsController.value;
      final file = await const VideoTimelineXmlExportService().export(
        script: script,
        shots: value.shots,
        tasks: value.tasks,
        fileForTask: generatedVideoFileFor,
        outputDirectory: DefaultExportDirectories(
          settings.exportDirectory,
        ).timelines,
        metadataProbe: FfmpegFrameExtractor(
          ffprobeExecutable: settings.ffprobeExecutable,
        ).probe,
      );
      value = value.copyWith(
        isBusy: false,
        message: '时间线 XML 已导出：${file.path}',
        errorMessage: '',
      );
    } on VideoTimelineXmlExportException catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: error.message,
      );
    } catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '导出时间线失败：$error',
      );
    }
  }

  Future<void> sendTimelineToDaVinci() async {
    final script = value.selectedScript;
    if (script == null) {
      value = value.copyWith(message: '', errorMessage: '尚未选择拍摄脚本');
      return;
    }
    value = value.copyWith(
      isBusy: true,
      message: '正在连接达芬奇流程整合插件…',
      errorMessage: '',
    );
    try {
      final health = await _daVinciResolveConnectionService.connect(
        healthCheck: _daVinciBridgeClient.health,
        launchPlugin: _daVinciResolvePluginLauncher.launch,
        onStatus: (message) {
          value = value.copyWith(
            isBusy: true,
            message: message,
            errorMessage: '',
          );
        },
      );
      if (health.projectId.isEmpty) {
        throw const DaVinciBridgeException('达芬奇当前没有打开项目');
      }
      final settings = _settingsController.value;
      final snapshot = await const VideoTimelineXmlExportService()
          .buildSnapshot(
            script: script,
            shots: value.shots,
            tasks: value.tasks,
            fileForTask: generatedVideoFileFor,
            metadataProbe: FfmpegFrameExtractor(
              ffprobeExecutable: settings.ffprobeExecutable,
            ).probe,
          );
      final result = await _daVinciBridgeClient.sync(snapshot);
      final projectLabel = health.projectName.isEmpty
          ? ''
          : '（${health.projectName}）';
      final message = result.unchanged
          ? '达芬奇时间线已是最新状态$projectLabel'
          : result.created
          ? '已在达芬奇$projectLabel创建时间线“${result.timelineName}”，'
                '同步 ${result.syncedClipCount} 个镜头'
          : '已更新达芬奇$projectLabel时间线“${result.timelineName}”，'
                '同步 ${result.syncedClipCount} 个镜头';
      value = value.copyWith(isBusy: false, message: message, errorMessage: '');
    } on VideoTimelineXmlExportException catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: error.message,
      );
    } on DaVinciBridgeException catch (error) {
      final shouldHideTimeout = error.kind == DaVinciBridgeFailureKind.timeout;
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: shouldHideTimeout ? '' : error.message,
      );
    } catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '发送到达芬奇失败：$error',
      );
    }
  }

  Future<void> exportVideo() async {
    final script = value.selectedScript;
    if (script == null) {
      value = value.copyWith(errorMessage: '尚未选择拍摄脚本', message: '');
      return;
    }
    value = value.copyWith(
      isBusy: true,
      message: '正在按镜号和 I/O 范围拼接视频…',
      errorMessage: '',
    );
    try {
      final clips = const VideoTimelineXmlExportService().timelineClips(
        script: script,
        shots: value.shots,
        tasks: value.tasks,
        fileForTask: generatedVideoFileFor,
      );
      if (clips.isEmpty) {
        throw const GeneratedVideoComposeException('暂无可导出的完成视频');
      }
      final directories = await _generationDirectories();
      final canvas = _videoExportCanvas;
      final file = await _composeService.export(
        script: script,
        clips: clips,
        outputDirectory: directories.results,
        width: canvas.width,
        height: canvas.height,
      );
      value = value.copyWith(
        isBusy: false,
        message: '视频已导出：${file.path}',
        errorMessage: '',
      );
    } on GeneratedVideoComposeException catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: error.message,
      );
    } catch (error) {
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '导出视频失败：$error',
      );
    }
  }

  ({int width, int height}) get _videoExportCanvas =>
      switch (projectAspectRatioLabel) {
        '4:3' => (width: 1440, height: 1080),
        '3:4' => (width: 1080, height: 1440),
        '4:5' => (width: 1080, height: 1350),
        '9:16' => (width: 1080, height: 1920),
        _ => (width: 1920, height: 1080),
      };

  Future<void> previewTask(VideoGenerationTask task) async {
    await previewFile(generatedVideoFileFor(task));
  }

  Future<bool> revealGeneratedVideo(VideoGenerationTask task) async {
    final file = generatedVideoFileFor(task);
    final revealed = await const FileExplorerService().revealFile(file.path);
    if (!revealed) {
      value = value.copyWith(errorMessage: '本地生成视频不存在，无法打开路径');
    }
    return revealed;
  }

  Future<void> previewFile(File file) async {
    if (!file.existsSync()) return;
    await Process.start('explorer.exe', [file.path]);
  }

  Future<void> deleteTask(VideoGenerationTask task) async {
    final file = generatedVideoFileFor(task);
    var taskRecordRemoved = false;
    try {
      if (file.existsSync()) {
        try {
          await file.delete();
        } on FileSystemException {
          _repository.deleteTask(task.id);
          taskRecordRemoved = true;
          _refreshData();
          await Future<void>.delayed(const Duration(milliseconds: 80));
          if (file.existsSync()) await file.delete();
        }
      }
      if (!taskRecordRemoved) _repository.deleteTask(task.id);
      _refreshData();
      value = value.copyWith(message: '已删除生成作品', errorMessage: '');
    } catch (error) {
      if (taskRecordRemoved) _repository.upsertTask(task);
      _refreshData();
      value = value.copyWith(message: '', errorMessage: '删除生成作品失败：$error');
    }
  }

  int get invalidWorkTaskCount {
    final scriptId = value.selectedScriptId;
    if (scriptId.isEmpty) return 0;
    return value.tasks
        .where((task) => task.scriptId == scriptId)
        .where(_isMissingCompletedWork)
        .length;
  }

  Future<int> cleanInvalidWorks() async {
    if (value.isBusy) return 0;
    final scriptId = value.selectedScriptId;
    final invalidTasks = value.tasks
        .where((task) => task.scriptId == scriptId)
        .where(_isMissingCompletedWork)
        .toList(growable: false);
    if (invalidTasks.isEmpty) {
      value = value.copyWith(message: '没有需要清理的失效作品', errorMessage: '');
      return 0;
    }
    value = value.copyWith(
      isBusy: true,
      message: '正在清理失效作品…',
      errorMessage: '',
    );
    try {
      for (final task in invalidTasks) {
        _repository.deleteTask(task.id);
      }
      _refreshData();
      value = value.copyWith(
        isBusy: false,
        message: '已清理 ${invalidTasks.length} 个失效作品',
        errorMessage: '',
      );
      return invalidTasks.length;
    } catch (error) {
      _refreshData();
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '清理失效作品失败：$error',
      );
      return 0;
    }
  }

  Future<void> cancelTask(VideoGenerationTask task) async {
    final current = _repository.getTask(task.id) ?? task;
    if (current.status.isTerminal) return;
    _canceledTaskIds.add(task.id);
    final canceled = current.copyWith(
      status: VideoGenerationTaskStatus.canceled,
      errorMessage: '',
      updatedAt: DateTime.now().toUtc(),
      completedAt: DateTime.now().toUtc(),
    );
    _repository.upsertTask(canceled);
    _handleTaskChanged(canceled);
    final config = _settingsController.value.activeVideoGenerationApiConfig;
    if (config != null &&
        config.isHttpApi &&
        config.baseUrl.trim().isNotEmpty &&
        task.generationId.trim().isNotEmpty) {
      try {
        await MiniMaxVideoApiService().cancelTask(
          config: config,
          generationId: task.generationId,
        );
      } catch (_) {
        // 本地状态立即取消；远端失败不阻塞用户继续操作。
      }
    }
    _refreshData();
    value = value.copyWith(message: '已取消生成任务', errorMessage: '');
  }

  Future<void> renameTask(VideoGenerationTask task, String name) async {
    final source = generatedVideoFileFor(task);
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
    final source = generatedVideoFileFor(task);
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
        shotNumber: shot == null ? 0 : _outputShotNumberFor(shot),
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

  Future<void> resumeTaskQuery(VideoGenerationTask task) async {
    if (task.generationId.trim().isEmpty) {
      value = value.copyWith(errorMessage: '该任务缺少生成 ID，不能继续查询');
      return;
    }
    value = value.copyWith(isBusy: true, message: '正在继续查询视频结果…');
    try {
      final recovered =
          await _videoTaskService(
            onTaskChanged: _handleTaskChanged,
          ).pollExisting(
            task,
            outputFile: generatedVideoFileFor(task),
            isCanceled: () => _disposed || _canceledTaskIds.contains(task.id),
          );
      if (_disposed) return;
      _refreshData();
      final completed =
          recovered.status == VideoGenerationTaskStatus.completed ||
          recovered.status == VideoGenerationTaskStatus.partialCompleted;
      value = value.copyWith(
        isBusy: false,
        message: completed ? '已接收生成视频结果，不会重复扣费' : '已继续查询该任务',
        errorMessage: completed ? '' : recovered.errorMessage,
      );
    } catch (error) {
      if (_disposed) return;
      value = value.copyWith(
        isBusy: false,
        message: '',
        errorMessage: '继续查询视频结果失败：$error',
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
    final usesLibTv = videoApiConfig?.isLibTvCli == true;
    final usesNonKlingBackend = usesVideoApi || usesLibTv;
    final model = profile == null ? null : _model(profile.model);
    if (shots.isEmpty) {
      value = value.copyWith(errorMessage: '没有具备首帧图的可生成镜头');
      return const [];
    }
    if (!usesNonKlingBackend &&
        (profile == null || model == null || value.identity == null)) {
      value = value.copyWith(errorMessage: '请先登录可灵并选择可用模型');
      return const [];
    }
    if (usesLibTv && (value.libTvAccount == null || value.libTvModel == null)) {
      value = value.copyWith(errorMessage: '请先登录 LibTV 并选择可用的视频模型');
      return const [];
    }
    final directories = await _generationDirectories();
    final submissions = <VideoGenerationSubmission>[];
    final now = DateTime.now().toUtc();
    for (final shot in shots) {
      final sequence = actionSequenceFor(shot);
      final imageFile = generationReferenceImageFileFor(shot);
      final draft = value.drafts[shot.id];
      if (imageFile == null ||
          draft == null ||
          draft.selectedPrompt.trim().isEmpty) {
        continue;
      }
      final confirmedAssets = _confirmedScriptAssetsForSequence(sequence.shots);
      final errorBeforeImageReferences = value.errorMessage;
      final imageReferences = usesNonKlingBackend
          ? _videoApiImageReferencesForShot(
              sequence: sequence,
              sourceImagePath: imageFile.path,
              assets: confirmedAssets,
            )
          : _klingImageReferencesForShot(
              sequence: sequence,
              model: model!,
              sourceImagePath: imageFile.path,
              assets: confirmedAssets,
            );
      if ((confirmedAssets.isNotEmpty ||
              _sequenceReferenceShots(sequence).isNotEmpty) &&
          imageReferences.isEmpty &&
          value.errorMessage.isNotEmpty &&
          value.errorMessage != errorBeforeImageReferences) {
        return const [];
      }
      final libTvParameters = usesLibTv
          ? _libTvParametersForSubmission(
              profile?.parameters ?? const <String, String>{},
              imageInputCount: imageReferences.length + 1,
            )
          : null;
      if (usesLibTv && libTvParameters?['modeType']?.isNotEmpty != true) {
        value = value.copyWith(
          errorMessage:
              '当前 LibTV 模型不支持 ${imageReferences.length + 1} 张图片输入，请切换模型或生成模式。',
        );
        return const [];
      }
      final prompt = usesNonKlingBackend
          ? _videoApiPromptForSubmission(
              draft.selectedPrompt,
              imageReferences: imageReferences,
              firstImageDescription: '@图片1是起始画面参考',
            )
          : _klingPromptForSubmission(
              draft.selectedPrompt,
              imageReferences: imageReferences,
              firstImageDescription: '图片1为起始画面参考',
            );
      final duration = usesVideoApi
          ? desiredDurationFor(shot).round().clamp(1, 15).toInt()
          : usesLibTv
          ? _normalizedLibTvDuration(desiredDurationFor(shot))
          : const KlingDurationMatcher().forModel(
              desiredSeconds: desiredDurationFor(shot),
              model: model!,
            );
      final taskId = _uuid.v4();
      final output = _outputFile(
        directories,
        shotNumber: _outputShotNumberFor(shot),
        version: _nextVersionForShot(shot.id),
      );
      submissions.add(
        VideoGenerationSubmission(
          task: VideoGenerationTask(
            id: taskId,
            scriptId: shot.scriptId,
            shotId: shot.id,
            model: usesNonKlingBackend
                ? usesLibTv
                      ? value.libTvModel!.modelName
                      : activeVideoGenerationApiModel
                : profile!.model,
            parameters: usesVideoApi
                ? _miniMaxApiParametersForSubmission(
                    profile?.parameters ?? const <String, String>{},
                  )
                : usesLibTv
                ? libTvParameters!
                : _parametersForSubmission(
                    profile!.parameters,
                    model: model!,
                    preferMultiShots: VideoMultiShotIntent.fromSequence(
                      sequence.shots,
                      sourcePrompt: draft.selectedPrompt,
                    ),
                  ),
            durationSeconds: duration,
            promptMode: draft.promptMode,
            prompt: prompt,
            status: VideoGenerationTaskStatus.draft,
            createdAt: now,
            updatedAt: now,
          ),
          sourceImagePath: imageFile.path,
          referenceImagePaths: [
            for (final reference in imageReferences) reference.path,
          ],
          scriptName: value.selectedScript?.name ?? '',
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
        (videoApiConfig.isLibTvCli ||
            (videoApiConfig.isHttpApi &&
                videoApiConfig.baseUrl.trim().isNotEmpty));
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
    if (isBatch) _activeBatchGenerationCount += 1;
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
    try {
      await _runQueuedGeneration(
        submissions,
        usesVideoApi: usesVideoApi,
        videoApiConfig: videoApiConfig,
        isBatch: isBatch,
      );
    } finally {
      if (isBatch) {
        _activeBatchGenerationCount = (_activeBatchGenerationCount - 1).clamp(
          0,
          1 << 30,
        );
        if (!_disposed) {
          final hasActiveBatch = _activeBatchGenerationCount > 0;
          value = value.copyWith(
            isBusy: hasActiveBatch,
            isGeneratingAll: hasActiveBatch,
          );
        }
      }
    }
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
      final results =
          await VideoGenerationTaskService(
            repository: _repository,
            cliService: _cliService,
            libTvCliService: _libTvCliService,
            onTaskChanged: _handleTaskChanged,
            videoApiConfig: usesVideoApi ? videoApiConfig : null,
          ).submitBatch(
            submissions,
            concurrency: concurrency,
            isTaskCanceled: _canceledTaskIds.contains,
          );
      if (_disposed) return;
      final completed = results
          .where(
            (task) =>
                task.status == VideoGenerationTaskStatus.completed ||
                task.status == VideoGenerationTaskStatus.partialCompleted,
          )
          .length;
      final canceled = results
          .where((task) => task.status == VideoGenerationTaskStatus.canceled)
          .length;
      final effectiveTotal = results.length - canceled;
      final status = completed == results.length || completed == effectiveTotal
          ? ProcessingStatus.completed
          : (completed > 0
                ? ProcessingStatus.partial
                : ProcessingStatus.failed);
      final resultMessage = canceled == 0
          ? '视频生成完成 $completed/${results.length}'
          : '视频生成完成 $completed/$effectiveTotal，已取消 $canceled 个';
      _replicateController.updateVideoGenerationStatus(
        status,
        message: resultMessage,
      );
      _refreshData();
      value = value.copyWith(
        message: resultMessage,
        errorMessage: status == ProcessingStatus.failed && canceled == 0
            ? '本批任务均未完成'
            : '',
      );
    } catch (error) {
      if (_disposed) return;
      _failUnfinishedSubmissions(submissions, error);
      _replicateController.updateVideoGenerationStatus(
        ProcessingStatus.failed,
        message: '$error',
      );
      value = value.copyWith(errorMessage: '视频生成失败：$error');
    }
  }

  void _failUnfinishedSubmissions(
    List<VideoGenerationSubmission> submissions,
    Object error,
  ) {
    final now = DateTime.now().toUtc();
    for (final submission in submissions) {
      final current = _repository.getTask(submission.task.id);
      if (current == null || current.status.isTerminal) continue;
      final failed = current.copyWith(
        status: VideoGenerationTaskStatus.failed,
        errorMessage: '$error',
        updatedAt: now,
        completedAt: now,
      );
      _repository.upsertTask(failed);
      _handleTaskChanged(failed);
    }
  }

  Future<void> _resumeStartupTasks() async {
    await _resumePendingTasks();
    if (usesConfiguredVideoGenerationApi) {
      await _resumeTimedOutVideoApiTasksInBackground();
    }
  }

  Future<void> _resumePendingTasks() async {
    final pending = _repository.listRecoverableTasks(includeTimedOut: false);
    if (pending.isEmpty) return;
    final videoApiConfig =
        _settingsController.value.activeVideoGenerationApiConfig;
    final usesNonKlingBackend =
        usesConfiguredVideoGenerationApi || usesLibTvCli;
    value = value.copyWith(
      isBusy: true,
      message: usesNonKlingBackend
          ? '正在恢复 ${pending.length} 个$activeVideoBackendName视频任务…'
          : '正在恢复查询 ${pending.length} 个可灵任务…',
    );
    try {
      final recovered =
          await _videoTaskService(
            onTaskChanged: _handleTaskChanged,
            videoApiConfig: usesNonKlingBackend ? videoApiConfig : null,
          ).resumePending(
            outputForTask: generatedVideoFileFor,
            isTaskCanceled: _canceledTaskIds.contains,
            includeTimedOut: false,
            concurrency: usesNonKlingBackend
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
        message: usesNonKlingBackend
            ? '已恢复 ${pending.length} 个$activeVideoBackendName视频任务'
            : '已恢复查询 ${pending.length} 个可灵任务',
      );
    } catch (error) {
      if (_disposed) return;
      value = value.copyWith(
        isBusy: false,
        errorMessage: usesNonKlingBackend
            ? '恢复$activeVideoBackendName视频任务失败：$error'
            : '恢复可灵任务查询失败：$error',
      );
    }
  }

  Future<void> _resumeTimedOutVideoApiTasksInBackground() async {
    final timedOutTasks = _repository
        .listRecoverableTasks()
        .where((task) => task.status == VideoGenerationTaskStatus.timedOut)
        .toList(growable: false);
    if (timedOutTasks.isEmpty) return;
    final service = _videoTaskService(onTaskChanged: _handleTaskChanged);
    var completed = 0;
    value = value.copyWith(
      message: '正在继续查询 ${timedOutTasks.length} 个超时视频 API 任务…',
      errorMessage: '',
    );
    for (final task in timedOutTasks) {
      if (_disposed || !usesConfiguredVideoGenerationApi) return;
      final recovered = await service.pollExisting(
        task,
        outputFile: generatedVideoFileFor(task),
        isCanceled: () =>
            _disposed ||
            !usesConfiguredVideoGenerationApi ||
            _canceledTaskIds.contains(task.id),
      );
      if (recovered.status == VideoGenerationTaskStatus.completed ||
          recovered.status == VideoGenerationTaskStatus.partialCompleted) {
        completed++;
      }
    }
    if (_disposed) return;
    _refreshData();
    value = value.copyWith(
      message: completed > 0
          ? '已接收 $completed/${timedOutTasks.length} 个超时视频结果'
          : '已继续查询 ${timedOutTasks.length} 个超时视频任务',
    );
  }

  VideoGenerationTaskService _videoTaskService({
    void Function(VideoGenerationTask task)? onTaskChanged,
    VideoGenerationApiConfig? videoApiConfig,
  }) => VideoGenerationTaskService(
    repository: _repository,
    cliService: _cliService,
    libTvCliService: _libTvCliService,
    onTaskChanged: onTaskChanged,
    videoApiConfig:
        videoApiConfig ??
        (usesConfiguredVideoGenerationApi || usesLibTvCli
            ? _settingsController.value.activeVideoGenerationApiConfig
            : null),
  );

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
    if (_canceledTaskIds.contains(updated.id) &&
        updated.status != VideoGenerationTaskStatus.canceled) {
      updated = updated.copyWith(
        status: VideoGenerationTaskStatus.canceled,
        errorMessage: '',
        updatedAt: DateTime.now().toUtc(),
        completedAt: DateTime.now().toUtc(),
      );
      _repository.upsertTask(updated);
    }
    final tasks = [
      updated,
      for (final task in value.tasks)
        if (task.id != updated.id) task,
    ];
    value = value.copyWith(tasks: tasks);
  }

  Object? _sourceDataKey;
  List<ReplicatedShotImage>? _sourceImages;
  SourceVideo? _previewVideo;
  List<VideoFrame> _previewFrames = const [];
  List<ScriptShot>? _sequenceShots;
  Map<String, VideoActionSequence> _sequencesByShot = const {};

  Object _currentSourceDataKey() {
    final shooting = _shootingScriptController.value;
    final replicate = _replicateController.value;
    return (
      shooting.scripts,
      shooting.shots,
      shooting.selectedScriptId,
      replicate.selectedScriptId,
      replicate.prompts,
    );
  }

  void _handleSourcesChanged() {
    if (_currentSourceDataKey() != _sourceDataKey) {
      _refreshData();
    } else if (!identical(
      _sourceImages,
      _replicateController.value.replicatedImages,
    )) {
      _sourceImages = _replicateController.value.replicatedImages;
      final shotIds = value.shots.map((shot) => shot.id).toSet();
      value = value.copyWith(
        replicatedImages: _sourceImages!
            .where((image) => shotIds.contains(image.scriptShotId))
            .toList(),
      );
    }
  }

  void _handleProjectAspectChanged() {
    value = value.copyWith(message: '项目画幅已切换为 $projectAspectRatioLabel');
  }

  // Used only by explicit missing-work cleanup, never by opening an editor.
  bool _isMissingCompletedWork(VideoGenerationTask task) =>
      (task.status == VideoGenerationTaskStatus.completed ||
          task.status == VideoGenerationTaskStatus.partialCompleted) &&
      !generatedVideoFileFor(task).existsSync();

  void _handleSettingsChanged() {
    _syncPromptModeWithActiveApi();
    if (usesConfiguredVideoGenerationApi) {
      _cacheKlingState();
      _cacheLibTvState();
      _resetVideoApiConfig();
      value = value.copyWith(
        environment: null,
        identity: null,
        account: null,
        libTvEnvironment: null,
        libTvAccount: null,
        libTvModels: const [],
        libTvModel: null,
        isLoadingEnvironment: false,
        message: '视频生成 API 已就绪',
        errorMessage: '',
      );
      unawaited(refreshVideoApiConfig());
      return;
    }
    if (usesLibTvCli) {
      _cacheKlingState();
      value = value.copyWith(environment: null, identity: null, account: null);
      if (_restoreCachedLibTvState()) return;
      unawaited(initializeEnvironment());
      return;
    }
    _cacheLibTvState();
    value = value.copyWith(
      libTvEnvironment: null,
      libTvAccount: null,
      libTvModels: const [],
      libTvModel: null,
    );
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

  void _cacheLibTvState() {
    final environment = value.libTvEnvironment;
    if (environment != null && environment.isReady) {
      _cachedLibTvEnvironment = environment;
    }
    final account = value.libTvAccount;
    if (account != null) _cachedLibTvAccount = account;
    if (value.libTvModels.isNotEmpty) {
      _cachedLibTvModels = value.libTvModels;
    }
    final model = value.libTvModel;
    if (model != null) _cachedLibTvModel = model;
  }

  void _resetVideoApiConfig({bool notify = false}) {
    _videoApiResolutionPresets = _fallbackMiniMaxApiResolutionPresets;
    _videoApiDefaultResolution = _fallbackMiniMaxApiDefaultResolution;
    _videoApiDefaultSteps = 12;
    if (notify && !_disposed) value = value.copyWith();
  }

  String? _allowedMiniMaxAspectRatio(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return videoApiAspectRatios.contains(normalized) ? normalized : null;
  }

  bool _isMiniMaxResolution(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) return false;
    return _videoApiResolutionPresets.any(
      (preset) => preset.label == normalized,
    );
  }

  String? _aspectRatioForMiniMaxResolution(String resolution) {
    final normalized = resolution.trim();
    for (final preset in _videoApiResolutionPresets) {
      if (preset.label == normalized) return preset.aspectRatio;
    }
    return null;
  }

  String _defaultMiniMaxResolutionForAspect(String aspectRatio) {
    if (_aspectRatioForMiniMaxResolution(_videoApiDefaultResolution) ==
        aspectRatio) {
      return _videoApiDefaultResolution;
    }
    for (final preset in _videoApiResolutionPresets) {
      if (preset.aspectRatio == aspectRatio) return preset.label;
    }
    return _videoApiDefaultResolution;
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
    _cliService = KlingCliService(
      executable: environment.commandExecutable,
      argumentPrefix: environment.commandArgumentsPrefix,
      runInShell: environment.commandRunInShell,
    );
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

  bool _restoreCachedLibTvState() {
    final environment = _cachedLibTvEnvironment;
    final account = _cachedLibTvAccount;
    final models = _cachedLibTvModels;
    final model = _cachedLibTvModel;
    if (environment == null ||
        !environment.isReady ||
        account == null ||
        models.isEmpty ||
        model == null) {
      return false;
    }
    _libTvCliService = _libTvCliServiceFactory(environment);
    value = value.copyWith(
      libTvEnvironment: environment,
      libTvAccount: account,
      libTvModels: models,
      libTvModel: model,
      isLoadingEnvironment: false,
      message: 'LibTV 账号已连接',
      errorMessage: '',
    );
    _applyLibTvModelProfile(model);
    return true;
  }

  void _refreshData() {
    PerformanceProbe.shared.increment('video_generation.data_refresh');
    _sourceDataKey = _currentSourceDataKey();
    _sourceImages = _replicateController.value.replicatedImages;
    final shooting = _shootingScriptController.value;
    final script = shooting.selectedScript;
    final videoId = script?.sourceVideoId;
    _previewVideo = videoId == null
        ? null
        : _videoRepository.getSourceVideo(videoId);
    _previewFrames = videoId == null
        ? const []
        : _videoRepository.listVideoFrames(videoId);
    if (script == null) {
      value = value.copyWith(
        scripts: shooting.scripts,
        shots: const [],
        selectedScriptId: '',
        profile: null,
        drafts: const {},
        tasks: const [],
        selectedPreviewTaskId: '',
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
        promptMode: _defaultPromptModeForActiveApi,
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
    final sequences = const VideoActionSequenceResolver().resolve(
      shooting.shots,
    );
    final builtPromptsByShotId =
        _replicateController.value.selectedScriptId == script.id
        ? <String, String>{
            for (final prompt in _replicateController.value.prompts)
              if ((prompt.scriptShotId ?? '').isNotEmpty &&
                  prompt.status == ProcessingStatus.completed &&
                  prompt.prompt.trim().isNotEmpty)
                prompt.scriptShotId!: prompt.prompt,
          }
        : const <String, String>{};
    final drafts = <String, VideoGenerationDraft>{};
    final changedDrafts = <VideoGenerationDraft>[];
    for (final shot in shooting.shots) {
      final sourcePrompt = builtPromptsByShotId[shot.id] ?? shot.prompt;
      final existing = storedDrafts[shot.id];
      final actionSequence = _actionSequenceForPrompt(shot, sequences);
      final klingPrompt = const KlingVideoPromptAdapter().adapt(
        shot,
        sourcePrompt: sourcePrompt,
        actionSequence: actionSequence,
        availableImageReferences: actionSequence.isEmpty
            ? 1
            : actionSequence.length,
      );
      final h3Prompt = const H3VideoPromptAdapter().adapt(
        shot,
        sourcePrompt: sourcePrompt,
        actionSequence: actionSequence,
        availableImageReferences: actionSequence.isEmpty
            ? 1
            : actionSequence.length,
      );
      if (existing == null ||
          existing.sourcePrompt != sourcePrompt ||
          existing.klingPrompt != klingPrompt ||
          existing.h3Prompt != h3Prompt) {
        final sourcePromptChanged =
            existing != null && existing.sourcePrompt != sourcePrompt;
        final updated = VideoGenerationDraft(
          id: existing?.id ?? _uuid.v4(),
          scriptId: script.id,
          shotId: shot.id,
          sourcePrompt: sourcePrompt,
          klingPrompt: klingPrompt,
          h3Prompt: h3Prompt,
          editedPrompt: existing?.editedPrompt ?? '',
          promptMode:
              sourcePromptChanged &&
                  existing.promptMode == VideoPromptMode.edited
              ? _defaultPromptModeForActiveApi
              : existing?.promptMode ?? profile.promptMode,
          updatedAt: DateTime.now().toUtc(),
        );
        changedDrafts.add(updated);
        drafts[shot.id] = updated;
      } else {
        drafts[shot.id] = existing;
      }
    }
    final shotIds = shooting.shots.map((shot) => shot.id).toSet();
    _repository.upsertDrafts(changedDrafts);
    final tasks = _repository.listTasks(scriptId: script.id);
    final selectedPreviewTaskId =
        value.selectedScriptId == script.id &&
            tasks.any((task) => task.id == value.selectedPreviewTaskId)
        ? value.selectedPreviewTaskId
        : '';
    value = value.copyWith(
      scripts: shooting.scripts,
      shots: shooting.shots,
      selectedScriptId: script.id,
      profile: profile,
      drafts: drafts,
      tasks: tasks,
      selectedPreviewTaskId: selectedPreviewTaskId,
      replicatedImages: _replicateController.value.replicatedImages
          .where((image) => shotIds.contains(image.scriptShotId))
          .toList(),
    );
    _syncPromptModeWithActiveApi();
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

  List<_GenerationImageReference> _klingImageReferencesForShot({
    required VideoActionSequence sequence,
    required KlingModelSpec model,
    required String sourceImagePath,
    required List<ScriptAsset> assets,
  }) {
    final referenceShots = _sequenceReferenceShots(sequence);
    if (assets.isEmpty && referenceShots.isEmpty) return const [];
    if (!model.supportsNumberedImageReferences) {
      value = value.copyWith(
        errorMessage: '当前可灵模型不支持多参考图，请切换到可灵 3.0 Omni 后再提交。',
      );
      return const [];
    }
    final maxImages = model.maxNumberedImageReferences;
    final capacity = maxImages - 1;
    if (capacity <= 0) {
      value = value.copyWith(errorMessage: '当前可灵模型没有可用的资产参考图位置。');
      return const [];
    }
    final requestedCount = referenceShots.length + assets.length;
    if (requestedCount > capacity) {
      value = value.copyWith(
        errorMessage:
            '当前可灵模型最多支持 $maxImages 张参考图，起始图后只能追加 $capacity 张组内参考图和资产图；请减少镜头资产或拆分生成。',
      );
      return const [];
    }

    final usedPaths = {p.normalize(sourceImagePath)};
    var imageNumber = 2;
    final references = <_GenerationImageReference>[];
    for (final referenceShot in referenceShots) {
      final file = sourceImageFileFor(referenceShot);
      if (file == null || !file.existsSync()) continue;
      final normalized = p.normalize(file.path);
      if (!usedPaths.add(normalized)) continue;
      references.add(
        _GenerationImageReference.sequenceFrame(
          path: file.path,
          imageNumber: imageNumber++,
          shot: referenceShot,
        ),
      );
    }
    for (final asset in assets) {
      final file = _runtimeFile(asset.path);
      if (!file.existsSync()) {
        value = value.copyWith(errorMessage: '资产图文件不存在：${asset.name}');
        return const [];
      }
      final normalized = p.normalize(file.path);
      if (!usedPaths.add(normalized)) continue;
      references.add(
        _GenerationImageReference.asset(
          path: file.path,
          imageNumber: imageNumber++,
          asset: asset,
        ),
      );
    }
    return references;
  }

  List<_GenerationImageReference> _videoApiImageReferencesForShot({
    required VideoActionSequence sequence,
    required String sourceImagePath,
    required List<ScriptAsset> assets,
  }) {
    final referenceShots = _sequenceReferenceShots(sequence);
    if (assets.isEmpty && referenceShots.isEmpty) return const [];
    const maxImages = 9;
    const capacity = maxImages - 1;
    final requestedCount = referenceShots.length + assets.length;
    if (requestedCount > capacity) {
      value = value.copyWith(
        errorMessage:
            '本地 H3 多参考图最多支持 $maxImages 张图片，首帧后只能追加 $capacity 张组内参考图和资产图；请减少镜头资产或拆分生成。',
      );
      return const [];
    }

    final usedPaths = {p.normalize(sourceImagePath)};
    var imageNumber = 2;
    final references = <_GenerationImageReference>[];
    for (final referenceShot in referenceShots) {
      final file = sourceImageFileFor(referenceShot);
      if (file == null || !file.existsSync()) continue;
      final normalized = p.normalize(file.path);
      if (!usedPaths.add(normalized)) continue;
      references.add(
        _GenerationImageReference.sequenceFrame(
          path: file.path,
          imageNumber: imageNumber++,
          shot: referenceShot,
        ),
      );
    }
    for (final asset in assets) {
      final file = _runtimeFile(asset.path);
      if (!file.existsSync()) {
        value = value.copyWith(errorMessage: '资产图文件不存在：${asset.name}');
        return const [];
      }
      final normalized = p.normalize(file.path);
      if (!usedPaths.add(normalized)) continue;
      references.add(
        _GenerationImageReference.asset(
          path: file.path,
          imageNumber: imageNumber++,
          asset: asset,
        ),
      );
    }
    return references;
  }

  List<ScriptShot> _sequenceReferenceShots(VideoActionSequence sequence) =>
      sequence.shots.skip(1).toList(growable: false);

  List<ScriptAsset> _confirmedScriptAssetsForSequence(
    Iterable<ScriptShot> shots,
  ) {
    final workflowRepository = _workflowRepository;
    if (workflowRepository == null) return const [];
    final sequence = shots.toList(growable: false);
    if (sequence.isEmpty) return const [];
    final assetsById = {
      for (final asset in workflowRepository.listScriptAssets(
        sequence.first.scriptId,
      ))
        asset.id: asset,
    };
    final assets = <ScriptAsset>[];
    final usedAssetIds = <String>{};
    for (final shot in sequence) {
      for (final link in workflowRepository.listLinksForShot(shot.id)) {
        if (!link.confirmed || !usedAssetIds.add(link.scriptAssetId)) continue;
        final asset = assetsById[link.scriptAssetId];
        if (asset == null ||
            asset.status != ProcessingStatus.completed ||
            asset.type == ReplicateAssetType.video ||
            asset.type == ReplicateAssetType.audio) {
          usedAssetIds.remove(link.scriptAssetId);
          continue;
        }
        assets.add(asset);
      }
    }
    return assets;
  }

  String _klingPromptForSubmission(
    String prompt, {
    required List<_GenerationImageReference> imageReferences,
    required String firstImageDescription,
  }) {
    if (imageReferences.isEmpty) return prompt;
    final descriptions = <String>[
      if (!_mentionsImageReference(prompt, 1)) firstImageDescription,
      for (final reference in imageReferences)
        if (!_mentionsImageReference(prompt, reference.imageNumber))
          reference.promptDescription,
    ];
    if (descriptions.isEmpty) return prompt;
    return [
      '参考图：${descriptions.join('；')}。',
      prompt,
    ].where((part) => part.trim().isNotEmpty).join('\n');
  }

  String _videoApiPromptForSubmission(
    String prompt, {
    required List<_GenerationImageReference> imageReferences,
    required String firstImageDescription,
  }) {
    if (imageReferences.isEmpty) return prompt;
    if (_usesOfficialH3PromptStructure(prompt)) return prompt;
    final descriptions = <String>[
      if (!_mentionsImageReference(prompt, 1)) firstImageDescription,
      for (final reference in imageReferences)
        if (!_mentionsImageReference(prompt, reference.imageNumber))
          reference.h3PromptDescription,
    ];
    if (descriptions.isEmpty) return prompt;
    return [
      '参考补充：${descriptions.join('；')}。',
      prompt,
    ].where((part) => part.trim().isNotEmpty).join('\n');
  }

  static bool _mentionsImageReference(String prompt, int imageNumber) {
    if (RegExp(
      '(?:@?图片|图)\\s*$imageNumber(?!\\d)|<Picture\\s+$imageNumber>',
      caseSensitive: false,
    ).hasMatch(prompt)) {
      return true;
    }
    final rangePattern = RegExp(
      r'(?:@?图片|图|Picture)\s*(\d+)\s*(?:至|到|[-~～]|to)\s*'
      r'(?:@?图片|图|Picture)?\s*(\d+)',
      caseSensitive: false,
    );
    for (final match in rangePattern.allMatches(prompt)) {
      final start = int.tryParse(match.group(1) ?? '');
      final end = int.tryParse(match.group(2) ?? '');
      if (start == null || end == null) continue;
      if (imageNumber >= start && imageNumber <= end) return true;
    }
    return false;
  }

  static bool _usesOfficialH3PromptStructure(String prompt) {
    final normalized = prompt.trimLeft();
    if (normalized.startsWith('subject_definitions:')) return true;
    final integrated = normalized.indexOf('integrated_multimodal_description:');
    final soundscape = normalized.indexOf('overall_soundscape:');
    final music = normalized.indexOf('non_diegetic_music:');
    return integrated >= 0 && soundscape > integrated && music > soundscape;
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

  LibTvModelSummary _preferredLibTvModel(List<LibTvModelSummary> models) {
    final preferredNames = [
      value.profile?.model ?? '',
      activeVideoGenerationApiConfig?.model ?? '',
      AppSettings.defaultLibTvCliVideoGenerationModel,
    ];
    for (final preferred in preferredNames) {
      final normalized = preferred.trim().toLowerCase();
      if (normalized.isEmpty) continue;
      for (final model in models) {
        if (model.modelName.toLowerCase() == normalized ||
            model.modelKey.toLowerCase() == normalized) {
          return model;
        }
      }
    }
    return models.first;
  }

  void _applyLibTvModelProfile(
    LibTvModelSpec model, {
    bool resetParameters = false,
  }) {
    final profile = value.profile;
    if (profile == null) return;
    final changedModel = profile.model != model.modelName;
    final updated = profile.copyWith(
      model: model.modelName,
      parameters: resetParameters || changedModel
          ? _defaultLibTvParameters(model)
          : _mergeLibTvParameterDefaults(profile.parameters, model),
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertProfile(updated);
    value = value.copyWith(profile: updated);
  }

  Map<String, String> _defaultLibTvParameters(LibTvModelSpec model) {
    final modeType = _preferredLibTvModeType(model, imageCount: 1);
    final result = <String, String>{};
    if (modeType.isNotEmpty) result[_libTvModeTypeKey] = modeType;
    final count = _preferredLibTvCount(model);
    result[_libTvCountKey] = count;
    for (final parameter in model.parametersForMode(modeType)) {
      if (parameter.key == 'duration') continue;
      final defaultValue = _preferredLibTvParameterDefault(parameter);
      if (defaultValue.isNotEmpty) {
        result[_libTvStoredParameterKey(parameter.key)] = defaultValue;
      }
    }
    return result;
  }

  Map<String, String> _mergeLibTvParameterDefaults(
    Map<String, String> parameters,
    LibTvModelSpec model,
  ) {
    final defaults = _defaultLibTvParameters(model);
    return {
      ...defaults,
      for (final entry in parameters.entries)
        if (defaults.containsKey(entry.key)) entry.key: entry.value,
    };
  }

  String _preferredLibTvModeType(
    LibTvModelSpec model, {
    required int imageCount,
  }) {
    final modes = model.imageInputModeTypes;
    if (modes.isEmpty) return '';
    final priorities = imageCount <= 1
        ? const [
            'singleImage2video',
            'image2video',
            'mixed2video',
            'frames2video',
          ]
        : const [
            'frames2video',
            'image2video',
            'mixed2video',
            'singleImage2video',
          ];
    for (final mode in priorities) {
      if (!modes.contains(mode)) continue;
      final range = model.inputRangeForMode(mode);
      if (range == null ||
          (imageCount >= range.min && imageCount <= range.max)) {
        return mode;
      }
    }
    return '';
  }

  String _preferredLibTvCount(LibTvModelSpec model) {
    final options = model.countOptions;
    if (options.isEmpty || options.any((option) => option.value == '1')) {
      return '1';
    }
    return options.first.value;
  }

  String _preferredLibTvParameterDefault(LibTvModelParameterSpec parameter) {
    final preferred = switch (parameter.key) {
      'ratio' => projectAspectRatioLabel,
      'resolution' => '720p',
      _ => '',
    };
    if (preferred.isNotEmpty &&
        parameter.options.any((option) => option.value == preferred)) {
      return preferred;
    }
    if (parameter.defaultValue.isNotEmpty &&
        (parameter.options.isEmpty ||
            parameter.options.any(
              (option) => option.value == parameter.defaultValue,
            ))) {
      return parameter.defaultValue;
    }
    if (parameter.options.isNotEmpty) return parameter.options.first.value;
    if (parameter.isSwitch) return '1';
    return parameter.min == null ? '' : '${parameter.min}';
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
        parameterValue = _allowedDefault(
          argument,
          projectAspectRatioLabel,
          parameterValue,
        );
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

  static String _parameterLookupKey(String name) =>
      name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

  Map<String, String> _parametersForSubmission(
    Map<String, String> parameters, {
    required KlingModelSpec model,
    bool preferMultiShots = false,
  }) {
    final declaredParameters = {
      for (final argument in model.arguments)
        if (argument.name != 'prompt' && argument.name != 'duration')
          _parameterLookupKey(argument.name),
    };
    final adjusted = <String, String>{
      for (final entry in parameters.entries)
        if (declaredParameters.contains(_parameterLookupKey(entry.key)))
          entry.key: entry.value,
    };
    if (preferMultiShots && declaredParameters.contains('prefermultishots')) {
      adjusted['prefer_multi_shots'] = 'true';
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
          : _videoApiDefaultResolution,
      'steps':
          '${_normalizeMiniMaxSteps(parameters[_minimaxApiStepsKey] ?? parameters['steps'], fallback: _videoApiDefaultSteps)}',
    };
  }

  Map<String, String> _libTvParametersForSubmission(
    Map<String, String> parameters, {
    required int imageInputCount,
  }) {
    final model = value.libTvModel;
    if (model == null) {
      return {
        'modeType': 'mixed2video',
        'count': '1',
        'ratio': parameters[_libTvRatioKey] ?? projectAspectRatioLabel,
        'resolution': parameters[_libTvResolutionKey] ?? '720p',
        'enableSound': parameters[_libTvEnableSoundKey] ?? 'on',
        'search_enabled': parameters[_libTvSearchEnabledKey] ?? '1',
      };
    }
    final storedMode = parameters[_libTvModeTypeKey] ?? '';
    final storedRange = model.inputRangeForMode(storedMode);
    final storedModeFits =
        model.imageInputModeTypes.contains(storedMode) &&
        (storedRange == null ||
            (imageInputCount >= storedRange.min &&
                imageInputCount <= storedRange.max));
    final modeType = storedModeFits
        ? storedMode
        : _preferredLibTvModeType(model, imageCount: imageInputCount);
    if (modeType.isEmpty) return const {'modeType': ''};
    final result = <String, String>{
      'modeType': modeType,
      'count':
          libTvCountOptions.any(
            (option) => option.value == parameters[_libTvCountKey],
          )
          ? parameters[_libTvCountKey]!
          : _preferredLibTvCount(model),
    };
    for (final parameter in model.parametersForMode(modeType)) {
      if (parameter.key == 'duration') continue;
      final stored = parameters[_libTvStoredParameterKey(parameter.key)];
      final parameterValue =
          stored != null && _isValidLibTvParameterValue(parameter, stored)
          ? stored
          : _preferredLibTvParameterDefault(parameter);
      if (parameterValue.isNotEmpty) result[parameter.key] = parameterValue;
    }
    return result;
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
    final number = shotNumber > 0 ? shotNumber : 0;
    return File(
      p.join(
        directories.results.path,
        '镜头$number-v${version.clamp(1, 9999)}.mp4',
      ),
    );
  }

  int _outputShotNumberFor(ScriptShot shot) {
    final groups = ScriptShotGroup.group(value.shots);
    final index = groups.indexWhere(
      (group) => group.shots.any((item) => item.id == shot.id),
    );
    return index < 0 ? shot.shotNumber : index + 1;
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

  File generatedVideoFileFor(VideoGenerationTask task) {
    final path = task.localPath.trim();
    if (path.isEmpty) return File('');
    return _runtimeFile(path);
  }

  @override
  void dispose() {
    _disposed = true;
    _videoApiConfigRequestToken++;
    _killLoginProcess();
    _completeLoginCancelSignal();
    _shootingScriptController.removeListener(_handleSourcesChanged);
    _replicateController.removeListener(_handleSourcesChanged);
    _settingsController.removeListener(_handleSettingsChanged);
    _projectAspectController?.removeListener(_handleProjectAspectChanged);
    super.dispose();
  }
}

class _MiniMaxResolutionPreset {
  const _MiniMaxResolutionPreset(this.label, this.aspectRatio);

  final String label;
  final String aspectRatio;
}

class _GenerationImageReference {
  const _GenerationImageReference.asset({
    required this.path,
    required this.imageNumber,
    required this.asset,
  }) : shot = null;

  const _GenerationImageReference.sequenceFrame({
    required this.path,
    required this.imageNumber,
    required this.shot,
  }) : asset = null;

  final String path;
  final int imageNumber;
  final ScriptAsset? asset;
  final ScriptShot? shot;

  String get promptDescription {
    final asset = this.asset;
    if (asset == null) return _sequencePromptDescription;
    return '图片$imageNumber为${_assetTypeLabel(asset.type)}参考';
  }

  String get h3PromptDescription {
    final asset = this.asset;
    if (asset == null) return _sequenceH3PromptDescription;
    return '@图片$imageNumber是${_assetTypeLabel(asset.type)}资产参考';
  }

  String get _sequencePromptDescription {
    return '图片$imageNumber为组内顺序动作参考';
  }

  String get _sequenceH3PromptDescription {
    final shot = this.shot;
    if (shot == null) return '@图片$imageNumber是组内顺序动作参考';
    return '@图片$imageNumber是组内顺序动作参考';
  }

  static String _assetTypeLabel(ReplicateAssetType type) => switch (type) {
    ReplicateAssetType.character => '角色',
    ReplicateAssetType.product => '产品',
    ReplicateAssetType.scene => '场景',
    ReplicateAssetType.prop => '道具',
    ReplicateAssetType.video => '视频',
    ReplicateAssetType.audio => '音频',
    ReplicateAssetType.reference => '参考',
    ReplicateAssetType.other => '其他',
  };
}

const _minimaxApiAspectRatioKey = 'minimax_api_aspect_ratio';
const _minimaxApiResolutionKey = 'minimax_api_resolution';
const _minimaxApiStepsKey = 'minimax_api_steps';
const _libTvRatioKey = 'libtv_ratio';
const _libTvResolutionKey = 'libtv_resolution';
const _libTvEnableSoundKey = 'libtv_enable_sound';
const _libTvSearchEnabledKey = 'libtv_search_enabled';
const _libTvModeTypeKey = 'libtv_mode_type';
const _libTvCountKey = 'libtv_count';
const _fallbackLibTvAspectRatios = [
  'adaptive',
  '16:9',
  '4:3',
  '1:1',
  '3:4',
  '9:16',
  '21:9',
];
const _fallbackLibTvResolutions = ['480p', '720p'];

String _libTvStoredParameterKey(String key) => switch (key) {
  'ratio' => _libTvRatioKey,
  'resolution' => _libTvResolutionKey,
  'enableSound' => _libTvEnableSoundKey,
  'search_enabled' => _libTvSearchEnabledKey,
  _ => 'libtv_parameter_$key',
};

const _fallbackMiniMaxApiDefaultResolution = '0.2MP 16:9 - 608x352';
const _fallbackMiniMaxApiResolutionPresets = [
  _MiniMaxResolutionPreset('0.2MP 21:9 - 672x288', '21:9'),
  _MiniMaxResolutionPreset('0.3MP 21:9 - 896x384', '21:9'),
  _MiniMaxResolutionPreset('0.5MP 21:9 - 1120x480', '21:9'),
  _MiniMaxResolutionPreset('0.2MP 16:9 - 608x352', '16:9'),
  _MiniMaxResolutionPreset('0.3MP 16:9 - 736x416', '16:9'),
  _MiniMaxResolutionPreset('0.4MP 16:9 - 864x480', '16:9'),
  _MiniMaxResolutionPreset('0.5MP 16:9 - 960x544', '16:9'),
  _MiniMaxResolutionPreset('0.6MP 16:9 - 1056x608', '16:9'),
  _MiniMaxResolutionPreset('0.2MP 4:3 - 512x384', '4:3'),
  _MiniMaxResolutionPreset('0.3MP 4:3 - 640x480', '4:3'),
  _MiniMaxResolutionPreset('0.4MP 4:3 - 768x576', '4:3'),
  _MiniMaxResolutionPreset('Square 512x512', '1:1'),
  _MiniMaxResolutionPreset('0.2MP 3:4 - 384x512', '3:4'),
  _MiniMaxResolutionPreset('0.3MP 3:4 - 480x640', '3:4'),
  _MiniMaxResolutionPreset('0.4MP 3:4 - 576x768', '3:4'),
  _MiniMaxResolutionPreset('0.2MP 9:16 - 352x608', '9:16'),
  _MiniMaxResolutionPreset('0.3MP 9:16 - 416x736', '9:16'),
  _MiniMaxResolutionPreset('0.4MP 9:16 - 480x864', '9:16'),
];

String? _aspectRatioFromMiniMaxResolutionLabel(String resolution) {
  final normalized = resolution.trim();
  final ratioMatch = RegExp(
    r'(\d+(?:\.\d+)?):(\d+(?:\.\d+)?)',
  ).firstMatch(normalized);
  if (ratioMatch != null) {
    return '${ratioMatch.group(1)}:${ratioMatch.group(2)}';
  }
  if (normalized.toLowerCase().contains('square')) return '1:1';
  return null;
}

int _normalizeMiniMaxSteps(String? value, {int fallback = 12}) {
  final parsed = int.tryParse(value?.trim() ?? '') ?? fallback;
  return parsed.clamp(4, 30).toInt();
}

const _sentinel = Object();
const _loginCanceledSignal = Object();
