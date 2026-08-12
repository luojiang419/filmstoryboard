import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/features/remote_access/application/remote_access_facade.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_auth_service.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_project_registry.dart';
import 'package:filmstoryboard/features/remote_access/application/remote_workspace_registry.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_access_config.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_events.dart';
import 'package:filmstoryboard/features/remote_access/domain/remote_project_models.dart';
import 'package:filmstoryboard/features/remote_access/server/embedded_web_server.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('远程工程列表不泄露路径且导演可请求桌面切换工程', () async {
    final changeBus = RemoteChangeBus();
    final source = _FakeProjectSource();
    final projectRegistry = RemoteProjectRegistry(changeBus: changeBus)
      ..attach(source);
    final workspaceRegistry = RemoteWorkspaceRegistry(changeBus);
    final facade = RemoteAccessFacade(
      workspaceRegistry: workspaceRegistry,
      changeBus: changeBus,
      projectRegistry: projectRegistry,
    );
    final config = RemoteAccessConfig(enabled: true);
    final auth = RemoteAuthService(
      config: config,
      tokenFactory: () => 'project-api-token',
      pairingCodeFactory: () => '445566',
    )..createPairingCode();
    final server = EmbeddedWebServer(
      config: config,
      authService: auth,
      appVersion: 'test',
      facade: facade,
      changeBus: changeBus,
    );
    await server.start(portOverride: 0);
    final client = HttpClient();
    addTearDown(() async {
      client.close(force: true);
      await server.stop();
      projectRegistry.detach(source: source);
      source.dispose();
      await changeBus.close();
    });
    final base = Uri.parse('http://127.0.0.1:${server.boundPort}');
    final pair = await _request(
      client,
      base.resolve('/api/v1/auth/pair'),
      method: 'POST',
      body: const {'code': '445566', 'clientName': '导演浏览器'},
    );
    final token = pair.json['accessToken']! as String;

    final collection = await _request(
      client,
      base.resolve('/api/v1/projects'),
      token: token,
    );
    expect(collection.statusCode, HttpStatus.ok);
    expect(collection.json['activeProjectId'], 'project-a');
    final encoded = jsonEncode(collection.json);
    expect(encoded, isNot(contains('indexPath')));
    expect(encoded, isNot(contains(r'C:\projects')));

    final opened = await _request(
      client,
      base.resolve('/api/v1/projects/project-b/open'),
      method: 'POST',
      token: token,
    );
    expect(opened.statusCode, HttpStatus.ok);
    expect(opened.json['projectId'], 'project-b');
    expect(opened.json['alreadyOpen'], isFalse);
    expect(source.activeProjectId, 'project-b');

    final unavailable = await _request(
      client,
      base.resolve('/api/v1/projects/project-missing/open'),
      method: 'POST',
      token: token,
    );
    expect(unavailable.statusCode, HttpStatus.conflict);
    expect(
      (unavailable.json['error']! as Map<String, Object?>)['code'],
      'project_unavailable',
    );
  });
}

class _FakeProjectSource extends ChangeNotifier implements RemoteProjectSource {
  @override
  String? activeProjectId = 'project-a';

  @override
  bool isTransitioning = false;

  @override
  List<RemoteProjectRecord> get projects => [
    _project('project-a', '项目 A', isActive: activeProjectId == 'project-a'),
    _project('project-b', '项目 B', isActive: activeProjectId == 'project-b'),
    RemoteProjectRecord(
      id: 'project-missing',
      name: '失效工程',
      availability: RemoteProjectAvailability.missing,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 2),
      lastOpenedAt: DateTime.utc(2026, 1, 3),
      isActive: false,
    ),
  ];

  @override
  Future<RemoteProjectOpenResult> openProject(String projectId) async {
    final project = projects.where((item) => item.id == projectId).firstOrNull;
    if (project == null) {
      throw const RemoteProjectSourceException('project_not_found', '工程不存在');
    }
    if (!project.canOpen) {
      throw const RemoteProjectSourceException(
        'project_unavailable',
        '工程位置已失效',
      );
    }
    final alreadyOpen = activeProjectId == projectId;
    activeProjectId = projectId;
    notifyListeners();
    return RemoteProjectOpenResult(
      projectId: project.id,
      projectName: project.name,
      alreadyOpen: alreadyOpen,
    );
  }

  static RemoteProjectRecord _project(
    String id,
    String name, {
    required bool isActive,
  }) => RemoteProjectRecord(
    id: id,
    name: name,
    availability: RemoteProjectAvailability.available,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 2),
    lastOpenedAt: DateTime.utc(2026, 1, 3),
    isActive: isActive,
  );
}

Future<_Response> _request(
  HttpClient client,
  Uri uri, {
  String method = 'GET',
  String? token,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  if (token != null) {
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final source = await utf8.decoder.bind(response).join();
  return _Response(
    statusCode: response.statusCode,
    json: source.isEmpty
        ? const {}
        : jsonDecode(source) as Map<String, Object?>,
  );
}

class _Response {
  const _Response({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, Object?> json;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => this.isEmpty ? null : first;
}
