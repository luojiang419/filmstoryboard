import 'package:filmstoryboard/features/video_generation/data/davinci_resolve_plugin_launcher.dart';
import 'package:test/test.dart';

void main() {
  test('原生端成功调用达芬奇流程整合菜单', () async {
    var invokedMethod = '';
    final launcher = DaVinciResolvePluginLauncher(
      methodInvoker: (method) async {
        invokedMethod = method;
        return const <String, Object?>{'success': true, 'message': '已启动'};
      },
    );

    await launcher.launch();

    expect(invokedMethod, 'launchWorkflowIntegration');
  });

  test('原生端失败时保留可操作的中文原因', () async {
    final launcher = DaVinciResolvePluginLauncher(
      methodInvoker: (_) async => const <String, Object?>{
        'success': false,
        'code': 'resolve_not_running',
        'message': '未检测到 DaVinci Resolve，请先启动达芬奇并打开项目',
      },
    );

    expect(
      launcher.launch,
      throwsA(
        isA<DaVinciResolvePluginLaunchException>()
            .having((error) => error.code, 'code', 'resolve_not_running')
            .having((error) => error.message, 'message', contains('请先启动达芬奇')),
      ),
    );
  });

  test('原生端返回异常数据时不误报成启动成功', () async {
    final launcher = DaVinciResolvePluginLauncher(
      methodInvoker: (_) async => 'unexpected',
    );

    expect(
      launcher.launch,
      throwsA(
        isA<DaVinciResolvePluginLaunchException>().having(
          (error) => error.code,
          'code',
          'invalid_native_response',
        ),
      ),
    );
  });
}
