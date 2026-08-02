import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database.dart';
import '../../../core/providers/app_providers.dart';
import '../../projects/application/project_workspace_controller.dart';
import '../../storyboard/domain/image_generation_model_catalog.dart';
import '../../storyboard/presentation/widgets/image_generation_model_selector.dart';
import '../../updater/domain/app_update_config.dart';
import '../../updater/domain/update_models.dart';
import '../application/settings_controller.dart';
import '../domain/app_settings.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

enum _SettingsSection {
  projects,
  exportDirectory,
  storyboardExport,
  visionApi,
  videoAnalysis,
  promptDefaults,
  imageGenerationApi,
  updater,
  dataDirectories,
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  static const _expandedSectionsKey = 'settingsPageExpandedSections';

  late final SettingsController _settingsController;
  late final TextEditingController _exportPathController;
  late final TextEditingController _visionApiBaseUrlController;
  late final TextEditingController _visionApiKeyController;
  late final TextEditingController _visionModelController;
  late final TextEditingController _ffmpegExecutableController;
  late final TextEditingController _ffprobeExecutableController;
  late final TextEditingController _videoFrameIntervalController;
  late final TextEditingController _videoSceneThresholdController;
  late final TextEditingController _videoMinimumSharpnessController;
  late final TextEditingController _replicateGlobalStyleController;
  late final TextEditingController _replicateConstraintsController;
  late final TextEditingController _imageGenerationApiBaseUrlController;
  late final TextEditingController _imageGenerationApiKeyController;
  late final TextEditingController _imageGenerationGeminiApiBaseUrlController;
  late final TextEditingController _imageGenerationGeminiApiKeyController;
  late final TextEditingController _imageGenerationApiMartApiBaseUrlController;
  late final TextEditingController _imageGenerationApiMartApiKeyController;
  late final TextEditingController _imageGenerationModelController;
  late final TextEditingController _updateManualProxyUrlController;
  bool _visionApiKeyObscured = true;
  bool _imageGenerationApiKeyObscured = true;
  bool _imageGenerationGeminiApiKeyObscured = true;
  bool _imageGenerationApiMartApiKeyObscured = true;
  late VideoFrameExtractionStrategy _videoExtractionStrategy;
  final _expandedSections = <_SettingsSection>{};

