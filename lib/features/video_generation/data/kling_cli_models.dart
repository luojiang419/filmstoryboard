import '../domain/video_generation_models.dart';

class KlingArgumentSpec {
  const KlingArgumentSpec({
    required this.name,
    required this.required,
    required this.defaultValue,
    required this.allowedValues,
    required this.description,
  });

  final String name;
  final bool required;
  final String defaultValue;
  final List<String> allowedValues;
  final String description;
}

class KlingInputSpec {
  const KlingInputSpec({
    required this.name,
    required this.required,
    required this.description,
  });

  final String name;
  final bool required;
  final String description;
}

class KlingModelSpec {
  const KlingModelSpec({
    required this.model,
    required this.alias,
    required this.description,
    required this.arguments,
    this.inputs = const [],
  });

  final String model;
  final String alias;
  final String description;
  final List<KlingArgumentSpec> arguments;
  final List<KlingInputSpec> inputs;

  KlingArgumentSpec? argument(String name) {
    for (final argument in arguments) {
      if (argument.name == name) return argument;
    }
    return null;
  }

  bool supportsInput(String name) {
    for (final input in inputs) {
      if (input.name == name) return true;
    }
    return false;
  }

  bool get supportsNumberedImageReferences => supportsInput('image_1');

  int get maxNumberedImageReferences {
    var max = 0;
    for (final input in inputs) {
      final match = RegExp(r'^image_(\d+)$').firstMatch(input.name);
      if (match == null) continue;
      final number = int.tryParse(match.group(1) ?? '') ?? 0;
      if (number > max) max = number;
    }
    return max;
  }
}

class KlingIdentity {
  const KlingIdentity({required this.userId, required this.imageToVideoModels});

  final String userId;
  final List<KlingModelSpec> imageToVideoModels;
}

class KlingAccount {
  const KlingAccount({
    required this.userId,
    required this.membershipType,
    required this.membershipDescription,
    required this.availableCredits,
  });

  final String userId;
  final String membershipType;
  final String membershipDescription;
  final int availableCredits;
}

class KlingSubmissionResult {
  const KlingSubmissionResult({
    required this.generationId,
    required this.rawJson,
  });

  final String generationId;
  final Map<String, Object?> rawJson;
}

class KlingTaskResult {
  const KlingTaskResult({
    required this.generationId,
    required this.status,
    required this.url,
    required this.urlWithoutWatermark,
    required this.errorMessage,
    required this.rawJson,
  });

  final String generationId;
  final VideoGenerationTaskStatus status;
  final String url;
  final String urlWithoutWatermark;
  final String errorMessage;
  final Map<String, Object?> rawJson;
}

class KlingCliException implements Exception {
  const KlingCliException(this.message, {this.exitCode, this.rawOutput = ''});

  final String message;
  final int? exitCode;
  final String rawOutput;

  @override
  String toString() => message;
}
