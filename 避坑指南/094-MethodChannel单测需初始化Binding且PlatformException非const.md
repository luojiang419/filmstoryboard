# 094 - MethodChannel 单测需初始化 Binding，且 PlatformException 非 const

## 适用环境

- Flutter SDK：`D:\flutter`
- 场景：在原有纯 Dart `flutter_test` 文件中新增 `MethodChannel` mock，并编写原生响应校验异常。

## 问题一：PlatformException 不能 const 构造

错误写法：

```dart
throw const PlatformException(
  code: 'invalid-native-response',
  message: 'Native response is invalid.',
);
```

编译错误：

```text
Cannot invoke a non-'const' constructor where a const expression is expected.
```

解决方式：

```dart
throw PlatformException(
  code: 'invalid-native-response',
  message: 'Native response is invalid.',
);
```

不要根据其他异常类型的习惯推断 `PlatformException` 一定有 `const` 构造；以当前 SDK 声明和编译结果为准。

## 问题二：纯 Dart 测试首次使用 mock MethodChannel 前必须初始化 Binding

症状：

```text
Binding has not yet been initialized.
TestDefaultBinaryMessengerBinding.instance ... is only available once that binding has been initialized.
```

原因：测试文件原先只测试普通 Future、文件系统和服务逻辑，没有 widget 测试调用，因此 Flutter 测试 Binding 从未创建。新增 `TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger` 后，必须先初始化。

解决方式：

```dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // tests...
}
```

`ensureInitialized()` 可重复调用；应放在 `main()` 开头，不要在每个 test 内各自初始化。

## 问题三：架构守卫测试需要允许统一服务的后端适配器

项目有正则扫描，禁止业务源码直接调用 `openFile/openFiles/getSaveLocation`。新增 `windows_sta_file_dialog_client.dart` 后，它作为 `DesktopFileDialogService` 的内部后端必然实现这些方法，不能被误判为业务绕过。

解决原则：只豁免明确的核心服务本体和核心后端适配器，不扩大到 feature/business 目录；业务层仍必须统一经过 `DesktopFileDialogService`。

## 验证

```powershell
& 'D:\flutter\bin\flutter.bat' test test\core\desktop_file_dialog_service_test.dart
```

结果：9 项测试全部通过。

## 发布版本同步补充

版本递增不能只修改 `pubspec.yaml` 和安装器脚本。项目的 `AppUpdateConfig.currentVersion/currentVersionTag` 也是运行时更新器使用的独立常量，遗漏后 `test/features/updater_service_test.dart` 会报告安装器期望版本与实际版本不一致。

本项目版本递增至少同步检查：

1. `pubspec.yaml`：`1.0.0+<build>`。
2. `installer/filmstoryboard.iss`：`1.0.0.<build>`。
3. `lib/features/updater/domain/app_update_config.dart`：`currentVersion` 与 `currentVersionTag`。

用版本一致性测试收口，不要靠人工比对：

```powershell
& 'D:\flutter\bin\flutter.bat' test test\features\updater_service_test.dart
```
