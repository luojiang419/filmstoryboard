import 'dart:io';

import 'package:filmstoryboard/features/replicate/data/replication_asset_view_selection_service.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:filmstoryboard/features/settings/domain/app_settings.dart';
import 'package:filmstoryboard/features/storyboard/data/vision_storyboard_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  test('视觉模型根据原帧选择拼图主视图和细节视图并从原始像素裁切', () async {
    final root = await Directory.systemTemp.createTemp('asset_view_select_');
    addTearDown(() => root.delete(recursive: true));
    final original = File(p.join(root.path, 'frame.png'));
    final asset = File(p.join(root.path, 'product-sheet.png'));
    await original.writeAsBytes(
      img.encodePng(img.Image(width: 80, height: 60)),
    );
    final sheet = img.Image(width: 100, height: 20);
    final colors = const [
      (255, 0, 0),
      (0, 255, 0),
      (0, 0, 255),
      (255, 255, 0),
      (255, 0, 255),
    ];
    for (var panel = 0; panel < colors.length; panel++) {
      final color = colors[panel];
      for (var y = 0; y < sheet.height; y++) {
        for (var x = panel * 20; x < (panel + 1) * 20; x++) {
          sheet.setPixelRgb(x, y, color.$1, color.$2, color.$3);
        }
      }
    }
    await asset.writeAsBytes(img.encodePng(sheet));
    final vision = _FixedVisionService('''
      {
        "is_multi_view": true,
        "views": [
          {"id":"front","bbox":[0.0,0.0,0.2,1.0],"orientation":"正面","match_score":0.4},
          {"id":"side","bbox":[0.2,0.0,0.2,1.0],"orientation":"右侧面","description":"完整侧缝","match_score":0.96,"match_reason":"匹配原帧侧面"},
          {"id":"detail","bbox":[0.8,0.0,0.2,1.0],"orientation":"局部细节","description":"裤脚结构","match_score":0.8}
        ],
        "selected_primary_view_id":"side",
        "selected_detail_view_ids":["detail"]
      }
      ''');
    final service = ReplicationAssetViewSelectionService(visionService: vision);

    final prepared = await service.prepare(
      settings: _settings(),
      originalFrame: original,
      assetImage: asset,
      outputDirectory: Directory(p.join(root.path, 'crops')),
      shotNumber: 3,
      assetId: 'product-1',
      assetName: '蓝色牛仔裤',
      assetType: ReplicateAssetType.product,
      slotLabel: '产品',
    );

    expect(prepared, hasLength(2));
    expect(prepared.first.isDetail, isFalse);
    expect(prepared.last.isDetail, isTrue);
    expect(prepared.first.description, contains('匹配原帧侧面'));
    final primary = img.decodeImage(
      await File(prepared.first.path).readAsBytes(),
    )!;
    final detail = img.decodeImage(
      await File(prepared.last.path).readAsBytes(),
    )!;
    expect((primary.width, primary.height), (20, 20));
    expect(primary.getPixel(0, 0).g, 255);
    expect(detail.getPixel(0, 0).r, 255);
    expect(detail.getPixel(0, 0).b, 255);
    expect(vision.imagePaths, [original.path, asset.path]);
    expect(vision.prompt, contains('根据图片1的目标机位和可见面选择一个主视图'));
  });

  test('视觉模型判断为单图时保持原资产路径', () async {
    final root = await Directory.systemTemp.createTemp('asset_single_view_');
    addTearDown(() => root.delete(recursive: true));
    final original = File(p.join(root.path, 'frame.png'));
    final asset = File(p.join(root.path, 'asset.png'));
    final bytes = img.encodePng(img.Image(width: 32, height: 32));
    await original.writeAsBytes(bytes);
    await asset.writeAsBytes(bytes);
    final service = ReplicationAssetViewSelectionService(
      visionService: _FixedVisionService(
        '{"is_multi_view":false,"views":[],"selected_primary_view_id":"","selected_detail_view_ids":[]}',
      ),
    );

    final prepared = await service.prepare(
      settings: _settings(),
      originalFrame: original,
      assetImage: asset,
      outputDirectory: Directory(p.join(root.path, 'crops')),
      shotNumber: 1,
      assetId: 'asset-1',
      assetName: '单图资产',
      assetType: ReplicateAssetType.character,
      slotLabel: '模特',
    );

    expect(prepared.single.path, asset.path);
    expect(Directory(p.join(root.path, 'crops')).existsSync(), isFalse);
  });
}

class _FixedVisionService extends VisionStoryboardService {
  _FixedVisionService(this.response);

  final String response;
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
