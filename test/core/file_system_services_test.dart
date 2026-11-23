import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:filmstoryboard/core/services/empty_directory_cleaner.dart';
import 'package:filmstoryboard/core/services/file_explorer_service.dart';
import 'package:test/test.dart';

void main() {
  test('资源管理器选中文件参数会拆分 select 标记和路径', () {
    final args = FileExplorerService.selectFileArguments(r'D:\demo\中文 文件.png');

    expect(args, [r'/select,', r'D:\demo\中文 文件.png']);
  });

  test('空目录清理只删除根目录下的空子目录', () async {
    final root = await Directory.systemTemp.createTemp(
      'empty_directory_cleaner_',
    );
    addTearDown(() => root.delete(recursive: true));

    final emptyParent = Directory(p.join(root.path, 'empty-parent'));
    final emptyChild = Directory(p.join(emptyParent.path, 'empty-child'));
    await emptyChild.create(recursive: true);

    final nonEmpty = Directory(p.join(root.path, 'non-empty'));
    await nonEmpty.create();
    await File(p.join(nonEmpty.path, 'image.png')).writeAsBytes([1, 2, 3]);

    final deleted = const EmptyDirectoryCleaner().cleanChildren(root);

    expect(deleted, 2);
    expect(root.existsSync(), isTrue);
    expect(emptyParent.existsSync(), isFalse);
    expect(emptyChild.existsSync(), isFalse);
    expect(nonEmpty.existsSync(), isTrue);
  });
}
