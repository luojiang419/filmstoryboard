import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/providers/app_providers.dart';
import '../../settings/application/settings_controller.dart';
import '../../replicate/domain/replicate_models.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import '../data/script_asset_matching_service.dart';
import '../data/shooting_script_workflow_repository.dart';
import '../domain/shooting_asset_library_models.dart';
import '../domain/script_asset_slot_policy.dart';
import '../domain/shooting_script_models.dart';
import '../domain/shooting_script_workflow_models.dart';
import 'shooting_asset_library_controller.dart';
import 'shooting_script_controller.dart';

final scriptAssetBindingControllerProvider =
    Provider<ShootingScriptAssetBindingController>(
      (ref) {
        final controller = ShootingScriptAssetBindingController(
          shootingScriptController: ref.watch(shootingScriptControllerProvider),
          libraryController: ref.watch(shootingAssetLibraryControllerProvider),
          repository: ShootingScriptWorkflowRepository(
            ref.watch(appDatabaseProvider),
          ),
          settingsController: ref.watch(settingsControllerProvider),
        );
        ref.onDispose(controller.dispose);
        return controller;
      },
      dependencies: [
        appDatabaseProvider,
        settingsControllerProvider,
        shootingAssetLibraryControllerProvider,
        shootingScriptControllerProvider,
      ],
    );

class ScriptAssetBindingState {
  const ScriptAssetBindingState({
    this.scriptId = '',
    this.assets = const [],
    this.links = const [],
    this.isBusy = false,
    this.message = '',
    this.errorMessage = '',
  });

  final String scriptId;
  final List<ScriptAsset> assets;
  final List<ScriptShotAssetLink> links;
  final bool isBusy;
  final String message;
  final String errorMessage;

  ScriptAssetBindingState copyWith({
    String? scriptId,
    List<ScriptAsset>? assets,
    List<ScriptShotAssetLink>? links,
    bool? isBusy,
    String? message,
    String? errorMessage,
  }) => ScriptAssetBindingState(
    scriptId: scriptId ?? this.scriptId,
    assets: assets ?? this.assets,
    links: links ?? this.links,
    isBusy: isBusy ?? this.isBusy,
    message: message ?? this.message,
    errorMessage: errorMessage ?? this.errorMessage,
  );

  List<ScriptShotAssetLink> linksForShot(String shotId) => [
    for (final link in links)
      if (link.shotId == shotId) link,
  ];

  ScriptAsset? assetById(String id) {
    for (final asset in assets) {
      if (asset.id == id) return asset;
    }
    return null;
  }
}

