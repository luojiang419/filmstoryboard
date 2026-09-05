import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/database/app_database.dart';
import '../core/performance/performance_probe.dart';
import '../core/providers/app_providers.dart';
import '../core/widgets/collapsible_panel_shortcut_scope.dart';
import '../core/widgets/desktop_drop_target_scope.dart';
import '../core/widgets/value_listenable_selector.dart';
import '../core/widgets/retained_page.dart';
import '../features/exporter/presentation/exporter_page.dart';
import '../features/exporter/application/export_remote_source.dart';
import '../features/grid_cut/presentation/grid_cut_page.dart';
import '../features/onboarding/application/onboarding_controller.dart';
import '../features/onboarding/data/onboarding_repository.dart';
import '../features/onboarding/presentation/onboarding_overlay.dart';
import '../features/settings/application/settings_controller.dart';
import '../features/settings/application/settings_remote_source.dart';
import '../features/settings/domain/app_settings.dart';
import '../features/settings/presentation/settings_page.dart';
import '../features/shooting_script/presentation/shooting_script_page.dart';
import '../features/shooting_script/application/shooting_script_controller.dart';
import '../features/shooting_script/application/shooting_script_remote_source.dart';
import '../features/shooting_script/application/script_analysis_controller.dart';
import '../features/shooting_script/application/script_asset_binding_controller.dart';
import '../features/story_design/presentation/story_design_page.dart';
import '../features/remote_access/application/remote_storyboard_registry.dart';
import '../features/remote_access/application/remote_shooting_workflow_registry.dart';
import '../features/remote_access/application/remote_export_registry.dart';
import '../features/remote_access/application/remote_video_analysis_registry.dart';
import '../features/remote_access/application/remote_video_generation_registry.dart';
import '../features/remote_access/application/remote_settings_registry.dart';
import '../features/storyboard/application/storyboard_controller.dart';
import '../features/storyboard/application/storyboard_remote_source.dart';
import '../features/storyboard/application/storyboard_shooting_script_sync_controller.dart';
import '../features/storyboard/presentation/storyboard_page.dart';
import '../features/replicate/application/replicate_controller.dart';
import '../features/updater/application/updater_controller.dart';
import '../features/updater/domain/app_update_config.dart';
import '../features/video_analysis/presentation/video_analysis_page.dart';
import '../features/video_analysis/application/video_analysis_controller.dart';
import '../features/video_analysis/application/video_analysis_remote_source.dart';
import '../features/video_generation/application/video_generation_controller.dart';
import '../features/video_generation/application/video_generation_remote_source.dart';
import '../features/video_generation/presentation/video_generation_page.dart';
import 'window_title_bar.dart';

class AppShell extends ConsumerStatefulWidget {
  const AppShell({
    super.key,
    this.enableWindowControls = true,
    this.initialTabIndex = 0,
    this.projectName,
    this.onCloseProject,
  });

  final bool enableWindowControls;
  final int initialTabIndex;
  final String? projectName;
  final Future<void> Function()? onCloseProject;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  static const _selectedTabIndexKey = 'appShellSelectedTabIndex';
  static const _selectedTabIndexVersionKey = 'appShellSelectedTabIndexVersion';
  static const _selectedTabIndexVersion = 5;

  late int _tabIndex;
  final _visitedTabIndexes = <int>{};
  final _pages = <int, Widget>{};
  final _pageHostKey = GlobalKey();
  late final UpdaterController _updaterController;
  late final OnboardingController _onboardingController;
  late final StoryboardController _storyboardController;
  late final StoryboardRemoteSource _storyboardRemoteSource;
  late final RemoteStoryboardRegistry _remoteStoryboardRegistry;
  ShootingScriptRemoteSource? _shootingScriptRemoteSource;
  late final RemoteShootingWorkflowRegistry _remoteShootingWorkflowRegistry;
  VideoAnalysisRemoteSource? _videoAnalysisRemoteSource;
  late final RemoteVideoAnalysisRegistry _remoteVideoAnalysisRegistry;
  VideoGenerationRemoteSource? _videoGenerationRemoteSource;
  late final RemoteVideoGenerationRegistry _remoteVideoGenerationRegistry;
  late final ExportRemoteSource _exportRemoteSource;
  late final RemoteExportRegistry _remoteExportRegistry;
  late final StoryboardShootingScriptSyncController
  _storyboardScriptSyncController;
  late final SettingsController _settingsController;
  late final SettingsRemoteSource _settingsRemoteSource;
  late final RemoteSettingsRegistry _remoteSettingsRegistry;
  bool _updatePromptVisible = false;
  bool _assetNormalizationPromptVisible = false;
  bool _assetNormalizationDeferred = false;

