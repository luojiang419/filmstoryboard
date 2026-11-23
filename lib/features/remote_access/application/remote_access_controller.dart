import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/services/app_directories.dart';
import '../../updater/domain/app_update_config.dart';
import '../data/remote_access_repository.dart';
import '../data/remote_audit_logger.dart';
import '../domain/remote_access_config.dart';
import '../domain/remote_auth_models.dart';
import '../domain/remote_events.dart';
import '../server/embedded_web_server.dart';
import 'remote_access_facade.dart';
import 'remote_auth_service.dart';
import 'remote_export_registry.dart';
import 'remote_media_registry.dart';
import 'remote_upload_registry.dart';

class RemoteAccessController extends ChangeNotifier {
  RemoteAccessController({
    required RemoteAccessRepository repository,
    required AppDirectories directories,
    required RemoteAccessFacade facade,
    required RemoteChangeBus changeBus,
    required RemoteMediaRegistry mediaRegistry,
    RemoteExportRegistry? exportRegistry,
    RemoteUploadRegistry? uploadRegistry,
    Directory? webRootOverride,
  }) : _repository = repository,
       _directories = directories,
       _facade = facade,
       _changeBus = changeBus,
       _mediaRegistry = mediaRegistry,
       _exportRegistry = exportRegistry,
       _uploadRegistry = uploadRegistry,
       _webRootOverride = webRootOverride,
       _config = repository.load();

  final RemoteAccessRepository _repository;
  final AppDirectories _directories;
  final RemoteAccessFacade _facade;
  final RemoteChangeBus _changeBus;
  final RemoteMediaRegistry _mediaRegistry;
  final RemoteExportRegistry? _exportRegistry;
  final RemoteUploadRegistry? _uploadRegistry;
  final Directory? _webRootOverride;

  RemoteAccessConfig _config;
  EmbeddedWebServer? _server;
  RemoteAuthService? _authService;
  RemotePairingCode? _pairingCode;
  String? _errorMessage;
  bool _busy = false;
  bool _initialized = false;
  bool _disposed = false;

  RemoteAccessConfig get config => _config;
  bool get isRunning => _server?.isRunning ?? false;
  bool get isBusy => _busy;
  int? get boundPort => _server?.boundPort;
  RemotePairingCode? get pairingCode => _pairingCode;
  String? get errorMessage => _errorMessage;
  List<RemoteSessionView> get sessions =>
      _authService?.listSessions() ?? const [];
  Directory get webRoot => _resolveWebRoot();
  bool get webAssetsAvailable =>
      File(p.join(webRoot.path, 'index.html')).existsSync();
  String get localAccessUrl =>
      'http://${_config.bindAddress.address}:${boundPort ?? _config.port}';

  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;
    if (_config.enabled) await _start();
  }

  Future<void> setEnabled(bool enabled) async {
    if (_disposed || _busy || enabled == _config.enabled) return;
    _errorMessage = null;
    _config = _config.copyWith(enabled: enabled);
    _repository.save(_config);
    notifyListeners();
    if (enabled) {
      await _start();
    } else {
      await _stop();
    }
  }

  Future<void> setPort(int port) async {
    final next = _config.copyWith(port: port).validated();
    if (_disposed || _busy || next.port == _config.port) return;
    final restart = isRunning;
    if (restart) await _stop();
    _config = next;
    _repository.save(_config);
    notifyListeners();
    if (restart) await _start();
  }

  RemotePairingCode createPairingCode(RemoteAccessRole role) {
    final authService = _authService;
    if (!isRunning || authService == null) {
      throw StateError('请先开启远程访问');
    }
    _pairingCode = authService.createPairingCode(role: role);
    notifyListeners();
    return _pairingCode!;
  }

  void revokeSession(String sessionId) {
    if (_authService?.revokeSession(sessionId) ?? false) notifyListeners();
  }

  void revokeAllSessions() {
    _authService?.revokeAll();
    _pairingCode = null;
    notifyListeners();
  }

  Future<void> _start() async {
    if (_disposed || _busy || isRunning) return;
    _busy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final authService = RemoteAuthService(config: _config);
      final server = EmbeddedWebServer(
        config: _config,
        authService: authService,
        appVersion: AppUpdateConfig.currentVersion,
        facade: _facade,
        changeBus: _changeBus,
        mediaRegistry: _mediaRegistry,
        exportRegistry: _exportRegistry,
        uploadRegistry: _uploadRegistry,
        auditLogger: JsonLineRemoteAuditLogger(
          File(p.join(_directories.logs.path, 'remote_access_audit.jsonl')),
        ),
        webRoot: webRoot,
        capabilitiesProvider: () => {
          'projects': true,
          'workspace': true,
          'storyboards': true,
          'shootingScripts': true,
          'shootingWorkflow': true,
          'videoGeneration': true,
          'videoAnalysis': true,
          'videoUploads': true,
          'tasks': true,
          'exports': _exportRegistry != null,
          'settings': true,
          'mediaStreaming': true,
        },
      );
      await server.start();
      _authService = authService;
      _server = server;
    } catch (error) {
      _authService = null;
      _server = null;
      _pairingCode = null;
      _errorMessage = '远程服务启动失败：$error';
      _config = _config.copyWith(enabled: false);
      _repository.save(_config);
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _stop() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();
    final server = _server;
    _server = null;
    _authService?.revokeAll();
    _authService = null;
    _pairingCode = null;
    try {
      await server?.stop();
    } finally {
      _busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Directory _resolveWebRoot() {
    if (_webRootOverride case final override?) return override;
    final installed = Directory(
      p.join(_directories.executableDirectory.path, 'web'),
    );
    if (File(p.join(installed.path, 'index.html')).existsSync()) {
      return installed;
    }
    return Directory(
      p.join(Directory.current.path, 'website', 'app', 'build', 'web'),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    final server = _server;
    _server = null;
    _authService?.revokeAll();
    _authService = null;
    unawaited(server?.stop());
    super.dispose();
  }
}
