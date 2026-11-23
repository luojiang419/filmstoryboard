import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers/app_providers.dart';
import '../core/widgets/middle_drag_auto_scroll.dart';
import '../features/updater/domain/app_update_config.dart';
import '../features/settings/domain/app_settings.dart';
import 'app_theme.dart';
import 'window_fullscreen_controller.dart';
import '../features/projects/presentation/project_portal.dart';

class StoryboardApp extends ConsumerStatefulWidget {
  const StoryboardApp({
    super.key,
    this.enableWindowControls = true,
    this.initialTabIndex = 0,
    this.initialProjectIndexPath,
  });

  final bool enableWindowControls;
  final int initialTabIndex;
  final String? initialProjectIndexPath;

  @override
  ConsumerState<StoryboardApp> createState() => _StoryboardAppState();
}

class _StoryboardAppState extends ConsumerState<StoryboardApp> {
  late final MiddleDragAutoScrollController _middleDragScrollController;

  @override
  void initState() {
    super.initState();
    _middleDragScrollController = MiddleDragAutoScrollController();
    unawaited(ref.read(remoteAccessControllerProvider).initialize());
  }

  @override
  Widget build(BuildContext context) {
    final settingsController = ref.watch(settingsControllerProvider);
    return ValueListenableBuilder(
      valueListenable: settingsController,
      builder: (context, settings, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: AppUpdateConfig.windowTitle,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: settings.themePreference.themeMode,
          scrollBehavior: MiddleDragScrollBehavior(
            controller: _middleDragScrollController,
          ),
          home: WindowFullscreenController(
            child: MiddleDragAutoScroll(
              controller: _middleDragScrollController,
              child: ProjectPortal(
                initialProjectIndexPath: widget.initialProjectIndexPath,
              ),
            ),
          ),
        );
      },
    );
  }
}

extension on AppThemePreference {
  ThemeMode get themeMode {
    return switch (this) {
      AppThemePreference.system => ThemeMode.system,
      AppThemePreference.light => ThemeMode.light,
      AppThemePreference.dark => ThemeMode.dark,
    };
  }
}
