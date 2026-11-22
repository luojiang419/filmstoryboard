import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../app/remote_app.dart';
import '../../core/models/remote_models.dart';
import '../exporter/exporter_page.dart';
import '../settings/settings_page.dart';
import '../storyboard/storyboard_review_page.dart';
import '../video_analysis/video_analysis_page.dart';
import '../video_generation/video_generation_page.dart';
import 'remote_app_controller.dart';

class WorkspacePage extends StatefulWidget {
  const WorkspacePage({super.key, required this.controller});

  final RemoteAppController controller;

  @override
  State<WorkspacePage> createState() => _WorkspacePageState();
}

class _WorkspacePageState extends State<WorkspacePage> {
  int _section = 0;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final desktop = constraints.maxWidth >= 960;
          final body = _WorkspaceBody(
            controller: widget.controller,
            section: _section,
            onSectionChanged: (value) => setState(() => _section = value),
            desktop: desktop,
          );
          return Scaffold(
            body: SafeArea(
              child: Stack(
                children: [
                  Positioned.fill(bottom: desktop ? 104 : 92, child: body),
                  Positioned(
                    left: 10,
                    right: 10,
                    bottom: 10,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: _WorkspaceDock(
                        selected: _section,
                        compact: !desktop,
                        onSelected: (value) => setState(() => _section = value),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

class _WorkspaceDock extends StatelessWidget {
  const _WorkspaceDock({
    required this.selected,
    required this.compact,
    required this.onSelected,
  });

  final int selected;
  final bool compact;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const destinations = [
      (Icons.space_dashboard_outlined, Icons.space_dashboard_rounded, '工作台'),
      (Icons.video_file_outlined, Icons.video_file_rounded, '视频解析'),
      (
        Icons.dashboard_customize_outlined,
        Icons.dashboard_customize_rounded,
        '故事板',
      ),
      (Icons.table_rows_outlined, Icons.table_rows_rounded, '拍摄脚本'),
      (
        Icons.auto_awesome_motion_outlined,
        Icons.auto_awesome_motion_rounded,
        '生成视频',
      ),
      (Icons.ios_share_outlined, Icons.ios_share_rounded, '导出'),
      (Icons.tune_outlined, Icons.tune_rounded, '设置'),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 780),
      child: Material(
        key: const ValueKey('workspace-bottom-dock'),
        elevation: 18,
        color: scheme.surfaceContainerHigh.withValues(alpha: .96),
        shadowColor: Colors.black.withValues(alpha: .34),
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: scheme.outlineVariant.withValues(alpha: .55),
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 7 : 11,
                vertical: 7,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < destinations.length; index++)
                    _DockItem(
                      selected: selected == index,
                      compact: compact,
                      icon: destinations[index].$1,
                      selectedIcon: destinations[index].$2,
                      label: destinations[index].$3,
                      onTap: () => onSelected(index),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.selected,
    required this.compact,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final bool compact;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Material(
        color: selected ? scheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(17),
        child: InkWell(
          key: ValueKey('workspace-dock-$label'),
          borderRadius: BorderRadius.circular(17),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: compact ? 72 : 96,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(selected ? selectedIcon : icon, size: 23),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 10 : 11,
                    fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
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

class _WorkspaceBody extends StatelessWidget {
  const _WorkspaceBody({
    required this.controller,
    required this.section,
    required this.onSectionChanged,
    required this.desktop,
  });

  final RemoteAppController controller;
  final int section;
  final ValueChanged<int> onSectionChanged;
  final bool desktop;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _TopBar(controller: controller, desktop: desktop),
      if (controller.busy) const LinearProgressIndicator(minHeight: 2),
      if (controller.errorMessage.isNotEmpty || controller.message.isNotEmpty)
        _StatusBanner(controller: controller),
      Expanded(
        child: controller.workspace?.project == null
            ? _NoProject(controller: controller)
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: section == 0
                    ? _Dashboard(
                        key: const ValueKey('dashboard'),
                        controller: controller,
                        onOpenStoryboards: () => onSectionChanged(2),
                        onOpenScripts: () => onSectionChanged(3),
                      )
                    : section == 1
                    ? VideoAnalysisPage(
                        key: const ValueKey('video-analysis'),
                        controller: controller,
                      )
                    : section == 2
                    ? StoryboardReviewPage(
                        key: const ValueKey('storyboards'),
                        controller: controller,
                      )
                    : section == 3
                    ? _ScriptWorkspace(
                        key: const ValueKey('scripts'),
                        controller: controller,
                      )
                    : section == 4
                    ? VideoGenerationPage(
                        key: const ValueKey('video-generation'),
                        controller: controller,
                      )
                    : section == 5
                    ? ExporterPage(
                        key: const ValueKey('exporter'),
                        controller: controller,
                      )
                    : SettingsPage(
                        key: const ValueKey('settings'),
                        controller: controller,
                      ),
              ),
      ),
    ],
  );
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, required this.desktop});

  final RemoteAppController controller;
  final bool desktop;

  @override
  Widget build(BuildContext context) {
    final project = controller.workspace?.project;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 74,
      padding: EdgeInsets.symmetric(horizontal: desktop ? 28 : 16),
      decoration: BoxDecoration(
        color: scheme.surface.withValues(alpha: .94),
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: .38),
          ),
        ),
      ),
      child: Row(
        children: [
          if (!desktop) ...[
            const BrandMark(size: 36),
            const SizedBox(width: 11),
          ],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project?.name ?? '等待桌面工程',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: controller.liveConnected
                            ? const Color(0xff43c78a)
                            : scheme.tertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      controller.liveConnected ? '实时同步中' : '正在恢复实时连接',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '刷新当前工程',
            onPressed: controller.busy ? null : controller.refreshAll,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            tooltip: '账户与连接',
            onSelected: (value) {
              if (value == 'projects') controller.showProjectSelection();
              if (value == 'logout') controller.logout();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Text(controller.session?.clientName ?? '远程客户端'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'projects',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.folder_open_rounded),
                  title: Text('切换工程'),
                ),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.logout_rounded),
                  title: Text('退出远程工作台'),
                ),
              ),
            ],
            child: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Text(
                (controller.session?.clientName ?? '导').characters.first,
                style: TextStyle(
                  color: scheme.onPrimaryContainer,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final error = controller.errorMessage.isNotEmpty;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      color: error ? scheme.errorContainer : const Color(0xff174a38),
      child: Row(
        children: [
          Icon(
            error
                ? Icons.info_outline_rounded
                : Icons.check_circle_outline_rounded,
            size: 18,
            color: error ? scheme.onErrorContainer : Colors.white,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              error ? controller.errorMessage : controller.message,
              style: TextStyle(
                color: error ? scheme.onErrorContainer : Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoProject extends StatelessWidget {
  const _NoProject({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.video_library_outlined,
            size: 68,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 18),
          Text(
            '桌面端尚未打开工程',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          const Text(
            '请在安装 FilmStoryboard 的电脑上打开一个工程，工作台会自动同步。',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 22),
          OutlinedButton.icon(
            onPressed: controller.refreshAll,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重新检查'),
          ),
        ],
      ),
    ),
  );
}

class _Dashboard extends StatelessWidget {
  const _Dashboard({
    super.key,
    required this.controller,
    required this.onOpenStoryboards,
    required this.onOpenScripts,
  });

  final RemoteAppController controller;
  final VoidCallback onOpenStoryboards;
  final VoidCallback onOpenScripts;

  @override
  Widget build(BuildContext context) {
    final project = controller.workspace!.project!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1280),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HeroCard(project: project, onOpenScripts: onOpenScripts),
              const SizedBox(height: 22),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 760 ? 3 : 1;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 14) / columns;
                  return Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      SizedBox(
                        width: width,
                        child: _StatCard(
                          icon: Icons.dashboard_customize_rounded,
                          label: '故事板',
                          value: '${project.storyboardCount}',
                          caption: controller.storyboardsAvailable
                              ? '可远程审阅与批注'
                              : '等待桌面端开放',
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _StatCard(
                          icon: Icons.table_rows_rounded,
                          label: '拍摄脚本',
                          value: '${project.scriptCount}',
                          caption: '当前工程版本',
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _StatCard(
                          icon: Icons.view_timeline_rounded,
                          label: '镜头总数',
                          value: '${project.shotCount}',
                          caption: '可远程审阅',
                        ),
                      ),
                      SizedBox(
                        width: width,
                        child: _StatCard(
                          icon: Icons.sync_rounded,
                          label: '同步状态',
                          value: controller.liveConnected ? '实时' : '恢复中',
                          caption: '桌面主机为数据源',
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 28),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: controller.storyboardsAvailable
                      ? onOpenStoryboards
                      : null,
                  icon: const Icon(Icons.dashboard_customize_outlined),
                  label: const Text('进入故事板审阅'),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Text(
                    '最近拍摄脚本',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: onOpenScripts,
                    child: const Text('查看全部'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (controller.scripts.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('当前工程还没有拍摄脚本。'),
                  ),
                )
              else
                ...controller.scripts
                    .take(4)
                    .map(
                      (script) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _RecentScriptTile(
                          script: script,
                          onTap: onOpenScripts,
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

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.project, required this.onOpenScripts});

  final RemoteProject project;
  final VoidCallback onOpenScripts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            scheme.primary,
            Color.lerp(scheme.primary, scheme.tertiary, .62)!,
          ],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: .25),
            blurRadius: 28,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '当前制作',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  project.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${project.scriptCount} 份脚本 · ${project.shotCount} 个镜头',
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: onOpenScripts,
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('继续审阅脚本'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: scheme.primary,
                  ),
                ),
              ],
            ),
          ),
          if (MediaQuery.sizeOf(context).width >= 720)
            Icon(
              Icons.movie_creation_rounded,
              color: Colors.white.withValues(alpha: .18),
              size: 130,
            ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.caption,
  });
  final IconData icon;
  final String label;
  final String value;
  final String caption;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          CircleAvatar(radius: 24, child: Icon(icon)),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(caption, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _RecentScriptTile extends StatelessWidget {
  const _RecentScriptTile({required this.script, required this.onTap});
  final RemoteScriptSummary script;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      leading: const CircleAvatar(child: Icon(Icons.description_outlined)),
      title: Text(
        script.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text('${script.shotCount} 个镜头 · 版本 ${script.version}'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: onTap,
    ),
  );
}

class _ScriptWorkspace extends StatefulWidget {
  const _ScriptWorkspace({super.key, required this.controller});
  final RemoteAppController controller;

  @override
  State<_ScriptWorkspace> createState() => _ScriptWorkspaceState();
}

class _ScriptWorkspaceState extends State<_ScriptWorkspace> {
  int _step = 0;

  RemoteAppController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.shootingWorkflowAvailable) {
      return LayoutBuilder(builder: _buildConfirmLayout);
    }
    return Column(
      children: [
        _ShootingWorkflowSteps(
          selected: _step,
          workflow: controller.shootingWorkflow,
          onSelected: (step) => setState(() => _step = step),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (_step) {
            0 => _ShootingPrepareAssetsStep(controller: controller),
            1 => LayoutBuilder(builder: _buildConfirmLayout),
            _ => _ShootingBuildStep(controller: controller),
          },
        ),
      ],
    );
  }

  Widget _buildConfirmLayout(BuildContext context, BoxConstraints constraints) {
    if (constraints.maxWidth >= 1120) {
      return Row(
        children: [
          SizedBox(width: 250, child: _ScriptList(controller: controller)),
          const VerticalDivider(width: 1),
          SizedBox(width: 340, child: _ShotList(controller: controller)),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                if (controller.shootingWorkflowAvailable)
                  _ConfirmShotsToolbar(controller: controller),
                Expanded(
                  child: _ShotInspector(
                    controller: controller,
                    shot: controller.selectedShot,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        if (controller.shootingWorkflowAvailable)
          _ConfirmShotsToolbar(controller: controller),
        Expanded(child: _CompactScriptWorkspace(controller: controller)),
      ],
    );
  }
}

class _ShootingWorkflowSteps extends StatelessWidget {
  const _ShootingWorkflowSteps({
    required this.selected,
    required this.workflow,
    required this.onSelected,
  });

  final int selected;
  final RemoteShootingWorkflow? workflow;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        '准备资产',
        '匹配当前脚本参考资产',
        Icons.inventory_2_outlined,
        workflow?.prepareAssetsStatus ?? 'pending',
        const ValueKey('shooting-step-prepare'),
      ),
      (
        '确认镜头',
        '核对并编辑全部镜头',
        Icons.fact_check_outlined,
        workflow?.confirmShotsStatus ?? 'pending',
        const ValueKey('shooting-step-confirm'),
      ),
      (
        '构建与复刻',
        '构建提示词并复刻分镜',
        Icons.account_tree_outlined,
        workflow?.composePromptsStatus ?? 'pending',
        const ValueKey('shooting-step-build'),
      ),
    ];
    return SizedBox(
      height: 94,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final item = items[index];
          final active = selected == index;
          return SizedBox(
            width: 260,
            child: Card(
              key: item.$5,
              color: active
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => onSelected(index),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    children: [
                      CircleAvatar(child: Icon(item.$3)),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${index + 1}. ${item.$1}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              item.$2,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        item.$4 == 'completed'
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: item.$4 == 'completed'
                            ? Colors.green
                            : Theme.of(context).colorScheme.outline,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ShootingPrepareAssetsStep extends StatelessWidget {
  const _ShootingPrepareAssetsStep({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final workflow = controller.shootingWorkflow;
    return LayoutBuilder(
      builder: (context, constraints) {
        final content = _PrepareAssetsContent(
          controller: controller,
          workflow: workflow,
        );
        if (constraints.maxWidth < 980) return content;
        return Row(
          children: [
            SizedBox(width: 250, child: _ScriptList(controller: controller)),
            const VerticalDivider(width: 1),
            Expanded(child: content),
          ],
        );
      },
    );
  }
}

class _PrepareAssetsContent extends StatelessWidget {
  const _PrepareAssetsContent({
    required this.controller,
    required this.workflow,
  });

  final RemoteAppController controller;
  final RemoteShootingWorkflow? workflow;

  @override
  Widget build(BuildContext context) {
    final script = controller.selectedScript;
    final currentWorkflow = workflow;
    if (script == null || currentWorkflow == null) {
      return const Center(child: Text('选择一份拍摄脚本以准备资产'));
    }
    return SingleChildScrollView(
      key: const ValueKey('shooting-prepare-assets-page'),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '步骤 1 · 准备资产',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    Text(
                      '${currentWorkflow.assets.length} 个资产 · ${currentWorkflow.links.length} 条镜头匹配',
                    ),
                  ],
                ),
              ),
              FilledButton.icon(
                key: const ValueKey('match-shooting-assets'),
                onPressed:
                    controller.canEdit &&
                        !controller.shootingWorkflowCommandBusy &&
                        !currentWorkflow.isBusy
                    ? () =>
                          controller.startShootingWorkflowAction('matchAssets')
                    : null,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('自动匹配资产'),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (currentWorkflow.assets.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('当前脚本还没有可用参考资产，请先在桌面资产库准备素材。'),
              ),
            )
          else
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final asset in currentWorkflow.assets)
                  SizedBox(
                    width: 280,
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 92,
                            height: 76,
                            child: _RemoteFrame(
                              controller: controller,
                              mediaId: asset.mediaId,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  asset.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                Text(
                                  '#${asset.referenceNumber} · ${asset.type}',
                                ),
                                Text(
                                  '${currentWorkflow.links.where((link) => link.assetId == asset.id).length} 个镜头已匹配',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 22),
          Text(
            '镜头匹配结果',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          for (final shot in script.shots)
            Card(
              child: ListTile(
                leading: CircleAvatar(child: Text('${shot.shotNumber}')),
                title: Text(
                  shot.content.isEmpty ? '镜头 ${shot.shotNumber}' : shot.content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${currentWorkflow.links.where((link) => link.shotId == shot.id).length} 个匹配资产',
                ),
                trailing: const Icon(Icons.link_rounded),
              ),
            ),
        ],
      ),
    );
  }
}

class _ConfirmShotsToolbar extends StatelessWidget {
  const _ConfirmShotsToolbar({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
    child: Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        FilledButton.tonalIcon(
          key: const ValueKey('confirm-shooting-shots'),
          onPressed:
              controller.canEdit && !controller.shootingWorkflowCommandBusy
              ? controller.confirmShootingWorkflowShots
              : null,
          icon: const Icon(Icons.done_all_rounded),
          label: const Text('确认全部镜头'),
        ),
        FilledButton.icon(
          key: const ValueKey('build-shooting-script'),
          onPressed:
              controller.canEdit && !controller.shootingWorkflowCommandBusy
              ? () => controller.startShootingWorkflowAction('buildScript')
              : null,
          icon: const Icon(Icons.account_tree_outlined),
          label: const Text('构建脚本'),
        ),
      ],
    ),
  );
}

class _ShootingBuildStep extends StatelessWidget {
  const _ShootingBuildStep({required this.controller});

  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final workflow = controller.shootingWorkflow;
    final script = controller.selectedScript;
    if (workflow == null || script == null) {
      return const Center(child: Text('选择一份拍摄脚本开始构建'));
    }
    return SingleChildScrollView(
      key: const ValueKey('shooting-build-page'),
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 40),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '步骤 3 · 构建脚本与复刻分镜',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '构建进度 ${workflow.analysisCompleted}/${workflow.analysisTotal} · '
                '${workflow.promptCount} 个提示词 · ${workflow.replicas.length} 个复刻结果',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    key: const ValueKey('build-shooting-script-final'),
                    onPressed:
                        controller.canEdit &&
                            !controller.shootingWorkflowCommandBusy &&
                            !workflow.isBusy
                        ? () => controller.startShootingWorkflowAction(
                            'buildScript',
                          )
                        : null,
                    icon: const Icon(Icons.account_tree_outlined),
                    label: const Text('构建脚本'),
                  ),
                  FilledButton.tonalIcon(
                    key: const ValueKey('replicate-all-storyboards'),
                    onPressed:
                        controller.canEdit &&
                            workflow.promptCount > 0 &&
                            !controller.shootingWorkflowCommandBusy &&
                            !workflow.isBusy
                        ? () => controller.startShootingWorkflowAction(
                            'replicateStoryboards',
                          )
                        : null,
                    icon: const Icon(Icons.auto_awesome_motion_outlined),
                    label: const Text('复刻全部分镜'),
                  ),
                  OutlinedButton.icon(
                    key: const ValueKey('replicate-selected-storyboard'),
                    onPressed:
                        controller.canEdit &&
                            controller.selectedShot != null &&
                            workflow.promptCount > 0 &&
                            !controller.shootingWorkflowCommandBusy &&
                            !workflow.isBusy
                        ? () => controller.startShootingWorkflowAction(
                            'replicateStoryboards',
                            shotId: controller.selectedShot!.id,
                          )
                        : null,
                    icon: const Icon(Icons.filter_center_focus_rounded),
                    label: const Text('复刻当前镜头'),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Text(
                '可恢复任务',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              if (controller.shootingWorkflowTasks.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('还没有脚本构建或复刻任务。'),
                  ),
                )
              else
                for (final task in controller.shootingWorkflowTasks)
                  Card(
                    child: ListTile(
                      leading: Icon(
                        task.terminal
                            ? task.status == 'succeeded'
                                  ? Icons.check_circle_outline_rounded
                                  : Icons.error_outline_rounded
                            : Icons.sync_rounded,
                      ),
                      title: Text(_shootingTaskLabel(task.kind)),
                      subtitle: Text(
                        task.errorMessage.isNotEmpty
                            ? task.errorMessage
                            : task.message,
                      ),
                      trailing: task.cancellable
                          ? IconButton(
                              tooltip: '取消任务',
                              onPressed: () =>
                                  controller.cancelRemoteTask(task.id),
                              icon: const Icon(Icons.stop_circle_outlined),
                            )
                          : Text(task.status),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

String _shootingTaskLabel(String kind) => switch (kind) {
  'shootingAssetMatch' => '匹配资产',
  'shootingScriptBuild' => '构建脚本',
  'storyboardReplication' => '复刻分镜',
  _ => kind,
};

class _CompactScriptWorkspace extends StatelessWidget {
  const _CompactScriptWorkspace({required this.controller});
  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: DropdownButtonFormField<String>(
          initialValue: controller.selectedScript?.id,
          decoration: const InputDecoration(
            labelText: '拍摄脚本',
            prefixIcon: Icon(Icons.description_outlined),
          ),
          items: [
            for (final script in controller.scripts)
              DropdownMenuItem(
                value: script.id,
                child: Text(script.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (value) {
            if (value != null) controller.selectScript(value);
          },
        ),
      ),
      SizedBox(
        height: 86,
        child: ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          scrollDirection: Axis.horizontal,
          itemCount: controller.selectedScript?.shots.length ?? 0,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final shot = controller.selectedScript!.shots[index];
            return ChoiceChip(
              selected: controller.selectedShot?.id == shot.id,
              onSelected: (_) => controller.selectShot(shot.id),
              avatar: CircleAvatar(child: Text('${shot.shotNumber}')),
              label: SizedBox(
                width: 120,
                child: Text(
                  shot.content.isEmpty ? '镜头 ${shot.shotNumber}' : shot.content,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            );
          },
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: _ShotInspector(
          controller: controller,
          shot: controller.selectedShot,
        ),
      ),
    ],
  );
}

class _ScriptList extends StatelessWidget {
  const _ScriptList({required this.controller});
  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const _PaneHeader(icon: Icons.description_outlined, title: '拍摄脚本'),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.all(10),
          itemCount: controller.scripts.length,
          itemBuilder: (context, index) {
            final script = controller.scripts[index];
            final selected = script.id == controller.selectedScript?.id;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                selected: selected,
                selectedTileColor: Theme.of(
                  context,
                ).colorScheme.primaryContainer.withValues(alpha: .65),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                title: Text(
                  script.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text('${script.shotCount} 镜头 · v${script.version}'),
                onTap: () => controller.selectScript(script.id),
              ),
            );
          },
        ),
      ),
    ],
  );
}

class _ShotList extends StatelessWidget {
  const _ShotList({required this.controller});
  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final script = controller.selectedScript;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PaneHeader(
          icon: Icons.view_timeline_outlined,
          title: script == null ? '镜头' : '${script.shotCount} 个镜头',
        ),
        Expanded(
          child: script == null
              ? const Center(child: Text('选择一份拍摄脚本'))
              : ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: script.shots.length,
                  itemBuilder: (context, index) {
                    final shot = script.shots[index];
                    return _ShotTile(
                      shot: shot,
                      selected: controller.selectedShot?.id == shot.id,
                      controller: controller,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ShotTile extends StatelessWidget {
  const _ShotTile({
    required this.shot,
    required this.selected,
    required this.controller,
  });
  final RemoteShot shot;
  final bool selected;
  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: .72)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: () => controller.selectShot(shot.id),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                SizedBox(
                  width: 88,
                  height: 58,
                  child: _RemoteFrame(
                    controller: controller,
                    mediaId: shot.frameMediaId,
                  ),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '镜头 ${shot.shotNumber}',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          const Spacer(),
                          Text(
                            '${shot.durationSeconds.toStringAsFixed(1)}s',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        shot.content.isEmpty ? '未填写镜头内容' : shot.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
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

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Container(
    height: 62,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    alignment: Alignment.centerLeft,
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
      ],
    ),
  );
}

class _ShotInspector extends StatefulWidget {
  const _ShotInspector({required this.controller, required this.shot});
  final RemoteAppController controller;
  final RemoteShot? shot;

  @override
  State<_ShotInspector> createState() => _ShotInspectorState();
}

class _ShotInspectorState extends State<_ShotInspector> {
  final Map<String, TextEditingController> _fields = {};
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _load(widget.shot);
  }

  @override
  void didUpdateWidget(covariant _ShotInspector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shot?.id != widget.shot?.id ||
        oldWidget.shot != widget.shot) {
      _load(widget.shot);
    }
  }

  void _load(RemoteShot? shot) {
    final values = <String, String>{
      'durationSeconds': shot?.durationSeconds.toStringAsFixed(1) ?? '',
      'content': shot?.content ?? '',
      'visual': shot?.visual ?? '',
      'shotSize': shot?.shotSize ?? '',
      'cameraMovement': shot?.cameraMovement ?? '',
      'composition': shot?.composition ?? '',
      'cameraAngle': shot?.cameraAngle ?? '',
      'lightingMood': shot?.lightingMood ?? '',
      'colorPalette': shot?.colorPalette ?? '',
      'scene': shot?.scene ?? '',
      'dialogue': shot?.dialogue ?? '',
      'sound': shot?.sound ?? '',
      'prompt': shot?.prompt ?? '',
      'generationFeedback': shot?.generationFeedback ?? '',
    };
    for (final entry in values.entries) {
      (_fields[entry.key] ??= TextEditingController()).text = entry.value;
    }
    _dirty = false;
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shot = widget.shot;
    if (shot == null) return const Center(child: Text('选择一个镜头开始审阅'));
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '镜头 ${shot.shotNumber}',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        Text(
                          '远程修改会保存到桌面端当前工程',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _dirty && !widget.controller.busy ? _save : null,
                    icon: const Icon(Icons.cloud_done_outlined),
                    label: const Text('保存同步'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              AspectRatio(
                aspectRatio: 16 / 7,
                child: _RemoteFrame(
                  controller: widget.controller,
                  mediaId: shot.frameMediaId,
                  large: true,
                ),
              ),
              const SizedBox(height: 22),
              _SectionTitle('叙事与画面'),
              const SizedBox(height: 10),
              _field('content', '镜头内容', lines: 3),
              const SizedBox(height: 12),
              _field('visual', '画面描述', lines: 3),
              const SizedBox(height: 18),
              _SectionTitle('镜头语言'),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth >= 620
                      ? (constraints.maxWidth - 12) / 2
                      : constraints.maxWidth;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: width,
                        child: _field('durationSeconds', '时长（秒）'),
                      ),
                      SizedBox(width: width, child: _field('shotSize', '景别')),
                      SizedBox(
                        width: width,
                        child: _field('cameraMovement', '运镜'),
                      ),
                      SizedBox(
                        width: width,
                        child: _field('composition', '构图'),
                      ),
                      SizedBox(
                        width: width,
                        child: _field('cameraAngle', '机位角度'),
                      ),
                      SizedBox(
                        width: width,
                        child: _field('lightingMood', '光影氛围'),
                      ),
                      SizedBox(
                        width: width,
                        child: _field('colorPalette', '色彩调性'),
                      ),
                      SizedBox(width: width, child: _field('scene', '场景')),
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),
              _SectionTitle('声音与生成'),
              const SizedBox(height: 10),
              _field('dialogue', '台词', lines: 2),
              const SizedBox(height: 12),
              _field('sound', '音乐 / 音效', lines: 2),
              const SizedBox(height: 12),
              _field('prompt', '最终提示词', lines: 5),
              const SizedBox(height: 12),
              _field('generationFeedback', '生成反馈', lines: 3),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _dirty && !widget.controller.busy ? _save : null,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存镜头修改'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String key, String label, {int lines = 1}) => TextField(
    key: ValueKey('shot-field-$key'),
    controller: _fields[key],
    minLines: lines,
    maxLines: lines,
    keyboardType: key == 'durationSeconds'
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.multiline,
    decoration: InputDecoration(labelText: label),
    onChanged: (_) {
      if (!_dirty) {
        setState(() => _dirty = true);
      }
    },
  );

  void _save() {
    final duration = double.tryParse(_fields['durationSeconds']!.text.trim());
    if (duration == null) return;
    widget.controller.saveSelectedShot({
      'durationSeconds': duration,
      for (final key in const [
        'content',
        'visual',
        'shotSize',
        'cameraMovement',
        'composition',
        'cameraAngle',
        'lightingMood',
        'colorPalette',
        'scene',
        'dialogue',
        'sound',
        'prompt',
        'generationFeedback',
      ])
        key: _fields[key]!.text,
    });
    setState(() => _dirty = false);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
  );
}

class _RemoteFrame extends StatelessWidget {
  const _RemoteFrame({
    required this.controller,
    required this.mediaId,
    this.large = false,
  });
  final RemoteAppController controller;
  final String? mediaId;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            scheme.surfaceContainerHighest,
            scheme.primaryContainer.withValues(alpha: .45),
          ],
        ),
        borderRadius: BorderRadius.circular(large ? 18 : 10),
      ),
      child: Center(
        child: Icon(
          Icons.image_outlined,
          color: scheme.onSurfaceVariant,
          size: large ? 42 : 24,
        ),
      ),
    );
    if (mediaId == null) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(large ? 18 : 10),
      child: FutureBuilder<Uint8List>(
        future: controller.mediaBytes(mediaId!),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return placeholder;
          return Image.memory(
            snapshot.data!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => placeholder,
          );
        },
      ),
    );
  }
}