  @override
  void initState() {
    super.initState();
    final controller = ref.read(settingsControllerProvider);
    _settingsController = controller;
    _exportPathController = TextEditingController(
      text: controller.value.exportDirectory,
    );
    _visionApiBaseUrlController = TextEditingController(
      text: controller.value.visionApiBaseUrl,
    );
    _visionApiKeyController = TextEditingController(
      text: controller.value.visionApiKey,
    );
    _visionModelController = TextEditingController(
      text: controller.value.visionModel,
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
    _replicateGlobalStyleController = TextEditingController(
      text: controller.value.replicateDefaultGlobalStyle,
    );
    _replicateConstraintsController = TextEditingController(
      text: controller.value.replicateDefaultConstraints,
    );
    _videoExtractionStrategy = controller.value.videoFrameExtractionStrategy;
    _imageGenerationApiBaseUrlController = TextEditingController(
      text: controller.value.imageGenerationApiBaseUrl,
    );
    _imageGenerationApiKeyController = TextEditingController(
      text: controller.value.imageGenerationApiKey,
    );
    _imageGenerationGeminiApiBaseUrlController = TextEditingController(
      text: controller.value.imageGenerationGeminiApiBaseUrl,
    );
    _imageGenerationGeminiApiKeyController = TextEditingController(
      text: controller.value.imageGenerationGeminiApiKey,
    );
    _imageGenerationApiMartApiBaseUrlController = TextEditingController(
      text: controller.value.imageGenerationApiMartApiBaseUrl,
    );
    _imageGenerationApiMartApiKeyController = TextEditingController(
      text: controller.value.imageGenerationApiMartApiKey,
    );
    _imageGenerationModelController = TextEditingController(
      text: controller.value.imageGenerationModel,
    );
    _updateManualProxyUrlController = TextEditingController(
      text: controller.value.updateManualProxyUrl,
    );
    _expandedSections.addAll(_loadExpandedSections());
    controller.addListener(_syncFromSettings);
  }

  @override
  void dispose() {
    _settingsController.removeListener(_syncFromSettings);
    _exportPathController.dispose();
    _visionApiBaseUrlController.dispose();
    _visionApiKeyController.dispose();
    _visionModelController.dispose();
    _ffmpegExecutableController.dispose();
    _ffprobeExecutableController.dispose();
    _videoFrameIntervalController.dispose();
    _videoSceneThresholdController.dispose();
    _videoMinimumSharpnessController.dispose();
    _replicateGlobalStyleController.dispose();
    _replicateConstraintsController.dispose();
    _imageGenerationApiBaseUrlController.dispose();
    _imageGenerationApiKeyController.dispose();
    _imageGenerationGeminiApiBaseUrlController.dispose();
    _imageGenerationGeminiApiKeyController.dispose();
    _imageGenerationApiMartApiBaseUrlController.dispose();
    _imageGenerationApiMartApiKeyController.dispose();
    _imageGenerationModelController.dispose();
    _updateManualProxyUrlController.dispose();
    super.dispose();
  }

  void _syncFromSettings() {
    final settings = ref.read(settingsControllerProvider).value;
    if (_exportPathController.text != settings.exportDirectory) {
      _exportPathController.text = settings.exportDirectory;
    }
    if (_visionApiBaseUrlController.text != settings.visionApiBaseUrl) {
      _visionApiBaseUrlController.text = settings.visionApiBaseUrl;
    }
    if (_visionApiKeyController.text != settings.visionApiKey) {
      _visionApiKeyController.text = settings.visionApiKey;
    }
    if (_visionModelController.text != settings.visionModel) {
      _visionModelController.text = settings.visionModel;
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
    if (_imageGenerationApiBaseUrlController.text !=
        settings.imageGenerationApiBaseUrl) {
      _imageGenerationApiBaseUrlController.text =
          settings.imageGenerationApiBaseUrl;
    }
    if (_imageGenerationApiKeyController.text !=
        settings.imageGenerationApiKey) {
      _imageGenerationApiKeyController.text = settings.imageGenerationApiKey;
    }
    if (_imageGenerationGeminiApiBaseUrlController.text !=
        settings.imageGenerationGeminiApiBaseUrl) {
      _imageGenerationGeminiApiBaseUrlController.text =
          settings.imageGenerationGeminiApiBaseUrl;
    }
    if (_imageGenerationGeminiApiKeyController.text !=
        settings.imageGenerationGeminiApiKey) {
      _imageGenerationGeminiApiKeyController.text =
          settings.imageGenerationGeminiApiKey;
    }
    if (_imageGenerationApiMartApiBaseUrlController.text !=
        settings.imageGenerationApiMartApiBaseUrl) {
      _imageGenerationApiMartApiBaseUrlController.text =
          settings.imageGenerationApiMartApiBaseUrl;
    }
    if (_imageGenerationApiMartApiKeyController.text !=
        settings.imageGenerationApiMartApiKey) {
      _imageGenerationApiMartApiKeyController.text =
          settings.imageGenerationApiMartApiKey;
    }
    if (_imageGenerationModelController.text != settings.imageGenerationModel) {
      _imageGenerationModelController.text = settings.imageGenerationModel;
    }
    if (_updateManualProxyUrlController.text != settings.updateManualProxyUrl) {
      _updateManualProxyUrlController.text = settings.updateManualProxyUrl;
    }
  }

  Future<void> _saveVisionSettings(SettingsController controller) async {
    await controller.setVisionSettings(
      baseUrl: _visionApiBaseUrlController.text,
      apiKey: _visionApiKeyController.text,
      model: _visionModelController.text,
    );
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
      thinkingEnabled: controller.value.videoAnalysisThinkingEnabled,
    );
  }

  Future<void> _saveGrsaiImageGenerationSettings(
    SettingsController controller,
  ) async {
    await controller.setImageGenerationGrsaiSettings(
      baseUrl: _imageGenerationApiBaseUrlController.text,
      apiKey: _imageGenerationApiKeyController.text,
    );
  }

  Future<void> _saveGeminiImageGenerationSettings(
    SettingsController controller,
  ) async {
    await controller.setImageGenerationGeminiSettings(
      baseUrl: _imageGenerationGeminiApiBaseUrlController.text,
      apiKey: _imageGenerationGeminiApiKeyController.text,
    );
  }

  Future<void> _saveApiMartImageGenerationSettings(
    SettingsController controller,
  ) async {
    try {
      await controller.setImageGenerationApiMartSettings(
        baseUrl: _imageGenerationApiMartApiBaseUrlController.text,
        apiKey: _imageGenerationApiMartApiKeyController.text,
      );
      if (!mounted) {
        return;
      }
      final hasApiKey =
          controller.value.imageGenerationApiMartApiKey.isNotEmpty;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            hasApiKey
                ? 'APIMart 配置已保存，请求地址：${controller.value.imageGenerationApiMartApiBaseUrl}'
                : 'APIMart 地址已保存；API Key 为空，生成前请先填写',
          ),
        ),
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  String _selectedImageProviderSummary(AppSettings settings) {
    final descriptor = ImageGenerationCatalog.descriptorFor(
      _imageGenerationModelController.text,
    );
    if (descriptor == null) {
      return '当前模型不在支持目录中，请重新选择';
    }
    return switch (descriptor.protocol) {
      ImageGenerationProviderProtocol.apiMart =>
        '将自动使用 APIMart 配置 · ${settings.imageGenerationApiMartApiBaseUrl}',
      ImageGenerationProviderProtocol.gemini =>
        '将自动使用 Gemini 配置 · ${settings.imageGenerationGeminiApiBaseUrl}',
      ImageGenerationProviderProtocol.grsai =>
        '将自动使用 GRSai 配置 · ${settings.imageGenerationApiBaseUrl}',
    };
  }

  Future<void> _saveUpdateSettings(SettingsController controller) async {
    await controller.setUpdateManualProxyUrl(
      _updateManualProxyUrlController.text,
    );
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
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('目录不可写：$error')));
      }
    }
  }

  void _resetDefaultProjectRoot() {
    final directories = ref.read(appDirectoriesProvider);
    _globalSettingsDatabase.setSetting(
      ProjectWorkspaceController.defaultProjectRootSettingKey,
      directories.projects.path,
    );
    setState(() {});
  }

  bool _sectionExpanded(_SettingsSection section) {
    return _expandedSections.contains(section);
  }

  void _toggleSection(_SettingsSection section) {
    setState(() {
      if (!_expandedSections.add(section)) {
        _expandedSections.remove(section);
      }
    });
    _saveExpandedSections();
  }

  Set<_SettingsSection> _loadExpandedSections() {
    try {
      final raw = ref
          .read(appDatabaseProvider)
          .getSetting(_expandedSectionsKey);
      if (raw == null || raw.trim().isEmpty) {
        return {};
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        return {};
      }
      final names = decoded.whereType<String>().toSet();
      return {
        for (final section in _SettingsSection.values)
          if (names.contains(section.name)) section,
      };
    } catch (_) {
      return {};
    }
  }

  void _saveExpandedSections() {
    try {
      final names = [
        for (final section in _SettingsSection.values)
          if (_expandedSections.contains(section)) section.name,
      ];
      ref
          .read(appDatabaseProvider)
          .setSetting(_expandedSectionsKey, jsonEncode(names));
    } catch (_) {
      // 测试或预览环境可能没有注入数据库，生产环境会正常保存。
    }
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
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _Section(
              title: '外观',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('主题', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<AppThemePreference>(
                    segments: [
                      for (final preference in AppThemePreference.values)
                        ButtonSegment(
                          value: preference,
                          label: Text(preference.label),
                          icon: Icon(switch (preference) {
                            AppThemePreference.system =>
                              Icons.brightness_auto_rounded,
                            AppThemePreference.light =>
                              Icons.light_mode_rounded,
                            AppThemePreference.dark => Icons.dark_mode_rounded,
                          }),
                        ),
                    ],
                    selected: {settings.themePreference},
                    onSelectionChanged: (selection) {
                      settingsController.setThemePreference(selection.first);
                    },
                  ),
                  const SizedBox(height: 18),
                  Text('功能菜单位置', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(
                    '切换后立即生效，下次启动会继续使用当前布局。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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
                      settingsController.setNavigationPosition(selection.first);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _CollapsibleSection(
              title: '工程与启动',
              expanded: _sectionExpanded(_SettingsSection.projects),
              onToggle: () => _toggleSection(_SettingsSection.projects),
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
                  Text('默认工程目录', style: Theme.of(context).textTheme.titleSmall),
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
            _CollapsibleSection(
              title: '导出文件夹',
              expanded: _sectionExpanded(_SettingsSection.exportDirectory),
              onToggle: () => _toggleSection(_SettingsSection.exportDirectory),
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
                            await settingsController.setExportDirectory(path);
                          }
                        },
                        icon: const Icon(Icons.folder_rounded),
                        label: const Text('选择文件夹'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => settingsController.setExportDirectory(
                          _exportPathController.text,
                        ),
                        icon: const Icon(Icons.save_rounded),
                        label: const Text('保存路径'),
                      ),
                      TextButton.icon(
                        onPressed: settingsController.resetToDefaults,
                        icon: const Icon(Icons.settings_backup_restore_rounded),
                        label: const Text('恢复默认'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _CollapsibleSection(
              title: '故事板导出',
              expanded: _sectionExpanded(_SettingsSection.storyboardExport),
              onToggle: () => _toggleSection(_SettingsSection.storyboardExport),
              child: SwitchListTile(
                value: settings.storyboardSummaryPageEnabled,
                contentPadding: EdgeInsets.zero,
                title: const Text('故事板内容页'),
                subtitle: const Text('开启后导出时附带自动归纳的大纲、内容、场景和道具页'),
                onChanged: settingsController.setStoryboardSummaryPageEnabled,
              ),
            ),
            const SizedBox(height: 14),
            _CollapsibleSection(
              title: '视觉模型 API',
              expanded: _sectionExpanded(_SettingsSection.visionApi),
              onToggle: () => _toggleSection(_SettingsSection.visionApi),
              child: Column(
                children: [
                  TextField(
                    controller: _visionApiBaseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'API 地址',
                      prefixIcon: Icon(Icons.cloud_queue_rounded),
                    ),
                    onSubmitted: settingsController.setVisionApiBaseUrl,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _visionApiKeyController,
                    obscureText: _visionApiKeyObscured,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      prefixIcon: const Icon(Icons.key_rounded),
                      suffixIcon: IconButton(
                        tooltip: _visionApiKeyObscured ? '显示 Key' : '隐藏 Key',
                        onPressed: () {
                          setState(() {
                            _visionApiKeyObscured = !_visionApiKeyObscured;
                          });
                        },
                        icon: Icon(
                          _visionApiKeyObscured
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                        ),
                      ),
                    ),
                    onSubmitted: settingsController.setVisionApiKey,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _visionModelController,
                    decoration: const InputDecoration(
                      labelText: '模型',
                      prefixIcon: Icon(Icons.auto_awesome_rounded),
                    ),
                    onSubmitted: settingsController.setVisionModel,
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    key: const ValueKey('video-analysis-thinking-switch'),
                    value: settings.videoAnalysisThinkingEnabled,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('视频解析 thinking 模式'),
                    subtitle: const Text('高级开关；开启后复杂视频会允许视觉模型思考，可能增加耗时和格式波动'),
                    onChanged:
                        settingsController.setVideoAnalysisThinkingEnabled,
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: () => _saveVisionSettings(settingsController),
                      icon: const Icon(Icons.save_rounded),
                      label: const Text('保存视觉模型配置'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _CollapsibleSection(
              title: 'FFmpeg 与视频抽帧',
              expanded: _sectionExpanded(_SettingsSection.videoAnalysis),
              onToggle: () => _toggleSection(_SettingsSection.videoAnalysis),
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
                    key: const ValueKey('video-extraction-strategy-field'),
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
                          key: const ValueKey('video-frame-interval-field'),
                          controller: _videoFrameIntervalController,
                          keyboardType: const TextInputType.numberWithOptions(
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
                          key: const ValueKey('video-scene-threshold-field'),
                          controller: _videoSceneThresholdController,
                          keyboardType: const TextInputType.numberWithOptions(
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
                          keyboardType: const TextInputType.numberWithOptions(
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
            _CollapsibleSection(
              title: 'Seedance 提示词默认规则',
              expanded: _sectionExpanded(_SettingsSection.promptDefaults),
              onToggle: () => _toggleSection(_SettingsSection.promptDefaults),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '新建复刻任务会复制这里的规则；已创建任务保留自己的版本，不会被静默覆盖。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
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
                          globalStyle: _replicateGlobalStyleController.text,
                          constraints: _replicateConstraintsController.text,
                        ),
                    icon: const Icon(Icons.save_rounded),
                    label: const Text('保存提示词默认规则'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _CollapsibleSection(
              title: '图片生成 API',
              expanded: _sectionExpanded(_SettingsSection.imageGenerationApi),
              onToggle: () =>
                  _toggleSection(_SettingsSection.imageGenerationApi),
              child: Column(
                children: [
                  _ImageProviderSettingsCard(
                    key: const ValueKey('image-provider-card-default'),
                    icon: Icons.auto_fix_high_rounded,
                    title: '默认图片生成模型',
                    subtitle: '选择模型后会自动绑定对应服务商的地址和 Key',
                    actionKey: const ValueKey(
                      'save-image-generation-default-model',
                    ),
                    actionLabel: '保存默认模型',
                    onSave: () => settingsController.setImageGenerationModel(
                      _imageGenerationModelController.text,
                    ),
                    children: [
                      ImageGenerationModelSelector(
                        key: const ValueKey('image-generation-model-field'),
                        value: _imageGenerationModelController.text,
                        labelText: '默认模型',
                        prefixIcon: const Icon(Icons.account_tree_rounded),
                        onChanged: (model) {
                          setState(() {
                            _imageGenerationModelController.text = model;
                          });
                        },
                      ),
                      const SizedBox(height: 10),
                      _ProviderRouteHint(
                        text: _selectedImageProviderSummary(settings),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ImageProviderSettingsCard(
                    key: const ValueKey('image-provider-card-grsai'),
                    icon: Icons.cloud_queue_rounded,
                    title: 'GRSai',
                    subtitle: '独立接口 · Nano Banana、GPT Image 系列',
                    actionKey: const ValueKey(
                      'save-image-generation-grsai-settings',
                    ),
                    actionLabel: '保存 GRSai 配置',
                    onSave: () =>
                        _saveGrsaiImageGenerationSettings(settingsController),
                    children: [
                      TextField(
                        key: const ValueKey(
                          'image-generation-api-base-url-field',
                        ),
                        controller: _imageGenerationApiBaseUrlController,
                        decoration: const InputDecoration(
                          labelText: 'GRSai API 地址',
                          prefixIcon: Icon(Icons.link_rounded),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const ValueKey('image-generation-api-key-field'),
                        controller: _imageGenerationApiKeyController,
                        obscureText: _imageGenerationApiKeyObscured,
                        decoration: InputDecoration(
                          labelText: 'GRSai API Key',
                          prefixIcon: const Icon(Icons.vpn_key_rounded),
                          suffixIcon: IconButton(
                            tooltip: _imageGenerationApiKeyObscured
                                ? '显示 Key'
                                : '隐藏 Key',
                            onPressed: () {
                              setState(() {
                                _imageGenerationApiKeyObscured =
                                    !_imageGenerationApiKeyObscured;
                              });
                            },
                            icon: Icon(
                              _imageGenerationApiKeyObscured
                                  ? Icons.visibility_rounded
                                  : Icons.visibility_off_rounded,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ImageProviderSettingsCard(
                    key: const ValueKey('image-provider-card-gemini'),
                    icon: Icons.auto_awesome_rounded,
                    title: 'Gemini',
                    subtitle: '独立诗影接口 · Gemini Image 系列',
                    actionKey: const ValueKey(
                      'save-image-generation-gemini-settings',
                    ),
                    actionLabel: '保存 Gemini 配置',
                    onSave: () =>
                        _saveGeminiImageGenerationSettings(settingsController),
                    children: [
                      TextField(
                        key: const ValueKey(
                          'image-generation-gemini-api-base-url-field',
                        ),
                        controller: _imageGenerationGeminiApiBaseUrlController,
                        decoration: const InputDecoration(
                          labelText: 'Gemini API 地址',
                          prefixIcon: Icon(Icons.link_rounded),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const ValueKey(
                          'image-generation-gemini-api-key-field',
                        ),
                        controller: _imageGenerationGeminiApiKeyController,
                        obscureText: _imageGenerationGeminiApiKeyObscured,
                        decoration: InputDecoration(
                          labelText: 'Gemini API Key',
                          prefixIcon: const Icon(Icons.key_rounded),
                          suffixIcon: IconButton(
                            tooltip: _imageGenerationGeminiApiKeyObscured
                                ? '显示 Key'
                                : '隐藏 Key',
                            onPressed: () {
                              setState(() {
                                _imageGenerationGeminiApiKeyObscured =
                                    !_imageGenerationGeminiApiKeyObscured;
                              });
                            },
                            icon: Icon(
                              _imageGenerationGeminiApiKeyObscured
                                  ? Icons.visibility_rounded
                                  : Icons.visibility_off_rounded,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ImageProviderSettingsCard(
                    key: const ValueKey('image-provider-card-apimart'),
                    icon: Icons.hub_rounded,
                    title: 'APIMart',
                    subtitle: '独立官方接口 · 异步任务、上传与多模型系列',
                    actionKey: const ValueKey(
                      'save-image-generation-apimart-settings',
                    ),
                    actionLabel: '保存 APIMart 配置',
                    onSave: () =>
                        _saveApiMartImageGenerationSettings(settingsController),
                    children: [
                      TextField(
                        key: const ValueKey(
                          'image-generation-apimart-api-base-url-field',
                        ),
                        controller: _imageGenerationApiMartApiBaseUrlController,
                        decoration: const InputDecoration(
                          labelText: 'APIMart API 地址',
                          hintText: 'https://api.apimart.ai',
                          helperText: '可粘贴带 /v1 的地址，保存时会自动规范化',
                          prefixIcon: Icon(Icons.link_rounded),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const ValueKey(
                          'image-generation-apimart-api-key-field',
                        ),
                        controller: _imageGenerationApiMartApiKeyController,
                        obscureText: _imageGenerationApiMartApiKeyObscured,
                        decoration: InputDecoration(
                          labelText: 'APIMart API Key',
                          prefixIcon: const Icon(Icons.key_rounded),
                          suffixIcon: IconButton(
                            tooltip: _imageGenerationApiMartApiKeyObscured
                                ? '显示 Key'
                                : '隐藏 Key',
                            onPressed: () {
                              setState(() {
                                _imageGenerationApiMartApiKeyObscured =
                                    !_imageGenerationApiMartApiKeyObscured;
                              });
                            },
                            icon: Icon(
                              _imageGenerationApiMartApiKeyObscured
                                  ? Icons.visibility_rounded
                                  : Icons.visibility_off_rounded,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _CollapsibleSection(
              title: '软件更新',
              expanded: _sectionExpanded(_SettingsSection.updater),
              onToggle: () => _toggleSection(_SettingsSection.updater),
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
                    onSubmitted: settingsController.setUpdateManualProxyUrl,
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
                            icon: const Icon(Icons.system_update_alt_rounded),
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
            _CollapsibleSection(
              title: '数据目录',
              expanded: _sectionExpanded(_SettingsSection.dataDirectories),
              onToggle: () => _toggleSection(_SettingsSection.dataDirectories),
              child: Column(
                children: [
                  _PathTile(
                    label: '程序同级目录',
                    path: directories.executableDirectory.path,
                    onOpen: () =>
                        _openDirectory(directories.executableDirectory.path),
                  ),
                  _PathTile(
                    label: 'data',
                    path: directories.data.path,
                    onOpen: () => _openDirectory(directories.data.path),
                  ),
                  _PathTile(
                    label: 'imports',
                    path: directories.imports.path,
                    onOpen: () => _openDirectory(directories.imports.path),
                  ),
                  _PathTile(
                    label: 'cuts',
                    path: directories.cuts.path,
                    onOpen: () => _openDirectory(directories.cuts.path),
                  ),
                  _PathTile(
                    label: 'storyboards',
                    path: directories.storyboards.path,
                    onOpen: () => _openDirectory(directories.storyboards.path),
                  ),
                  _PathTile(
                    label: 'exports',
                    path: directories.exports.path,
                    onOpen: () => _openDirectory(directories.exports.path),
                  ),
                  _PathTile(
                    label: 'updates',
                    path: directories.updates.path,
                    onOpen: () => _openDirectory(directories.updates.path),
                  ),
                  _PathTile(
                    label: 'database',
                    path: directories.database.path,
                    onOpen: () => _openDirectory(directories.database.path),
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
            Text(
              '配置已持久化到 ${directories.databaseFile.path}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openDirectory(String path) async {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      await directory.create(recursive: true);
    }
    await Process.start('explorer.exe', [directory.path]);
  }
}

class _ImageProviderSettingsCard extends StatelessWidget {
  const _ImageProviderSettingsCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.children,
    required this.actionKey,
    required this.actionLabel,
    required this.onSave,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<Widget> children;
  final Key actionKey;
  final String actionLabel;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.7)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 21, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...children,
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            key: actionKey,
            onPressed: onSave,
            icon: const Icon(Icons.save_rounded),
            label: Text(actionLabel),
          ),
        ],
      ),
    );
  }
}

class _ProviderRouteHint extends StatelessWidget {
  const _ProviderRouteHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.route_rounded,
            size: 18,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
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

class _CollapsibleSection extends StatelessWidget {
  const _CollapsibleSection({
    required this.title,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  final String title;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
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
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: child,
            ),
          ),
        ],
      ),
    );
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
