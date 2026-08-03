import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/app_shell.dart';
import '../../../app/window_title_bar.dart';
import '../../../core/providers/app_providers.dart';
import '../application/project_workspace_controller.dart';
import '../domain/project_models.dart';

class ProjectPortal extends ConsumerStatefulWidget {
  const ProjectPortal({super.key, this.initialProjectIndexPath});

  final String? initialProjectIndexPath;

  @override
  ConsumerState<ProjectPortal> createState() => _ProjectPortalState();
}

class _ProjectPortalState extends ConsumerState<ProjectPortal> {
  static const _projectFileType = XTypeGroup(
    label: '故事板工程',
    extensions: ['storyboard'],
  );

  late final ProjectWorkspaceController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ProjectWorkspaceController(
      appDirectories: ref.read(appDirectoriesProvider),
      globalDatabase: ref.read(globalDatabaseProvider),
      catalog: ref.read(projectCatalogRepositoryProvider),
      projectService: ref.read(projectServiceProvider),
      legacyMigrator: ref.read(legacyProjectMigratorProvider),
    )..addListener(_handleChanged);
    unawaited(
      _controller.initialize(
        initialProjectIndexPath: widget.initialProjectIndexPath,
      ),
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_handleChanged);
    unawaited(_controller.disposeSession());
    _controller.dispose();
    super.dispose();
  }

  void _handleChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.phase == ProjectWorkspacePhase.editor) {
      final session = _controller.session!;
      return ProviderScope(
        key: ValueKey(session.manifest.projectId),
        overrides: [
          projectDatabaseProvider.overrideWithValue(session.database),
          projectDirectoriesProvider.overrideWithValue(session.directories),
          currentProjectNameProvider.overrideWithValue(session.manifest.name),
        ],
        child: AppShell(
          projectName: session.manifest.name,
          onCloseProject: _controller.closeProject,
        ),
      );
    }

    final body = switch (_controller.phase) {
      ProjectWorkspacePhase.booting ||
      ProjectWorkspacePhase.opening => _ProjectLoadingPage(
        message: _controller.phase == ProjectWorkspacePhase.booting
            ? '正在检查工程与旧版数据...'
            : '正在打开工程...',
      ),
      ProjectWorkspacePhase.welcome => _WelcomePage(
        projects: _controller.projects.take(5).toList(),
        showOnStartup: _controller.showWelcomeOnStartup,
        warning: _controller.migrationWarning,
        onCreate: _createProject,
        onOpen: _openProjectPicker,
        onOpenEntry: _openEntry,
        onEnterHome: _controller.enterHome,
        onShowOnStartupChanged: _controller.setShowWelcomeOnStartup,
        onRetryMigration: _retryMigration,
      ),
      ProjectWorkspacePhase.home => _ProjectHomePage(
        projects: _controller.projects,
        defaultRoot: _controller.defaultProjectRoot.path,
        warning: _controller.migrationWarning,
        onCreate: _createProject,
        onOpen: _openProjectPicker,
        onImport: _importProjectPackage,
        onOpenEntry: _openEntry,
        onChangeRoot: _changeDefaultRoot,
        onRename: _renameProject,
        onDelete: _removeProjectFromHome,
        onMigrate: _migrateProject,
        onExport: _exportProject,
        onShowWelcome: _controller.showWelcome,
        onRetryMigration: _retryMigration,
      ),
      ProjectWorkspacePhase.editor => const SizedBox.shrink(),
    };
    return Scaffold(
      body: Column(
        children: [
          const WindowTitleBar(),
          Expanded(
            child: DropTarget(
              onDragDone: (detail) {
                final files = detail.files
                    .where(
                      (file) => file.path.toLowerCase().endsWith('.storyboard'),
                    )
                    .toList();
                if (files.isNotEmpty) {
                  unawaited(_openIndex(File(files.first.path)));
                }
              },
              child: body,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createProject() async {
    final request = await showDialog<_CreateProjectRequest>(
      context: context,
      builder: (context) => _CreateProjectDialog(
        initialParentDirectory: _controller.defaultProjectRoot,
      ),
    );
    if (request == null || !mounted) {
      return;
    }
    try {
      await _controller.createProject(
        name: request.name,
        parentDirectory: request.parentDirectory,
      );
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _openProjectPicker() async {
    final file = await openFile(
      acceptedTypeGroups: const [_projectFileType],
      confirmButtonText: '打开工程',
    );
    if (file != null) {
      await _openIndex(File(file.path));
    }
  }

  Future<void> _openEntry(ProjectEntry entry) async {
    if (!entry.exists) {
      await _openProjectPicker();
      return;
    }
    await _openIndex(File(entry.indexPath));
  }

  Future<void> _openIndex(File file) async {
    try {
      await _controller.openProject(file);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _changeDefaultRoot() async {
    final path = await getDirectoryPath(confirmButtonText: '选择工程根目录');
    if (path == null) {
      return;
    }
    try {
      await _controller.setDefaultProjectRoot(Directory(path));
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _removeProjectFromHome(ProjectEntry entry) async {
    final decision = await showDialog<_DeleteProjectDecision>(
      context: context,
      builder: (context) => _DeleteProjectDialog(project: entry),
    );
    if (decision == null) {
      return;
    }
    if (!decision.permanent) {
      _controller.removeFromCatalog(entry.projectId);
      return;
    }
    try {
      await _runOperation(
        '正在永久删除工程...',
        () => ref
            .read(projectOperationsServiceProvider)
            .permanentlyDeleteProject(
              entry: entry,
              defaultProjectRoot: _controller.defaultProjectRoot,
              confirmedName: decision.confirmedName,
            ),
      );
      _controller.refreshProjects();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _renameProject(ProjectEntry entry) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _RenameProjectDialog(
        initialName: entry.displayName,
        validateName: ref.read(projectServiceProvider).validateProjectName,
      ),
    );
    if (name == null || name == entry.displayName || !mounted) {
      return;
    }
    try {
      await _controller.renameProject(entry, name);
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _migrateProject(ProjectEntry entry) async {
    final path = await getDirectoryPath(confirmButtonText: '选择迁移目标位置');
    if (path == null) {
      return;
    }
    try {
      await _runOperation('正在迁移并校验工程...', () async {
        await ref
            .read(projectOperationsServiceProvider)
            .migrateProject(entry: entry, targetParent: Directory(path));
      });
      _controller.refreshProjects();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _exportProject(ProjectEntry entry) async {
    final safeName = entry.displayName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
    final timestamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
    final location = await getSaveLocation(
      suggestedName: '${safeName}_$timestamp.storyboard.zip',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'ZIP 工程包', extensions: ['zip']),
      ],
      confirmButtonText: '导出工程包',
    );
    if (location == null) {
      return;
    }
    try {
      await _runOperation('正在打包并校验工程...', () async {
        await ref
            .read(projectOperationsServiceProvider)
            .exportProject(entry: entry, outputFile: File(location.path));
      });
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _importProjectPackage() async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(label: '故事板工程包', extensions: ['zip']),
      ],
      confirmButtonText: '导入工程包',
    );
    if (file == null) {
      return;
    }
    try {
      late ProjectEntry imported;
      await _runOperation('正在导入工程包...', () async {
        imported = await ref
            .read(projectOperationsServiceProvider)
            .importPackage(
              packageFile: File(file.path),
              projectRoot: _controller.defaultProjectRoot,
            );
      });
      await _controller.openProject(File(imported.indexPath));
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _retryMigration() async {
    try {
      await _controller.retryLegacyMigration();
    } catch (error) {
      _showError(error);
    }
  }

  Future<void> _runOperation(
    String message,
    Future<void> Function() operation,
  ) async {
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: Row(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(width: 20),
                Expanded(child: Text(message)),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      await operation();
    } finally {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    }
  }

  void _showError(Object error) {
    if (!mounted) {
      return;
    }
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('操作失败'),
          content: SelectableText(error.toString()),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectLoadingPage extends StatelessWidget {
  const _ProjectLoadingPage({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 42,
            height: 42,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          const SizedBox(height: 20),
          Text(message, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage({
    required this.projects,
    required this.showOnStartup,
    required this.warning,
    required this.onCreate,
    required this.onOpen,
    required this.onOpenEntry,
    required this.onEnterHome,
    required this.onShowOnStartupChanged,
    required this.onRetryMigration,
  });

  final List<ProjectEntry> projects;
  final bool showOnStartup;
  final String? warning;
  final VoidCallback onCreate;
  final VoidCallback onOpen;
  final ValueChanged<ProjectEntry> onOpenEntry;
  final VoidCallback onEnterHome;
  final ValueChanged<bool> onShowOnStartupChanged;
  final VoidCallback onRetryMigration;

  @override
  Widget build(BuildContext context) {
    return _ProjectShortcuts(
      onCreate: onCreate,
      onOpen: onOpen,
      onImport: onEnterHome,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal = constraints.maxWidth >= 1040;
          final hero = _WelcomeHero(
            onCreate: onCreate,
            onOpen: onOpen,
            onEnterHome: onEnterHome,
          );
          final recent = _WelcomeRecentProjects(
            projects: projects,
            showOnStartup: showOnStartup,
            warning: warning,
            onOpenEntry: onOpenEntry,
            onShowOnStartupChanged: onShowOnStartupChanged,
            onRetryMigration: onRetryMigration,
          );
          return Padding(
            padding: const EdgeInsets.all(28),
            child: horizontal
                ? Row(
                    children: [
                      Expanded(flex: 6, child: hero),
                      const SizedBox(width: 24),
                      Expanded(flex: 5, child: recent),
                    ],
                  )
                : ListView(
                    children: [hero, const SizedBox(height: 20), recent],
                  ),
          );
        },
      ),
    );
  }
}

class _WelcomeHero extends StatelessWidget {
  const _WelcomeHero({
    required this.onCreate,
    required this.onOpen,
    required this.onEnterHome,
  });

  final VoidCallback onCreate;
  final VoidCallback onOpen;
  final VoidCallback onEnterHome;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(42),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: const Color(0xFF2B2B2B),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 58, color: scheme.primary),
          const SizedBox(height: 24),
          Text(
            '欢迎使用故事板',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '从一个独立工程开始整理素材、裁切画面并完成故事板。工程可以自由移动、打包和分发。',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: Colors.white70, height: 1.6),
          ),
          const SizedBox(height: 32),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                key: const ValueKey('welcome-create-project'),
                onPressed: onCreate,
                icon: const Icon(Icons.add_rounded),
                label: const Text('创建新工程'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('welcome-open-project'),
                onPressed: onOpen,
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('打开工程'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          TextButton.icon(
            onPressed: onEnterHome,
            icon: const Icon(Icons.dashboard_outlined),
            label: const Text('进入工程首页'),
          ),
        ],
      ),
    );
  }
}

class _WelcomeRecentProjects extends StatelessWidget {
  const _WelcomeRecentProjects({
    required this.projects,
    required this.showOnStartup,
    required this.warning,
    required this.onOpenEntry,
    required this.onShowOnStartupChanged,
    required this.onRetryMigration,
  });

  final List<ProjectEntry> projects;
  final bool showOnStartup;
  final String? warning;
  final ValueChanged<ProjectEntry> onOpenEntry;
  final ValueChanged<bool> onShowOnStartupChanged;
  final VoidCallback onRetryMigration;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('最近工程', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            if (warning != null)
              _MigrationWarning(message: warning!, onRetry: onRetryMigration),
            if (projects.isEmpty)
              const Expanded(
                child: Center(
                  child: Text(
                    '还没有工程\n创建第一个工程后会显示在这里',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: projects.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final project = projects[index];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      leading: Icon(
                        project.exists
                            ? Icons.movie_creation_outlined
                            : Icons.link_off_rounded,
                      ),
                      title: Text(project.displayName),
                      subtitle: Text(
                        project.exists ? project.indexPath : '位置已变化，点击重新定位',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => onOpenEntry(project),
                    );
                  },
                ),
              ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启动时显示欢迎页'),
              value: showOnStartup,
              onChanged: onShowOnStartupChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectHomePage extends StatefulWidget {
  const _ProjectHomePage({
    required this.projects,
    required this.defaultRoot,
    required this.warning,
    required this.onCreate,
    required this.onOpen,
    required this.onImport,
    required this.onOpenEntry,
    required this.onChangeRoot,
    required this.onRename,
    required this.onDelete,
    required this.onMigrate,
    required this.onExport,
    required this.onShowWelcome,
    required this.onRetryMigration,
  });

  final List<ProjectEntry> projects;
  final String defaultRoot;
  final String? warning;
  final VoidCallback onCreate;
  final VoidCallback onOpen;
  final VoidCallback onImport;
  final ValueChanged<ProjectEntry> onOpenEntry;
  final VoidCallback onChangeRoot;
  final ValueChanged<ProjectEntry> onRename;
  final ValueChanged<ProjectEntry> onDelete;
  final ValueChanged<ProjectEntry> onMigrate;
  final ValueChanged<ProjectEntry> onExport;
  final VoidCallback onShowWelcome;
  final VoidCallback onRetryMigration;

  @override
  State<_ProjectHomePage> createState() => _ProjectHomePageState();
}

enum _ProjectSort { lastOpened, updated, name }

class _ProjectHomePageState extends State<_ProjectHomePage> {
  String _query = '';
  _ProjectSort _sort = _ProjectSort.lastOpened;

  @override
  Widget build(BuildContext context) {
    final projects = widget.projects.where((project) {
      final query = _query.trim().toLowerCase();
      return query.isEmpty ||
          project.displayName.toLowerCase().contains(query) ||
          project.indexPath.toLowerCase().contains(query);
    }).toList();
    projects.sort(
      (a, b) => switch (_sort) {
        _ProjectSort.lastOpened => b.lastOpenedAt.compareTo(a.lastOpenedAt),
        _ProjectSort.updated => b.updatedAt.compareTo(a.updatedAt),
        _ProjectSort.name => a.displayName.compareTo(b.displayName),
      },
    );
    return _ProjectShortcuts(
      onCreate: widget.onCreate,
      onOpen: widget.onOpen,
      onImport: widget.onImport,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('工程首页', style: Theme.of(context).textTheme.headlineSmall),
                const Spacer(),
                IconButton(
                  tooltip: '返回欢迎页',
                  onPressed: widget.onShowWelcome,
                  icon: const Icon(Icons.waving_hand_outlined),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: const ValueKey('home-create-project'),
                  onPressed: widget.onCreate,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('创建工程'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onOpen,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('打开工程'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onImport,
                  icon: const Icon(Icons.unarchive_outlined),
                  label: const Text('导入工程包'),
                ),
                SizedBox(
                  width: 260,
                  child: TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: '搜索工程名称或路径',
                    ),
                  ),
                ),
                DropdownButton<_ProjectSort>(
                  value: _sort,
                  onChanged: (value) => setState(() => _sort = value!),
                  items: const [
                    DropdownMenuItem(
                      value: _ProjectSort.lastOpened,
                      child: Text('最近打开'),
                    ),
                    DropdownMenuItem(
                      value: _ProjectSort.updated,
                      child: Text('最近修改'),
                    ),
                    DropdownMenuItem(
                      value: _ProjectSort.name,
                      child: Text('名称'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.folder_special_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '默认工程目录：${widget.defaultRoot}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: widget.onChangeRoot,
                  child: const Text('更改'),
                ),
              ],
            ),
            if (widget.warning != null)
              _MigrationWarning(
                message: widget.warning!,
                onRetry: widget.onRetryMigration,
              ),
            const SizedBox(height: 10),
            Expanded(
              child: projects.isEmpty
                  ? _EmptyProjectHome(
                      onCreate: widget.onCreate,
                      hasSearch: _query.isNotEmpty,
                    )
                  : GridView.builder(
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 360,
                            mainAxisExtent: 230,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 16,
                          ),
                      itemCount: projects.length,
                      itemBuilder: (context, index) {
                        final project = projects[index];
                        return _ProjectCard(
                          project: project,
                          defaultRoot: widget.defaultRoot,
                          onOpen: () => widget.onOpenEntry(project),
                          onRename: () => widget.onRename(project),
                          onDelete: () => widget.onDelete(project),
                          onMigrate: () => widget.onMigrate(project),
                          onExport: () => widget.onExport(project),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    required this.project,
    required this.defaultRoot,
    required this.onOpen,
    required this.onRename,
    required this.onDelete,
    required this.onMigrate,
    required this.onExport,
  });

  final ProjectEntry project;
  final String defaultRoot;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onMigrate;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = switch (project.health) {
      ProjectHealth.available => (
        '正常',
        scheme.primary,
        Icons.check_circle_outline_rounded,
      ),
      ProjectHealth.missing => ('位置已变化', scheme.error, Icons.link_off_rounded),
      ProjectHealth.invalid => (
        '索引损坏',
        scheme.error,
        Icons.error_outline_rounded,
      ),
      ProjectHealth.newerVersion => (
        '需要更新软件',
        scheme.tertiary,
        Icons.system_update_rounded,
      ),
    };
    final isDefault = File(project.indexPath).parent.path
        .toLowerCase()
        .startsWith(Directory(defaultRoot).absolute.path.toLowerCase());
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.movie_creation_outlined),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      project.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                project.indexPath,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _StatusChip(
                    label: status.$1,
                    color: status.$2,
                    icon: status.$3,
                  ),
                  _StatusChip(
                    label: isDefault ? '默认位置' : '自定义位置',
                    color: scheme.secondary,
                    icon: Icons.folder_outlined,
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '修改于 ${DateFormat('yyyy-MM-dd HH:mm').format(project.updatedAt.toLocal())}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  IconButton(
                    key: ValueKey('rename-project-${project.projectId}'),
                    tooltip: '重命名',
                    onPressed: onRename,
                    icon: const Icon(Icons.edit_outlined),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                  ),
                  IconButton(
                    tooltip: '删除',
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline_rounded),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                  ),
                  IconButton(
                    tooltip: '迁移',
                    onPressed: onMigrate,
                    icon: const Icon(Icons.drive_file_move_outline),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                  ),
                  IconButton(
                    tooltip: '导出',
                    onPressed: onExport,
                    icon: const Icon(Icons.archive_outlined),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 36,
                      height: 36,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.color,
    required this.icon,
  });

  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color)),
        ],
      ),
    );
  }
}

class _EmptyProjectHome extends StatelessWidget {
  const _EmptyProjectHome({required this.onCreate, required this.hasSearch});

  final VoidCallback onCreate;
  final bool hasSearch;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.video_library_outlined, size: 64),
          const SizedBox(height: 16),
          Text(hasSearch ? '没有匹配的工程' : '还没有故事板工程'),
          if (!hasSearch) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add_rounded),
              label: const Text('创建第一个工程'),
            ),
          ],
        ],
      ),
    );
  }
}

class _MigrationWarning extends StatelessWidget {
  const _MigrationWarning({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(child: Text(message)),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _ProjectShortcuts extends StatelessWidget {
  const _ProjectShortcuts({
    required this.onCreate,
    required this.onOpen,
    required this.onImport,
    required this.child,
  });

  final VoidCallback onCreate;
  final VoidCallback onOpen;
  final VoidCallback onImport;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): onCreate,
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): onOpen,
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): onImport,
      },
      child: Focus(autofocus: true, child: child),
    );
  }
}

