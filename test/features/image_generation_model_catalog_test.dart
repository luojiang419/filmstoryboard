import 'package:flutter_test/flutter_test.dart';
import 'package:filmstoryboard/features/storyboard/data/image_generation_service.dart';

void main() {
  test('模型目录按服务商和系列完整分组且模型 id 唯一', () {
    final providers = ImageGenerationModelCatalog.providerGroups;
    expect(providers.map((item) => item.id), ['gemini', 'grsai', 'apimart']);

    final groupedIds = <String>[];
    for (final provider in providers) {
      for (final family in provider.families) {
        groupedIds.addAll(family.modelIds);
      }
    }

    expect(groupedIds.toSet().length, groupedIds.length);
    expect(ImageGenerationModelCatalog.values.toSet(), containsAll(groupedIds));
    expect(groupedIds, contains('gemini-3-pro-image'));
    expect(
      groupedIds,
      isNot(contains('gemini-3-pro-image-preview')),
      reason: '已停用的 preview 模型只保留历史记录兼容，不再出现在选择器里',
    );
  });

  test('GRSai 保留 Nano 和 GPT 两个系列', () {
    final grsai = ImageGenerationModelCatalog.providerGroups.singleWhere(
      (item) => item.id == 'grsai',
    );

    expect(grsai.families.map((item) => item.label), [
      'Nano Banana',
      'GPT Image',
    ]);
    expect(grsai.families.first.modelIds, contains('nano-banana-fast'));
    expect(grsai.families.last.modelIds, contains('gpt-image-2-vip'));
  });

  test('APIMart 使用命名空间区分与 GRSai 重名的模型', () {
    final grsai = ImageGenerationModelCatalog.descriptorFor('gpt-image-2');
    final apiMart = ImageGenerationModelCatalog.descriptorFor(
      'apimart:gpt-image-2',
    );

    expect(grsai?.providerId, 'grsai');
    expect(apiMart?.providerId, 'apimart');
    expect(apiMart?.apiModel, 'gpt-image-2');
    expect(
      ImageGenerationModelCatalog.providerLabelForModel(apiMart!.id),
      'APIMart',
    );
  });

  test('APIMart 模型能力与官方文档约束一致', () {
    final nano2 = ImageGenerationModelCatalog.descriptorFor(
      'apimart:gemini-3.1-flash-image-preview',
    )!;
    final imagen = ImageGenerationModelCatalog.descriptorFor(
      'apimart:imagen-4.0-apimart',
    )!;
    final grok = ImageGenerationModelCatalog.descriptorFor(
      'apimart:grok-imagine-1.5-apimart',
    )!;
    final wanPro = ImageGenerationModelCatalog.descriptorFor(
      'apimart:wan2.7-image-pro',
    )!;
    final seedream4 = ImageGenerationModelCatalog.descriptorFor(
      'apimart:doubao-seedance-4-0',
    )!;
    final seedream45 = ImageGenerationModelCatalog.descriptorFor(
      'apimart:doubao-seedance-4-5',
    )!;
    final seedream5Lite = ImageGenerationModelCatalog.descriptorFor(
      'apimart:doubao-seedream-5-0-lite',
    )!;

    expect(nano2.aspectRatios, containsAll(['1:8', '8:1']));
    expect(nano2.resolutions, ['0.5K', '1K', '2K', '4K']);
    expect(nano2.maxReferenceImages, 14);
    expect(imagen.supportsReferenceImages, isFalse);
    expect(imagen.aspectRatios, isNot(contains('21:9')));
    expect(grok.referenceApiModel, 'grok-imagine-1.5-edit-apimart');
    expect(wanPro.maxReferenceImages, 9);
    expect(wanPro.resolutions, ['1K', '2K', '4K']);
    expect(seedream4.maxReferenceImages, 10);
    expect(seedream45.maxReferenceImages, 10);
    expect(seedream5Lite.maxReferenceImages, 10);
    expect(seedream5Lite.resolutions, ['2K', '3K']);
    expect(seedream5Lite.aspectRatios, isNot(contains('9:21')));
  });

  test('APIMart GPT Image 2 仅在官方允许的比例提供 4K', () {
    expect(
      ImageGenerationModelCatalog.resolutionsFor(
        'apimart:gpt-image-2-official',
        '1:1',
      ),
      ['1K', '2K'],
    );
    expect(
      ImageGenerationModelCatalog.resolutionsFor(
        'apimart:gpt-image-2-official',
        '16:9',
      ),
      ['1K', '2K', '4K'],
    );
  });

  test('APIMart 参考图模型可解析实际编辑模型 id', () {
    expect(
      ImageGenerationCatalog.apiModelFor(
        'apimart:grok-imagine-1.5-apimart',
        hasReferences: false,
      ),
      'grok-imagine-1.5-apimart',
    );
    expect(
      ImageGenerationCatalog.apiModelFor(
        'apimart:grok-imagine-1.5-apimart',
        hasReferences: true,
      ),
      'grok-imagine-1.5-edit-apimart',
    );
  });
}
