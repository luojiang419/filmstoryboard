import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/settings/application/settings_controller.dart';
import '../../features/settings/data/settings_repository.dart';
import '../../features/settings/data/resolve_plugin_installer.dart';
import '../../features/projects/application/project_service.dart';
import '../../features/projects/application/project_aspect_controller.dart';
import '../../features/projects/data/project_aspect_repository.dart';
import '../../features/projects/data/legacy_project_migrator.dart';
import '../../features/projects/data/project_catalog_repository.dart';
import '../../features/projects/data/project_operations_service.dart';
import '../../features/remote_access/application/remote_access_facade.dart';
import '../../features/remote_access/application/remote_access_controller.dart';
import '../../features/remote_access/application/remote_export_registry.dart';
import '../../features/remote_access/application/remote_media_registry.dart';
import '../../features/remote_access/application/remote_project_registry.dart';
import '../../features/remote_access/application/remote_settings_registry.dart';
import '../../features/remote_access/application/remote_shooting_workflow_registry.dart';
import '../../features/remote_access/application/remote_storyboard_registry.dart';
import '../../features/remote_access/application/remote_task_registry.dart';
import '../../features/remote_access/application/remote_upload_registry.dart';
import '../../features/remote_access/application/remote_video_analysis_registry.dart';
import '../../features/remote_access/application/remote_video_generation_registry.dart';
import '../../features/remote_access/application/remote_workspace_registry.dart';
import '../../features/remote_access/data/remote_access_repository.dart';
import '../../features/remote_access/domain/remote_events.dart';
import '../../features/updater/application/updater_controller.dart';
import '../../features/updater/data/updater_service.dart';
import '../database/app_database.dart';
import '../services/app_directories.dart';
import '../services/desktop_file_dialog_service.dart';
import '../services/workspace_directories.dart';

final globalDatabaseProvider = Provider<AppDatabase>((ref) {
  throw StateError('全局数据库尚未初始化');
});

final appDirectoriesProvider = Provider<AppDirectories>((ref) {
  throw StateError('AppDirectories 尚未初始化');
});

final desktopFileDialogServiceProvider = Provider<DesktopFileDialogService>((
  ref,
) {
  final directories = ref.watch(appDirectoriesProvider);
  final service = DesktopFileDialogService(
    defaultDirectory: directories.imports,
    logsDirectory: directories.logs,
  );
  ref.onDispose(service.dispose);
  return service;
}, dependencies: [appDirectoriesProvider]);

final appDatabaseProvider = Provider<AppDatabase>((ref) {
  return ref.watch(projectDatabaseProvider);
}, dependencies: [projectDatabaseProvider]);

final projectDatabaseProvider = Provider<AppDatabase>((ref) {
  return ref.watch(globalDatabaseProvider);
}, dependencies: []);

final projectDirectoriesProvider = Provider<WorkspaceDirectories>((ref) {
  return ref.watch(appDirectoriesProvider);
}, dependencies: []);

final currentProjectNameProvider = Provider<String>(
  (ref) => '项目',
  dependencies: [],
);

final projectAspectControllerProvider = Provider<ProjectAspectController>((
  ref,
) {
  final controller = ProjectAspectController(
    repository: ProjectAspectRepository(ref.watch(appDatabaseProvider)),
  );
  ref.onDispose(controller.dispose);
  return controller;
}, dependencies: [appDatabaseProvider]);

final remoteChangeBusProvider = Provider<RemoteChangeBus>((ref) {
  final bus = RemoteChangeBus();
  ref.onDispose(() => unawaited(bus.close()));
  return bus;
}, dependencies: const []);

final remoteWorkspaceRegistryProvider = Provider<RemoteWorkspaceRegistry>((
  ref,
) {
  return RemoteWorkspaceRegistry(ref.watch(remoteChangeBusProvider));
}, dependencies: [remoteChangeBusProvider]);

final remoteProjectRegistryProvider = Provider<RemoteProjectRegistry>((ref) {
  return RemoteProjectRegistry(changeBus: ref.watch(remoteChangeBusProvider));
}, dependencies: [remoteChangeBusProvider]);

final remoteMediaRegistryProvider = Provider<RemoteMediaRegistry>((ref) {
  return RemoteMediaRegistry(
    workspaceRegistry: ref.watch(remoteWorkspaceRegistryProvider),
  );
}, dependencies: [remoteWorkspaceRegistryProvider]);

