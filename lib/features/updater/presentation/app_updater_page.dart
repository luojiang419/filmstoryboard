import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/updater_service.dart';
import '../domain/update_models.dart';

class AppUpdaterPage extends StatefulWidget {
  const AppUpdaterPage({
    super.key,
    required this.session,
    required this.service,
    this.exitApplication,
  });

  final UpdaterInstallSession session;
  final UpdaterService service;
  final void Function(int exitCode)? exitApplication;

  @override
  State<AppUpdaterPage> createState() => _AppUpdaterPageState();
}

class _AppUpdaterPageState extends State<AppUpdaterPage> {
  static const _steps = ['准备安装', '关闭旧版本', '安装新版本', '启动新版本', '完成'];
  static const _backgroundColor = Color(0xFF101418);
  static const _panelColor = Color(0xFF171B20);
  static const _panelBorderColor = Color(0xFF30343A);
  static const _neutralAccent = Color(0xFFC5CBD3);
  static const _successAccent = Color(0xFF69B783);
  static const _errorAccent = Color(0xFFE06464);

  int _currentStep = 0;
  String _message = '正在准备独立更新器...';
  String _substep = '';
  bool _isError = false;
  bool _isSuccess = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_run());
    });
  }

  Future<void> _run() async {
    try {
      await widget.service.runUpdaterSession(
        widget.session,
        onProgress: (event) {
          if (!mounted) {
            return;
          }
          setState(() {
            _currentStep = event.stepIndex;
            _message = event.message;
            _substep = event.substep;
            _isError = event.isError;
            _isSuccess = event.isSuccess;
          });
        },
      );
      if (_isSuccess) {
        await Future<void>.delayed(const Duration(seconds: 2));
        _exit(0);
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isError = true;
        _message = '更新器执行失败：$error';
        _substep = '请重新打开故事板后在设置页重试。';
      });
    }
  }

  void _exit(int exitCode) {
    final exitApplication = widget.exitApplication;
    if (exitApplication != null) {
      exitApplication(exitCode);
      return;
    }
    exit(exitCode);
  }

  @override
  Widget build(BuildContext context) {
    final accent = _isError
        ? _errorAccent
        : _isSuccess
        ? _successAccent
        : _neutralAccent;
    return Scaffold(
      backgroundColor: _backgroundColor,
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 720),
          margin: const EdgeInsets.all(24),
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: _panelColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _panelBorderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.34),
                blurRadius: 28,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.11),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: accent.withValues(alpha: 0.22)),
                    ),
                    child: Icon(
                      _isError
                          ? Icons.error_outline_rounded
                          : _isSuccess
                          ? Icons.check_circle_outline_rounded
                          : Icons.system_update_alt_rounded,
                      color: accent,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isError
                              ? '更新失败'
                              : _isSuccess
                              ? '更新完成'
                              : 'filmstoryboard 正在更新',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '目标版本 ${widget.session.versionTag}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.62),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < _steps.length; i++)
                    _StepChip(
                      index: i,
                      label: _steps[i],
                      active: i <= _currentStep,
                      accent: accent,
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Text(
                _message,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (_substep.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _substep,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.72),
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  if (!_isError && !_isSuccess)
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: accent,
                      ),
                    ),
                  if (!_isError && !_isSuccess) const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _isError
                          ? '本次自动更新已停止，当前安装包仍保留在更新目录中。'
                          : _isSuccess
                          ? '新版本已启动，更新窗口即将自动关闭。'
                          : '请勿关闭该窗口，安装过程会自动完成并重新打开故事板。',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.64),
                        fontSize: 13,
                        height: 1.5,
                      ),
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

class _StepChip extends StatelessWidget {
  const _StepChip({
    required this.index,
    required this.label,
    required this.active,
    required this.accent,
  });

  final int index;
  final String label;
  final bool active;
  final Color accent;
  static const _inactiveFill = Color(0xFF20242A);
  static const _inactiveBorder = Color(0xFF30343A);
  static const _activeText = Color(0xFFE8EAED);
  static const _inactiveText = Color(0xFF9AA1AA);

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: active ? accent.withValues(alpha: 0.12) : _inactiveFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? accent.withValues(alpha: 0.32) : _inactiveBorder,
        ),
      ),
      child: Text(
        '${index + 1}. $label',
        style: TextStyle(
          color: active ? _activeText : _inactiveText,
          fontSize: 12,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    );
  }
}
