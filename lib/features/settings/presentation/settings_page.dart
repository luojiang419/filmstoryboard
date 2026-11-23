import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers/app_providers.dart';
import '../../projects/application/project_workspace_controller.dart';
import '../../remote_access/domain/remote_auth_models.dart';
import '../../storyboard/domain/image_generation_model_catalog.dart';
import '../../storyboard/presentation/widgets/image_generation_model_selector.dart';
import '../../updater/domain/app_update_config.dart';
import '../../updater/domain/update_models.dart';
import '../application/settings_controller.dart';
import '../domain/app_settings.dart';
import '../domain/image_generation_api_config.dart';
import '../domain/video_generation_api_config.dart';
import '../domain/vision_api_config.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

enum _SettingsSection {
  appearance,
  projects,
  remoteAccess,
  exportDirectory,
  storyboardExport,
  visionApi,
  analysisDimensions,
  videoAnalysis,
  promptDefaults,
  imageGenerationApi,
  videoGenerationApi,
  plugins,
  updater,
  dataDirectories,
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final SettingsController _settingsController;
  late final TextEditingController _exportPathController;
  late final TextEditingController _ffmpegExecutableController;
  late final TextEditingController _ffprobeExecutableController;
  late final TextEditingController _videoFrameIntervalController;
  late final TextEditingController _videoSceneThresholdController;
  late final TextEditingController _videoMinimumSharpnessController;
  late final TextEditingController _videoPreviewPaddingController;
  late final TextEditingController _replicateGlobalStyleController;
  late final TextEditingController _replicateConstraintsController;
  late final TextEditingController _updateManualProxyUrlController;
  late VideoFrameExtractionStrategy _videoExtractionStrategy;
  _SettingsSection _selectedSection = _SettingsSection.appearance;
  bool _isInstallingResolvePlugin = false;
  bool? _resolvePluginInstallSucceeded;
  String? _resolvePluginInstallMessage;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(settingsControllerProvider);
    _settingsController = controller;
    _exportPathController = TextEditingController(
      text: controller.value.exportDirectory,
    );
    _ffmpegExecutableController = TextEditingController(
      text: controller.value.ffmpegExecutable,
    );
    _ffprobeExecutableController = TextEditingController(
      text: controller.value.ffprobeExecutable,
    );
    _videoFrameIntervalController = TextEditingController(
      text: controller.value.videoFrameIntervalSeconds.toStringAsFixed(2),
    );
    _videoSceneThresholdController = TextEditingController(
      text: controller.value.videoSceneThreshold.toStringAsFixed(2),
    );
    _videoMinimumSharpnessController = TextEditingController(
      text: controller.value.videoMinimumSharpness.toStringAsFixed(2),
    );
    _videoPreviewPaddingController = TextEditingController(
      text: controller.value.videoPreviewPaddingSeconds.toStringAsFixed(2),
    );
    _replicateGlobalStyleController = TextEditingController(
      text: controller.value.replicateDefaultGlobalStyle,
    );
    _replicateConstraintsController = TextEditingController(
      text: controller.value.replicateDefaultConstraints,
    );
    _videoExtractionStrategy = controller.value.videoFrameExtractionStrategy;
    _updateManualProxyUrlController = TextEditingController(
      text: controller.value.updateManualProxyUrl,
    );
    controller.addListener(_syncFromSettings);
  }

  @override
  void dispose() {
    _settingsController.removeListener(_syncFromSettings);
    _exportPathController.dispose();
    _ffmpegExecutableController.dispose();
    _ffprobeExecutableController.dispose();
    _videoFrameIntervalController.dispose();
    _videoSceneThresholdController.dispose();
    _videoMinimumSharpnessController.dispose();
    _videoPreviewPaddingController.dispose();
    _replicateGlobalStyleController.dispose();
    _replicateConstraintsController.dispose();
    _updateManualProxyUrlController.dispose();
    super.dispose();
  }

  void _syncFromSettings() {
    final settings = ref.read(settingsControllerProvider).value;
    if (_exportPathController.text != settings.exportDirectory) {
      _exportPathController.text = settings.exportDirectory;
    }
    if (_ffmpegExecutableController.text != settings.ffmpegExecutable) {
      _ffmpegExecutableController.text = settings.ffmpegExecutable;
    }
    if (_ffprobeExecutableController.text != settings.ffprobeExecutable) {
      _ffprobeExecutableController.text = settings.ffprobeExecutable;
    }
    final frameInterval = settings.videoFrameIntervalSeconds.toStringAsFixed(2);
    if (_videoFrameIntervalController.text != frameInterval) {
      _videoFrameIntervalController.text = frameInterval;
    }
    final sceneThreshold = settings.videoSceneThreshold.toStringAsFixed(2);
    if (_videoSceneThresholdController.text != sceneThreshold) {
      _videoSceneThresholdController.text = sceneThreshold;
    }
    final minimumSharpness = settings.videoMinimumSharpness.toStringAsFixed(2);
    if (_videoMinimumSharpnessController.text != minimumSharpness) {
      _videoMinimumSharpnessController.text = minimumSharpness;
    }
    final previewPadding = settings.videoPreviewPaddingSeconds.toStringAsFixed(
      2,
    );
    if (_videoPreviewPaddingController.text != previewPadding) {
      _videoPreviewPaddingController.text = previewPadding;
    }
    if (_replicateGlobalStyleController.text !=
        settings.replicateDefaultGlobalStyle) {
      _replicateGlobalStyleController.text =
          settings.replicateDefaultGlobalStyle;
    }
    if (_replicateConstraintsController.text !=
        settings.replicateDefaultConstraints) {
      _replicateConstraintsController.text =
          settings.replicateDefaultConstraints;
    }
    _videoExtractionStrategy = settings.videoFrameExtractionStrategy;
    if (_updateManualProxyUrlController.text != settings.updateManualProxyUrl) {
      _updateManualProxyUrlController.text = settings.updateManualProxyUrl;
    }
  }

  Future<void> _saveVideoAnalysisSettings(SettingsController controller) async {
    await controller.setVideoAnalysisSettings(
      ffmpegExecutable: _ffmpegExecutableController.text,
      ffprobeExecutable: _ffprobeExecutableController.text,
      extractionStrategy: _videoExtractionStrategy,
      frameIntervalSeconds:
          double.tryParse(_videoFrameIntervalController.text) ?? 1,
      sceneThreshold:
          double.tryParse(_videoSceneThresholdController.text) ?? 0.3,
      minimumSharpness:
          double.tryParse(_videoMinimumSharpnessController.text) ?? 0.08,
      previewPaddingSeconds:
          double.tryParse(_videoPreviewPaddingController.text) ?? 1.5,
      thinkingEnabled: controller.value.videoAnalysisThinkingEnabled,
    );
  }

  Future<void> _saveUpdateSettings(SettingsController controller) async {
    await controller.setUpdateManualProxyUrl(
      _updateManualProxyUrlController.text,
    );
  }

  Future<void> _installResolvePlugin() async {
    if (_isInstallingResolvePlugin) return;
    setState(() {
      _isInstallingResolvePlugin = true;
      _resolvePluginInstallSucceeded = null;
      _resolvePluginInstallMessage = '正在请求管理员权限并安装插件…';
    });

    late final String message;
    late final bool succeeded;
    try {
      final result = await ref.read(resolvePluginInstallerProvider).install();
      message = result.message;
      succeeded = true;
    } catch (error) {
      message = '$error';
      succeeded = false;
    }
    if (!mounted) return;

    setState(() {
      _isInstallingResolvePlugin = false;
      _resolvePluginInstallSucceeded = succeeded;
      _resolvePluginInstallMessage = message;
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  AppDatabase get _globalSettingsDatabase {
    try {
      return ref.read(globalDatabaseProvider);
    } catch (_) {
      return ref.read(appDatabaseProvider);
    }
  }

  bool get _showWelcomeOnStartup =>
      _globalSettingsDatabase.getSetting(
        ProjectWorkspaceController.showWelcomeSettingKey,
      ) !=
      'false';

  String _defaultProjectRoot(String fallback) {
    final saved = _globalSettingsDatabase.getSetting(
      ProjectWorkspaceController.defaultProjectRootSettingKey,
    );
    return saved == null || saved.trim().isEmpty ? fallback : saved.trim();
  }

  void _setShowWelcomeOnStartup(bool value) {
    _globalSettingsDatabase.setSetting(
      ProjectWorkspaceController.showWelcomeSettingKey,
      value.toString(),
    );
    setState(() {});
  }

  Future<void> _pickDefaultProjectRoot() async {
    final directories = ref.read(appDirectoriesProvider);
    final current = _defaultProjectRoot(directories.projects.path);
    final path = await getDirectoryPath(
      initialDirectory: current,
      confirmButtonText: '选择默认工程目录',
    );
    if (path == null) {
      return;
    }
    try {
      final directory = Directory(path);
      await directory.create(recursive: true);
      final probe = File(
        '${directory.path}${Platform.pathSeparator}.storyboard-write-test',
      );
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      _globalSettingsDatabase.setSetting(
        ProjectWorkspaceController.defaultProjectRootSettingKey,
        directory.absolute.path,
      );
      if (mounted) {
        setState(() {});
      }
    } catch (_) {}
  }

  void _resetDefaultProjectRoot() {
    final directories = ref.read(appDirectoriesProvider);
    _globalSettingsDatabase.setSetting(
      ProjectWorkspaceController.defaultProjectRootSettingKey,
      directories.projects.path,
    );
    setState(() {});
  }

  bool _sectionSelected(_SettingsSection section) {
    return _selectedSection == section;
  }

  void _selectSection(_SettingsSection section) {
    if (_selectedSection == section) return;
    setState(() => _selectedSection = section);
  }

  @override
  Widget build(BuildContext context) {
    final directories = ref.watch(appDirectoriesProvider);
    final settingsController = ref.watch(settingsControllerProvider);
    final updaterController = ref.watch(updaterControllerProvider);
    final scheme = Theme.of(context).colorScheme;

    return ValueListenableBuilder(
      valueListenable: settingsController,
      builder: (context, settings, _) {
        return Row(
          children: [
            SizedBox(
              width: 224,
              child: _SettingsNavigation(
                selectedSection: _selectedSection,
                onSelected: _selectSection,
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.48),
            ),
            Expanded(
              child: ListView(
                key: const ValueKey('settings-operation-area'),
                padding: const EdgeInsets.all(20),
                children: <Widget>[
                  if (_sectionSelected(_SettingsSection.appearance))
                    _Section(
                      title: '外观',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '主题',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          SegmentedButton<AppThemePreference>(
                            segments: [
                              for (final preference
                                  in AppThemePreference.values)
                                ButtonSegment(
                                  value: preference,
                                  label: Text(preference.label),
                                  icon: Icon(switch (preference) {
                                    AppThemePreference.system =>
                                      Icons.brightness_auto_rounded,
                                    AppThemePreference.light =>
                                      Icons.light_mode_rounded,
                                    AppThemePreference.dark =>
                                      Icons.dark_mode_rounded,
                                  }),
                                ),
                            ],
                            selected: {settings.themePreference},
                            onSelectionChanged: (selection) {
                              settingsController.setThemePreference(
                                selection.first,
                              );
                            },
                          ),
                          const SizedBox(height: 18),
                          Text(
                            '功能菜单位置',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '切换后立即生效，下次启动会继续使用当前布局。',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 8),
                          SegmentedButton<AppNavigationPosition>(
                            key: const ValueKey('navigation-position-selector'),
                            segments: const [
                              ButtonSegment(
                                value: AppNavigationPosition.bottom,
                                label: Text('底部'),
                                icon: Icon(Icons.vertical_align_bottom_rounded),
                              ),
                              ButtonSegment(
                                value: AppNavigationPosition.left,
                                label: Text('左侧'),
                                icon: Icon(Icons.vertical_align_center_rounded),
                              ),
                            ],
                            selected: {settings.navigationPosition},
                            onSelectionChanged: (selection) {
                              settingsController.setNavigationPosition(
                                selection.first,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '工程与启动',
                    visible: _sectionSelected(_SettingsSection.projects),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('启动时显示欢迎页'),
                          subtitle: const Text('关闭后，软件下次启动将直接进入工程首页。'),
                          value: _showWelcomeOnStartup,
                          onChanged: _setShowWelcomeOnStartup,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '默认工程目录',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _defaultProjectRoot(directories.projects.path),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            TextButton.icon(
                              onPressed: _pickDefaultProjectRoot,
                              icon: const Icon(Icons.folder_open_rounded),
                              label: const Text('更改'),
                            ),
                            TextButton(
                              onPressed: _resetDefaultProjectRoot,
                              child: const Text('恢复默认'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text('默认位置为软件 data/project；不可写时请改用拥有写权限的目录。'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '导演远程访问',
                    visible: _sectionSelected(_SettingsSection.remoteAccess),
                    child: _sectionSelected(_SettingsSection.remoteAccess)
                        ? const _RemoteAccessSettingsPanel()
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '导出文件夹',
                    visible: _sectionSelected(_SettingsSection.exportDirectory),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _exportPathController,
                          decoration: const InputDecoration(
                            labelText: '默认导出路径',
                            prefixIcon: Icon(Icons.folder_open_rounded),
                          ),
                          onSubmitted: settingsController.setExportDirectory,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              onPressed: () async {
                                final path = await getDirectoryPath(
                                  initialDirectory: settings.exportDirectory,
                                );
                                if (path != null) {
                                  await settingsController.setExportDirectory(
                                    path,
                                  );
                                }
                              },
                              icon: const Icon(Icons.folder_rounded),
                              label: const Text('选择文件夹'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  settingsController.setExportDirectory(
                                    _exportPathController.text,
                                  ),
                              icon: const Icon(Icons.save_rounded),
                              label: const Text('保存路径'),
                            ),
                            TextButton.icon(
                              onPressed: settingsController.resetToDefaults,
                              icon: const Icon(
                                Icons.settings_backup_restore_rounded,
                              ),
                              label: const Text('恢复默认'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '故事板导出',
                    visible: _sectionSelected(
                      _SettingsSection.storyboardExport,
                    ),
                    child: SwitchListTile(
                      value: settings.storyboardSummaryPageEnabled,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('故事板内容页'),
                      subtitle: const Text('开启后导出时附带自动归纳的大纲、内容、场景和道具页'),
                      onChanged:
                          settingsController.setStoryboardSummaryPageEnabled,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '视觉模型 API',
                    visible: _sectionSelected(_SettingsSection.visionApi),
                    child: Column(
                      children: [
                        _VisionApiConfigSection(
                          configs: settings.visionApiConfigs,
                          activeId: settings.activeVisionApiConfigId,
                          onSelect: settingsController.setActiveVisionApiConfig,
                          onSave: settingsController.saveVisionApiConfig,
                          onDelete: settingsController.deleteVisionApiConfig,
                          onMaxRequestsPerMinuteChanged: settingsController
                              .setVisionApiConfigMaxRequestsPerMinute,
                        ),
                        const SizedBox(height: 12),
                        SwitchListTile(
                          key: const ValueKey('video-analysis-thinking-switch'),
                          value: settings.videoAnalysisThinkingEnabled,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('视频解析 thinking 模式'),
                          subtitle: const Text(
                            '高级开关；开启后复杂视频会允许视觉模型思考，可能增加耗时和格式波动',
                          ),
                          onChanged: settingsController
                              .setVideoAnalysisThinkingEnabled,
                        ),
                        const Divider(height: 20),
                        SwitchListTile(
                          key: const ValueKey('full-automation-switch'),
                          value: settings.fullAutomationEnabled,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('全自动模式'),
                          subtitle: const Text(
                            '添加视频后自动完成视频解析、故事板、拍摄脚本和分镜脚本解析；失败任务将在一分钟后自动重试一次。',
                          ),
                          onChanged:
                              settingsController.setFullAutomationEnabled,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '解析维度',
                    visible: _sectionSelected(
                      _SettingsSection.analysisDimensions,
                    ),
                    child: Column(
                      children: [
                        CheckboxListTile(
                          key: const ValueKey(
                            'video-analysis-multi-dimension-checkbox',
                          ),
                          value: settings.videoAnalysisMultiDimensionEnabled,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('多维度分析'),
                          subtitle: const Text('分析视频结构、留存、转化、画面风格与平台适配等视频级维度'),
                          onChanged: (enabled) => settingsController
                              .setVideoAnalysisMultiDimensionEnabled(
                                enabled ?? false,
                              ),
                        ),
                        CheckboxListTile(
                          key: const ValueKey(
                            'video-analysis-shot-details-checkbox',
                          ),
                          value: settings.videoAnalysisShotDetailsEnabled,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('镜头明细'),
                          subtitle: const Text('逐帧分析画面、人物、动作、景别、运镜、构图、光影与色彩'),
                          onChanged: (enabled) => settingsController
                              .setVideoAnalysisShotDetailsEnabled(
                                enabled ?? false,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: 'FFmpeg 与视频抽帧',
                    visible: _sectionSelected(_SettingsSection.videoAnalysis),
                    child: Column(
                      children: [
                        TextField(
                          key: const ValueKey('ffmpeg-executable-field'),
                          controller: _ffmpegExecutableController,
                          decoration: const InputDecoration(
                            labelText: 'FFmpeg 可执行文件',
                            helperText: '可填写命令名或本机完整路径',
                            prefixIcon: Icon(Icons.movie_filter_rounded),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('ffprobe-executable-field'),
                          controller: _ffprobeExecutableController,
                          decoration: const InputDecoration(
                            labelText: 'FFprobe 可执行文件',
                            helperText: '通常与 FFmpeg 位于同一目录',
                            prefixIcon: Icon(Icons.info_outline_rounded),
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<VideoFrameExtractionStrategy>(
                          key: const ValueKey(
                            'video-extraction-strategy-field',
                          ),
                          initialValue: _videoExtractionStrategy,
                          decoration: const InputDecoration(
                            labelText: '抽帧策略',
                            prefixIcon: Icon(Icons.filter_frames_rounded),
                          ),
                          items: [
                            for (final strategy
                                in VideoFrameExtractionStrategy.values)
                              DropdownMenuItem(
                                value: strategy,
                                child: Text(strategy.label),
                              ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _videoExtractionStrategy = value);
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                key: const ValueKey(
                                  'video-frame-interval-field',
                                ),
                                controller: _videoFrameIntervalController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: '抽帧间隔（秒）',
                                  helperText: '逐帧模式会忽略此项',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                key: const ValueKey(
                                  'video-scene-threshold-field',
                                ),
                                controller: _videoSceneThresholdController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: '场景阈值（0.05–0.95）',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextField(
                                key: const ValueKey(
                                  'video-sharpness-threshold-field',
                                ),
                                controller: _videoMinimumSharpnessController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: '清晰度阈值（0–1）',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('video-preview-padding-field'),
                          controller: _videoPreviewPaddingController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '播放视频帧前后（秒）',
                            helperText: '控制原视频缩略图弹窗的 I/O 点；范围 0.1–30 秒',
                            prefixIcon: Icon(Icons.play_circle_outline_rounded),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.icon(
                            key: const ValueKey('save-video-analysis-settings'),
                            onPressed: () =>
                                _saveVideoAnalysisSettings(settingsController),
                            icon: const Icon(Icons.save_rounded),
                            label: const Text('保存视频解析配置'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '即梦提示词默认规则',
                    visible: _sectionSelected(_SettingsSection.promptDefaults),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '新建复刻任务会复制这里的规则；已创建任务保留自己的版本，不会被静默覆盖。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('replicate-global-style-field'),
                          controller: _replicateGlobalStyleController,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            labelText: '默认全局风格',
                            prefixIcon: Icon(Icons.palette_outlined),
                            alignLabelWithHint: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          key: const ValueKey('replicate-constraints-field'),
                          controller: _replicateConstraintsController,
                          minLines: 3,
                          maxLines: 6,
                          decoration: const InputDecoration(
                            labelText: '默认整体约束',
                            helperText: '建议保留无字幕、无 Logo、无水印等成片约束',
                            prefixIcon: Icon(Icons.rule_rounded),
                            alignLabelWithHint: true,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          key: const ValueKey('save-replicate-prompt-defaults'),
                          onPressed: () =>
                              settingsController.setReplicatePromptDefaults(
                                globalStyle:
                                    _replicateGlobalStyleController.text,
                                constraints:
                                    _replicateConstraintsController.text,
                              ),
                          icon: const Icon(Icons.save_rounded),
                          label: const Text('保存提示词默认规则'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '图片生成 API',
                    visible: _sectionSelected(
                      _SettingsSection.imageGenerationApi,
                    ),
                    child: _ImageGenerationApiConfigSection(
                      configs: settings.imageGenerationApiConfigs,
                      activeId: settings.activeImageGenerationApiConfigId,
                      onSelect:
                          settingsController.setActiveImageGenerationApiConfig,
                      onSave: settingsController.saveImageGenerationApiConfig,
                      onDelete:
                          settingsController.deleteImageGenerationApiConfig,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '视频生成 API',
                    visible: _sectionSelected(
                      _SettingsSection.videoGenerationApi,
                    ),
                    child: _VideoGenerationApiConfigSection(
                      configs: settings.videoGenerationApiConfigs,
                      activeId: settings.activeVideoGenerationApiConfigId,
                      onSelect:
                          settingsController.setActiveVideoGenerationApiConfig,
                      onSave: settingsController.saveVideoGenerationApiConfig,
                      onDelete:
                          settingsController.deleteVideoGenerationApiConfig,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '插件',
                    visible: _sectionSelected(_SettingsSection.plugins),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'DaVinci Resolve 流程整合',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '从软件 data 文件夹中的内置插件包自动安装到 Resolve“流程整合”插件目录。'
                          '安装时会请求 Windows 管理员权限；是否能够加载由目标机 Resolve 环境决定。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.icon(
                          key: const ValueKey('install-resolve-plugin-button'),
                          onPressed: _isInstallingResolvePlugin
                              ? null
                              : _installResolvePlugin,
                          icon: _isInstallingResolvePlugin
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.extension_rounded),
                          label: Text(
                            _isInstallingResolvePlugin ? '正在安装…' : '安装达芬奇插件',
                          ),
                        ),
                        if (_resolvePluginInstallMessage != null) ...[
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                _resolvePluginInstallSucceeded == false
                                    ? Icons.error_outline_rounded
                                    : _resolvePluginInstallSucceeded == true
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.hourglass_top_rounded,
                                size: 18,
                                color: _resolvePluginInstallSucceeded == false
                                    ? scheme.error
                                    : _resolvePluginInstallSucceeded == true
                                    ? scheme.primary
                                    : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _resolvePluginInstallMessage!,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '软件更新',
                    visible: _sectionSelected(_SettingsSection.updater),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _PathTile(
                          label: '当前版本',
                          path: AppUpdateConfig.currentVersionTag,
                        ),
                        SwitchListTile(
                          key: const ValueKey('auto-install-updates-switch'),
                          value: settings.autoInstallUpdates,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('自动更新'),
                          subtitle: const Text('开启后下载完成会直接升级，关闭时会先弹窗确认'),
                          onChanged: settingsController.setAutoInstallUpdates,
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: SegmentedButton<UpdateDownloadMode>(
                            segments: [
                              for (final mode in UpdateDownloadMode.values)
                                ButtonSegment(
                                  value: mode,
                                  label: Text(mode.label),
                                  icon: Icon(switch (mode) {
                                    UpdateDownloadMode.automatic =>
                                      Icons.travel_explore_rounded,
                                    UpdateDownloadMode.manual =>
                                      Icons.settings_ethernet_rounded,
                                    UpdateDownloadMode.direct =>
                                      Icons.near_me_rounded,
                                  }),
                                ),
                            ],
                            selected: {settings.updateDownloadMode},
                            onSelectionChanged: (selection) {
                              settingsController.setUpdateDownloadMode(
                                selection.first,
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _updateManualProxyUrlController,
                          decoration: const InputDecoration(
                            labelText: '手动代理',
                            prefixIcon: Icon(Icons.hub_rounded),
                          ),
                          onSubmitted:
                              settingsController.setUpdateManualProxyUrl,
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            FilledButton.icon(
                              onPressed: () async {
                                await _saveUpdateSettings(settingsController);
                                await updaterController.checkForUpdates();
                              },
                              icon: const Icon(Icons.system_update_rounded),
                              label: const Text('检查更新'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  _saveUpdateSettings(settingsController),
                              icon: const Icon(Icons.save_rounded),
                              label: const Text('保存更新设置'),
                            ),
                            ValueListenableBuilder(
                              valueListenable: updaterController,
                              builder: (context, updateState, _) {
                                if (!updateState.hasReadyUpdate) {
                                  return const SizedBox.shrink();
                                }
                                return FilledButton.tonalIcon(
                                  onPressed: updateState.isBusy
                                      ? null
                                      : () => updaterController
                                            .installPendingUpdateNow(),
                                  icon: const Icon(
                                    Icons.system_update_alt_rounded,
                                  ),
                                  label: const Text('立即更新'),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        ValueListenableBuilder(
                          valueListenable: updaterController,
                          builder: (context, updateState, _) {
                            return _UpdateStatusPanel(state: updateState);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _SettingsContentSection(
                    title: '数据目录',
                    visible: _sectionSelected(_SettingsSection.dataDirectories),
                    child: Column(
                      children: [
                        _PathTile(
                          label: '程序同级目录',
                          path: directories.executableDirectory.path,
                          onOpen: () => _openDirectory(
                            directories.executableDirectory.path,
                          ),
                        ),
                        _PathTile(
                          label: 'data',
                          path: directories.data.path,
                          onOpen: () => _openDirectory(directories.data.path),
                        ),
                        _PathTile(
                          label: 'imports',
                          path: directories.imports.path,
                          onOpen: () =>
                              _openDirectory(directories.imports.path),
                        ),
                        _PathTile(
                          label: 'cuts',
                          path: directories.cuts.path,
                          onOpen: () => _openDirectory(directories.cuts.path),
                        ),
                        _PathTile(
                          label: 'storyboards',
                          path: directories.storyboards.path,
                          onOpen: () =>
                              _openDirectory(directories.storyboards.path),
                        ),
                        _PathTile(
                          label: 'exports',
                          path: directories.exports.path,
                          onOpen: () =>
                              _openDirectory(directories.exports.path),
                        ),
                        _PathTile(
                          label: 'updates',
                          path: directories.updates.path,
                          onOpen: () =>
                              _openDirectory(directories.updates.path),
                        ),
                        _PathTile(
                          label: 'database',
                          path: directories.database.path,
                          onOpen: () =>
                              _openDirectory(directories.database.path),
                        ),
                        _PathTile(
                          label: 'temp',
                          path: directories.temp.path,
                          onOpen: () => _openDirectory(directories.temp.path),
                        ),
                        _PathTile(
                          label: 'logs',
                          path: directories.logs.path,
                          onOpen: () => _openDirectory(directories.logs.path),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      '配置已持久化到 ${directories.databaseFile.path}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ].where((widget) => widget is! SizedBox).toList(),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    await Process.start('explorer.exe', [directory.path]);
  }
}

class _VisionApiConfigSection extends StatelessWidget {
  const _VisionApiConfigSection({
    required this.configs,
    required this.activeId,
    required this.onSelect,
    required this.onSave,
    required this.onDelete,
    required this.onMaxRequestsPerMinuteChanged,
  });

  final List<VisionApiConfig> configs;
  final String activeId;
  final Future<void> Function(String id) onSelect;
  final Future<void> Function(VisionApiConfig config) onSave;
  final Future<void> Function(String id) onDelete;
  final Future<void> Function(String id, int value)
  onMaxRequestsPerMinuteChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '点击卡片即可设为默认；可保存多个视觉模型配置。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final config in configs)
              _VisionApiConfigCard(
                config: config,
                selected: config.id == activeId,
                deleteEnabled: configs.length > 1,
                onSelect: () => onSelect(config.id),
                onEdit: () => _edit(context, config),
                onDelete: () => onDelete(config.id),
                onMaxRequestsPerMinuteChanged: (value) =>
                    onMaxRequestsPerMinuteChanged(config.id, value),
              ),
            _AddVisionApiConfigCard(onPressed: () => _edit(context, null)),
          ],
        ),
      ],
    );
  }

  Future<void> _edit(BuildContext context, VisionApiConfig? current) async {
    final config = await showDialog<VisionApiConfig>(
      context: context,
      builder: (_) => _VisionApiConfigDialog(config: current),
    );
    if (config != null) {
      await onSave(config);
    }
  }
}

class _VisionApiConfigCard extends StatelessWidget {
  const _VisionApiConfigCard({
    required this.config,
    required this.selected,
    required this.deleteEnabled,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
    required this.onMaxRequestsPerMinuteChanged,
  });

  final VisionApiConfig config;
  final bool selected;
  final bool deleteEnabled;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final Future<void> Function(int value) onMaxRequestsPerMinuteChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 272,
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey('vision-api-config-${config.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onSelect,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.visibility_rounded,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        config.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: '编辑配置',
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    if (deleteEnabled)
                      IconButton(
                        tooltip: '删除配置',
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  config.model.isEmpty ? '未设置模型' : config.model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  config.baseUrl.isEmpty ? '未设置 API 地址' : config.baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_isMiniMaxConfig(config)) ...[
                  const SizedBox(height: 10),
                  TextFormField(
                    key: ValueKey(
                      'vision-api-max-requests-per-minute-${config.id}',
                    ),
                    initialValue: config.maxRequestsPerMinute.toString(),
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: '每分钟最大解析请求数（1–200）',
                      helperText: '所有页面共享此上限，避免 API 限流',
                    ),
                    onFieldSubmitted: (text) async {
                      final value = int.tryParse(text);
                      if (value != null) {
                        await onMaxRequestsPerMinuteChanged(value);
                      }
                    },
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  selected ? '当前默认配置' : '点击设为默认',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static bool _isMiniMaxConfig(VisionApiConfig config) {
    final model = config.model.trim().toLowerCase();
    final host = Uri.tryParse(config.baseUrl.trim())?.host.toLowerCase() ?? '';
    return model == 'minimax-m3' && host.endsWith('minimaxi.com');
  }
}

class _AddVisionApiConfigCard extends StatelessWidget {
  const _AddVisionApiConfigCard({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 180,
      height: 180,
      child: OutlinedButton.icon(
        key: const ValueKey('add-vision-api-config'),
        onPressed: onPressed,
        icon: const Icon(Icons.add_circle_outline_rounded),
        label: const Text('添加 API 卡片'),
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}

class _VisionApiConfigDialog extends StatefulWidget {
  const _VisionApiConfigDialog({this.config});

  final VisionApiConfig? config;

  @override
  State<_VisionApiConfigDialog> createState() => _VisionApiConfigDialogState();
}

class _VisionApiConfigDialogState extends State<_VisionApiConfigDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  var _apiKeyObscured = true;

  @override
  void initState() {
    super.initState();
    final config = widget.config;
    _nameController = TextEditingController(text: config?.name ?? '');
    _baseUrlController = TextEditingController(text: config?.baseUrl ?? '');
    _apiKeyController = TextEditingController(text: config?.apiKey ?? '');
    _modelController = TextEditingController(text: config?.model ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.config == null;
    return AlertDialog(
      title: Text(isNew ? '添加视觉模型配置' : '编辑视觉模型配置'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '配置名称'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                labelText: 'API 地址',
                hintText: 'https://api.example.com',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              obscureText: _apiKeyObscured,
              decoration: InputDecoration(
                labelText: 'API Key',
                suffixIcon: IconButton(
                  tooltip: _apiKeyObscured ? '显示 Key' : '隐藏 Key',
                  onPressed: () {
                    setState(() => _apiKeyObscured = !_apiKeyObscured);
                  },
                  icon: Icon(
                    _apiKeyObscured
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelController,
              decoration: const InputDecoration(labelText: '模型名称'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final name = _nameController.text.trim();
            Navigator.of(context).pop(
              VisionApiConfig(
                id:
                    widget.config?.id ??
                    'vision-${DateTime.now().microsecondsSinceEpoch}',
                name: name.isEmpty ? '未命名视觉模型' : name,
                baseUrl: _baseUrlController.text.trim(),
                apiKey: _apiKeyController.text.trim(),
                model: _modelController.text.trim(),
                maxRequestsPerMinute:
                    widget.config?.maxRequestsPerMinute ?? 200,
              ),
            );
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _ImageGenerationApiConfigSection extends StatelessWidget {
  const _ImageGenerationApiConfigSection({
    required this.configs,
    required this.activeId,
    required this.onSelect,
    required this.onSave,
    required this.onDelete,
  });

  final List<ImageGenerationApiConfig> configs;
  final String activeId;
  final Future<void> Function(String id) onSelect;
  final Future<void> Function(ImageGenerationApiConfig config) onSave;
  final Future<void> Function(String id) onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '点击卡片即可设为默认；每张卡片保存图片模型、API 地址和 Key。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final config in configs)
              _ImageGenerationApiConfigCard(
                config: config,
                selected: config.id == activeId,
                deleteEnabled: configs.length > 1,
                onSelect: () => onSelect(config.id),
                onEdit: () => _edit(context, config),
                onDelete: () => onDelete(config.id),
              ),
            _AddImageGenerationApiConfigCard(
              onPressed: () => _edit(context, null),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _edit(
    BuildContext context,
    ImageGenerationApiConfig? current,
  ) async {
    final config = await showDialog<ImageGenerationApiConfig>(
      context: context,
      builder: (_) => _ImageGenerationApiConfigDialog(config: current),
    );
    if (config == null || !context.mounted) return;
    try {
      await onSave(config);
    } on FormatException catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message.toString())));
      }
    }
  }
}

class _ImageGenerationApiConfigCard extends StatelessWidget {
  const _ImageGenerationApiConfigCard({
    required this.config,
    required this.selected,
    required this.deleteEnabled,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
  });

  final ImageGenerationApiConfig config;
  final bool selected;
  final bool deleteEnabled;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final model = ImageGenerationCatalog.descriptorFor(config.model);
    return SizedBox(
      width: 272,
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey('image-generation-api-config-${config.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onSelect,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.auto_fix_high_rounded,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        config.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: '编辑配置',
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    if (deleteEnabled)
                      IconButton(
                        tooltip: '删除配置',
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  model?.label ?? '未设置模型',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${config.providerLabel} · ${config.baseUrl.isEmpty ? '未设置 API 地址' : config.baseUrl}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  selected ? '当前默认配置' : '点击设为默认',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
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

class _AddImageGenerationApiConfigCard extends StatelessWidget {
  const _AddImageGenerationApiConfigCard({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 180,
      height: 180,
      child: OutlinedButton.icon(
        key: const ValueKey('add-image-generation-api-config'),
        onPressed: onPressed,
        icon: const Icon(Icons.add_circle_outline_rounded),
        label: const Text('添加 API 卡片'),
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}

class _ImageGenerationApiConfigDialog extends StatefulWidget {
  const _ImageGenerationApiConfigDialog({this.config});

  final ImageGenerationApiConfig? config;

  @override
  State<_ImageGenerationApiConfigDialog> createState() =>
      _ImageGenerationApiConfigDialogState();
}

class _ImageGenerationApiConfigDialogState
    extends State<_ImageGenerationApiConfigDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late String _model;
  var _apiKeyObscured = true;

  @override
  void initState() {
    super.initState();
    final config = widget.config;
    _nameController = TextEditingController(text: config?.name ?? '');
    _baseUrlController = TextEditingController(text: config?.baseUrl ?? '');
    _apiKeyController = TextEditingController(text: config?.apiKey ?? '');
    _model = config?.model ?? 'nano-banana-fast';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final descriptor = ImageGenerationCatalog.descriptorFor(_model);
    final provider = ImageGenerationCatalog.providerLabelFor(_model);
    return AlertDialog(
      title: Text(widget.config == null ? '添加图片生成 API' : '编辑图片生成 API'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '配置名称'),
            ),
            const SizedBox(height: 12),
            ImageGenerationModelSelector(
              value: _model,
              labelText: '图片生成模型',
              onChanged: (model) => setState(() => _model = model),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _baseUrlController,
              decoration: InputDecoration(
                labelText: '$provider API 地址',
                hintText:
                    descriptor?.protocol ==
                        ImageGenerationProviderProtocol.apiMart
                    ? 'https://api.apimart.ai'
                    : 'https://api.example.com',
                helperText:
                    descriptor?.protocol ==
                        ImageGenerationProviderProtocol.apiMart
                    ? '可粘贴带 /v1 的地址，保存时会自动规范化'
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              obscureText: _apiKeyObscured,
              decoration: InputDecoration(
                labelText: '$provider API Key',
                suffixIcon: IconButton(
                  tooltip: _apiKeyObscured ? '显示 Key' : '隐藏 Key',
                  onPressed: () =>
                      setState(() => _apiKeyObscured = !_apiKeyObscured),
                  icon: Icon(
                    _apiKeyObscured
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            ImageGenerationApiConfig(
              id:
                  widget.config?.id ??
                  'image-${DateTime.now().microsecondsSinceEpoch}',
              name: _nameController.text.trim(),
              baseUrl: _baseUrlController.text.trim(),
              apiKey: _apiKeyController.text.trim(),
              model: _model,
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _VideoGenerationApiConfigSection extends StatelessWidget {
  const _VideoGenerationApiConfigSection({
    required this.configs,
    required this.activeId,
    required this.onSelect,
    required this.onSave,
    required this.onDelete,
  });

  final List<VideoGenerationApiConfig> configs;
  final String activeId;
  final Future<void> Function(String id) onSelect;
  final Future<void> Function(VideoGenerationApiConfig config) onSave;
  final Future<void> Function(String id) onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '点击卡片即可设为默认。视觉模型只读取当前所选视频模型对应的提示词 Skill：可灵只读可灵图生视频规则，LibTV/Seedance 只读 Seedance 规则；仅本地 MiniMax H3 读取通用 H3，并可按镜头剧情最多追加一个专项 Skill。远程 H3、未知 HTTP 模型和其他视频模型不会显示或执行本地 H3 Skill 路由偏好。可灵与 LibTV CLI 均使用本机命令行并在需要时自动打开浏览器授权；LibTV 为每个脚本复用独立画布。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        SelectableText(
          '即梦 2.0 官方提示词教程：https://www.volcengine.com/docs/82379/2222480?lang=zh',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final config in configs)
              _VideoGenerationApiConfigCard(
                config: config,
                selected: config.id == activeId,
                deleteEnabled:
                    configs.length > 1 &&
                    config.id !=
                        AppSettings.defaultKlingCliVideoGenerationConfigId &&
                    config.id !=
                        AppSettings.defaultLibTvCliVideoGenerationConfigId,
                onSelect: () => onSelect(config.id),
                onEdit: () => _edit(context, config),
                onDelete: () => onDelete(config.id),
              ),
            _AddVideoGenerationApiConfigCard(
              onPressed: () => _edit(context, null),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _edit(
    BuildContext context,
    VideoGenerationApiConfig? current,
  ) async {
    final config = await showDialog<VideoGenerationApiConfig>(
      context: context,
      builder: (_) => _VideoGenerationApiConfigDialog(config: current),
    );
    if (config == null || !context.mounted) return;
    await onSave(config);
  }
}

class _VideoGenerationApiConfigCard extends StatelessWidget {
  const _VideoGenerationApiConfigCard({
    required this.config,
    required this.selected,
    required this.deleteEnabled,
    required this.onSelect,
    required this.onEdit,
    required this.onDelete,
  });

  final VideoGenerationApiConfig config;
  final bool selected;
  final bool deleteEnabled;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final model = switch (config.kind) {
      VideoGenerationApiConfigKind.klingCli => switch (config.klingCliRegion) {
        'china' => '本机可灵 CLI · 中国区',
        'global' => '本机可灵 CLI · 海外区',
        _ => '本机可灵 CLI · 首次安装时选择区域',
      },
      VideoGenerationApiConfigKind.libTvCli => '${config.model}（即梦 2.0）',
      VideoGenerationApiConfigKind.httpApi =>
        config.model.trim().isEmpty ? '未设置模型' : config.model,
    };
    final baseUrl = switch (config.kind) {
      VideoGenerationApiConfigKind.klingCli => '使用可灵登录状态与命令行能力',
      VideoGenerationApiConfigKind.libTvCli => '浏览器授权 · 脚本专属 LibTV 画布',
      VideoGenerationApiConfigKind.httpApi =>
        config.baseUrl.trim().isEmpty ? '未设置 API 地址' : config.baseUrl.trim(),
    };
    return SizedBox(
      width: 272,
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: ValueKey('video-generation-api-config-${config.id}'),
          borderRadius: BorderRadius.circular(14),
          onTap: onSelect,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      !config.isHttpApi
                          ? Icons.terminal_rounded
                          : Icons.movie_creation_outlined,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        config.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: '编辑配置',
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    if (deleteEnabled)
                      IconButton(
                        tooltip: '删除配置',
                        onPressed: onDelete,
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  baseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Text(
                  selected ? '当前默认配置' : '点击设为默认',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurfaceVariant,
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

class _AddVideoGenerationApiConfigCard extends StatelessWidget {
  const _AddVideoGenerationApiConfigCard({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 180,
      height: 180,
      child: OutlinedButton.icon(
        key: const ValueKey('add-video-generation-api-config'),
        onPressed: onPressed,
        icon: const Icon(Icons.add_circle_outline_rounded),
        label: const Text('添加 API 卡片'),
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
    );
  }
}

class _VideoGenerationApiConfigDialog extends StatefulWidget {
  const _VideoGenerationApiConfigDialog({this.config});

  final VideoGenerationApiConfig? config;

  @override
  State<_VideoGenerationApiConfigDialog> createState() =>
      _VideoGenerationApiConfigDialogState();
}

class _VideoGenerationApiConfigDialogState
    extends State<_VideoGenerationApiConfigDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  late VideoGenerationApiConfigKind _kind;
  late String _klingCliRegion;
  var _apiKeyObscured = true;

  @override
  void initState() {
    super.initState();
    final config = widget.config;
    _kind = config?.kind ?? VideoGenerationApiConfigKind.httpApi;
    _klingCliRegion = config?.klingCliRegion ?? '';
    _nameController = TextEditingController(text: config?.name ?? '');
    _baseUrlController = TextEditingController(
      text: config?.isHttpApi == false
          ? ''
          : config?.baseUrl ?? AppSettings.defaultVideoGenerationApiBaseUrl,
    );
    _apiKeyController = TextEditingController(text: config?.apiKey ?? '');
    _modelController = TextEditingController(
      text: config?.isHttpApi == false
          ? ''
          : config?.model ?? AppSettings.defaultVideoGenerationModel,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isHttpApi = _kind == VideoGenerationApiConfigKind.httpApi;
    return AlertDialog(
      title: Text(widget.config == null ? '添加视频生成 API' : '编辑视频生成 API'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<VideoGenerationApiConfigKind>(
                segments: const [
                  ButtonSegment(
                    value: VideoGenerationApiConfigKind.klingCli,
                    label: Text('可灵 CLI'),
                    icon: Icon(Icons.terminal_rounded),
                  ),
                  ButtonSegment(
                    value: VideoGenerationApiConfigKind.libTvCli,
                    label: Text('LibTV CLI'),
                    icon: Icon(Icons.video_library_outlined),
                  ),
                  ButtonSegment(
                    value: VideoGenerationApiConfigKind.httpApi,
                    label: Text('HTTP API'),
                    icon: Icon(Icons.http_rounded),
                  ),
                ],
                selected: {_kind},
                onSelectionChanged: (selection) {
                  setState(() => _kind = selection.first);
                },
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: '配置名称'),
            ),
            const SizedBox(height: 12),
            if (isHttpApi) ...[
              TextField(
                controller: _baseUrlController,
                decoration: const InputDecoration(
                  labelText: 'API 地址',
                  hintText: AppSettings.defaultVideoGenerationApiBaseUrl,
                  helperText: '填写 Base URL，保存时不会追加具体路径',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _apiKeyController,
                obscureText: _apiKeyObscured,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  suffixIcon: IconButton(
                    tooltip: _apiKeyObscured ? '显示 Key' : '隐藏 Key',
                    onPressed: () =>
                        setState(() => _apiKeyObscured = !_apiKeyObscured),
                    icon: Icon(
                      _apiKeyObscured
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: '模型名称',
                  hintText: AppSettings.defaultVideoGenerationModel,
                ),
              ),
            ] else if (_kind == VideoGenerationApiConfigKind.libTvCli)
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'LibTV CLI 固定使用 Seedance 2.0（即梦 2.0）预设。首次使用会自动打开浏览器授权；生成时上传镜头参考图到当前脚本专属画布，并遵循“主体 + 动作 + 场景 + 光色 + 单一运镜 + 风格/约束”的官方提示词结构。',
                ),
              )
            else ...[
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '可灵中国区与海外区使用不同的官方 CLI 包。首次自动安装前必须选择区域，软件不会同时安装两个版本。',
                ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'china', label: Text('中国区')),
                    ButtonSegment(value: 'global', label: Text('海外区')),
                  ],
                  selected: _klingCliRegion.isEmpty
                      ? const <String>{}
                      : {_klingCliRegion},
                  emptySelectionAllowed: true,
                  onSelectionChanged: (selection) {
                    setState(
                      () => _klingCliRegion = selection.isEmpty
                          ? ''
                          : selection.first,
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            VideoGenerationApiConfig(
              id:
                  widget.config?.id ??
                  'video-${DateTime.now().microsecondsSinceEpoch}',
              name: _nameController.text.trim(),
              kind: _kind,
              baseUrl: isHttpApi ? _baseUrlController.text.trim() : '',
              apiKey: isHttpApi ? _apiKeyController.text.trim() : '',
              model: isHttpApi
                  ? _modelController.text.trim()
                  : _kind == VideoGenerationApiConfigKind.libTvCli
                  ? AppSettings.defaultLibTvCliVideoGenerationModel
                  : AppSettings.defaultKlingCliVideoGenerationModel,
              klingCliRegion: _kind == VideoGenerationApiConfigKind.klingCli
                  ? _klingCliRegion
                  : '',
            ),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _RemoteAccessSettingsPanel extends ConsumerWidget {
  const _RemoteAccessSettingsPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(remoteAccessControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final pairing = controller.pairingCode;
        final sessions = controller.sessions;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: controller.isRunning
                    ? scheme.primaryContainer.withValues(alpha: 0.52)
                    : scheme.surfaceContainerHighest.withValues(alpha: 0.46),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(
                    controller.isRunning
                        ? Icons.public_rounded
                        : Icons.public_off_rounded,
                    color: controller.isRunning
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          controller.isRunning ? '远程工作台运行中' : '远程工作台已关闭',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          controller.isRunning
                              ? '导演可通过配对码访问当前打开工程的拍摄脚本。'
                              : '默认关闭；开启后才会监听本机端口。',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: controller.config.enabled,
                    onChanged: controller.isBusy
                        ? null
                        : (value) => controller.setEnabled(value),
                  ),
                ],
              ),
            ),
            if (controller.isBusy) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
            if (controller.errorMessage case final error?) ...[
              const SizedBox(height: 10),
              Text(error, style: TextStyle(color: scheme.error)),
            ],
            const SizedBox(height: 16),
            TextFormField(
              key: ValueKey('remote-port-${controller.config.port}'),
              initialValue: '${controller.config.port}',
              enabled: !controller.isBusy,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '本地服务端口',
                helperText: '范围 1024–65535；修改后会自动重启远程服务。',
                prefixIcon: Icon(Icons.settings_ethernet_rounded),
              ),
              onFieldSubmitted: (value) async {
                final port = int.tryParse(value.trim());
                if (port == null) {
                  _showMessage(context, '请输入有效的数字端口');
                  return;
                }
                try {
                  await controller.setPort(port);
                } on FormatException catch (error) {
                  if (context.mounted) _showMessage(context, error.message);
                }
              },
            ),
            const SizedBox(height: 14),
            Text('本机访问地址', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(child: SelectableText(controller.localAccessUrl)),
                  IconButton(
                    tooltip: '复制地址',
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: controller.localAccessUrl),
                      );
                      if (context.mounted) _showMessage(context, '地址已复制');
                    },
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              controller.webAssetsAvailable
                  ? 'Web 页面资源已就绪。内网穿透目标请填写上方地址，并在公网侧启用 HTTPS。'
                  : '未找到 Web 页面资源；API 可启动，但安装包需要重新构建后才能打开页面。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: controller.webAssetsAvailable
                    ? scheme.onSurfaceVariant
                    : scheme.error,
              ),
            ),
            const SizedBox(height: 18),
            Text('安全配对', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: controller.isRunning
                      ? () => controller.createPairingCode(
                          RemoteAccessRole.director,
                        )
                      : null,
                  icon: const Icon(Icons.movie_filter_rounded),
                  label: const Text('生成导演配对码'),
                ),
                OutlinedButton.icon(
                  onPressed: controller.isRunning
                      ? () => controller.createPairingCode(
                          RemoteAccessRole.viewer,
                        )
                      : null,
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('生成只读配对码'),
                ),
                if (sessions.isNotEmpty)
                  TextButton.icon(
                    onPressed: controller.revokeAllSessions,
                    icon: const Icon(Icons.phonelink_erase_rounded),
                    label: const Text('撤销全部会话'),
                  ),
              ],
            ),
            if (pairing != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [scheme.primaryContainer, scheme.tertiaryContainer],
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pairing.role == RemoteAccessRole.director
                          ? '导演权限配对码'
                          : '只读权限配对码',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 6),
                    SelectableText(
                      pairing.code,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            fontWeight: FontWeight.w900,
                            letterSpacing: 7,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '有效至 ${_formatTime(pairing.expiresAt)}，使用一次后立即失效。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
            if (sessions.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(
                '已连接设备（${sessions.length}）',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              for (final session in sessions)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const CircleAvatar(
                    child: Icon(Icons.devices_rounded, size: 19),
                  ),
                  title: Text(session.clientName),
                  subtitle: Text(
                    '${session.role == RemoteAccessRole.director ? '导演' : '只读'} · 最近活动 ${_formatTime(session.lastSeenAt)}',
                  ),
                  trailing: IconButton(
                    tooltip: '撤销会话',
                    onPressed: () => controller.revokeSession(session.id),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
            ],
          ],
        );
      },
    );
  }

  static String _formatTime(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static void _showMessage(BuildContext context, Object message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$message')));
  }
}

extension on _SettingsSection {
  String get label => switch (this) {
    _SettingsSection.appearance => '外观',
    _SettingsSection.projects => '工程与启动',
    _SettingsSection.remoteAccess => '导演远程访问',
    _SettingsSection.exportDirectory => '导出文件夹',
    _SettingsSection.storyboardExport => '故事板导出',
    _SettingsSection.visionApi => '视觉模型 API',
    _SettingsSection.analysisDimensions => '解析维度',
    _SettingsSection.videoAnalysis => 'FFmpeg 与视频抽帧',
    _SettingsSection.promptDefaults => '即梦提示词默认规则',
    _SettingsSection.imageGenerationApi => '图片生成 API',
    _SettingsSection.videoGenerationApi => '视频生成 API',
    _SettingsSection.plugins => '插件',
    _SettingsSection.updater => '软件更新',
    _SettingsSection.dataDirectories => '数据目录',
  };

  IconData get icon => switch (this) {
    _SettingsSection.appearance => Icons.palette_outlined,
    _SettingsSection.projects => Icons.folder_special_outlined,
    _SettingsSection.remoteAccess => Icons.cast_connected_rounded,
    _SettingsSection.exportDirectory => Icons.drive_folder_upload_outlined,
    _SettingsSection.storyboardExport => Icons.auto_stories_outlined,
    _SettingsSection.visionApi => Icons.visibility_outlined,
    _SettingsSection.analysisDimensions => Icons.analytics_outlined,
    _SettingsSection.videoAnalysis => Icons.video_settings_outlined,
    _SettingsSection.promptDefaults => Icons.text_snippet_outlined,
    _SettingsSection.imageGenerationApi => Icons.image_outlined,
    _SettingsSection.videoGenerationApi => Icons.movie_creation_outlined,
    _SettingsSection.plugins => Icons.extension_outlined,
    _SettingsSection.updater => Icons.system_update_alt_rounded,
    _SettingsSection.dataDirectories => Icons.storage_rounded,
  };
}

class _SettingsNavigation extends StatelessWidget {
  const _SettingsNavigation({
    required this.selectedSection,
    required this.onSelected,
  });

  final _SettingsSection selectedSection;
  final ValueChanged<_SettingsSection> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLowest.withValues(alpha: 0.72),
      child: ListView(
        key: const ValueKey('settings-function-menu'),
        padding: const EdgeInsets.fromLTRB(12, 18, 12, 18),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
            child: Text(
              '设置',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          for (final section in _SettingsSection.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: ListTile(
                key: ValueKey('settings-menu-${section.name}'),
                selected: section == selectedSection,
                selectedTileColor: scheme.secondaryContainer.withValues(
                  alpha: 0.72,
                ),
                selectedColor: scheme.onSecondaryContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                minTileHeight: 44,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                leading: Icon(section.icon, size: 20),
                title: Text(section.label, maxLines: 1),
                onTap: () => onSelected(section),
              ),
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.84),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.48),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _SettingsContentSection extends StatelessWidget {
  const _SettingsContentSection({
    required this.title,
    required this.visible,
    required this.child,
  });

  final String title;
  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return _Section(title: title, child: child);
  }
}

class _UpdateStatusPanel extends StatelessWidget {
  const _UpdateStatusPanel({required this.state});

  final UpdaterState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = state.statusMessage.trim().isEmpty
        ? '尚未检查更新'
        : state.statusMessage.trim();
    final progress = state.downloadProgress;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                state.isBusy
                    ? Icons.sync_rounded
                    : state.hasReadyUpdate
                    ? Icons.download_done_rounded
                    : Icons.info_outline_rounded,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (state.isBusy && progress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress <= 0 ? null : progress),
          ],
        ],
      ),
    );
  }
}

class _PathTile extends StatelessWidget {
  const _PathTile({required this.label, required this.path, this.onOpen});

  final String label;
  final String path;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              path,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          if (onOpen != null) ...[
            const SizedBox(width: 8),
            Tooltip(
              message: '打开目录',
              child: IconButton(
                onPressed: onOpen,
                icon: const Icon(Icons.folder_open_rounded),
                iconSize: 20,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 34,
                  height: 34,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
