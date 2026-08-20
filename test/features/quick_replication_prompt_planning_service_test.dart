import 'dart:io';

import 'package:filmstoryboard/features/replicate/data/quick_replication_prompt_planning_service.dart';
import 'package:filmstoryboard/features/replicate/domain/quick_replication_reference.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/shooting_script/domain/shooting_script_workflow_models.dart';
import 'package:filmstoryboard/features/storyboard/data/vision_storyboard_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('单产品顺序明确时完全跳过视觉调用', () async {
    final vision = _RecordingPlanningVisionService('{}');
    final service = QuickReplicationPromptPlanningService(
      visionService: vision,
    );
    final outcome = await service.plan(
      settings: _settings(),
      references: _singleProductReferences,
      imageFilesByAssetId: const {},
    );

    expect(outcome.usedVision, isFalse);
    expect(vision.calls, 0);
    expect(outcome.plan.productGroups.single.detailAssetIds, ['detail-a']);
  });

  test('多产品视觉规划按快速顺序提交图片并缓存联合指纹结果', () async {
    final root = await Directory.systemTemp.createTemp('quick_plan_cache_');
    addTearDown(() => root.delete(recursive: true));
    final files = await _files(root, _multiProductReferences);
    final vision = _RecordingPlanningVisionService(_validResponse);
    final service = QuickReplicationPromptPlanningService(
      visionService: vision,
    );

    final first = await service.plan(
      settings: _settings(),
      references: _multiProductReferences,
      imageFilesByAssetId: files,
      supplement: '图4的模特展示产品A和产品B',
    );
    final second = await service.plan(
      settings: _settings(),
      references: _multiProductReferences,
      imageFilesByAssetId: files,
      supplement: '图4的模特展示产品A和产品B',
    );

    expect(first.usedVision, isTrue);
    expect(first.cacheHit, isFalse);
    expect(second.cacheHit, isTrue);
    expect(vision.calls, 1);
    expect(vision.imagePaths, [
      for (final reference in _multiProductReferences)
        files[reference.assetId]!.path,
    ]);
    expect(vision.prompt, contains('不得重排、删除或添加图片编号'));
    expect(second.plan.assignmentFor('detail-a')!.groupAnchorAssetId, 'a');
    expect(second.plan.assignmentFor('detail-b')!.groupAnchorAssetId, 'b');
    expect(service.cacheEntryCount, 1);
  });

  test('非法图片编号或重复细节分组会回退本地计划而不中断', () async {
    final root = await Directory.systemTemp.createTemp('quick_plan_invalid_');
    addTearDown(() => root.delete(recursive: true));
    final files = await _files(root, _multiProductReferences);
    final vision = _RecordingPlanningVisionService('''
      {
        "productGroups":[
          {"label":"A","masterImage":2,"detailImages":[4]},
          {"label":"B","masterImage":3,"detailImages":[4]}
        ],
        "references":[{"imageNumber":99,"warning":""}],
        "normalizedSupplement":""
      }
    ''');
    final service = QuickReplicationPromptPlanningService(
      visionService: vision,
    );

    final outcome = await service.plan(
      settings: _settings(),
      references: _multiProductReferences,
      imageFilesByAssetId: files,
    );

    expect(outcome.usedLocalFallback, isTrue);
    expect(outcome.fallbackReason, contains('多个产品'));
    expect(outcome.plan.needsVisualPlanning, isTrue);
  });

  test('视觉结果不得覆盖描述中明确指定的产品A', () {
    const planner = QuickReplicationLocalPlanner();
    final references = <QuickReplicationReference>[
      ..._multiProductReferences.take(2),
      const QuickReplicationReference(
        assetId: 'detail-explicit',
        imageNumber: 4,
        order: 3,
        role: QuickReferenceRole.productDetail,
        description: '产品A的正面细节',
      ),
    ];
    final local = planner.plan(references: references);
    final service = QuickReplicationPromptPlanningService();
    final plan = service.parseAndValidateResponse(
      '''
      {
        "productGroups":[
          {"label":"A","masterImage":2,"detailImages":[]},
          {"label":"B","masterImage":3,"detailImages":[4]}
        ],
        "references":[{
          "imageNumber":4,
          "assignedProduct":"B",
          "normalizedDescription":"产品A的正面细节",
          "evidence":"visual",
          "confidence":0.95,
          "warning":"视觉更像产品B"
        }],
        "normalizedSupplement":""
      }
      ''',
      localPlan: local,
      originalSupplement: '',
    );

    final assignment = plan.assignmentFor('detail-explicit')!;
    expect(assignment.groupAnchorAssetId, 'a');
    expect(assignment.confidence, 1);
    expect(assignment.warning, contains('用户明确描述'));
  });

  test('图片内容变化会使缓存失效并重新规划', () async {
    final root = await Directory.systemTemp.createTemp('quick_plan_digest_');
    addTearDown(() => root.delete(recursive: true));
    final files = await _files(root, _multiProductReferences);
    final vision = _RecordingPlanningVisionService(_validResponse);
    final service = QuickReplicationPromptPlanningService(
      visionService: vision,
    );
    await service.plan(
      settings: _settings(),
      references: _multiProductReferences,
      imageFilesByAssetId: files,
    );
    await files['detail-a']!.writeAsBytes([9, 9, 9], flush: true);
    final changed = await service.plan(
      settings: _settings(),
      references: _multiProductReferences,
      imageFilesByAssetId: files,
    );

    expect(changed.cacheHit, isFalse);
    expect(vision.calls, 2);
  });
}