  static const _tabs = <_ShellTab>[
    _ShellTab('设计分镜图', Icons.draw_rounded),
    _ShellTab('视频解析', Icons.video_file_rounded),
    _ShellTab('故事板', Icons.dashboard_customize_rounded),
    _ShellTab('影视制作', Icons.table_chart_rounded),
    _ShellTab('视频生成', Icons.movie_creation_outlined),
    _ShellTab('导出', Icons.ios_share_rounded),
    _ShellTab('设置', Icons.tune_rounded),
  ];

  @override
  void initState() {
    super.initState();
    _updaterController = ref.read(updaterControllerProvider);
    _updaterController.addListener(_handleUpdaterStateChanged);
    _onboardingController = OnboardingController(
      repository: OnboardingRepository(_globalDatabase()),
    )..addListener(_handleOnboardingChanged);
    _storyboardController = ref.read(storyboardControllerProvider)
      ..addListener(_handleAssetNormalizationStateChanged);
    _settingsController = ref.read(settingsControllerProvider);
    _storyboardRemoteSource = StoryboardRemoteSource(_storyboardController);
    _remoteStoryboardRegistry = ref.read(remoteStoryboardRegistryProvider)
      ..attach(_storyboardRemoteSource);
    _remoteShootingWorkflowRegistry = ref.read(
      remoteShootingWorkflowRegistryProvider,
    )..attachDeferred(_createShootingSource);
    _remoteVideoAnalysisRegistry = ref.read(remoteVideoAnalysisRegistryProvider)
      ..attachDeferred(_createAnalysisSource);
    _remoteVideoGenerationRegistry = ref.read(
      remoteVideoGenerationRegistryProvider,
    )..attachDeferred(_createGenerationSource);
    _settingsRemoteSource = SettingsRemoteSource(_settingsController);
    _remoteSettingsRegistry = ref.read(remoteSettingsRegistryProvider)
      ..attach(_settingsRemoteSource);
    _exportRemoteSource = ExportRemoteSource(
      storyboardController: _storyboardController,
      shootingScriptController: ref.read(shootingScriptControllerProvider),
      settingsController: ref.read(settingsControllerProvider),
      database: ref.read(appDatabaseProvider),
      directories: ref.read(projectDirectoriesProvider),
    );
    _remoteExportRegistry = ref.read(remoteExportRegistryProvider)
      ..attach(_exportRemoteSource);
    _storyboardScriptSyncController = StoryboardShootingScriptSyncController(
      storyboardController: _storyboardController,
      shootingScriptController: ref.read(shootingScriptControllerProvider),
    );
    _tabIndex =
        _loadSavedTabIndex() ??
        widget.initialTabIndex.clamp(0, _tabs.length - 1).toInt();
    _visitedTabIndexes.add(_tabIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final resumable = ref
          .read(appDatabaseProvider)
          .selectRows(
            "SELECT 1 FROM video_generation_tasks WHERE status IN "
            "('submitting', 'queued', 'running', 'timedOut') LIMIT 1;",
          );
      if (resumable.isNotEmpty) _remoteVideoGenerationRegistry.source;
      if (_onboardingController.shouldStartAutomatically) {
        _onboardingController.start(originTabIndex: _tabIndex, automatic: true);
      }
      _updaterController.beginStartupFlow();
      _handleAssetNormalizationStateChanged();
      _handleUpdaterStateChanged();
    });
  }

  @override
  void dispose() {
    _onboardingController.removeListener(_handleOnboardingChanged);
    _onboardingController.dispose();
    _storyboardController.removeListener(_handleAssetNormalizationStateChanged);
    _remoteStoryboardRegistry.detach(source: _storyboardRemoteSource);
    _storyboardRemoteSource.dispose();
    _remoteShootingWorkflowRegistry.detach(factory: _createShootingSource);
    _shootingScriptRemoteSource?.dispose();
    _remoteVideoAnalysisRegistry.detach(factory: _createAnalysisSource);
    _remoteVideoGenerationRegistry.detach(factory: _createGenerationSource);
    _videoGenerationRemoteSource?.dispose();
    _remoteSettingsRegistry.detach(source: _settingsRemoteSource);
    _settingsRemoteSource.dispose();
    _remoteExportRegistry.detach(source: _exportRemoteSource);
    _exportRemoteSource.dispose();
    _storyboardScriptSyncController.dispose();
    _updaterController.removeListener(_handleUpdaterStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    PerformanceProbe.shared.countBuild('app_shell');
    return ValueListenableSelector<AppSettings, AppNavigationPosition>(
      valueListenable: _settingsController,
      selector: (settings) => settings.navigationPosition,
      builder: (context, navigationPosition, _) {
        final scheme = Theme.of(context).colorScheme;
        final content = Scaffold(
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.surface,
                  scheme.surfaceContainerHighest.withValues(alpha: 0.72),
                  scheme.surface,
                ],
              ),
            ),
            child: Column(
              children: [
                WindowTitleBar(
                  enableWindowControls: widget.enableWindowControls,
                  title: widget.projectName == null
                      ? null
                      : '${AppUpdateConfig.windowTitle} — ${widget.projectName}',
                  actions: [_OnboardingHelpAction(onPressed: _showOnboarding)],
                ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      navigationPosition == AppNavigationPosition.left
                          ? Row(
                              children: [
                                _SideTabs(
                                  tabs: _tabs,
                                  selectedIndex: _tabIndex,
                                  onSelected: _selectTab,
                                  projectName: widget.projectName,
                                  onCloseProject: widget.onCloseProject,
                                ),
                                Expanded(child: _buildPageSwitcher()),
                              ],
                            )
                          : Column(
                              children: [
                                Expanded(child: _buildPageSwitcher()),
                                _BottomTabs(
                                  tabs: _tabs,
                                  selectedIndex: _tabIndex,
                                  onSelected: _selectTab,
                                  projectName: widget.projectName,
                                  onCloseProject: widget.onCloseProject,
                                ),
                              ],
                            ),
                      if (_onboardingController.visible)
                        OnboardingOverlay(controller: _onboardingController),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
        return CollapsiblePanelShortcutScope(child: content);
      },
    );
  }

  Widget _buildPageSwitcher() {
    return Stack(
      key: _pageHostKey,
      fit: StackFit.expand,
      children: [
        for (final index in _visitedTabIndexes.toList()..sort())
          Positioned.fill(
            key: ValueKey('app-shell-page-$index'),
            child: DesktopDropTargetScope(
              enabled: index == _tabIndex,
              child: RetainedPage(
                active: index == _tabIndex,
                child: _pages.putIfAbsent(index, () => _buildPage(index)),
              ),
            ),
          ),
      ],
    );
  }

  ShootingScriptRemoteSource _createShootingSource() =>
      _shootingScriptRemoteSource ??= ShootingScriptRemoteSource(
        replicateController: ref.read(replicateControllerProvider),
        analysisController: ref.read(scriptAnalysisControllerProvider),
        assetBindingController: ref.read(scriptAssetBindingControllerProvider),
      );

  VideoAnalysisRemoteSource _createAnalysisSource() =>
      _videoAnalysisRemoteSource ??= VideoAnalysisRemoteSource(
        ref.read(videoAnalysisControllerProvider),
      );

  VideoGenerationRemoteSource _createGenerationSource() =>
      _videoGenerationRemoteSource ??= VideoGenerationRemoteSource(
        ref.read(videoGenerationControllerProvider),
      );

  Widget _buildPage(int index) {
    // Attach lightweight events as soon as a desktop module is visited. Remote
    // requests use the same deferred factory, so both paths share controllers.
    if (index == 1) _remoteVideoAnalysisRegistry.source;
    if (index == 3) _remoteShootingWorkflowRegistry.source;
    if (index == 4) _remoteVideoGenerationRegistry.source;
    return switch (index) {
      0 => StoryDesignPage(onOpenGridCutPage: _showLegacyGridCutPage),
      1 => VideoAnalysisPage(onOpenStoryboard: () => _selectTab(2)),
      2 => const StoryboardPage(),
      3 => const ShootingScriptPage(),
      4 => const VideoGenerationPage(),
      5 => const ExporterPage(),
      _ => const SettingsPage(),
    };
  }

  int? _loadSavedTabIndex() {
    try {
      final raw = ref
          .read(appDatabaseProvider)
          .getSetting(_selectedTabIndexKey);
      final index = int.tryParse(raw ?? '');
      if (index == null) {
        return null;
      }
      final version = ref
          .read(appDatabaseProvider)
          .getSetting(_selectedTabIndexVersionKey);
      final migratedIndex = _migrateSavedTabIndex(index, version);
      final clamped = migratedIndex.clamp(0, _tabs.length - 1).toInt();
      if (version != '$_selectedTabIndexVersion') {
        ref
            .read(appDatabaseProvider)
            .setSetting(_selectedTabIndexKey, clamped.toString());
        ref
            .read(appDatabaseProvider)
            .setSetting(
              _selectedTabIndexVersionKey,
              _selectedTabIndexVersion.toString(),
            );
      }
      return clamped;
    } catch (_) {
      return null;
    }
  }

  int _migrateSavedTabIndex(int index, String? version) {
    if (version == '$_selectedTabIndexVersion') {
      return index;
    }
    final version4Index = switch (version) {
      '4' => index,
      '3' => switch (index) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 || 4 => 3,
        5 => 4,
        _ => 5,
      },
      '2' => switch (index) {
        0 => 0,
        1 => 1,
        2 => 2,
        3 => 4,
        _ => 5,
      },
      _ => switch (index) {
        0 => 1,
        1 => 2,
        2 => 4,
        _ => 5,
      },
    };
    return version4Index >= 4 ? version4Index + 1 : version4Index;
  }

  AppDatabase _globalDatabase() {
    try {
      return ref.read(globalDatabaseProvider);
    } catch (_) {
      // 独立组件测试与预览可能只注入工作区数据库；生产环境始终使用全局数据库。
      return ref.read(appDatabaseProvider);
    }
  }

  void _selectTab(int index) {
    _setTabIndex(index, persist: true);
  }

  void _setTabIndex(int index, {required bool persist}) {
    final nextIndex = index.clamp(0, _tabs.length - 1).toInt();
    if (_tabIndex == nextIndex) {
      return;
    }
    setState(() {
      _tabIndex = nextIndex;
      _visitedTabIndexes.add(nextIndex);
    });
    if (!persist) {
      return;
    }
    try {
      ref
          .read(appDatabaseProvider)
          .setSetting(_selectedTabIndexKey, nextIndex.toString());
      ref
          .read(appDatabaseProvider)
          .setSetting(
            _selectedTabIndexVersionKey,
            _selectedTabIndexVersion.toString(),
          );
    } catch (_) {
      // 测试或预览环境可能没有注入数据库，生产环境会正常保存。
    }
  }

  void _showOnboarding() {
    _onboardingController.start(originTabIndex: _tabIndex);
  }

  Future<void> _showLegacyGridCutPage() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('图片多宫格裁切（兼容工具）'),
            leading: IconButton(
              key: const ValueKey('close-legacy-grid-cut'),
              onPressed: () => Navigator.of(dialogContext).pop(),
              icon: const Icon(Icons.close_rounded),
              tooltip: '返回设计分镜图',
            ),
          ),
          body: const GridCutPage(),
        ),
      ),
    );
  }

  void _handleOnboardingChanged() {
    if (!mounted) {
      return;
    }
    final requestedTabIndex = _onboardingController.visible
        ? _onboardingController.currentStep.tabIndex
        : _onboardingController.takeExitTabIndex();
    if (requestedTabIndex != null && requestedTabIndex != _tabIndex) {
      _setTabIndex(requestedTabIndex, persist: false);
    } else {
      setState(() {});
    }
    if (!_onboardingController.visible) {
      _handleAssetNormalizationStateChanged();
      _handleUpdaterStateChanged();
    }
  }

  void _handleAssetNormalizationStateChanged() {
    if (!mounted ||
        _assetNormalizationPromptVisible ||
        _assetNormalizationDeferred ||
        _updatePromptVisible ||
        _onboardingController.visible ||
        !_storyboardController.value.assetNormalizationRequired) {
      return;
    }
    _assetNormalizationPromptVisible = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showAssetNormalizationDialog());
    });
  }

  void _handleUpdaterStateChanged() {
    if (!mounted ||
        _updatePromptVisible ||
        _assetNormalizationPromptVisible ||
        (_storyboardController.value.assetNormalizationRequired &&
            !_assetNormalizationDeferred) ||
        _onboardingController.visible) {
      return;
    }
    if (!_updaterController.shouldShowReadyPrompt) {
      return;
    }
    _updatePromptVisible = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_showUpdateReadyDialog());
    });
  }

  Future<void> _showUpdateReadyDialog() async {
    try {
      if (!mounted ||
          _onboardingController.visible ||
          !_updaterController.shouldShowReadyPrompt) {
        return;
      }
      final versionTag = _updaterController.value.readyVersionTag;
      if (versionTag == null) {
        return;
      }
      final action = await showDialog<_UpdateReadyAction>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          return AlertDialog(
            icon: const Icon(Icons.system_update_alt_rounded),
            title: const Text('更新已下载完成'),
            content: Text('新版本 $versionTag 已准备好。可以现在更新并重启故事板，也可以安排到下次启动时更新。'),
            actions: [
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop(_UpdateReadyAction.nextStartup);
                },
                icon: const Icon(Icons.schedule_rounded),
                label: const Text('下次启动更新'),
              ),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(context).pop(_UpdateReadyAction.installNow);
                },
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('立即更新'),
              ),
            ],
          );
        },
      );
      if (!mounted) {
        return;
      }
      switch (action) {
        case _UpdateReadyAction.installNow:
          await _updaterController.installPendingUpdateNow();
        case _UpdateReadyAction.nextStartup:
          _updaterController.installPendingUpdateOnNextStartup();
        case null:
          _updaterController.installPendingUpdateOnNextStartup();
      }
    } finally {
      _updatePromptVisible = false;
      if (mounted) {
        _handleAssetNormalizationStateChanged();
        if (_updaterController.shouldShowReadyPrompt) {
          _handleUpdaterStateChanged();
        }
      }
    }
  }

  Future<void> _showAssetNormalizationDialog() async {
    var normalizing = false;
    try {
      if (!mounted ||
          _onboardingController.visible ||
          !_storyboardController.value.assetNormalizationRequired) {
        return;
      }
      final state = _storyboardController.value;
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                key: const ValueKey('legacy-asset-normalization-dialog'),
                icon: const Icon(Icons.folder_copy_outlined),
                title: const Text('归纳旧工程图片'),
                content: SizedBox(
                  width: 520,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '检测到旧工程中存在分散保存的图片。归纳后会同步更新 DATA 数据库和所有画板引用，图片仍可正常显示。',
                      ),
                      const SizedBox(height: 12),
                      Text('AI 修改：${state.legacyAiEditedImageCount} 张'),
                      Text('手动替换：${state.legacyManualReplacementImageCount} 张'),
                      const SizedBox(height: 12),
                      const Text(
                        '图片将分别统一保存到“画板名称-AI修改”和“画板名称-手动替换”目录，并使用连续序号命名。',
                      ),
                      if (normalizing) ...[
                        const SizedBox(height: 18),
                        const Row(
                          children: [
                            SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(child: Text('正在归纳并校验画板引用…')),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    key: const ValueKey('legacy-asset-normalization-later'),
                    onPressed: normalizing
                        ? null
                        : () => Navigator.of(dialogContext).pop(false),
                    child: const Text('稍后处理'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('legacy-asset-normalization-now'),
                    onPressed: normalizing
                        ? null
                        : () async {
                            setDialogState(() => normalizing = true);
                            final success = await _storyboardController
                                .normalizeLegacyReplacementAssets();
                            if (dialogContext.mounted) {
                              Navigator.of(dialogContext).pop(success);
                            }
                          },
                    icon: const Icon(Icons.auto_fix_high_rounded),
                    label: const Text('立即归纳'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (!mounted) {
        return;
      }
      if (result != true) {
        _assetNormalizationDeferred = true;
      }
    } finally {
      _assetNormalizationPromptVisible = false;
      if (mounted) {
        _handleUpdaterStateChanged();
      }
    }
  }
}

enum _UpdateReadyAction { installNow, nextStartup }

class _OnboardingHelpAction extends StatelessWidget {
  const _OnboardingHelpAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      key: const ValueKey('onboarding-help-action'),
      height: 42,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '查看使用教程',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.arrow_forward_rounded,
            size: 16,
            color: scheme.onSurfaceVariant,
          ),
          IconButton(
            key: const ValueKey('show-onboarding-help'),
            onPressed: onPressed,
            tooltip: '新手引导',
            icon: const Icon(Icons.help_outline_rounded),
          ),
        ],
      ),
    );
  }
}

