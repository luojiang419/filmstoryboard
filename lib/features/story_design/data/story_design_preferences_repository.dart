import 'dart:convert';

import '../../../core/database/app_database.dart';

class StoryDesignGenerationPreferences {
  const StoryDesignGenerationPreferences({
    required this.model,
    required this.aspectRatio,
    required this.imageSize,
    required this.quality,
    required this.batchCount,
    required this.gridCount,
    required this.portraitGrid,
  });

  factory StoryDesignGenerationPreferences.defaults({required String model}) {
    return StoryDesignGenerationPreferences(
      model: model,
      aspectRatio: 'auto',
      imageSize: '1K',
      quality: 'auto',
      batchCount: 1,
      gridCount: 0,
      portraitGrid: false,
    );
  }

  factory StoryDesignGenerationPreferences.fromJson(
    Object? json, {
    required String fallbackModel,
  }) {
    final defaults = StoryDesignGenerationPreferences.defaults(
      model: fallbackModel,
    );
    if (json is! Map) {
      return defaults;
    }
    return StoryDesignGenerationPreferences(
      model: _string(json['model'], defaults.model),
      aspectRatio: _string(json['aspectRatio'], defaults.aspectRatio),
      imageSize: _string(json['imageSize'], defaults.imageSize),
      quality: _string(json['quality'], defaults.quality),
      batchCount: _integer(json['batchCount'], defaults.batchCount),
      gridCount: _integer(json['gridCount'], defaults.gridCount),
      portraitGrid: json['portraitGrid'] == true,
    );
  }

  final String model;
  final String aspectRatio;
  final String imageSize;
  final String quality;
  final int batchCount;
  final int gridCount;
  final bool portraitGrid;

  Map<String, Object?> toJson() {
    return {
      'model': model,
      'aspectRatio': aspectRatio,
      'imageSize': imageSize,
      'quality': quality,
      'batchCount': batchCount,
      'gridCount': gridCount,
      'portraitGrid': portraitGrid,
    };
  }

  static String _string(Object? value, String fallback) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static int _integer(Object? value, int fallback) {
    return value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}

class StoryDesignPreferencesRepository {
  const StoryDesignPreferencesRepository(this._database);

  static const settingKey = 'storyDesignGenerationParameters';

  final AppDatabase _database;

  StoryDesignGenerationPreferences load({required String fallbackModel}) {
    final raw = _database.getSetting(settingKey);
    if (raw == null || raw.trim().isEmpty) {
      return StoryDesignGenerationPreferences.defaults(model: fallbackModel);
    }
    try {
      return StoryDesignGenerationPreferences.fromJson(
        jsonDecode(raw),
        fallbackModel: fallbackModel,
      );
    } on FormatException {
      return StoryDesignGenerationPreferences.defaults(model: fallbackModel);
    }
  }

  void save(StoryDesignGenerationPreferences preferences) {
    _database.setSetting(settingKey, jsonEncode(preferences.toJson()));
  }
}
