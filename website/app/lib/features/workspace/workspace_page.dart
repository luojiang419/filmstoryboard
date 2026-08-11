import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../../app/remote_app.dart';
import '../../core/models/remote_models.dart';
import '../storyboard/storyboard_review_page.dart';
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
              child: desktop
                  ? Row(
                      children: [
                        _SideNavigation(
                          selected: _section,
                          onSelected: (value) =>
                              setState(() => _section = value),
                        ),
                        Expanded(child: body),
                      ],
                    )
                  : body,
            ),
            bottomNavigationBar: desktop
                ? null
                : NavigationBar(
                    selectedIndex: _section,
                    onDestinationSelected: (value) =>
                        setState(() => _section = value),
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.space_dashboard_outlined),
                        selectedIcon: Icon(Icons.space_dashboard_rounded),
                        label: '工作台',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.dashboard_customize_outlined),
                        selectedIcon: Icon(Icons.dashboard_customize_rounded),
                        label: '故事板',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.table_rows_outlined),
                        selectedIcon: Icon(Icons.table_rows_rounded),
                        label: '拍摄脚本',
                      ),
                    ],
                  ),
          );
        },
      );
    },
  );
}

class _SideNavigation extends StatelessWidget {
  const _SideNavigation({required this.selected, required this.onSelected});

  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 236,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border(
          right: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: .45),
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                BrandMark(size: 38),
                SizedBox(width: 11),
                Expanded(
                  child: Text(
                    'FilmStoryboard',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 34),
          _NavItem(
            selected: selected == 0,
            icon: Icons.space_dashboard_outlined,
            selectedIcon: Icons.space_dashboard_rounded,
            label: '导演工作台',
            onTap: () => onSelected(0),
          ),
          const SizedBox(height: 8),
          _NavItem(
            selected: selected == 1,
            icon: Icons.dashboard_customize_outlined,
            selectedIcon: Icons.dashboard_customize_rounded,
            label: '故事板审阅',
            onTap: () => onSelected(1),
          ),
          const SizedBox(height: 8),
          _NavItem(
            selected: selected == 2,
            icon: Icons.table_rows_outlined,
            selectedIcon: Icons.table_rows_rounded,
            label: '拍摄脚本',
            onTap: () => onSelected(2),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: .45),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Row(
              children: [
                Icon(Icons.shield_outlined, size: 19),
                SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '本地数据 · 加密通道',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.selected,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Icon(selected ? selectedIcon : icon, size: 21),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
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
                        onOpenStoryboards: () => onSectionChanged(1),
                        onOpenScripts: () => onSectionChanged(2),
                      )
                    : section == 1
                    ? StoryboardReviewPage(
                        key: const ValueKey('storyboards'),
                        controller: controller,
                      )
                    : _ScriptWorkspace(
                        key: const ValueKey('scripts'),
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
              if (value == 'logout') controller.logout();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                enabled: false,
                child: Text(controller.session?.clientName ?? '远程客户端'),
              ),
              const PopupMenuDivider(),
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

class _ScriptWorkspace extends StatelessWidget {
  const _ScriptWorkspace({super.key, required this.controller});
  final RemoteAppController controller;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth >= 1120) {
        return Row(
          children: [
            SizedBox(width: 270, child: _ScriptList(controller: controller)),
            const VerticalDivider(width: 1),
            SizedBox(width: 360, child: _ShotList(controller: controller)),
            const VerticalDivider(width: 1),
            Expanded(
              child: _ShotInspector(
                controller: controller,
                shot: controller.selectedShot,
              ),
            ),
          ],
        );
      }
      return _CompactScriptWorkspace(controller: controller);
    },
  );
}

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
