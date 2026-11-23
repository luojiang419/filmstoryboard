# Dart 测试新增领域类型需显式导入

新增 `List<ShootingAssetLibraryItem>` 测试变量时曾因缺少模型文件 import 编译失败。Dart import 不传递；直接使用领域类型时必须显式导入 `shooting_asset_library_models.dart`。补齐后相关测试通过。