class _DeleteProjectDecision {
  const _DeleteProjectDecision({
    required this.permanent,
    this.confirmedName = '',
  });

  final bool permanent;
  final String confirmedName;
}

class _RenameProjectDialog extends StatefulWidget {
  const _RenameProjectDialog({
    required this.initialName,
    required this.validateName,
  });

  final String initialName;
  final String? Function(String value) validateName;

  @override
  State<_RenameProjectDialog> createState() => _RenameProjectDialogState();
}

class _RenameProjectDialogState extends State<_RenameProjectDialog> {
  late final TextEditingController _nameController;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initialName.length,
      );
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名工程'),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const ValueKey('rename-project-name'),
          controller: _nameController,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(
            labelText: '工程名称',
            errorText: _errorText,
            helperText: '只修改显示名称，不改变磁盘文件夹路径',
          ),
          onChanged: (_) {
            if (_errorText != null) {
              setState(() => _errorText = null);
            }
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm-rename-project'),
          onPressed: _submit,
          child: const Text('保存名称'),
        ),
      ],
    );
  }

  void _submit() {
    final name = _nameController.text.trim();
    final error = widget.validateName(name);
    if (error != null) {
      setState(() => _errorText = error);
      return;
    }
    Navigator.pop(context, name);
  }
}

class _DeleteProjectDialog extends StatefulWidget {
  const _DeleteProjectDialog({required this.project});

