import 'dart:io';

import 'package:flutter/services.dart';

typedef ResolvePluginMethodInvoker = Future<Object?> Function(String method);

class DaVinciResolvePluginLauncher {
  const DaVinciResolvePluginLauncher({
    ResolvePluginMethodInvoker methodInvoker = _invokeNative,
  }) : _methodInvoker = methodInvoker;

  static const _channel = MethodChannel(
    'filmstoryboard/davinci_resolve_automation',
  );

  final ResolvePluginMethodInvoker _methodInvoker;

  Future<void> launch() async {
    if (!Platform.isWindows) {
      throw const DaVinciResolvePluginLaunchException(
        code: 'unsupported_platform',
        message: '达芬奇插件自动启动当前仅支持 Windows',
      );
    }
    Object? response;
    try {
      response = await _methodInvoker('launchWorkflowIntegration');
    } on MissingPluginException {
      throw const DaVinciResolvePluginLaunchException(
        code: 'native_channel_unavailable',
        message: '当前安装版未包含达芬奇插件自动启动组件，请更新软件',
      );
    } on PlatformException catch (error) {
      throw DaVinciResolvePluginLaunchException(
        code: error.code,
        message: error.message?.trim().isNotEmpty == true
            ? error.message!.trim()
            : '无法自动启动达芬奇流程整合插件',
      );
    }
    if (response is! Map) {
      throw const DaVinciResolvePluginLaunchException(
        code: 'invalid_native_response',
        message: '达芬奇插件自动启动组件返回了无效结果',
      );
    }
    final success = response['success'] == true;
    if (success) return;
    final code = '${response['code'] ?? 'launch_failed'}'.trim();
    final message = '${response['message'] ?? ''}'.trim();
    throw DaVinciResolvePluginLaunchException(
      code: code.isEmpty ? 'launch_failed' : code,
      message: message.isEmpty ? '无法自动启动达芬奇流程整合插件' : message,
    );
  }

  static Future<Object?> _invokeNative(String method) {
    return _channel.invokeMethod<Object?>(method);
  }
}

class DaVinciResolvePluginLaunchException implements Exception {
  const DaVinciResolvePluginLaunchException({
    required this.code,
    required this.message,
  });

  final String code;
  final String message;

  @override
  String toString() => message;
}
