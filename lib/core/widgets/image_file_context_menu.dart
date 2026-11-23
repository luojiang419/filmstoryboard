import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pasteboard/pasteboard.dart';

import '../services/file_explorer_service.dart';

enum _ImageFileAction { copy, openDirectory }

class ImageFileContextMenuAction<T> {
  const ImageFileContextMenuAction({
    required this.value,
    required this.icon,
    required this.label,
  });

  final T value;
  final IconData icon;
  final String label;
}

Future<T?> showImageFileContextMenu<T>(
  BuildContext context, {
  required Offset globalPosition,
  required String imagePath,
  List<ImageFileContextMenuAction<T>> leadingActions = const [],
  List<ImageFileContextMenuAction<T>> trailingActions = const [],
}) async {
  final action = await showMenu<Object?>(
    context: context,
    position: RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      globalPosition.dx,
      globalPosition.dy,
    ),
    items: [
      for (final action in leadingActions)
        PopupMenuItem<Object?>(
          value: action.value,
          child: _ImageFileMenuItem(icon: action.icon, label: action.label),
        ),
      if (leadingActions.isNotEmpty) const PopupMenuDivider(height: 1),
      const PopupMenuItem<Object?>(
        value: _ImageFileAction.copy,
        child: _ImageFileMenuItem(icon: Icons.copy_rounded, label: '复制'),
      ),
      const PopupMenuItem<Object?>(
        value: _ImageFileAction.openDirectory,
        child: _ImageFileMenuItem(
          icon: Icons.folder_open_rounded,
          label: '打开目录',
        ),
      ),
      if (trailingActions.isNotEmpty) const PopupMenuDivider(height: 1),
      for (final action in trailingActions)
        PopupMenuItem<Object?>(
          value: action.value,
          child: _ImageFileMenuItem(icon: action.icon, label: action.label),
        ),
    ],
  );
  if (!context.mounted || action == null) {
    return null;
  }
  if (action is _ImageFileAction) {
    switch (action) {
      case _ImageFileAction.copy:
        await _copyImageFile(context, imagePath);
        break;
      case _ImageFileAction.openDirectory:
        await _openImageDirectory(context, imagePath);
        break;
    }
    return null;
  }
  return action as T;
}

Future<void> _copyImageFile(BuildContext context, String imagePath) async {
  final file = File(imagePath);
  if (!file.existsSync()) {
    _showMessage(context, '图片文件不存在');
    return;
  }
  final copied = await Pasteboard.writeFiles([file.path]);
  if (!context.mounted) {
    return;
  }
  if (copied) {
    _showMessage(context, '已复制图片');
    return;
  }
  Pasteboard.writeText(file.path);
  _showMessage(context, '已复制图片路径');
}

Future<void> _openImageDirectory(BuildContext context, String imagePath) async {
  final file = File(imagePath);
  if (!file.existsSync()) {
    _showMessage(context, '图片文件不存在');
    return;
  }
  final directory = file.parent;
  if (!directory.existsSync()) {
    _showMessage(context, '图片目录不存在');
    return;
  }
  final opened = await const FileExplorerService().revealFile(file.path);
  if (!context.mounted) {
    return;
  }
  if (!opened) {
    _showMessage(context, '图片文件不存在');
  }
}

void _showMessage(BuildContext context, String message) {
  // 操作结果不再通过底部横幅播报，保留调用点以维持菜单流程。
}

class _ImageFileMenuItem extends StatelessWidget {
  const _ImageFileMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon, size: 18), const SizedBox(width: 10), Text(label)],
    );
  }
}