  final ProjectEntry project;

  @override
  State<_DeleteProjectDialog> createState() => _DeleteProjectDialogState();
}

class _DeleteProjectDialogState extends State<_DeleteProjectDialog> {
  final _confirmationController = TextEditingController();
  bool _permanent = false;

  @override
  void dispose() {
    _confirmationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canDelete =
        !_permanent ||
        _confirmationController.text == widget.project.displayName;
    return AlertDialog(
      title: const Text('删除工程'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('工程：${widget.project.displayName}'),
            const SizedBox(height: 12),
            const Text('默认只从首页移除记录，工程文件会继续保留在磁盘。'),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _permanent,
              onChanged: (value) {
                setState(() => _permanent = value ?? false);
              },
              title: const Text('永久删除整个工程文件夹'),
              subtitle: const Text('此操作不可恢复，将删除数据库、素材和导出文件。'),
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_permanent) ...[
              const SizedBox(height: 8),
              Text('请输入完整工程名“${widget.project.displayName}”确认：'),
              const SizedBox(height: 6),
              TextField(
                controller: _confirmationController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: '输入完整工程名'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canDelete
              ? () => Navigator.pop(
                  context,
                  _DeleteProjectDecision(
                    permanent: _permanent,
                    confirmedName: _confirmationController.text,
                  ),
                )
              : null,
          style: _permanent
              ? FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                )
              : null,
          child: Text(_permanent ? '永久删除' : '移出首页'),
        ),
      ],
    );
  }
}

