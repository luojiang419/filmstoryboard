import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/database/app_database.dart';
import '../../../core/services/app_directories.dart';
import '../data/legacy_project_migrator.dart';
import '../data/project_catalog_repository.dart';
import '../domain/project_models.dart';
import '../domain/project_aspect_ratio.dart';
import 'project_service.dart';

enum ProjectWorkspacePhase { booting, welcome, home, opening, editor }

class ProjectWorkspaceController extends ChangeNotifier {
  ProjectWorkspaceController({
    required AppDirectories appDirectories,
    required AppDatabase globalDatabase,
    required ProjectCatalogRepository catalog,
    required ProjectService projectService,
    required LegacyProjectMigrator legacyMigrator,
  }) : _appDirectories = appDirectories,
       _globalDatabase = globalDatabase,
       _catalog = catalog,
       _projectService = projectService,
       _legacyMigrator = legacyMigrator;

  static const showWelcomeSettingKey = 'showWelcomeOnStartup';
  static const defaultProjectRootSettingKey = 'defaultProjectRoot';

  final AppDirectories _appDirectories;
  final AppDatabase _globalDatabase;
  final ProjectCatalogRepository _catalog;
  final ProjectService _projectService;
  final LegacyProjectMigrator _legacyMigrator;

  ProjectWorkspacePhase phase = ProjectWorkspacePhase.booting;
  List<ProjectEntry> projects = const [];
  ProjectSession? session;
  String? errorMessage;
  String? migrationWarning;

  bool get showWelcomeOnStartup =>
      _globalDatabase.getSetting(showWelcomeSettingKey) != 'false';

  Directory get defaultProjectRoot {
    final saved = _globalDatabase.getSetting(defaultProjectRootSettingKey);
    return Directory(
      saved == null || saved.trim().isEmpty
          ? _appDirectories.projects.path
          : saved.trim(),
    );
  }

  Future<void> initialize({String? initialProjectIndexPath}) async {
    phase = ProjectWorkspacePhase.booting;
    errorMessage = null;
    notifyListeners();
    try {
      await _legacyMigrator.migrateIfNeeded();
    } catch (error) {
      migrationWarning = '旧版数据接管未完成：$error';
    }
    refreshProjects();
    final initialPath = initialProjectIndexPath?.trim();
    if (initialPath != null && initialPath.isNotEmpty) {
      try {
        await openProject(File(initialPath));
        return;
      } catch (_) {
        // 启动参数无效时仍进入欢迎页/首页，并显示可恢复错误。
      }
    }
    phase = showWelcomeOnStartup
        ? ProjectWorkspacePhase.welcome
        : ProjectWorkspacePhase.home;
    notifyListeners();
  }

  void refreshProjects() {
    projects = _catalog.load();
    notifyListeners();
  }

  void enterHome() {
    phase = ProjectWorkspacePhase.home;
    errorMessage = null;
    notifyListeners();
  }

  void showWelcome() {
    phase = ProjectWorkspacePhase.welcome;
    errorMessage = null;
    notifyListeners();
  }

  void setShowWelcomeOnStartup(bool value) {
    _globalDatabase.setSetting(showWelcomeSettingKey, value.toString());
    notifyListeners();
  }

  Future<void> setDefaultProjectRoot(Directory directory) async {
    await _verifyWritableDirectory(directory);
    _globalDatabase.setSetting(
      defaultProjectRootSettingKey,
      directory.absolute.path,
    );
    notifyListeners();
  }

  Future<void> createProject({
    String? name,
    Directory? parentDirectory,
    ProjectAspectMode aspectMode = ProjectAspectMode.auto,
  }) async {
    final previousPhase = phase == ProjectWorkspacePhase.welcome
        ? ProjectWorkspacePhase.welcome
        : ProjectWorkspacePhase.home;
    phase = ProjectWorkspacePhase.opening;
    errorMessage = null;
    notifyListeners();
    try {
      final parent = parentDirectory ?? defaultProjectRoot;
      await _verifyWritableDirectory(parent);
      final opened = await _projectService.createProject(
        name: name ?? '',
        parentDirectory: parent,
        aspectMode: aspectMode,
      );
      session = opened;
      refreshProjects();
      phase = ProjectWorkspacePhase.editor;
      notifyListeners();
    } catch (error) {
      phase = previousPhase;
      errorMessage = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> openProject(File indexFile) async {
    final previousPhase = phase == ProjectWorkspacePhase.welcome
        ? ProjectWorkspacePhase.welcome
        : ProjectWorkspacePhase.home;
    phase = ProjectWorkspacePhase.opening;
    errorMessage = null;
    notifyListeners();
    try {
      final opened = await _projectService.openProject(indexFile);
      session = opened;
      refreshProjects();
      phase = ProjectWorkspacePhase.editor;
      notifyListeners();
    } catch (error) {
      phase = previousPhase;
      errorMessage = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> switchToCatalogProject(ProjectEntry entry) async {
    if (phase == ProjectWorkspacePhase.booting ||
        phase == ProjectWorkspacePhase.opening) {
      throw const ProjectException('桌面端正在切换工程，请稍后再试');
    }
    if (session?.manifest.projectId == entry.projectId) {
      return;
    }
    if (!entry.exists) {
      throw const ProjectException('工程当前不可用');
    }
    final closing = session;
    phase = ProjectWorkspacePhase.opening;
    errorMessage = null;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    try {
      final opened = await _projectService.openProject(File(entry.indexPath));
      session = opened;
      refreshProjects();
      phase = ProjectWorkspacePhase.editor;
      notifyListeners();
      if (closing != null) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await closing.close();
      }
    } catch (error) {
      session = closing;
      phase = closing == null
          ? ProjectWorkspacePhase.home
          : ProjectWorkspacePhase.editor;
      errorMessage = error.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> closeProject() async {
    final closing = session;
    session = null;
    refreshProjects();
    phase = ProjectWorkspacePhase.home;
    notifyListeners();
    if (closing != null) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await closing.close();
    }
  }

  void removeFromCatalog(String projectId) {
    _catalog.remove(projectId);
    refreshProjects();
  }

  Future<void> renameProject(ProjectEntry entry, String name) async {
    await _projectService.renameProject(entry: entry, name: name);
    refreshProjects();
  }

  Future<void> retryLegacyMigration() async {
    migrationWarning = null;
    try {
      await _legacyMigrator.migrateIfNeeded();
      refreshProjects();
    } catch (error) {
      migrationWarning = '旧版数据接管未完成：$error';
      notifyListeners();
      rethrow;
    }
  }

  Future<void> disposeSession() async {
    final current = session;
    session = null;
    if (current != null) {
      await current.close();
    }
  }

  Future<void> _verifyWritableDirectory(Directory directory) async {
    try {
      if (!directory.existsSync()) {
        await directory.create(recursive: true);
      }
      final probe = File(
        '${directory.path}${Platform.pathSeparator}.storyboard-write-test-${DateTime.now().microsecondsSinceEpoch}',
      );
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
    } catch (error) {
      throw ProjectException('工程目录不可写，请选择其他位置：$error');
    }
  }
}