final remoteTaskRegistryProvider = Provider<RemoteTaskRegistry>((ref) {
  return RemoteTaskRegistry(
    workspaceRegistry: ref.watch(remoteWorkspaceRegistryProvider),
    changeBus: ref.watch(remoteChangeBusProvider),
  );
}, dependencies: [remoteWorkspaceRegistryProvider, remoteChangeBusProvider]);

final remoteExportRegistryProvider = Provider<RemoteExportRegistry>(
  (ref) {
    final registry = RemoteExportRegistry(
      workspaceRegistry: ref.watch(remoteWorkspaceRegistryProvider),
      changeBus: ref.watch(remoteChangeBusProvider),
      taskRegistry: ref.watch(remoteTaskRegistryProvider),
    );
    ref.onDispose(registry.dispose);
    return registry;
  },
  dependencies: [
    remoteWorkspaceRegistryProvider,
    remoteChangeBusProvider,
    remoteTaskRegistryProvider,
  ],
);

final remoteUploadRegistryProvider = Provider<RemoteUploadRegistry>((ref) {
  return RemoteUploadRegistry(
    workspaceRegistry: ref.watch(remoteWorkspaceRegistryProvider),
  );
}, dependencies: [remoteWorkspaceRegistryProvider]);

final remoteVideoAnalysisRegistryProvider =
    Provider<RemoteVideoAnalysisRegistry>(
      (ref) {
        final registry = RemoteVideoAnalysisRegistry(
          workspaceRegistry: ref.watch(remoteWorkspaceRegistryProvider),
          changeBus: ref.watch(remoteChangeBusProvider),
          mediaRegistry: ref.watch(remoteMediaRegistryProvider),
          uploadRegistry: ref.watch(remoteUploadRegistryProvider),
          taskRegistry: ref.watch(remoteTaskRegistryProvider),
        );
        ref.onDispose(registry.dispose);
        return registry;
      },
      dependencies: [
        remoteWorkspaceRegistryProvider,
        remoteChangeBusProvider,
        remoteMediaRegistryProvider,
        remoteUploadRegistryProvider,
        remoteTaskRegistryProvider,
      ],
    );

final remoteVideoGenerationRegistryProvider =
    Provider<RemoteVideoGenerationRegistry>(
      (ref) {
        final registry = RemoteVideoGenerationRegistry(
          workspaceRegistry: ref.watch(remoteWorkspaceRegistryProvider),
          changeBus: ref.watch(remoteChangeBusProvider),
          mediaRegistry: ref.watch(remoteMediaRegistryProvider),
          taskRegistry: ref.watch(remoteTaskRegistryProvider),
        );
        ref.onDispose(registry.dispose);
        return registry;
      },
      dependencies: [
        remoteWorkspaceRegistryProvider,
        remoteChangeBusProvider,
        remoteMediaRegistryProvider,
        remoteTaskRegistryProvider,
      ],
    );

final remoteStoryboardRegistryProvider = Provider<RemoteStoryboardRegistry>((
  ref,
) {
  final registry = RemoteStoryboardRegistry(
    workspaceRegistry: ref.watch(remoteWorkspaceRegistryProvider),
    changeBus: ref.watch(remoteChangeBusProvider),
  );
  ref.onDispose(registry.dispose);
  return registry;
}, dependencies: [remoteWorkspaceRegistryProvider, remoteChangeBusProvider]);

final remoteShootingWorkflowRegistryProvider =
    Provider<RemoteShootingWorkflowRegistry>(
      (ref) {
        final registry = RemoteShootingWorkflowRegistry(
          workspaceRegistry: ref.watch(remoteWorkspaceRegistryProvider),
          changeBus: ref.watch(remoteChangeBusProvider),
        );
        ref.onDispose(registry.dispose);
        return registry;
      },
      dependencies: [remoteWorkspaceRegistryProvider, remoteChangeBusProvider],
    );

final remoteSettingsRegistryProvider = Provider<RemoteSettingsRegistry>((ref) {
  final registry = RemoteSettingsRegistry(
    workspaceRegistry: ref.watch(remoteWorkspaceRegistryProvider),
    changeBus: ref.watch(remoteChangeBusProvider),
  );
  ref.onDispose(registry.dispose);
  return registry;
}, dependencies: [remoteWorkspaceRegistryProvider, remoteChangeBusProvider]);