class ShootingScriptAssetBindingController
    extends ValueNotifier<ScriptAssetBindingState> {
  ShootingScriptAssetBindingController({
    required ShootingScriptController shootingScriptController,
    required ShootingAssetLibraryController libraryController,
    required ShootingScriptWorkflowRepository repository,
    required SettingsController settingsController,
    ScriptAssetMatchingService? matchingService,
    Uuid uuid = const Uuid(),
  }) : _shootingScriptController = shootingScriptController,
       _libraryController = libraryController,
       _repository = repository,
       _settingsController = settingsController,
       _matchingService = matchingService ?? ScriptAssetMatchingService(),
       _ownsMatchingService = matchingService == null,
       _uuid = uuid,
       super(const ScriptAssetBindingState()) {
    _shootingScriptController.addListener(_handleScriptChanged);
    _libraryController.addListener(_handleLibraryChanged);
    refresh();
  }

  final ShootingScriptController _shootingScriptController;
  final ShootingAssetLibraryController _libraryController;
  final ShootingScriptWorkflowRepository _repository;
  final SettingsController _settingsController;
  final ScriptAssetMatchingService _matchingService;
  final bool _ownsMatchingService;
  final Uuid _uuid;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _shootingScriptController.removeListener(_handleScriptChanged);
    _libraryController.removeListener(_handleLibraryChanged);
    if (_ownsMatchingService) _matchingService.close();
    super.dispose();
  }

  void refresh({bool preserveBusy = false}) {
    final script = _shootingScriptController.value.selectedScript;
    if (script == null) {
      value = const ScriptAssetBindingState();
      return;
    }
    final assets = _repository.listScriptAssets(script.id);
    final links = _repository.listLinksForScript(script.id);
    value = value.copyWith(
      scriptId: script.id,
      assets: assets,
      links: links,
      isBusy: preserveBusy ? value.isBusy : false,
    );
  }

  Future<void> addLibraryAssetToShot(
    ShootingAssetLibraryItem item,
    String shotId, {
    int? slotSortOrder,
    String? slotLabel,
  }) => _bindAssetToShot(
    item,
    shotId,
    slotSortOrder: slotSortOrder,
    slotLabel: slotLabel,
  );

  Future<void> replaceLibraryAssetOnShot(
    ShootingAssetLibraryItem item,
    String shotId, {
    String? replaceScriptAssetId,
    int? slotSortOrder,
    String? slotLabel,
  }) => _bindAssetToShot(
    item,
    shotId,
    replaceScriptAssetId: replaceScriptAssetId,
    slotSortOrder: slotSortOrder,
    slotLabel: slotLabel,
  );

  Future<void> addStepAssetToShot(
    ReplicateAsset item,
    String shotId, {
    String? replaceScriptAssetId,
    int? slotSortOrder,
    String? slotLabel,
  }) => _bindAssetToShot(
    _libraryCandidateFromStepAsset(item),
    shotId,
    replaceScriptAssetId: replaceScriptAssetId,
    slotSortOrder: slotSortOrder,
    slotLabel: slotLabel,
  );

  Future<void> _bindAssetToShot(
    ShootingAssetLibraryItem item,
    String shotId, {
    String? replaceScriptAssetId,
    int? slotSortOrder,
    String? slotLabel,
  }) async {
    final script = _shootingScriptController.value.selectedScript;
    if (script == null ||
        !_shootingScriptController.value.shots.any(
          (shot) => shot.id == shotId,
        )) {
      value = value.copyWith(errorMessage: '请先选择有效的拍摄脚本和镜头');
      return;
    }
    final asset = _ensureScriptAsset(script.id, item);
    final links = value.linksForShot(shotId);
    final replaced = replaceScriptAssetId == null
        ? null
        : links
              .where((link) => link.scriptAssetId == replaceScriptAssetId)
              .firstOrNull;
    final existing = value
        .linksForShot(shotId)
        .where((link) => link.scriptAssetId == asset.id)
        .firstOrNull;
    if (replaced != null && replaced.scriptAssetId != asset.id) {
      _repository.deleteLink(shotId, replaced.scriptAssetId);
    }
    final now = DateTime.now().toUtc();
    _repository.upsertLink(
      existing?.copyWith(
            matchSource: ScriptAssetMatchSource.manual,
            confidence: 1,
            matchReason: slotLabel == null ? '用户从资产库拖拽' : '用户绑定至“$slotLabel”槽位',
            confirmed: true,
            locked: true,
            sortOrder:
                slotSortOrder ?? replaced?.sortOrder ?? existing.sortOrder,
            updatedAt: now,
          ) ??
          ScriptShotAssetLink(
            shotId: shotId,
            scriptAssetId: asset.id,
            matchSource: ScriptAssetMatchSource.manual,
            confidence: 1,
            matchReason: slotLabel != null
                ? '用户绑定至“$slotLabel”槽位'
                : replaced == null
                ? '用户手动绑定'
                : '用户替换绑定',
            confirmed: true,
            locked: true,
            sortOrder: slotSortOrder ?? replaced?.sortOrder ?? links.length,
            createdAt: now,
            updatedAt: now,
          ),
    );
    refresh();
    value = value.copyWith(
      message: replaced == null
          ? '已将“${item.name}”绑定到镜头'
          : '已将“${item.name}”替换到镜头',
    );
  }

  void removeAssetFromShot(String shotId, String scriptAssetId) {
    _repository.deleteLink(shotId, scriptAssetId);
    refresh();
    value = value.copyWith(message: '已移除镜头资产绑定');
  }

  void updateLink(ScriptShotAssetLink link) {
    _repository.upsertLink(link.copyWith(updatedAt: DateTime.now().toUtc()));
    refresh();
  }

  Future<void> autoMatchAll({
    List<ReplicateAsset> preferredAssets = const [],
    Map<String, int> maximumProductCountsByShotId = const {},
  }) async {
    final script = _shootingScriptController.value.selectedScript;
    final shots = _shootingScriptController.value.shots;
    final libraryItems = _libraryController.value.items;
    final preferredItems = _stepAssetCandidates(preferredAssets);
    if (script == null ||
        shots.isEmpty ||
        (preferredItems.isEmpty && libraryItems.isEmpty)) {
      value = value.copyWith(errorMessage: '需要脚本镜头和可用资产后才能自动匹配', message: '');
      return;
    }
    value = value.copyWith(
      isBusy: true,
      message: '正在匹配 0/${shots.length} 个镜头…',
      errorMessage: '',
    );
    for (var index = 0; index < shots.length; index++) {
      if (_disposed) return;
      await _matchShot(
        script.id,
        shots[index],
        libraryItems,
        preferredItems: preferredItems,
        maximumProductCount: maximumProductCountsByShotId[shots[index].id],
      );
      if (!_disposed) {
        value = value.copyWith(
          message: '正在匹配 ${index + 1}/${shots.length} 个镜头…',
        );
      }
    }
    refresh();
    value = value.copyWith(isBusy: false, message: '已完成本地名称匹配');
  }

  Future<void> autoMatchShot(
    String shotId, {
    List<ReplicateAsset> preferredAssets = const [],
    int? maximumProductCount,
  }) async {
    final script = _shootingScriptController.value.selectedScript;
    final shot = _shootingScriptController.value.shots
        .where((item) => item.id == shotId)
        .firstOrNull;
    if (script == null || shot == null) return;
    value = value.copyWith(isBusy: true, message: '正在匹配镜头 ${shot.shotNumber}…');
    await _matchShot(
      script.id,
      shot,
      _libraryController.value.items,
      preferredItems: _stepAssetCandidates(preferredAssets),
      maximumProductCount: maximumProductCount,
    );
    refresh();
    value = value.copyWith(
      isBusy: false,
      message: '镜头 ${shot.shotNumber} 已完成本地名称匹配',
    );
  }

  void cancelMatching() {
    _matchingService.cancel();
    value = value.copyWith(isBusy: false, message: '已取消资产匹配');
  }

  Future<ScriptAssetMatchResult> _matchShot(
    String scriptId,
    ScriptShot shot,
    List<ShootingAssetLibraryItem> libraryItems, {
    List<ShootingAssetLibraryItem> preferredItems = const [],
    int? maximumProductCount,
  }) async {
    final preferredResult = preferredItems.isEmpty
        ? const ScriptAssetMatchResult(candidates: [], usedModel: false)
        : await _matchingService.match(
            settings: _settingsController.value,
            shot: shot,
            assets: preferredItems,
          );
    final result =
        preferredResult.candidates.any(
          (candidate) => candidate.confidence >= 0.08,
        )
        ? preferredResult
        : await _matchingService.match(
            settings: _settingsController.value,
            shot: shot,
            assets: libraryItems,
          );
    final candidatesById = <String, ShootingAssetLibraryItem>{
      for (final item in libraryItems) item.id: item,
      for (final item in preferredItems) item.id: item,
    };
    final lockedIds = {
      for (final link in value.linksForShot(shot.id))
        if (link.locked) link.scriptAssetId,
    };
    final occupiedSortOrders = {
      for (final link in value.linksForShot(shot.id)) link.sortOrder,
    };
    final reservedParticipantCount = occupiedSortOrders
        .map(ScriptAssetSlotPolicy.presetSlotForSortOrder)
        .whereType<ScriptAssetPresetSlot>()
        .fold<int>(1, (count, slot) {
          final slotCount = switch (slot.kind) {
            ScriptAssetPresetSlotKind.character => slot.characterIndex + 1,
            ScriptAssetPresetSlotKind.product => slot.productIndex + 1,
            ScriptAssetPresetSlotKind.productDetail => slot.productIndex + 1,
            ScriptAssetPresetSlotKind.scene => 1,
          };
          return math.max(count, slotCount);
        });
    final effectiveMaximumProductCount = math.max(
      maximumProductCount ?? 0,
      math.max(
        ScriptAssetSlotPolicy.recognizedCharacterCount(shot: shot),
        reservedParticipantCount,
      ),
    );
    for (final candidate in result.candidates.where(
      (item) => item.confidence >= 0.08,
    )) {
      final libraryItem = candidatesById[candidate.assetId];
      if (libraryItem == null) continue;
      final scriptAsset = _ensureScriptAsset(scriptId, libraryItem);
      if (lockedIds.contains(scriptAsset.id)) continue;
      final existing = value
          .linksForShot(shot.id)
          .where((link) => link.scriptAssetId == scriptAsset.id)
          .firstOrNull;
      if (existing != null) {
        occupiedSortOrders.remove(existing.sortOrder);
      }
      final preferredSortOrder =
          ScriptAssetSlotPolicy.preferredSortOrderForAsset(
            type: libraryItem.type,
            name: libraryItem.name,
            description: libraryItem.description,
            aliases: libraryItem.aliases,
            occupiedSortOrders: occupiedSortOrders,
            maximumProductCount: effectiveMaximumProductCount,
          );
      final sortOrder =
          preferredSortOrder ??
          existing?.sortOrder ??
          _nextGeneralSortOrder(occupiedSortOrders);
      occupiedSortOrders.add(sortOrder);
      final now = DateTime.now().toUtc();
      _repository.upsertLink(
        existing?.copyWith(
              matchSource: ScriptAssetMatchSource.rule,
              confidence: candidate.confidence,
              matchReason: candidate.reason,
              confirmed: candidate.confidence >= 0.82,
              sortOrder: sortOrder,
              updatedAt: now,
            ) ??
            ScriptShotAssetLink(
              shotId: shot.id,
              scriptAssetId: scriptAsset.id,
              matchSource: ScriptAssetMatchSource.rule,
              confidence: candidate.confidence,
              matchReason: candidate.reason,
              confirmed: candidate.confidence >= 0.82,
              locked: false,
              sortOrder: sortOrder,
              createdAt: now,
              updatedAt: now,
            ),
      );
    }
    return result;
  }

  ScriptAsset _ensureScriptAsset(
    String scriptId,
    ShootingAssetLibraryItem item,
  ) {
    final effectiveType = ScriptAssetSlotPolicy.effectiveTypeForSlotting(
      type: item.type,
      name: item.name,
      description: item.description,
      aliases: item.aliases,
    );
    final existing = value.assets
        .where(
          (asset) =>
              asset.scriptId == scriptId && asset.libraryAssetId == item.id,
        )
        .firstOrNull;
    if (existing != null) {
      if (existing.type == effectiveType) return existing;
      final updated = existing.copyWith(
        type: effectiveType,
        updatedAt: DateTime.now().toUtc(),
      );
      _repository.upsertScriptAsset(updated);
      value = value.copyWith(
        assets: [
          for (final asset in value.assets)
            if (asset.id == updated.id) updated else asset,
        ],
      );
      return updated;
    }
    final now = DateTime.now().toUtc();
    final asset = ScriptAsset(
      id: _uuid.v4(),
      scriptId: scriptId,
      libraryAssetId: item.id,
      type: effectiveType,
      name: item.name,
      description: item.description,
      path: item.path,
      referenceNumber: _nextReferenceNumber(item.type),
      status: item.path.trim().isEmpty
          ? ProcessingStatus.failed
          : ProcessingStatus.completed,
      createdAt: now,
      updatedAt: now,
    );
    _repository.upsertScriptAsset(asset);
    value = value.copyWith(assets: [...value.assets, asset]);
    return asset;
  }

  List<ShootingAssetLibraryItem> _stepAssetCandidates(
    List<ReplicateAsset> assets,
  ) => [
    for (final asset in assets)
      if (asset.path.trim().isNotEmpty) _libraryCandidateFromStepAsset(asset),
  ];

  ShootingAssetLibraryItem _libraryCandidateFromStepAsset(
    ReplicateAsset asset,
  ) {
    return ShootingAssetLibraryItem(
      id: asset.id,
      type: asset.type,
      name: asset.name,
      description: asset.description,
      path: asset.path,
      createdAt: asset.createdAt,
      updatedAt: asset.updatedAt,
    );
  }

  int _nextReferenceNumber(ReplicateAssetType type) {
    final numbers = value.assets
        .where((asset) => asset.type == type)
        .map((asset) => asset.referenceNumber)
        .toList();
    return numbers.isEmpty ? 1 : numbers.reduce((a, b) => a > b ? a : b) + 1;
  }

  int _nextGeneralSortOrder(Set<int> occupiedSortOrders) {
    var sortOrder = 0;
    while (occupiedSortOrders.contains(sortOrder)) {
      sortOrder++;
    }
    return sortOrder;
  }

  void _handleScriptChanged() {
    if (!_disposed) refresh(preserveBusy: true);
  }

  void _handleLibraryChanged() {
    if (!_disposed) refresh(preserveBusy: true);
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