class _BottomTabs extends StatelessWidget {
  const _BottomTabs({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    this.projectName,
    this.onCloseProject,
  });

  final List<_ShellTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final String? projectName;
  final Future<void> Function()? onCloseProject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasProjectEntry = projectName != null || onCloseProject != null;
    final tabsWidget = Container(
      key: const ValueKey('app-shell-bottom-tabs'),
      constraints: const BoxConstraints(maxWidth: 1240),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.34),
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.1),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 6,
        runSpacing: 6,
        children: [
          if (hasProjectEntry)
            _ProjectShortcut(
              projectName: projectName,
              onCloseProject: onCloseProject,
            ),
          for (var i = 0; i < tabs.length; i++)
            _TabButton(
              tab: tabs[i],
              selected: i == selectedIndex,
              onTap: () => onSelected(i),
            ),
        ],
      ),
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Center(child: tabsWidget),
    );
  }
}

class _SideTabs extends StatelessWidget {
  const _SideTabs({
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
    this.projectName,
    this.onCloseProject,
  });

  final List<_ShellTab> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final String? projectName;
  final Future<void> Function()? onCloseProject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasProjectEntry = projectName != null || onCloseProject != null;
    return Container(
      key: const ValueKey('app-shell-left-tabs'),
      width: 216,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: 0.94),
        border: Border(
          right: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.42),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasProjectEntry) ...[
            _ProjectShortcut(
              projectName: projectName,
              onCloseProject: onCloseProject,
            ),
            const SizedBox(height: 12),
          ],
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < tabs.length; i++) ...[
                    _TabButton(
                      tab: tabs[i],
                      selected: i == selectedIndex,
                      onTap: () => onSelected(i),
                      expand: true,
                    ),
                    if (i != tabs.length - 1) const SizedBox(height: 6),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectShortcut extends StatelessWidget {
  const _ProjectShortcut({this.projectName, this.onCloseProject});

  final String? projectName;
  final Future<void> Function()? onCloseProject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = projectName ?? '返回首页';
    return SizedBox(
      height: 40,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.72),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: scheme.outlineVariant.withValues(alpha: 0.32),
          ),
        ),
        child: InkWell(
          key: const ValueKey('close-project-to-home'),
          borderRadius: BorderRadius.circular(10),
          onTap: onCloseProject == null ? null : () => onCloseProject!(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.home_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.selected,
    required this.onTap,
    this.expand = false,
  });

  final _ShellTab tab;
  final bool selected;
  final VoidCallback onTap;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tab.label,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        key: ValueKey('app-shell-tab-${tab.label}'),
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          width: expand ? double.infinity : null,
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: selected
                ? scheme.primaryContainer.withValues(alpha: 0.9)
                : Colors.transparent,
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: 0.32)
                  : scheme.outlineVariant.withValues(alpha: 0.28),
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.14),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Icon(
                tab.icon,
                size: 18,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                tab.label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShellTab {
  const _ShellTab(this.label, this.icon);

  final String label;
  final IconData icon;
}
