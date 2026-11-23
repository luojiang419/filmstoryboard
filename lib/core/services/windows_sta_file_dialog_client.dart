import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/services.dart';

class WindowsStaFileDialogClient {
  const WindowsStaFileDialogClient({
    MethodChannel channel = const MethodChannel(
      'filmstoryboard/native_file_dialog',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  Future<file_selector.XFile?> openFile({
    List<file_selector.XTypeGroup> acceptedTypeGroups = const [],
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final response = await _invoke(
      'open',
      acceptedTypeGroups: acceptedTypeGroups,
      initialDirectory: initialDirectory,
      confirmButtonText: confirmButtonText,
    );
    return response.paths.isEmpty
        ? null
        : file_selector.XFile(response.paths.first);
  }

  Future<List<file_selector.XFile>> openFiles({
    List<file_selector.XTypeGroup> acceptedTypeGroups = const [],
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final response = await _invoke(
      'openFiles',
      acceptedTypeGroups: acceptedTypeGroups,
      initialDirectory: initialDirectory,
      confirmButtonText: confirmButtonText,
    );
    return response.paths.map(file_selector.XFile.new).toList();
  }

  Future<file_selector.FileSaveLocation?> getSaveLocation({
    List<file_selector.XTypeGroup> acceptedTypeGroups = const [],
    String? initialDirectory,
    String? suggestedName,
    String? confirmButtonText,
    bool? canCreateDirectories,
  }) async {
    final response = await _invoke(
      'save',
      acceptedTypeGroups: acceptedTypeGroups,
      initialDirectory: initialDirectory,
      suggestedName: suggestedName,
      confirmButtonText: confirmButtonText,
    );
    if (response.paths.isEmpty) {
      return null;
    }
    final filterIndex = response.activeFilterIndex;
    final activeFilter =
        filterIndex != null &&
            filterIndex >= 0 &&
            filterIndex < acceptedTypeGroups.length
        ? acceptedTypeGroups[filterIndex]
        : null;
    return file_selector.FileSaveLocation(
      response.paths.first,
      activeFilter: activeFilter,
    );
  }

  Future<_WindowsFileDialogResponse> _invoke(
    String method, {
    required List<file_selector.XTypeGroup> acceptedTypeGroups,
    String? initialDirectory,
    String? suggestedName,
    String? confirmButtonText,
  }) async {
    final filters = acceptedTypeGroups.map((group) {
      final extensions = group.extensions;
      if (!group.allowsAny && (extensions == null || extensions.isEmpty)) {
        throw ArgumentError(
          'Provided type group $group does not allow all files, but does not '
          'set the Windows-supported "extensions" filter.',
        );
      }
      return <String, Object?>{
        'label': group.label ?? '',
        'extensions': extensions ?? const <String>[],
      };
    }).toList();
    final raw = await _channel.invokeMethod<Object?>(method, <String, Object?>{
      'initialDirectory': initialDirectory,
      'suggestedName': suggestedName,
      'confirmButtonText': confirmButtonText,
      'filters': filters,
    });
    if (raw is! Map<Object?, Object?>) {
      throw PlatformException(
        code: 'invalid-native-response',
        message: 'Native file dialog response must be a map.',
      );
    }
    final rawPaths = raw['paths'];
    if (rawPaths is! List<Object?> || rawPaths.any((path) => path is! String)) {
      throw PlatformException(
        code: 'invalid-native-response',
        message: 'Native file dialog response paths must be strings.',
      );
    }
    final rawFilterIndex = raw['activeFilterIndex'];
    if (rawFilterIndex != null && rawFilterIndex is! int) {
      throw PlatformException(
        code: 'invalid-native-response',
        message: 'Native active filter index must be an integer.',
      );
    }
    return _WindowsFileDialogResponse(
      paths: rawPaths.cast<String>(),
      activeFilterIndex: rawFilterIndex as int?,
    );
  }
}

class _WindowsFileDialogResponse {
  const _WindowsFileDialogResponse({
    required this.paths,
    required this.activeFilterIndex,
  });

  final List<String> paths;
  final int? activeFilterIndex;
}
