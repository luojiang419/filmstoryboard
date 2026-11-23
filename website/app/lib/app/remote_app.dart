import 'package:flutter/material.dart';

import '../core/theme/remote_theme.dart';
import '../features/auth/pairing_page.dart';
import '../features/projects/project_selection_page.dart';
import '../features/workspace/remote_app_controller.dart';
import '../features/workspace/workspace_page.dart';

class FilmStoryboardRemoteApp extends StatefulWidget {
  const FilmStoryboardRemoteApp({super.key, required this.controller});

  final RemoteAppController controller;

  @override
  State<FilmStoryboardRemoteApp> createState() =>
      _FilmStoryboardRemoteAppState();
}

class _FilmStoryboardRemoteAppState extends State<FilmStoryboardRemoteApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.initialize();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'FilmStoryboard 多平台工作台',
    theme: RemoteTheme.light(),
    darkTheme: RemoteTheme.dark(),
    themeMode: ThemeMode.system,
    home: AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) => switch (widget.controller.phase) {
        RemoteAppPhase.loading => const _AppLoadingPage(),
        RemoteAppPhase.signedOut => PairingPage(controller: widget.controller),
        RemoteAppPhase.projectSelection => ProjectSelectionPage(
          controller: widget.controller,
        ),
        RemoteAppPhase.ready => WorkspacePage(controller: widget.controller),
      },
    ),
  );
}

class _AppLoadingPage extends StatelessWidget {
  const _AppLoadingPage();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BrandMark(size: 58),
          const SizedBox(height: 22),
          Text(
            '正在连接导演工作台',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 18),
          const SizedBox(
            width: 180,
            child: LinearProgressIndicator(
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
          ),
        ],
      ),
    ),
  );
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 44});

  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: key,
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
        borderRadius: BorderRadius.circular(size * .3),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: .3),
            blurRadius: size * .45,
            offset: Offset(0, size * .18),
          ),
        ],
      ),
      child: Icon(
        Icons.movie_filter_rounded,
        color: Colors.white,
        size: size * .55,
      ),
    );
  }
}
