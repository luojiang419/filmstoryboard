import 'dart:io';

import 'package:path/path.dart' as p;

class DefaultExportDirectories {
  const DefaultExportDirectories(String rootPath) : _rootPath = rootPath;

  final String _rootPath;

  Directory get storyboards => _directory('故事板');
  Directory get boardImages => _directory('画板图片');
  Directory get shootingScripts => _directory('拍摄脚本');
  Directory get timelines => _directory('时间线');
  Directory get analysisReports => _directory('多维度报告');

  Directory _directory(String name) => Directory(p.join(_rootPath, name));
}
