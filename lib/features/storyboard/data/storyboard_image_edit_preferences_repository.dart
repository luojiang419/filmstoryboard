import 'dart:convert';

import '../../../core/database/app_database.dart';

class StoryboardImageEditPreferences {
  const StoryboardImageEditPreferences({
    required this.model,
    required this.aspectRatio,
    required this.imageSize,
  });

  final String model;
  final String aspectRatio;
  final String imageSize;
}

class StoryboardImageEditPreferencesRepository {
  const StoryboardImageEditPreferencesRepository(this._database);

  static const settingKey = 'storyboardImageEditPreferences';

  final AppDatabase _database;

  StoryboardImageEditPreferences load({required String fallbackModel}) {
    final fallback = StoryboardImageEditPreferences(
      model: fallbackModel.trim(),
      aspectRatio: 'auto',
      imageSize: '1K',
    );
    final raw = _database.getSetting(settingKey);
    if (raw == null || raw.trim().isEmpty) {
      return fallback;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return fallback;
      }
      return StoryboardImageEditPreferences(
        model: _nonEmpty(decoded['model'], fallback.model),
        aspectRatio: _nonEmpty(decoded['aspectRatio'], fallback.aspectRatio),
        imageSize: _nonEmpty(decoded['imageSize'], fallback.imageSize),
      );
    } on FormatException {
      return fallback;
    }
  }

  void save(StoryboardImageEditPreferences preferences) {
    _database.setSetting(
      settingKey,
      jsonEncode({
        'model': preferences.model.trim(),
        'aspectRatio': preferences.aspectRatio.trim(),
        'imageSize': preferences.imageSize.trim(),
      }),
    );
  }

  String _nonEmpty(Object? value, String fallback) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }
}