final remoteAccessFacadeProvider = Provider<RemoteAccessFacade>(
  (ref) {
    return RemoteAccessFacade(
      workspaceRegistry: ref.watch(remoteWorkspaceRegistryProvider),
      changeBus: ref.watch(remoteChangeBusProvider),
      mediaRegistry: ref.watch(remoteMediaRegistryProvider),
      storyboardRegistry: ref.watch(remoteStoryboardRegistryProvider),
      shootingWorkflowRegistry: ref.watch(
        remoteShootingWorkflowRegistryProvider,
      ),
      projectRegistry: ref.watch(remoteProjectRegistryProvider),
      taskRegistry: ref.watch(remoteTaskRegistryProvider),
      exportRegistry: ref.watch(remoteExportRegistryProvider),
      videoAnalysisRegistry: ref.watch(remoteVideoAnalysisRegistryProvider),
      videoGenerationRegistry: ref.watch(remoteVideoGenerationRegistryProvider),
      settingsRegistry: ref.watch(remoteSettingsRegistryProvider),
    );
  },
  dependencies: [
    remoteWorkspaceRegistryProvider,
    remoteChangeBusProvider,
    remoteMediaRegistryProvider,
    remoteStoryboardRegistryProvider,
    remoteShootingWorkflowRegistryProvider,
    remoteProjectRegistryProvider,
    remoteTaskRegistryProvider,
    remoteExportRegistryProvider,
    remoteVideoAnalysisRegistryProvider,
    remoteVideoGenerationRegistryProvider,
    remoteSettingsRegistryProvider,
  ],
);

final remoteAccessControllerProvider = Provider<RemoteAccessController>(
  (ref) {
    final controller = RemoteAccessController(
      repository: RemoteAccessRepository(ref.watch(globalDatabaseProvider)),
      directories: ref.watch(appDirectoriesProvider),
      facade: ref.watch(remoteAccessFacadeProvider),
      changeBus: ref.watch(remoteChangeBusProvider),
      mediaRegistry: ref.watch(remoteMediaRegistryProvider),
      exportRegistry: ref.watch(remoteExportRegistryProvider),
      uploadRegistry: ref.watch(remoteUploadRegistryProvider),
    );
    ref.onDispose(controller.dispose);
    return controller;
  },
  dependencies: [
    globalDatabaseProvider,
    appDirectoriesProvider,
    remoteAccessFacadeProvider,
    remoteChangeBusProvider,
    remoteMediaRegistryProvider,
    remoteExportRegistryProvider,
    remoteUploadRegistryProvider,
  ],
);

final projectCatalogRepositoryProvider = Provider<ProjectCatalogRepository>((
  ref,
) {
  return ProjectCatalogRepository(ref.watch(globalDatabaseProvider));
});

final projectServiceProvider = Provider<ProjectService>((ref) {
  return ProjectService(catalog: ref.watch(projectCatalogRepositoryProvider));
});

final projectOperationsServiceProvider = Provider<ProjectOperationsService>((
  ref,
) {
  return ProjectOperationsService(
    catalog: ref.watch(projectCatalogRepositoryProvider),
  );
});

final legacyProjectMigratorProvider = Provider<LegacyProjectMigrator>((ref) {
  return LegacyProjectMigrator(
    appDirectories: ref.watch(appDirectoriesProvider),
    globalDatabase: ref.watch(globalDatabaseProvider),
    catalog: ref.watch(projectCatalogRepositoryProvider),
  );
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  throw StateError('SettingsRepository 尚未初始化');
});

final settingsControllerProvider = Provider<SettingsController>((ref) {
  throw StateError('SettingsController 尚未初始化');
});

final resolvePluginInstallerProvider = Provider<ResolvePluginInstaller>((ref) {
  return const ResolvePluginInstaller();
});

final updaterServiceProvider = Provider<UpdaterService>((ref) {
  return UpdaterService(directories: ref.watch(appDirectoriesProvider));
});

final updaterControllerProvider = Provider<UpdaterController>((ref) {
  final controller = UpdaterController(
    settingsController: ref.watch(settingsControllerProvider),
    settingsRepository: ref.watch(settingsRepositoryProvider),
    service: ref.watch(updaterServiceProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
