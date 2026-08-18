# Dart 空安全 Map 元素与三引号首行行为

日期：2026-08-17

## 问题 1：null-aware Map entry 位置写反

错误形式：

```dart
?'key': nullableValue,
```

当 key 是固定非空字符串时，分析器会提示 `invalid_null_aware_operator`，因为这里检查的是 key。

正确形式：

```dart
'key': ?nullableValue,
```

含义是 value 为 null 时省略整个 Map entry。若当前 SDK 或项目语言版本不支持该语法，则使用传统条件元素：

```dart
if (nullableValue != null) 'key': nullableValue,
```

## 问题 2：三引号字符串没有预期的前导换行

当源码写成：

```dart
'''内容第一行
后续内容'''
```

运行时字符串从“内容第一行”直接开始，不包含前导 `\n`。只有把第一行内容放到下一源码行时才会产生前导换行。

测试应断言实际 API 字符串契约，例如：

```dart
expect(prompt, startsWith('只修正以下一个问题'));
```

不要根据三引号的视觉排版臆测首字符。

## 后续规避

- 修改 nullable collection element 后先运行定向 `flutter analyze`。
- 对精确提示词前后缀使用 `startsWith`/`endsWith` 时，先确认真实首尾字符。
- 业务上不需要前导空行时，让提示词正文紧跟三引号开头，避免把无意义空白发送给 API。
