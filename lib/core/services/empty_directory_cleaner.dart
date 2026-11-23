import 'dart:io';

class EmptyDirectoryCleaner {
  const EmptyDirectoryCleaner();

  int cleanChildren(Directory root) {
    if (!root.existsSync()) {
      return 0;
    }
    var deleted = 0;
    for (final entity in root.listSync(followLinks: false)) {
      if (entity is Directory) {
        deleted += _cleanDirectory(entity);
      }
    }
    return deleted;
  }

  int _cleanDirectory(Directory directory) {
    var deleted = 0;
    var hasRemainingContent = false;
    List<FileSystemEntity> entities;
    try {
      entities = directory.listSync(followLinks: false);
    } on FileSystemException {
      return 0;
    }

    for (final entity in entities) {
      if (entity is Directory) {
        deleted += _cleanDirectory(entity);
        if (entity.existsSync()) {
          hasRemainingContent = true;
        }
      } else {
        hasRemainingContent = true;
      }
    }

    if (hasRemainingContent) {
      return deleted;
    }

    try {
      directory.deleteSync();
      return deleted + 1;
    } on FileSystemException {
      return deleted;
    }
  }
}
