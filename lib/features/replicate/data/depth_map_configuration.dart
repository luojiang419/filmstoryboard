import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../settings/domain/app_settings.dart';

class DepthMapControls {
  const DepthMapControls({
    this.farPoint = 0,
    this.nearPoint = 100,
    this.midtone = 0,
    this.contrast = 100,
    this.brightness = 0,
    this.smooth = 0,
    this.invert = false,
  });

  final int farPoint;
  final int nearPoint;
  final int midtone;
  final int contrast;
  final int brightness;
  final int smooth;
  final bool invert;

  factory DepthMapControls.fromJson(Object? value) {
    final source = value is Map
        ? Map<String, dynamic>.from(value)
        : const <String, dynamic>{};
    var farPoint = _integer(source['farPoint'], 0, min: 0, max: 99);
    var nearPoint = _integer(source['nearPoint'], 100, min: 1, max: 100);
    if (nearPoint <= farPoint) {
      if (farPoint < 99) {
        nearPoint = farPoint + 1;
      } else {
        farPoint = nearPoint - 1;
      }
    }
    return DepthMapControls(
      farPoint: farPoint,
      nearPoint: nearPoint,
      midtone: _integer(source['midtone'], 0, min: -100, max: 100),
      contrast: _integer(source['contrast'], 100, min: 0, max: 300),
      brightness: _integer(source['brightness'], 0, min: -100, max: 100),
      smooth: _integer(source['smooth'], 0, min: 0, max: 50),
      invert: source['invert'] == true,
    );
  }

  Map<String, Object> toJson() => {
    'farPoint': farPoint,
    'nearPoint': nearPoint,
    'midtone': midtone,
    'contrast': contrast,
    'brightness': brightness,
    'smooth': smooth,
    'invert': invert,
  };

  static int _integer(
    Object? value,
    int fallback, {
    required int min,
    required int max,
  }) {
    final number = value is num ? value : num.tryParse('$value');
    return (number?.round() ?? fallback).clamp(min, max);
  }
}

class DepthMapConfiguration {
  const DepthMapConfiguration({
    this.person = const DepthMapControls(),
    this.professional = const DepthMapControls(),
  });

  final DepthMapControls person;
  final DepthMapControls professional;

  DepthMapControls controlsFor(DepthProcessingMode mode) => switch (mode) {
    DepthProcessingMode.person => person,
    DepthProcessingMode.professional => professional,
  };

  factory DepthMapConfiguration.fromJson(Object? value) {
    if (value is! Map) return const DepthMapConfiguration();
    final source = Map<String, dynamic>.from(value);
    final profiles = source['profiles'];
    if (profiles is Map) {
      return DepthMapConfiguration(
        person: DepthMapControls.fromJson(profiles['person']),
        professional: DepthMapControls.fromJson(profiles['professional']),
      );
    }
    // Compatibility with the original tuner export schema.
    final legacy = source['compatibility'] is Map
        ? (source['compatibility'] as Map)['values']
        : source['canvasDefaults'];
    final controls = DepthMapControls.fromJson(legacy);
    return DepthMapConfiguration(person: controls, professional: controls);
  }

  Map<String, Object> toJson() => {
    'schema': 'filmstoryboard.depth-map-config/v1',
    'schemaVersion': 1,
    'profiles': {
      'person': person.toJson(),
      'professional': professional.toJson(),
    },
  };
}

class DepthMapConfigurationStore {
  const DepthMapConfigurationStore(this.file);

  final File file;

  static File defaultFile() => File(
    p.join(
      p.dirname(Platform.resolvedExecutable),
      'data',
      'depth-map',
      'depth-map-config.json',
    ),
  );

  Future<DepthMapConfiguration> load() async {
    try {
      if (!await file.exists()) return const DepthMapConfiguration();
      return DepthMapConfiguration.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } on FileSystemException {
      return const DepthMapConfiguration();
    } on FormatException {
      return const DepthMapConfiguration();
    }
  }

  Future<void> save(DepthMapConfiguration configuration) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(configuration.toJson())}\n',
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }
}
