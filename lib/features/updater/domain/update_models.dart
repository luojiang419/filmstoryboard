class UpdateReleaseInfo {
  const UpdateReleaseInfo({
    required this.versionTag,
    required this.installerName,
    required this.installerUrl,
    required this.installerSize,
  });

  final String versionTag;
  final String installerName;
  final String installerUrl;
  final int installerSize;
}

class UpdaterInstallSession {
  const UpdaterInstallSession({
    required this.sessionId,
    required this.versionTag,
    required this.installerPath,
    required this.installRoot,
    required this.oldProcessId,
  });

  final String sessionId;
  final String versionTag;
  final String installerPath;
  final String installRoot;
  final int oldProcessId;
}

class UpdaterProgressEvent {
  const UpdaterProgressEvent({
    required this.stepIndex,
    required this.stepLabel,
    required this.message,
    this.substep = '',
    this.isError = false,
    this.isSuccess = false,
  });

  final int stepIndex;
  final String stepLabel;
  final String message;
  final String substep;
  final bool isError;
  final bool isSuccess;
}

class UpdaterState {
  const UpdaterState({
    required this.isBusy,
    required this.statusMessage,
    this.readyVersionTag,
    this.readyInstallerPath,
    this.downloadProgress,
    this.readyFromManualCheck = false,
  });

  const UpdaterState.initial()
    : isBusy = false,
      statusMessage = '',
      readyVersionTag = null,
      readyInstallerPath = null,
      downloadProgress = null,
      readyFromManualCheck = false;

  final bool isBusy;
  final String statusMessage;
  final String? readyVersionTag;
  final String? readyInstallerPath;
  final double? downloadProgress;
  final bool readyFromManualCheck;

  bool get hasReadyUpdate =>
      readyVersionTag != null && readyInstallerPath != null;

  UpdaterState copyWith({
    bool? isBusy,
    String? statusMessage,
    Object? readyVersionTag = _unchanged,
    Object? readyInstallerPath = _unchanged,
    Object? downloadProgress = _unchanged,
    bool? readyFromManualCheck,
  }) {
    return UpdaterState(
      isBusy: isBusy ?? this.isBusy,
      statusMessage: statusMessage ?? this.statusMessage,
      readyVersionTag: identical(readyVersionTag, _unchanged)
          ? this.readyVersionTag
          : readyVersionTag as String?,
      readyInstallerPath: identical(readyInstallerPath, _unchanged)
          ? this.readyInstallerPath
          : readyInstallerPath as String?,
      downloadProgress: identical(downloadProgress, _unchanged)
          ? this.downloadProgress
          : _downloadProgressValue(downloadProgress),
      readyFromManualCheck: readyFromManualCheck ?? this.readyFromManualCheck,
    );
  }
}

const _unchanged = Object();

double? _downloadProgressValue(Object? value) {
  if (value == null) {
    return null;
  }
  return (value as num).toDouble();
}
