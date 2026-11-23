import 'dart:io';

typedef ProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

class FileExplorerService {
  const FileExplorerService({this.startProcess = Process.start});

  final ProcessStarter startProcess;

  Future<bool> revealFile(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      return false;
    }
    await startProcess('explorer.exe', selectFileArguments(file.absolute.path));
    return true;
  }

  Future<bool> openDirectory(String path) async {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      return false;
    }
    await startProcess('explorer.exe', [directory.absolute.path]);
    return true;
  }

  static List<String> selectFileArguments(String absolutePath) {
    return ['/select,', absolutePath];
  }
}
