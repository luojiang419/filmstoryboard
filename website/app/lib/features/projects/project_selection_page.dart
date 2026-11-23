import 'package:flutter/material.dart';
import '../../app/remote_app.dart';
import '../../core/models/remote_models.dart';
import '../workspace/remote_app_controller.dart';

class ProjectSelectionPage extends StatelessWidget {
  const ProjectSelectionPage({super.key, required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.surface,
              scheme.primaryContainer.withValues(alpha: .24),
              scheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _ProjectHeader(controller: controller),
              if (controller.busy) const LinearProgressIndicator(minHeight: 2),
              if (controller.errorMessage.isNotEmpty)
                _ProjectError(message: controller.errorMessage),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: controller.refreshProjects,
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(24, 26, 24, 12),
                        sliver: SliverToBoxAdapter(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1180),
                              child: const _ProjectIntro(),
                            ),
                          ),
                        ),
                      ),
                      if (controller.projects.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: _EmptyProjects(),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(24, 12, 24, 40),
                          sliver: SliverLayoutBuilder(
                            builder: (context, constraints) {
                              final width = constraints.crossAxisExtent;
                              final columns = width >= 1040
                                  ? 3
                                  : width >= 680
                                  ? 2
                                  : 1;
                              return SliverGrid(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      mainAxisSpacing: 16,
                                      crossAxisSpacing: 16,
                                      childAspectRatio: columns == 1
                                          ? 1.8
                                          : 1.42,
                                    ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) => _ProjectCard(
                                    project: controller.projects[index],
                                    enabled:
                                        controller.canEdit && !controller.busy,
                                    onOpen: () => controller.openProject(
                                      controller.projects[index].id,
                                    ),
                                  ),
                                  childCount: controller.projects.length,
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 18, 20, 14),
    child: Row(
      children: [
        const BrandMark(size: 40),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            'FilmStoryboard',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
        ),
        IconButton(
          tooltip: '刷新工程列表',
          onPressed: controller.busy ? null : controller.refreshProjects,
          icon: const Icon(Icons.refresh_rounded),
        ),
        const SizedBox(width: 4),
        TextButton.icon(
          onPressed: controller.busy ? null : controller.logout,
          icon: const Icon(Icons.logout_rounded, size: 19),
          label: const Text('退出'),
        ),
      ],
    ),
  );
}

class _ProjectIntro extends StatelessWidget {
  const _ProjectIntro();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '选择要继续的工程',
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w900),
      ),
      const SizedBox(height: 9),
      Text(
        '工程由本机 FilmStoryboard 安全打开。进入后可使用视频解析、故事板、拍摄脚本、生成视频和导出。',
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          height: 1.55,
        ),
      ),
    ],
  );
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.enabled,
    required this.onOpen,
  });

  final RemoteProjectEntry project;
  final bool enabled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final available = project.canOpen;
    return Card(
      key: ValueKey('remote-project-${project.id}'),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: available && enabled ? onOpen : null,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: available
                        ? scheme.primaryContainer
                        : scheme.errorContainer,
                    child: Icon(
                      available
                          ? Icons.movie_creation_outlined
                          : Icons.link_off_rounded,
                      color: available
                          ? scheme.onPrimaryContainer
                          : scheme.onErrorContainer,
                    ),
                  ),
                  const Spacer(),
                  if (project.isActive)
                    const Chip(
                      avatar: Icon(Icons.desktop_windows_rounded, size: 16),
                      label: Text('桌面当前'),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                project.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              const Spacer(),
              Text(
                available
                    ? '最近打开 ${_date(project.lastOpenedAt)}'
                    : _availabilityLabel(project.availability),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: available ? scheme.onSurfaceVariant : scheme.error,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    available
                        ? Icons.arrow_forward_rounded
                        : Icons.warning_amber_rounded,
                    size: 18,
                  ),
                  const SizedBox(width: 7),
                  Text(
                    available ? '进入工程' : '请在桌面端处理',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _date(DateTime? value) {
    if (value == null) return '未知时间';
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  static String _availabilityLabel(String value) => switch (value) {
    'missing' => '工程位置已失效',
    'newerVersion' => '需要更新桌面软件',
    _ => '工程索引不可用',
  };
}

class _EmptyProjects extends StatelessWidget {
  const _EmptyProjects();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.video_library_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 18),
          const Text(
            '本机还没有可选择的工程',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          const Text('请先在桌面软件创建或导入工程，然后下拉刷新。'),
        ],
      ),
    ),
  );
}

class _ProjectError extends StatelessWidget {
  const _ProjectError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    color: Theme.of(context).colorScheme.errorContainer,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
    ),
  );
}
