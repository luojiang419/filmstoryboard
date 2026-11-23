import 'package:filmstoryboard/features/video_generation/data/davinci_resolve_bridge_client.dart';
import 'package:filmstoryboard/features/video_generation/data/davinci_resolve_connection_service.dart';
import 'package:filmstoryboard/features/video_generation/data/davinci_resolve_plugin_launcher.dart';
import 'package:test/test.dart';

void main() {
  const ready = DaVinciBridgeHealth(
    pluginVersion: '0.2.5',
    resolveVersion: '21.0',
    projectName: '测试项目',
    projectId: 'project-1',
  );

  test('桥接已连接时直接返回且不拉起插件', () async {
    var launchCount = 0;
    final result = await const DaVinciResolveConnectionService().connect(
      healthCheck: () async => ready,
      launchPlugin: () async => launchCount++,
    );

    expect(result.projectId, 'project-1');
    expect(launchCount, 0);
  });

  test('桥接离线时自动拉起并轮询到连接成功', () async {
    var healthCount = 0;
    var launchCount = 0;
    final statuses = <String>[];
    final service = DaVinciResolveConnectionService(
      pollInterval: const Duration(milliseconds: 20),
      startupTimeout: const Duration(seconds: 1),
      delay: (_) async {},
    );

    final result = await service.connect(
      healthCheck: () async {
        healthCount++;
        if (healthCount < 4) {
          throw const DaVinciBridgeException(
            '插件离线',
            kind: DaVinciBridgeFailureKind.pluginUnavailable,
          );
        }
        return ready;
      },
      launchPlugin: () async => launchCount++,
      onStatus: statuses.add,
    );

    expect(result.projectId, 'project-1');
    expect(launchCount, 1);
    expect(healthCount, 4);
    expect(statuses, ['未检测到插件，正在自动启动…', '已请求启动插件，正在等待连接…']);
  });

  test('原生拉起失败时转为桥接错误', () async {
    final service = DaVinciResolveConnectionService(delay: (_) async {});

    expect(
      () => service.connect(
        healthCheck: () async => throw const DaVinciBridgeException(
          '插件离线',
          kind: DaVinciBridgeFailureKind.pluginUnavailable,
        ),
        launchPlugin: () async =>
            throw const DaVinciResolvePluginLaunchException(
              code: 'plugin_menu_not_found',
              message: '插件未安装，请先安装并重启 Resolve',
            ),
      ),
      throwsA(
        isA<DaVinciBridgeException>().having(
          (error) => error.message,
          'message',
          contains('请先安装'),
        ),
      ),
    );
  });

  test('桥接返回非离线错误时不得尝试拉起插件', () async {
    var launchCount = 0;
    final service = DaVinciResolveConnectionService(delay: (_) async {});

    expect(
      () => service.connect(
        healthCheck: () async => throw const DaVinciBridgeException('插件响应超时'),
        launchPlugin: () async => launchCount++,
      ),
      throwsA(isA<DaVinciBridgeException>()),
    );
    expect(launchCount, 0);
  });

  test('拉起后在时限内仍离线时返回超时指引', () async {
    final service = DaVinciResolveConnectionService(
      pollInterval: const Duration(milliseconds: 20),
      startupTimeout: const Duration(milliseconds: 40),
      delay: (_) async {},
    );

    expect(
      () => service.connect(
        healthCheck: () async => throw const DaVinciBridgeException(
          '插件离线',
          kind: DaVinciBridgeFailureKind.pluginUnavailable,
        ),
        launchPlugin: () async {},
      ),
      throwsA(
        isA<DaVinciBridgeException>().having(
          (error) => error.message,
          'message',
          allOf(contains('连接超时'), contains('工作区 → 流程整合')),
        ),
      ),
    );
  });
}
