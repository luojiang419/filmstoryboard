class LibTvCliEnvironment {
  const LibTvCliEnvironment({
    required this.executablePath,
    required this.version,
    required this.errorMessage,
  });

  final String executablePath;
  final String version;
  final String errorMessage;

  bool get isReady => errorMessage.isEmpty;
}

class LibTvAccountInfo {
  const LibTvAccountInfo({
    required this.userId,
    required this.nickname,
    required this.accountName,
    required this.teamId,
  });

  final String userId;
  final String nickname;
  final String accountName;
  final int teamId;
}

class LibTvModelSummary {
  const LibTvModelSummary({
    required this.modelName,
    required this.modelKey,
    required this.modality,
  });

  final String modelName;
  final String modelKey;
  final String modality;
}

class LibTvParameterOption {
  const LibTvParameterOption({required this.value, required this.label});

  final String value;
  final String label;
}

enum LibTvParameterGroup { basic, advanced }

class LibTvModelParameterSpec {
  const LibTvModelParameterSpec({
    required this.key,
    required this.displayName,
    required this.component,
    required this.defaultValue,
    required this.options,
    required this.group,
    this.min,
    this.max,
    this.step,
  });

  final String key;
  final String displayName;
  final String component;
  final String defaultValue;
  final List<LibTvParameterOption> options;
  final LibTvParameterGroup group;
  final num? min;
  final num? max;
  final num? step;

  bool get isSwitch => component.toLowerCase() == 'switch';

  bool get hasNumericRange => min != null && max != null;
}

class LibTvModelSpec {
  const LibTvModelSpec({
    required this.modelName,
    required this.modelKey,
    required this.modality,
    required this.schema,
  });

  final String modelName;
  final String modelKey;
  final String modality;
  final Map<String, Object?> schema;

  Map<String, Object?> get properties => _stringMap(schema['properties']);

  Map<String, Object?> get config => _stringMap(schema['config']);

  List<String> get modeTypes {
    final modeType = _stringMap(properties['modeType']);
    return List.unmodifiable(_stringMap(modeType['items']).keys);
  }

  List<String> get imageInputModeTypes => List.unmodifiable(
    modeTypes.where(
      const {
        'singleImage2video',
        'frames2video',
        'image2video',
        'mixed2video',
      }.contains,
    ),
  );

  ({int min, int max})? inputRangeForMode(String modeType) {
    final mode = _stringMap(properties['modeType']);
    final raw = _objectList(_stringMap(mode['items'])[modeType]);
    if (raw.length < 2) return null;
    final min = _integerOrNull(raw[0]);
    final max = _integerOrNull(raw[1]);
    if (min == null || max == null) return null;
    return (min: min, max: max);
  }

  List<LibTvParameterOption> get countOptions {
    final property = properties['count'];
    final raw = property is Map ? _stringMap(property)['enum'] : property;
    return List.unmodifiable(_parameterOptions(raw));
  }

  LibTvModelParameterSpec? parameter(
    String key, {
    LibTvParameterGroup group = LibTvParameterGroup.basic,
  }) {
    final property = _stringMap(properties[key]);
    if (property.isEmpty) return null;
    return _parameterSpec(key, property, group);
  }

  List<LibTvModelParameterSpec> parametersForMode(String modeType) {
    final result = <LibTvModelParameterSpec>[];
    final seen = <String>{};
    void addGroup(Object? raw, LibTvParameterGroup group) {
      for (final key in _configuredKeys(raw, modeType)) {
        if (!seen.add(key)) continue;
        final spec = parameter(key, group: group);
        if (spec != null) result.add(spec);
      }
    }

    addGroup(config['settings'], LibTvParameterGroup.basic);
    addGroup(config['advancedSettings'], LibTvParameterGroup.advanced);
    return List.unmodifiable(result);
  }
}

LibTvModelParameterSpec _parameterSpec(
  String key,
  Map<String, Object?> property,
  LibTvParameterGroup group,
) {
  return LibTvModelParameterSpec(
    key: key,
    displayName: _string(property['displayName']).isEmpty
        ? key
        : _string(property['displayName']),
    component: _string(property['component']),
    defaultValue: _scalarString(property['default']),
    options: List.unmodifiable(_parameterOptions(property['enum'])),
    group: group,
    min: _numberOrNull(property['min']),
    max: _numberOrNull(property['max']),
    step: _numberOrNull(property['step']),
  );
}

List<String> _configuredKeys(Object? raw, String modeType) {
  if (raw is List) {
    return raw.map(_string).where((value) => value.isNotEmpty).toList();
  }
  final byMode = _stringMap(raw);
  final selected = byMode[modeType] ?? byMode['default'];
  if (selected is! List) return const [];
  return selected.map(_string).where((value) => value.isNotEmpty).toList();
}

List<LibTvParameterOption> _parameterOptions(Object? raw) {
  if (raw is! List) return const [];
  final result = <LibTvParameterOption>[];
  final seen = <String>{};
  for (final item in raw) {
    final map = _stringMap(item);
    final value = map.isEmpty
        ? _scalarString(item)
        : _scalarString(map['value'] ?? map['key'] ?? map['id']);
    if (value.isEmpty || !seen.add(value)) continue;
    final label = map.isEmpty
        ? value
        : _string(map['displayName'] ?? map['label'] ?? map['name']);
    result.add(
      LibTvParameterOption(value: value, label: label.isEmpty ? value : label),
    );
  }
  return result;
}

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map) return const {};
  return value.map((key, value) => MapEntry('$key', value));
}

List<Object?> _objectList(Object? value) => value is List ? value : const [];

String _string(Object? value) => value is String ? value.trim() : '';

String _scalarString(Object? value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  if (value is num || value is bool) return '$value';
  return '';
}

num? _numberOrNull(Object? value) {
  if (value is num) return value;
  return num.tryParse(_string(value));
}

int? _integerOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(_string(value));
}

class LibTvGenerationResult {
  const LibTvGenerationResult({
    required this.projectUuid,
    required this.nodeKey,
    required this.taskId,
    required this.videoUrl,
    required this.rawJson,
  });

  final String projectUuid;
  final String nodeKey;
  final String taskId;
  final String videoUrl;
  final Map<String, Object?> rawJson;
}

class LibTvCliException implements Exception {
  const LibTvCliException(this.message, {this.exitCode, this.rawOutput = ''});

  final String message;
  final int? exitCode;
  final String rawOutput;

  @override
  String toString() => message;
}

class LibTvGenerationCanceledException extends LibTvCliException {
  const LibTvGenerationCanceledException() : super('已取消 LibTV 视频生成。');
}
