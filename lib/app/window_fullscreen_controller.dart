import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

class WindowFullscreenController extends StatefulWidget {
  const WindowFullscreenController({super.key, required this.child});

  final Widget child;

  @override
  State<WindowFullscreenController> createState() =>
      _WindowFullscreenControllerState();
}

class _WindowFullscreenControllerState extends State<WindowFullscreenController>
    with WindowListener {
  bool _isFullscreen = false;
  bool _f11IsDown = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKeyEvent);
    windowManager.addListener(this);
    unawaited(_syncFullscreenState());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent);
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowEnterFullScreen() {
    _setFullscreenState(true);
  }

  @override
  void onWindowLeaveFullScreen() {
    _setFullscreenState(false);
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.f11) {
      return false;
    }
    if (event is KeyUpEvent) {
      _f11IsDown = false;
      return true;
    }
    if (event is! KeyDownEvent || _f11IsDown) {
      return true;
    }
    _f11IsDown = true;
    unawaited(_toggleFullscreen());
    return true;
  }

  Future<void> _syncFullscreenState() async {
    try {
      _setFullscreenState(await windowManager.isFullScreen());
    } on MissingPluginException {
      _setFullscreenState(false);
    }
  }

  Future<void> _toggleFullscreen() async {
    final next = !_isFullscreen;
    _setFullscreenState(next);
    try {
      await windowManager.setFullScreen(next);
    } on MissingPluginException {
      _setFullscreenState(false);
    } catch (_) {
      _setFullscreenState(await _safeIsFullscreen());
    }
  }

  Future<bool> _safeIsFullscreen() async {
    try {
      return await windowManager.isFullScreen();
    } on MissingPluginException {
      return false;
    }
  }

  void _setFullscreenState(bool value) {
    if (_isFullscreen == value || !mounted) {
      return;
    }
    setState(() {
      _isFullscreen = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return WindowFullscreenScope(
      isFullscreen: _isFullscreen,
      child: widget.child,
    );
  }
}

class WindowFullscreenScope extends InheritedWidget {
  const WindowFullscreenScope({
    super.key,
    required this.isFullscreen,
    required super.child,
  });

  final bool isFullscreen;

  static bool isFullscreenOf(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<WindowFullscreenScope>()
            ?.isFullscreen ??
        false;
  }

  @override
  bool updateShouldNotify(WindowFullscreenScope oldWidget) {
    return oldWidget.isFullscreen != isFullscreen;
  }
}