class _CreateProjectRequest {
  const _CreateProjectRequest({
    required this.name,
    required this.parentDirectory,
  });

  final String name;
  final Directory parentDirectory;
}

class _CreateProjectDialog extends StatefulWidget {
  const _CreateProjectDialog({required this.initialParentDirectory});

  final Directory initialParentDirectory;

  @override
  State<_CreateProjectDialog> createState() => _CreateProjectDialogState();
}

class _CreateProjectDialogState extends State<_CreateProjectDialog> {
  final _nameController = TextEditingController();
  late Directory _parentDirectory;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _parentDirectory = widget.initialParentDirectory;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('创建故事板工程'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('create-project-name'),
              controller: _nameController,
              autofocus: true,
              maxLength: 80,
              decoration: InputDecoration(
                labelText: '工程名称',
                errorText: _errorText,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            const Text('创建位置'),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _parentDirectory.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  onPressed: _pickDirectory,
                  icon: const Icon(Icons.folder_open_rounded),
                  label: const Text('更改'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('软件会在所选位置内创建一个同名工程文件夹，不会覆盖已有目录。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm-create-project'),
          onPressed: _submit,
          child: const Text('创建并打开'),
        ),
      ],
    );
  }

  Future<void> _pickDirectory() async {
    final path = await getDirectoryPath(
      initialDirectory: _parentDirectory.path,
      confirmButtonText: '选择创建位置',
    );
    if (path != null && mounted) {
      setState(() => _parentDirectory = Directory(path));
    }
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _errorText = '请输入工程名称');
      return;
    }
    Navigator.pop(
      context,
      _CreateProjectRequest(name: name, parentDirectory: _parentDirectory),
    );
  }
}
