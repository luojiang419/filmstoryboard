import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'window_fullscreen_controller.dart';
import '../features/updater/domain/app_update_config.dart';

class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({
    super.key,
    this.enableWindowControls = true,
    this.title,
    this.actions = const [],
  });

  final bool enableWindowControls;
  final String? title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    if (WindowFullscreenScope.isFullscreenOf(context)) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 42,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.86),
        border: Border(
          bottom: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.42),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: _TitleDragRegion(
              enabled: enableWindowControls,
              title: title ?? AppUpdateConfig.windowTitle,
            ),
          ),
          ...actions,
          if (enableWindowControls) ...const [
            _WindowButton(
              icon: Icons.remove_rounded,
              tooltip: '最小化',
              action: _WindowAction.minimize,
            ),
            _WindowButton(
              icon: Icons.crop_square_rounded,
              tooltip: '最大化/还原',
              action: _WindowAction.maximize,
            ),
            _WindowButton(
              icon: Icons.close_rounded,
              tooltip: '关闭',
              action: _WindowAction.close,
              danger: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _TitleDragRegion extends StatelessWidget {
  const _TitleDragRegion({required this.enabled, required this.title});

  final bool enabled;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.only(left: 16, right: 12),
      child: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(5),
              color: scheme.primary,
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.34),
                  blurRadius: 12,
                ),
              ],
            ),
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 12,
              color: scheme.onPrimary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
    if (!enabled) {
      return content;
    }
    return DragToMoveArea(child: content);
  }
}

class _WindowButton extends StatelessWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.action,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final _WindowAction action;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: () async {
          switch (action) {
            case _WindowAction.minimize:
              await windowManager.minimize();
            case _WindowAction.maximize:
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
            case _WindowAction.close:
              await windowManager.close();
          }
        },
        child: SizedBox(
          width: 46,
          height: 42,
          child: Icon(
            icon,
            size: 18,
            color: danger ? scheme.error : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

enum _WindowAction { minimize, maximize, close }
