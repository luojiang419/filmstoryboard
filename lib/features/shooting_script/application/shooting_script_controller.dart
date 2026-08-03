import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/services/workspace_directories.dart';
import '../../exporter/data/shooting_script_export_service.dart';
import '../../storyboard/domain/storyboard_models.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../data/shooting_script_repository.dart';
import '../domain/shooting_script_models.dart';

final shootingScriptControllerProvider = Provider<ShootingScriptController>((
  ref,
) {
  final controller = ShootingScriptController(
    repository: ShootingScriptRepository(ref.watch(appDatabaseProvider)),
    directories: ref.watch(projectDirectoriesProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
}, dependencies: [appDatabaseProvider, projectDirectoriesProvider]);

class ShootingScriptState {
  const ShootingScriptState({
    this.scripts = const [],
    this.shots = const [],
    this.selectedScriptId = '',
    this.selectedShotId = '',
    this.isExporting = false,
    this.message = '',
    this.errorMessage = '',
  });

  final List<ShootingScript> scripts;
  final List<ScriptShot> shots;
  final String selectedScriptId;
  final String selectedShotId;
  final bool isExporting;
  final String message;
  final String errorMessage;

  ShootingScript? get selectedScript {
    for (final script in scripts) {
      if (script.id == selectedScriptId) {
        return script;
      }
    }
    return null;
  }

  ScriptShot? get selectedShot {
    for (final shot in shots) {
      if (shot.id == selectedShotId) {
        return shot;
      }
    }
    return null;
  }

  ShootingScriptState copyWith({
    List<ShootingScript>? scripts,
    List<ScriptShot>? shots,
    String? selectedScriptId,
    String? selectedShotId,
    bool? isExporting,
    String? message,
    String? errorMessage,
  }) => ShootingScriptState(
    scripts: scripts ?? this.scripts,
    shots: shots ?? this.shots,
    selectedScriptId: selectedScriptId ?? this.selectedScriptId,
    selectedShotId: selectedShotId ?? this.selectedShotId,
    isExporting: isExporting ?? this.isExporting,
    message: message ?? this.message,
    errorMessage: errorMessage ?? this.errorMessage,
  );
}

class ShootingScriptOriginalExportResult {
  const ShootingScriptOriginalExportResult({
    required this.directory,
    required this.copiedCount,
    required this.missingCount,
  });

  final Directory directory;
  final int copiedCount;
  final int missingCount;
}

class ShootingScriptController extends ValueNotifier<ShootingScriptState> {
  ShootingScriptController({
    required ShootingScriptRepository repository,
    required WorkspaceDirectories directories,
    ShootingScriptExportService exportService =
        const ShootingScriptExportService(),
    Uuid uuid = const Uuid(),
  }) : _repository = repository,
       _directories = directories,
       _exportService = exportService,
       _uuid = uuid,
       super(const ShootingScriptState()) {
    refresh();
  }

  final ShootingScriptRepository _repository;
  final WorkspaceDirectories _directories;
  final ShootingScriptExportService _exportService;
  final Uuid _uuid;

  void refresh({String? selectScriptId, String? selectShotId}) {
    final scripts = _repository.listScripts();
    final selectedScriptId =
        selectScriptId ??
        (scripts.any((script) => script.id == value.selectedScriptId)
            ? value.selectedScriptId
            : (scripts.isEmpty ? '' : scripts.first.id));
    final shots = selectedScriptId.isEmpty
        ? const <ScriptShot>[]
        : _repository.listShots(selectedScriptId);
    final selectedShotId =
        selectShotId ??
        (shots.any((shot) => shot.id == value.selectedShotId)
            ? value.selectedShotId
            : (shots.isEmpty ? '' : shots.first.id));
    value = value.copyWith(
      scripts: scripts,
      shots: shots,
      selectedScriptId: selectedScriptId,
      selectedShotId: selectedShotId,
    );
  }

  void selectScript(String scriptId) {
    if (scriptId == value.selectedScriptId) {
      return;
    }
    refresh(selectScriptId: scriptId);
  }

  void reorderScripts(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= value.scripts.length) {
      return;
    }
    var target = newIndex;
    if (target > oldIndex) {
      target--;
    }
    target = target.clamp(0, value.scripts.length - 1);
    if (target == oldIndex) {
      return;
    }
    final scripts = [...value.scripts];
    final moving = scripts.removeAt(oldIndex);
    scripts.insert(target, moving);

    // 现有数据库按 updated_at 排序；用单调时间戳保存用户拖拽后的顺序，
    // 不新增迁移字段，也不会改变脚本版本号。
    final now = DateTime.now().toUtc();
    for (var index = 0; index < scripts.length; index++) {
      _repository.upsertScript(
        scripts[index].copyWith(
          updatedAt: now.add(Duration(microseconds: scripts.length - index)),
        ),
      );
    }
    refresh(
      selectScriptId: value.selectedScriptId,
      selectShotId: value.selectedShotId,
    );
    value = value.copyWith(message: '已调整脚本顺序', errorMessage: '');
  }

  void selectShot(String shotId) {
    value = value.copyWith(selectedShotId: shotId);
  }

  ShootingScript createEmpty({String name = '新建脚本'}) {
    final now = DateTime.now().toUtc();
    final script = ShootingScript(
      id: _uuid.v4(),
      name: _uniqueScriptName(name),
      sourceStoryboardId: null,
      sourceVideoId: null,
      status: ShootingScriptStatus.draft,
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
    _repository.upsertScript(script);
    refresh(selectScriptId: script.id, selectShotId: '');
    value = value.copyWith(message: '已创建 ${script.name}', errorMessage: '');
    return script;
  }

  ShootingScript? createFromVideo({
    required SourceVideo video,
    required List<VideoFrame> frames,
    required List<VideoShot> videoShots,
    required List<VideoFrameAnalysis> analyses,
  }) {
    final focusFrames =
        frames
            .where(
              (frame) =>
                  frame.isFocus && frame.status == ProcessingStatus.completed,
            )
            .toList()
          ..sort((first, second) => first.index.compareTo(second.index));
    if (focusFrames.isEmpty) {
      value = value.copyWith(message: '', errorMessage: '当前视频没有已完成解析的焦点帧');
      return null;
    }
    final now = DateTime.now().toUtc();
    final script = ShootingScript(
      id: _uuid.v4(),
      name: _uniqueScriptName('${_baseName(video.fileName)} · 拍摄脚本'),
      sourceStoryboardId: null,
      sourceVideoId: video.id,
      status: ShootingScriptStatus.draft,
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
    final shotByFrameId = {
      for (final shot in videoShots)
        if (shot.primaryFrameId != null) shot.primaryFrameId!: shot,
    };
    final analysisByFrameId = {
      for (final analysis in analyses) analysis.frameId: analysis,
    };
    final shots = <ScriptShot>[];
    for (var index = 0; index < focusFrames.length; index++) {
      final frame = focusFrames[index];
      final sourceShot = shotByFrameId[frame.id];
      final analysis = analysisByFrameId[frame.id];
      final dimensions = analysis?.dimensions ?? const <String, String>{};
      shots.add(
        ScriptShot(
          id: _uuid.v4(),
          scriptId: script.id,
          shotNumber: index + 1,
          durationSeconds: sourceShot == null
              ? 0
              : ((sourceShot.endMs - sourceShot.startMs).clamp(0, 3600000) /
                    1000),
          framePath: frame.path,
          visual: '',
          content: _firstNotEmpty([
            sourceShot?.storyFlow,
            sourceShot?.description,
            dimensions['narrativeFunction'],
            dimensions['caption'],
          ]),
          shotSize: dimensions['shotSize'] ?? '',
          cameraMovement: dimensions['cameraMovement'] ?? '',
          cameraNotes: '',
          composition: dimensions['composition'] ?? '',
          cameraAngle: dimensions['cameraAngle'] ?? '',
          lightingMood: dimensions['lightingMood'] ?? '',
          colorPalette: dimensions['colorPalette'] ?? '',
          visualFocus: dimensions['visualFocus'] ?? '',
          transitionHint: dimensions['transitionHint'] ?? '',
          scene: dimensions['scene'] ?? '',
          productCode: '',
          productStyling: '',
          dialogue: '',
          sound: '',
          prompt: '',
          status: ProcessingStatus.completed,
          updatedAt: now,
        ),
      );
    }
    _repository.upsertScript(script);
    _repository.replaceShots(script.id, shots);
    refresh(selectScriptId: script.id);
    value = value.copyWith(
      message: '已从视频生成 ${shots.length} 个脚本镜头',
      errorMessage: '',
    );
    return script;
  }

  ShootingScript? createFromStoryboard(StoryboardBoard? board) {
    if (board == null || board.items.isEmpty) {
      value = value.copyWith(message: '', errorMessage: '当前故事板没有可生成脚本的镜头');
      return null;
    }
    final items = board.items.toList()
      ..sort((first, second) => first.slotIndex.compareTo(second.slotIndex));
    final now = DateTime.now().toUtc();
    final script = ShootingScript(
      id: _uuid.v4(),
      name: _uniqueScriptName('${board.name} · 拍摄脚本'),
      sourceStoryboardId: board.id,
      sourceVideoId: null,
      status: ShootingScriptStatus.draft,
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
    final shots = [
      for (var index = 0; index < items.length; index++)
        _blankShot(script.id, index + 1, now).copyWith(
          framePath: items[index].asset.path,
          content: items[index].caption,
          status: ProcessingStatus.completed,
        ),
    ];
    _repository.upsertScript(script);
    _repository.replaceShots(script.id, shots);
    refresh(selectScriptId: script.id);
    value = value.copyWith(
      message: '已从故事板生成 ${shots.length} 个脚本镜头',
      errorMessage: '',
    );
    return script;
  }

  ShootingScript? duplicateSelectedScript() {
    final source = value.selectedScript;
    if (source == null) {
      return null;
    }
    final now = DateTime.now().toUtc();
    final duplicate = ShootingScript(
      id: _uuid.v4(),
      name: _uniqueScriptName('${source.name} 副本'),
      sourceStoryboardId: source.sourceStoryboardId,
      sourceVideoId: source.sourceVideoId,
      status: ShootingScriptStatus.draft,
      version: 1,
      createdAt: now,
      updatedAt: now,
    );
    final shots = [
      for (var index = 0; index < value.shots.length; index++)
        value.shots[index].copyWith(
          scriptId: duplicate.id,
          shotNumber: index + 1,
          updatedAt: now,
        ),
    ];
    final copiedShots = [
      for (final shot in shots)
        ScriptShot(
          id: _uuid.v4(),
          scriptId: shot.scriptId,
          shotNumber: shot.shotNumber,
          durationSeconds: shot.durationSeconds,
          framePath: shot.framePath,
          visual: shot.visual,
          content: shot.content,
          shotSize: shot.shotSize,
          cameraMovement: shot.cameraMovement,
          cameraNotes: shot.cameraNotes,
          composition: shot.composition,
          cameraAngle: shot.cameraAngle,
          lightingMood: shot.lightingMood,
          colorPalette: shot.colorPalette,
          visualFocus: shot.visualFocus,
          transitionHint: shot.transitionHint,
          scene: shot.scene,
          productCode: shot.productCode,
          productStyling: shot.productStyling,
          dialogue: shot.dialogue,
          sound: shot.sound,
          prompt: shot.prompt,
          status: shot.status,
          updatedAt: now,
        ),
    ];
    _repository.upsertScript(duplicate);
    _repository.replaceShots(duplicate.id, copiedShots);
    refresh(selectScriptId: duplicate.id);
    value = value.copyWith(message: '已复制为 ${duplicate.name}', errorMessage: '');
    return duplicate;
  }

  bool renameSelectedScript(String name) {
    final script = value.selectedScript;
    final normalized = name.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (script == null || normalized.isEmpty) {
      value = value.copyWith(errorMessage: '脚本名称不能为空');
      return false;
    }
    final renamed = script.copyWith(
      name: _uniqueScriptName(normalized, excludingId: script.id),
      version: script.version + 1,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertScript(renamed);
    refresh(selectScriptId: renamed.id);
    value = value.copyWith(message: '已重命名为 ${renamed.name}', errorMessage: '');
    return true;
  }

  void toggleArchiveSelectedScript() {
    final script = value.selectedScript;
    if (script == null) {
      return;
    }
    final archived = script.status != ShootingScriptStatus.archived;
    final updated = script.copyWith(
      status: archived
          ? ShootingScriptStatus.archived
          : ShootingScriptStatus.draft,
      version: script.version + 1,
      updatedAt: DateTime.now().toUtc(),
    );
    _repository.upsertScript(updated);
    refresh(selectScriptId: updated.id);
    value = value.copyWith(
      message: archived ? '已归档 ${updated.name}' : '已恢复 ${updated.name}',
      errorMessage: '',
    );
  }

  void deleteSelectedScript() {
    final script = value.selectedScript;
    if (script == null) {
      return;
    }
    deleteScript(script.id);
  }

  void deleteScript(String scriptId) {
    final script = value.scripts.cast<ShootingScript?>().firstWhere(
      (item) => item?.id == scriptId,
      orElse: () => null,
    );
    if (script == null) {
      return;
    }
    _repository.deleteScript(script.id);
    refresh();
    value = value.copyWith(message: '已删除 ${script.name}', errorMessage: '');
  }

  ScriptShot? addShot({int? afterIndex}) {
    final script = value.selectedScript;
    if (script == null) {
      return null;
    }
    final now = DateTime.now().toUtc();
    final insertIndex = ((afterIndex ?? value.shots.length - 1) + 1).clamp(
      0,
      value.shots.length,
    );
    final shot = _blankShot(script.id, insertIndex + 1, now);
    final shots = [...value.shots]..insert(insertIndex, shot);
    _saveShots(script, shots, selectShotId: shot.id, message: '已新增镜头');
    return shot;
  }

  ScriptShot? duplicateShot(String shotId) {
    final script = value.selectedScript;
    final index = value.shots.indexWhere((shot) => shot.id == shotId);
    if (script == null || index < 0) {
      return null;
    }
    final source = value.shots[index];
    final duplicate = ScriptShot(
      id: _uuid.v4(),
      scriptId: script.id,
      shotNumber: index + 2,
      durationSeconds: source.durationSeconds,
      framePath: source.framePath,
      visual: source.visual,
      content: source.content,
      shotSize: source.shotSize,
      cameraMovement: source.cameraMovement,
      cameraNotes: source.cameraNotes,
      composition: source.composition,
      cameraAngle: source.cameraAngle,
      lightingMood: source.lightingMood,
      colorPalette: source.colorPalette,
      visualFocus: source.visualFocus,
      transitionHint: source.transitionHint,
      scene: source.scene,
      productCode: source.productCode,
      productStyling: source.productStyling,
      dialogue: source.dialogue,
      sound: source.sound,
      prompt: source.prompt,
      status: source.status,
      updatedAt: DateTime.now().toUtc(),
    );
    final shots = [...value.shots]..insert(index + 1, duplicate);
    _saveShots(
      script,
      shots,
      selectShotId: duplicate.id,
      message: '已复制镜头 ${source.shotNumber}',
    );
    return duplicate;
  }

  void deleteShot(String shotId) {
    final script = value.selectedScript;
    final index = value.shots.indexWhere((shot) => shot.id == shotId);
    if (script == null || index < 0) {
      return;
    }
    final shots = value.shots.where((shot) => shot.id != shotId).toList();
    final nextSelectedId = shots.isEmpty
        ? ''
        : shots[index.clamp(0, shots.length - 1)].id;
    _saveShots(script, shots, selectShotId: nextSelectedId, message: '已删除镜头');
  }

  void reorderShots(int oldIndex, int newIndex) {
    final script = value.selectedScript;
    if (script == null || oldIndex < 0 || oldIndex >= value.shots.length) {
      return;
    }
    var target = newIndex;
    if (target > oldIndex) {
      target--;
    }
    target = target.clamp(0, value.shots.length - 1);
    if (target == oldIndex) {
      return;
    }
    final shots = [...value.shots];
    final moving = shots.removeAt(oldIndex);
    shots.insert(target, moving);
    _saveShots(script, shots, selectShotId: moving.id, message: '已调整镜头顺序');
  }

  void updateShot(ScriptShot updated) {
    final script = value.selectedScript;
    final index = value.shots.indexWhere((shot) => shot.id == updated.id);
    if (script == null || index < 0 || updated.scriptId != script.id) {
      return;
    }
    final shots = [...value.shots];
    shots[index] = updated.copyWith(
      shotNumber: index + 1,
      updatedAt: DateTime.now().toUtc(),
    );
    _saveShots(script, shots, selectShotId: updated.id, message: '脚本镜头已保存');
  }

  void updateShotPrompts(Map<String, String> promptsByShotId) {
    final script = value.selectedScript;
    if (script == null || promptsByShotId.isEmpty) {
      return;
    }
    var changed = false;
    final shots = <ScriptShot>[];
    for (final shot in value.shots) {
      final prompt = promptsByShotId[shot.id];
      if (prompt != null && shot.prompt != prompt) {
        changed = true;
        shots.add(shot.copyWith(prompt: prompt));
      } else {
        shots.add(shot);
      }
    }
    if (!changed) {
      return;
    }
    _saveShots(
      script,
      shots,
      selectShotId: value.selectedShotId,
      message: '最终提示词已同步到拍摄脚本',
    );
  }

  void batchUpdateShots({
    required ShootingScriptBatchField field,
    required String fieldValue,
  }) {
    final script = value.selectedScript;
    if (script == null || value.shots.isEmpty) {
      return;
    }
    final shots = [
      for (final shot in value.shots)
        switch (field) {
          ShootingScriptBatchField.shotSize => shot.copyWith(
            shotSize: fieldValue,
          ),
          ShootingScriptBatchField.cameraMovement => shot.copyWith(
            cameraMovement: fieldValue,
          ),
          ShootingScriptBatchField.composition => shot.copyWith(
            composition: fieldValue,
          ),
          ShootingScriptBatchField.cameraAngle => shot.copyWith(
            cameraAngle: fieldValue,
          ),
          ShootingScriptBatchField.lightingMood => shot.copyWith(
            lightingMood: fieldValue,
          ),
          ShootingScriptBatchField.colorPalette => shot.copyWith(
            colorPalette: fieldValue,
          ),
          ShootingScriptBatchField.visualFocus => shot.copyWith(
            visualFocus: fieldValue,
          ),
          ShootingScriptBatchField.transitionHint => shot.copyWith(
            transitionHint: fieldValue,
          ),
          ShootingScriptBatchField.cameraNotes => shot.copyWith(
            cameraNotes: fieldValue,
          ),
          ShootingScriptBatchField.scene => shot.copyWith(scene: fieldValue),
          ShootingScriptBatchField.productCode => shot.copyWith(
            productCode: fieldValue,
          ),
          ShootingScriptBatchField.visual => shot.copyWith(visual: fieldValue),
          ShootingScriptBatchField.productStyling => shot.copyWith(
            productStyling: fieldValue,
          ),
        },
    ];
    _saveShots(
      script,
      shots,
      selectShotId: value.selectedShotId,
      message: '已批量更新 ${shots.length} 个镜头',
    );
  }

  Future<File?> exportXlsx() async {
    final script = value.selectedScript;
    if (script == null || value.isExporting) {
      return null;
    }
    value = value.copyWith(
      isExporting: true,
      message: '正在导出拍摄脚本…',
      errorMessage: '',
    );
    try {
      final output = _uniqueFile(
        _directories.scripts,
        shootingScriptEntityExportFileName(scriptName: script.name),
      );
      final file = await _exportService.exportScript(
        script: script,
        shots: value.shots,
        outputPath: output.path,
      );
      value = value.copyWith(
        isExporting: false,
        message: '已导出 ${file.path}',
        errorMessage: '',
      );
      return file;
    } catch (error) {
      value = value.copyWith(
        isExporting: false,
        message: '',
        errorMessage: '导出脚本失败：$error',
      );
      return null;
    }
  }

  Future<ShootingScriptOriginalExportResult?> exportOriginalImages() async {
    final script = value.selectedScript;
    if (script == null || value.isExporting) {
      return null;
    }
    value = value.copyWith(
      isExporting: true,
      message: '正在复制镜头原图…',
      errorMessage: '',
    );
    try {
      final directory = _uniqueDirectory(
        _directories.scripts,
        '${_safeFileName(script.name)}-原图',
      );
      await directory.create(recursive: true);
      var copied = 0;
      var missing = 0;
      for (final shot in value.shots) {
        final source = File(shot.framePath);
        if (shot.framePath.trim().isEmpty || !source.existsSync()) {
          missing++;
          continue;
        }
        final targetName =
            '${shot.shotNumber.toString().padLeft(3, '0')}-${_safeFileName(p.basenameWithoutExtension(source.path))}${p.extension(source.path)}';
        await source.copy(p.join(directory.path, targetName));
        copied++;
      }
      if (copied == 0) {
        await directory.delete(recursive: true);
        throw const FileSystemException('脚本中没有可导出的原图');
      }
      final result = ShootingScriptOriginalExportResult(
        directory: directory,
        copiedCount: copied,
        missingCount: missing,
      );
      value = value.copyWith(
        isExporting: false,
        message: missing == 0
            ? '已导出 $copied 张原图到 ${directory.path}'
            : '已导出 $copied 张原图，另有 $missing 个镜头缺图',
        errorMessage: '',
      );
      return result;
    } catch (error) {
      value = value.copyWith(
        isExporting: false,
        message: '',
        errorMessage: '导出原图失败：$error',
      );
      return null;
    }
  }

  Future<void> openOutputDirectory() async {
    await _directories.scripts.create(recursive: true);
    if (Platform.isWindows) {
      await Process.start('explorer.exe', [_directories.scripts.path]);
    }
  }

  Future<void> openShotOriginal(ScriptShot shot) async {
    if (!Platform.isWindows || shot.framePath.trim().isEmpty) {
      return;
    }
    final file = File(shot.framePath);
    if (!file.existsSync()) {
      value = value.copyWith(errorMessage: '镜头原图不存在：${shot.framePath}');
      return;
    }
    await Process.start('explorer.exe', ['/select,', file.path]);
  }

  void _saveShots(
    ShootingScript script,
    List<ScriptShot> shots, {
    required String selectShotId,
    required String message,
  }) {
    final now = DateTime.now().toUtc();
    final normalized = [
      for (var index = 0; index < shots.length; index++)
        shots[index].copyWith(shotNumber: index + 1, updatedAt: now),
    ];
    final updatedScript = script.copyWith(
      version: script.version + 1,
      updatedAt: now,
    );
    _repository.upsertScript(updatedScript);
    _repository.replaceShots(script.id, normalized);
    refresh(selectScriptId: script.id, selectShotId: selectShotId);
    value = value.copyWith(message: message, errorMessage: '');
  }

  ScriptShot _blankShot(String scriptId, int shotNumber, DateTime now) =>
      ScriptShot(
        id: _uuid.v4(),
        scriptId: scriptId,
        shotNumber: shotNumber,
        durationSeconds: 0,
        framePath: '',
        visual: '',
        content: '',
        shotSize: '',
        cameraMovement: '',
        cameraNotes: '',
        scene: '',
        productCode: '',
        productStyling: '',
        dialogue: '',
        sound: '',
        prompt: '',
        status: ProcessingStatus.pending,
        updatedAt: now,
      );

  String _uniqueScriptName(String requested, {String? excludingId}) {
    final base = requested.trim().isEmpty ? '新建脚本' : requested.trim();
    final used = {
      for (final script in value.scripts)
        if (script.id != excludingId) script.name.toLowerCase(),
    };
    if (!used.contains(base.toLowerCase())) {
      return base;
    }
    var suffix = 2;
    while (used.contains('$base $suffix'.toLowerCase())) {
      suffix++;
    }
    return '$base $suffix';
  }

  static String _baseName(String fileName) {
    final extension = p.extension(fileName);
    return extension.isEmpty
        ? fileName
        : fileName.substring(0, fileName.length - extension.length);
  }

  static String _firstNotEmpty(List<String?> values) {
    for (final value in values) {
      final normalized = value?.trim() ?? '';
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }

  static String _safeFileName(String value) {
    final safe = value
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'[. ]+$'), '');
    return safe.isEmpty ? '拍摄脚本' : safe;
  }

  static File _uniqueFile(Directory directory, String name) {
    var file = File(p.join(directory.path, name));
    if (!file.existsSync()) {
      return file;
    }
    final extension = p.extension(name);
    final base = p.basenameWithoutExtension(name);
    var suffix = 2;
    while (file.existsSync()) {
      file = File(p.join(directory.path, '$base ($suffix)$extension'));
      suffix++;
    }
    return file;
  }

  static Directory _uniqueDirectory(Directory parent, String name) {
    var directory = Directory(p.join(parent.path, name));
    var suffix = 2;
    while (directory.existsSync()) {
      directory = Directory(p.join(parent.path, '$name ($suffix)'));
      suffix++;
    }
    return directory;
  }
}

enum ShootingScriptBatchField {
  shotSize,
  cameraMovement,
  composition,
  cameraAngle,
  lightingMood,
  colorPalette,
  visualFocus,
  transitionHint,
  cameraNotes,
  scene,
  productCode,
  visual,
  productStyling,
}
