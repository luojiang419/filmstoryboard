import '../../../core/database/app_database.dart';
import '../domain/remote_access_config.dart';

class RemoteAccessRepository {
  const RemoteAccessRepository(this._database);

  static const settingKey = 'remoteAccessConfigV1';

  final AppDatabase _database;

  RemoteAccessConfig load() {
    final source = _database.getSetting(settingKey);
    if (source == null || source.trim().isEmpty) {
      return RemoteAccessConfig();
    }
    try {
      return RemoteAccessConfig.decode(source);
    } on FormatException {
      // 损坏或被手工修改的配置必须回到“关闭 + 仅回环地址”的安全默认值。
      return RemoteAccessConfig();
    }
  }

  void save(RemoteAccessConfig config) {
    _database.setSetting(settingKey, config.validated().encode());
  }
}