const _singleProductReferences = [
  QuickReplicationReference(
    assetId: 'a',
    imageNumber: 2,
    order: 1,
    role: QuickReferenceRole.product,
  ),
  QuickReplicationReference(
    assetId: 'detail-a',
    imageNumber: 3,
    order: 2,
    role: QuickReferenceRole.productDetail,
  ),
];

const _multiProductReferences = [
  QuickReplicationReference(
    assetId: 'a',
    imageNumber: 2,
    order: 1,
    role: QuickReferenceRole.product,
    name: '黑色裤子',
  ),
  QuickReplicationReference(
    assetId: 'b',
    imageNumber: 3,
    order: 2,
    role: QuickReferenceRole.product,
    name: '白色鞋子',
  ),
  QuickReplicationReference(
    assetId: 'detail-a',
    imageNumber: 4,
    order: 3,
    role: QuickReferenceRole.productDetail,
  ),
  QuickReplicationReference(
    assetId: 'detail-b',
    imageNumber: 5,
    order: 4,
    role: QuickReferenceRole.productDetail,
    description: '白色鞋子的鞋底',
  ),
];

const _validResponse = '''
{
  "productGroups":[
    {"label":"A","masterImage":2,"detailImages":[4]},
    {"label":"B","masterImage":3,"detailImages":[5]}
  ],
  "references":[
    {"imageNumber":4,"assignedProduct":"A","normalizedDescription":"裤子腰头与口袋细节","evidence":"visual","confidence":0.88,"warning":""},
    {"imageNumber":5,"assignedProduct":"B","normalizedDescription":"白色鞋子的鞋底","evidence":"description","confidence":1.0,"warning":""}
  ],
  "normalizedSupplement":"图4的模特展示产品A和产品B"
}
''';

Future<Map<String, File>> _files(
  Directory root,
  List<QuickReplicationReference> references,
) async {
  final result = <String, File>{};
  for (var index = 0; index < references.length; index++) {
    final reference = references[index];
    final file = File(p.join(root.path, '${reference.assetId}.png'));
    await file.writeAsBytes([index + 1, index + 2], flush: true);
    result[reference.assetId] = file;
  }
  return result;
}

class _RecordingPlanningVisionService extends VisionStoryboardService {
  _RecordingPlanningVisionService(this.response);

  final String response;
  int calls = 0;
  String prompt = '';
  List<String> imagePaths = const [];

  @override
  Future<String> complete({
    required AppSettings settings,
    required String prompt,
    List<File> imageFiles = const [],
    int maxTokens = 1200,
    bool allowThinking = false,
    Duration responseTimeout = VisionStoryboardService.requestTimeout,
    bool compressOversizedImages = false,
  }) async {
    calls++;
    this.prompt = prompt;
    imagePaths = [for (final file in imageFiles) file.path];
    return response;
  }
}

AppSettings _settings() => AppSettings(
  exportDirectory: 'exports',
  themePreference: AppThemePreference.system,
  cutImageNumberEnabled: false,
  cutImageNumberPosition: CutImageNumberPosition.topLeft,
  cutImageNumberBackgroundOpacity:
      AppSettings.defaultCutImageNumberBackgroundOpacity,
  cutImageNumberTextScale: AppSettings.defaultCutImageNumberTextScale,
  storyboardSummaryPageEnabled: true,
  visionApiBaseUrl: '127.0.0.1:12345',
  visionApiKey: 'test-key',
  visionModel: 'test-vlm',
  imageGenerationApiBaseUrl: 'https://grsai.example',
  imageGenerationApiKey: 'test-image-key',
  imageGenerationGeminiApiKey: 'test-gemini-key',
  imageGenerationModel: 'nano-banana-fast',
  updateReleaseApiUrl: '',
  autoInstallUpdates: false,
  updateDownloadMode: UpdateDownloadMode.automatic,
  updateManualProxyUrl: 'http://127.0.0.1:7890',
);
