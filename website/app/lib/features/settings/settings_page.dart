import 'package:flutter/material.dart';

import '../../core/models/remote_models.dart';
import '../workspace/remote_app_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.settingsAvailable) {
      return const Center(child: Text('当前桌面版本未开放远程设置选择'));
    }
    final settings = controller.settingsSelection;
    if (settings == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 980;
        final cards = [
          _SelectionCard(
            key: const ValueKey('settings-frame-extraction'),
            icon: Icons.video_settings_outlined,
            title: 'FFmpeg 抽帧方法',
            description: '选择桌面端已经支持的候选帧提取策略，不开放可执行文件路径。',
            options: settings.extractionStrategies,
            value: settings.selectedExtractionStrategy,
            enabled: _enabled(controller),
            onChanged: (value) =>
                controller.updateSettingsSelection(extractionStrategy: value),
          ),
          _SelectionCard(
            key: const ValueKey('settings-video-model'),
            icon: Icons.movie_creation_outlined,
            title: '视频生成模型',
            description: '切换桌面端已配置的视频生成后端。',
            options: settings.videoGenerationModels,
            value: settings.selectedVideoGenerationModelId,
            enabled: _enabled(controller),
            onChanged: (value) => controller.updateSettingsSelection(
              videoGenerationModelId: value,
            ),
          ),
          _SelectionCard(
            key: const ValueKey('settings-vision-model'),
            icon: Icons.visibility_outlined,
            title: '视觉模型',
            description: '用于视频帧解析、脚本理解和画面分析。',
            options: settings.visionModels,
            value: settings.selectedVisionModelId,
            enabled: _enabled(controller),
            onChanged: (value) =>
                controller.updateSettingsSelection(visionModelId: value),
          ),
          _SelectionCard(
            key: const ValueKey('settings-image-model'),
            icon: Icons.auto_awesome_outlined,
            title: '图片生成模型',
            description: '用于故事板生成、素材替换和分镜复刻。',
            options: settings.imageGenerationModels,
            value: settings.selectedImageGenerationModelId,
            enabled: _enabled(controller),
            onChanged: (value) => controller.updateSettingsSelection(
              imageGenerationModelId: value,
            ),
          ),
        ];
        return CustomScrollView(
          key: const ValueKey('remote-settings-page'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                wide ? 28 : 16,
                22,
                wide ? 28 : 16,
                28,
              ),
              sliver: SliverList.list(
                children: [
                  Text(
                    '设置',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '选择当前工程使用的本机能力',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _PermissionNotice(),
                  const SizedBox(height: 18),
                  GridView.count(
                    crossAxisCount: wide ? 2 : 1,
                    childAspectRatio: wide ? 2.05 : 1.8,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: cards,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static bool _enabled(RemoteAppController controller) =>
      controller.canEdit && !controller.settingsCommandBusy;
}

class _PermissionNotice extends StatelessWidget {
  const _PermissionNotice();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .42),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.primary.withValues(alpha: .22)),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.admin_panel_settings_outlined),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Web 端只能选择桌面端已经创建的配置。API 地址、API Key、本机路径、添加、编辑和删除配置均只在桌面软件中管理。',
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectionCard extends StatelessWidget {
  const _SelectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.options,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String description;
  final List<RemoteSettingsOption> options;
  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final validValue = options.any((item) => item.id == value) ? value : null;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                CircleAvatar(child: Icon(icon, size: 20)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
            DropdownButtonFormField<String>(
              initialValue: validValue,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: options.isEmpty ? '桌面端尚未配置' : '当前选择',
              ),
              items: [
                for (final option in options)
                  DropdownMenuItem(
                    value: option.id,
                    child: Text(
                      option.detail.trim().isEmpty
                          ? option.name
                          : '${option.name} · ${option.detail}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: enabled && options.isNotEmpty
                  ? (next) {
                      if (next != null && next != value) onChanged(next);
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
