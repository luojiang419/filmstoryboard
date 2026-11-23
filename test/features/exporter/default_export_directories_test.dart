import 'dart:io';

import 'package:filmstoryboard/features/exporter/data/default_export_directories.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('默认导出路径按导出类型分类', () {
    final root = p.join('D:', 'exports');
    final directories = DefaultExportDirectories(root);

    expect(directories.storyboards.path, p.join(root, '故事板'));
    expect(directories.boardImages.path, p.join(root, '画板图片'));
    expect(directories.shootingScripts.path, p.join(root, '拍摄脚本'));
    expect(directories.timelines.path, p.join(root, '时间线'));
    expect(directories.analysisReports.path, p.join(root, '多维度报告'));
  });

  test('分类路径仅描述目录，不会提前创建无用文件夹', () async {
    final root = await Directory.systemTemp.createTemp('export_categories_');
    addTearDown(() => root.delete(recursive: true));

    final directory = DefaultExportDirectories(root.path).boardImages;

    expect(directory.existsSync(), isFalse);
    expect(p.dirname(directory.path), root.path);
  });
}
