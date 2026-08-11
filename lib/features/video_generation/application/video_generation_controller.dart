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
import '../../shooting_script/data/shooting_script_workflow_repository.dart';
import '../../shooting_script/domain/script_shot_group.dart';
import '../../shooting_script/domain/shooting_script_models.dart';
import '../../shooting_script/domain/shooting_script_workflow_models.dart';
import '../../video_analysis/data/video_analysis_repository.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../data/cli_dependency_installer.dart';
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
      workflowRepository: ShootingScriptWorkflowRepository(database),
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
    this.replicatedImages = const [],
    this.environment,
    this.identity,
    this.account,
    this.libTvEnvironment,
    this.libTvAccount,
    this.libTvModel,
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
  final List<ReplicatedShotImage> replicatedImages;
  final KlingCliEnvironment? environment;
  final KlingIdentity? identity;
  final KlingAccount? account;
  final LibTvCliEnvironment? libTvEnvironment;
  final LibTvAccountInfo? libTvAccount;
  final LibTvModelSpec? libTvModel;
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
    Object? libTvEnvironment = _sentinel,
    Object? libTvAccount = _sentinel,
    Object? libTvModel = _sentinel,
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
    libTvModel: identical(libTvModel, _sentinel)
        ? this.libTvModel
        : libTvModel as LibTvModelSpec?,
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
    KlingCliResolver cliResolver = const KlingCliResolver(),
    KlingCliService cliService = const KlingCliService(),
    LibTvCliResolver libTvCliResolver = const LibTvCliResolver(),
    LibTvCliService libTvCliService = const LibTvCliService(),
    CliDependencyInstaller dependencyInstaller = const CliDependencyInstaller(),
    LibTvCliService Function(LibTvCliEnvironment environment)?
    libTvCliServiceFactory,
    MiniMaxVideoApiService? videoApiService,
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
       _loginAuthorizationTimeout = loginAuthorizationTimeout,
       _loginAuthorizationPollInterval = loginAuthorizationPollInterval,
       _uuid = uuid,
       super(const VideoGenerationState()) {
    _shootingScriptController.addListener(_handleSourcesChanged);
    _replicateController.addListener(_handleSourcesChanged);
    _settingsController.addListener(_handleSettingsChanged);
    final removedTaskCount = _removeMissingGeneratedVideoTaskRecords();
    _refreshData();
    if (removedTaskCount > 0) {
      value = value.copyWith(message: '已移除 $removedTaskCount 条本地成片已删除的生成记录');
    }
  }

  final VideoGenerationRepository _repository;
  final VideoAnalysisRepository _videoRepository;
  final ShootingScriptWorkflowRepository? _workflowRepository;
  final ShootingScriptController _shootingScriptController;
  final ReplicateController _replicateController;
  final WorkspaceDirectories _directories;
  final SettingsController _settingsController;
  final KlingCliResolver _cliResolver;
  KlingCliService _cliService;
  final LibTvCliResolver _libTvCliResolver;
  LibTvCliService _libTvCliService;
  final CliDependencyInstaller _dependencyInstaller;
  final LibTvCliService Function(LibTvCliEnvironment environment)
  _libTvCliServiceFactory;
  final MiniMaxVideoApiService _videoApiService;
  final Duration _loginAuthorizationTimeout;
  final Duration _loginAuthorizationPollInterval;
  final Uuid _uuid;
  KlingCliEnvironment? _cachedKlingEnvironment;
  KlingIdentity? _cachedKlingIdentity;
  KlingAccount? _cachedKlingAccount;
  LibTvCliEnvironment? _cachedLibTvEnvironment;
  LibTvAccountInfo? _cachedLibTvAccount;
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
        value = value.copyWith(
          libTvEnvironment: null,
          libTvAccount: null,
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
    final model = await _libTvCliService.model(
      AppSettings.defaultLibTvCliVideoGenerationModel,
    );
    final environment = value.libTvEnvironment;
    if (environment != null && environment.isReady) {
      _cachedLibTvEnvironment = environment;
    }
    _cachedLibTvAccount = account;
    _cachedLibTvModel = model;
    value = value.copyWith(
      libTvAccount: account,
      libTvModel: model,
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
      return seconds.round().clamp(4, 15).toDouble();
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
  }) {
    final script = value.selectedScript;
    if (script?.sourceVideoId == null) return null;
    final video = _videoRepository.getSourceVideo(script!.sourceVideoId!);
    if (video == null) return null;
    return const SourceVideoPreviewResolver().resolve(
      video: video,
      frames: _videoRepository.listVideoFrames(script.sourceVideoId!),
      shot: shot,
      endShot: endShot,
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
    final resolution = selectedVideoApiResolution;
    return _aspectRatioForMiniMaxResolution(resolution) ?? '16:9';
  }

  String get selectedVideoApiResolution {
    final parameters = value.profile?.parameters ?? const <String, String>{};
    final stored =
        parameters[_minimaxApiResolutionKey] ?? parameters['resolution'];
    if (_isMiniMaxResolution(stored)) return stored!;
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
    final normalized = _allowedMiniMaxAspectRatio(aspectRatio) ?? '16:9';
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

  List<String> get libTvAspectRatios => _libTvAspectRatios;

  List<String> get libTvResolutions => _libTvResolutions;

  String get selectedLibTvAspectRatio => _normalizedLibTvParameters()['ratio']!;

  String get selectedLibTvResolution =>
      _normalizedLibTvParameters()['resolution']!;

  bool get selectedLibTvSoundEnabled =>
      _normalizedLibTvParameters()['enableSound'] == 'on';

  bool get selectedLibTvSearchEnabled =>
      _normalizedLibTvParameters()['search_enabled'] == '1';

  void updateLibTvAspectRatio(String ratio) {
    if (!_libTvAspectRatios.contains(ratio)) return;
    updateParameter(_libTvRatioKey, ratio);
  }

  void updateLibTvResolution(String resolution) {
    if (!_libTvResolutions.contains(resolution)) return;
    updateParameter(_libTvResolutionKey, resolution);
  }

  void updateLibTvSoundEnabled(bool enabled) {
    updateParameter(_libTvEnableSoundKey, enabled ? 'on' : 'off');
  }

  void updateLibTvSearchEnabled(bool enabled) {
    updateParameter(_libTvSearchEnabledKey, enabled ? '1' : '0');
  }

  String get libTvParameterSummary {
    final parameters = _normalizedLibTvParameters();
    return '生成比例：${parameters['ratio']}\n'
        '分辨率：${parameters['resolution']}\n'
        '生成音频：${parameters['enableSound'] == 'off' ? '关闭' : '开启'}\n'
        '联网增强：${parameters['search_enabled'] == '0' ? '关闭' : '开启'}\n'
        '时长范围：4–15 秒';
  }

  Map<String, String> _normalizedLibTvParameters() =>
      _libTvParametersForSubmission(
        value.profile?.parameters ?? const <String, String>{},
      );

  Map<String, String> get selectedVideoApiSubmissionParameters =>
      _miniMaxApiParametersForSubmission(
        value.profile?.parameters ?? const <String, String>{},
      );

  VideoActionSequence actionSequenceFor(ScriptShot shot) {
    final sequences = const VideoActionSequenceResolver().resolve(value.shots);
    return sequences.firstWhere(
      (sequence) => sequence.contains(shot.id),
      orElse: () => VideoActionSequence([shot]),
    );
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
      final directories = await _generationDirectories();
      final file = await const VideoTimelineXmlExportService().export(
        script: script,
        shots: value.shots,
        tasks: value.tasks,
        fileForTask: generatedVideoFileFor,
        outputDirectory: directories.results,
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
      value = value.copyWith(errorMessage: '请先登录 LibTV 并确认 Seedance 2.0 模型可用');
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
          ? desiredDurationFor(shot).round().clamp(4, 15).toInt()
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
                ? activeVideoGenerationApiModel
                : profile!.model,
            parameters: usesVideoApi
                ? _miniMaxApiParametersForSubmission(
                    profile?.parameters ?? const <String, String>{},
                  )
                : usesLibTv
                ? _libTvParametersForSubmission(
                    profile?.parameters ?? const <String, String>{},
                  )
                : _parametersForSubmission(profile!.parameters, model: model!),
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

  void _handleSourcesChanged() => _refreshData();

  int _removeMissingGeneratedVideoTaskRecords() {
    final missingTasks = _repository
        .listTasks()
        .where(
          (task) =>
              (task.status == VideoGenerationTaskStatus.completed ||
                  task.status == VideoGenerationTaskStatus.partialCompleted) &&
              !generatedVideoFileFor(task).existsSync(),
        )
        .toList(growable: false);
    for (final task in missingTasks) {
      _repository.deleteTask(task.id);
    }
    return missingTasks.length;
  }

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
    final model = _cachedLibTvModel;
    if (environment == null ||
        !environment.isReady ||
        account == null ||
        model == null) {
      return false;
    }
    _libTvCliService = _libTvCliServiceFactory(environment);
    value = value.copyWith(
      libTvEnvironment: environment,
      libTvAccount: account,
      libTvModel: model,
      isLoadingEnvironment: false,
      message: 'LibTV 账号已连接',
      errorMessage: '',
    );
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
    final drafts = <String, VideoGenerationDraft>{};
    for (final shot in shooting.shots) {
      final sourcePrompt = shot.prompt;
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
        final updated = VideoGenerationDraft(
          id: existing?.id ?? _uuid.v4(),
          scriptId: script.id,
          shotId: shot.id,
          sourcePrompt: sourcePrompt,
          klingPrompt: klingPrompt,
          h3Prompt: h3Prompt,
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

  static String _parameterLookupKey(String name) =>
      name.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').toLowerCase();

  Map<String, String> _parametersForSubmission(
    Map<String, String> parameters, {
    required KlingModelSpec model,
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
    Map<String, String> parameters,
  ) {
    final ratio = parameters[_libTvRatioKey] ?? parameters['ratio'];
    final resolution =
        parameters[_libTvResolutionKey] ?? parameters['resolution'];
    final enableSound =
        parameters[_libTvEnableSoundKey] ?? parameters['enableSound'];
    final searchEnabled =
        parameters[_libTvSearchEnabledKey] ?? parameters['search_enabled'];
    return {
      'ratio': _libTvAspectRatios.contains(ratio) ? ratio! : '16:9',
      'resolution': _libTvResolutions.contains(resolution)
          ? resolution!
          : '720p',
      'enableSound': enableSound == 'off' ? 'off' : 'on',
      'search_enabled': searchEnabled == '0' ? '0' : '1',
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
    final name = asset.name.trim();
    return '图片$imageNumber为${_assetTypeLabel(asset.type)}参考'
        '${name.isEmpty ? '' : '（$name）'}';
  }

  String get h3PromptDescription {
    final asset = this.asset;
    if (asset == null) return _sequenceH3PromptDescription;
    final parts = [
      '@图片$imageNumber是${_assetTypeLabel(asset.type)}资产参考',
      if (asset.name.trim().isNotEmpty) '名称：${asset.name.trim()}',
      if (asset.description.trim().isNotEmpty) '说明：${asset.description.trim()}',
    ];
    return parts.join('，');
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
const _libTvAspectRatios = [
  'adaptive',
  '16:9',
  '4:3',
  '1:1',
  '3:4',
  '9:16',
  '21:9',
];
const _libTvResolutions = ['480p', '720p'];

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
