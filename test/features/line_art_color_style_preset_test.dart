import 'dart:convert';
import 'dart:io';

import 'package:filmstoryboard/features/replicate/domain/line_art_color_style_catalog.dart';
import 'package:filmstoryboard/features/replicate/domain/line_art_color_style_preset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('内置目录聚焦高端服装、电影和商业摄影且仅保留一个艺术化预设', () {
    final presets = LineArtColorStyleCatalog.builtInPresets;

    expect(presets, hasLength(10));
    expect(presets.map((preset) => preset.id).toSet(), hasLength(10));
    expect(
      presets
          .where(
            (preset) => preset.useCase == LineArtColorStyleUseCase.stylized,
          )
          .length,
      1,
    );
    expect(
      presets.where(
        (preset) => preset.useCase == LineArtColorStyleUseCase.fashion,
      ),
      hasLength(greaterThanOrEqualTo(4)),
    );
    expect(
      presets.where(
        (preset) => preset.useCase == LineArtColorStyleUseCase.cinema,
      ),
      hasLength(greaterThanOrEqualTo(3)),
    );
  });

  test('所有内置预设均有本地16比9缩略图、色板和商业色彩保护约束', () {
    for (final preset in LineArtColorStyleCatalog.builtInPresets) {
      expect(preset.isBuiltIn, isTrue, reason: preset.id);
      expect(preset.version, greaterThan(0), reason: preset.id);
      expect(preset.swatches, hasLength(greaterThanOrEqualTo(3)));
      expect(preset.thumbnail, isNotNull, reason: preset.id);
      expect(
        preset.thumbnail!.type,
        ColorStyleThumbnailType.bundledAsset,
        reason: preset.id,
      );
      expect(
        File(preset.thumbnail!.path).existsSync(),
        isTrue,
        reason: preset.id,
      );
      expect(
        preset.prompt.toLowerCase(),
        contains('preserve'),
        reason: preset.id,
      );
      expect(
        preset.prompt.toLowerCase(),
        contains('authorized'),
        reason: preset.id,
      );
    }
  });

  test('选择快照序列化后指纹稳定，内容被修改时校验失败', () {
    final preset = LineArtColorStyleCatalog.byId('desaturated_prestige');
    final snapshot = LineArtColorStyleSelectionSnapshot.fromPreset(preset);
    final restored = LineArtColorStyleSelectionSnapshot.fromJson(
      (jsonDecode(jsonEncode(snapshot.toJson())) as Map)
          .cast<String, Object?>(),
    );

    expect(restored.fingerprint, snapshot.fingerprint);
    expect(restored.hasValidFingerprint, isTrue);

    final tamperedJson = Map<String, Object?>.from(restored.toJson())
      ..['prompt'] = '${restored.prompt} changed';
    final tampered = LineArtColorStyleSelectionSnapshot.fromJson(tamperedJson);
    expect(tampered.hasValidFingerprint, isFalse);
  });

  test('自定义预设可完整序列化项目缩略图与时间信息', () {
    final now = DateTime.utc(2026, 8, 21, 6, 30);
    final preset = LineArtColorStylePreset(
      id: 'custom-1',
      name: '客户红毯',
      description: '客户定制',
      prompt:
          'Preserve authorized colors and apply a restrained red-carpet grade.',
      swatches: const ['#551122', '#D5B89A'],
      useCase: LineArtColorStyleUseCase.fashion,
      isBuiltIn: false,
      version: 3,
      thumbnail: const ColorStyleThumbnailReference.projectFile(
        r'assets\color_style_thumbnails\custom.jpg',
      ),
      createdAt: now,
      updatedAt: now,
    );

    final restored = LineArtColorStylePreset.fromJson(
      (jsonDecode(jsonEncode(preset.toJson())) as Map).cast<String, Object?>(),
    );
    expect(restored.id, preset.id);
    expect(restored.thumbnail!.path, preset.thumbnail!.path);
    expect(restored.updatedAt, now);
    expect(restored.version, 3);
  });
}
