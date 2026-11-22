import 'davinci_resolve_bridge_client.dart';
import 'davinci_resolve_plugin_launcher.dart';

typedef DaVinciBridgeHealthCheck = Future<DaVinciBridgeHealth> Function();
typedef DaVinciPluginLaunch = Future<void> Function();
typedef DaVinciConnectionStatusCallback = void Function(String message);
typedef DaVinciConnectionDelay = Future<void> Function(Duration duration);

class DaVinciResolveConnectionService {
  const DaVinciResolveConnectionService({
    this.pollInterval = const Duration(milliseconds: 250),
    this.startupTimeout = const Duration(seconds: 15),
    DaVinciConnectionDelay delay = Future<void>.delayed,
  }) : _delay = delay;

  final Duration pollInterval;
  final Duration startupTimeout;
  final DaVinciConnectionDelay _delay;

  Future<DaVinciBridgeHealth> connect({
    required DaVinciBridgeHealthCheck healthCheck,
    required DaVinciPluginLaunch launchPlugin,
    DaVinciConnectionStatusCallback? onStatus,
  }) async {
    try {
      return await healthCheck();
    } on DaVinciBridgeException catch (error) {
      if (error.kind != DaVinciBridgeFailureKind.pluginUnavailable) rethrow;
    }

    onStatus?.call('未检测到插件，正在自动启动…');
    try {
      await launchPlugin();
    } on DaVinciResolvePluginLaunchException catch (error) {
      throw DaVinciBridgeException(error.message);
    }
    onStatus?.call('已请求启动插件，正在等待连接…');

    var waited = Duration.zero;
    while (true) {
      try {
        return await healthCheck();
      } on DaVinciBridgeException catch (error) {
        if (error.kind != DaVinciBridgeFailureKind.pluginUnavailable) rethrow;
        if (waited >= startupTimeout) {
          throw const DaVinciBridgeException(
            '已自动调用达芬奇插件，但等待连接超时。'
            '请在 Resolve“工作区 → 流程整合”中确认插件状态',
          );
        }
      }
      await _delay(pollInterval);
      waited += pollInterval;
    }
  }
}
