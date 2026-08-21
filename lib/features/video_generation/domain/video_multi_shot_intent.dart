import '../../shooting_script/domain/shooting_script_models.dart';

/// Detects whether one generated video is intentionally composed of multiple
/// edited shots rather than multiple stage frames inside one continuous shot.
class VideoMultiShotIntent {
  const VideoMultiShotIntent._();

  static bool fromSequence(
    List<ScriptShot> sequence, {
    String sourcePrompt = '',
  }) {
    final text = [
      sourcePrompt,
      for (final shot in sequence) ...[
        shot.freeCreationDescription,
        shot.content,
        shot.cameraMovement,
        shot.transitionHint,
        shot.cameraNotes,
      ],
    ].where((part) => part.trim().isNotEmpty).join('\n');
    return fromText(text);
  }

  static bool fromText(String value) {
    final text = _withoutNegatedDirectives(value.trim());
    if (text.isEmpty) return false;
    if (RegExp(
      r'(?:多镜头|双镜头|两(?:个)?镜头|[三四五六七八九十](?:个)?镜头|智能分镜)',
    ).hasMatch(text)) {
      return true;
    }
    if (RegExp(r'(?:硬切|跳切|匹配切|动作匹配切|切到|切至|切回|镜头切换|转场到|转场至)').hasMatch(text)) {
      return true;
    }
    if (RegExp(
      r'\[\s*Shot\s*[2-9]\d*\s*\]',
      caseSensitive: false,
    ).hasMatch(text)) {
      return true;
    }
    final numberedShots =
        RegExp(r'(?:^|[\n；;。])\s*镜头\s*([1-9]\d*)\s*(?:[-—:：])', multiLine: true)
            .allMatches(text)
            .map((match) => match.group(1))
            .whereType<String>()
            .toSet();
    return numberedShots.length >= 2;
  }

  static String _withoutNegatedDirectives(String text) => text.replaceAll(
    RegExp(
      r'(?:不要|不得|禁止|不应|无需|无须|不能|避免).{0,16}'
      r'(?:切镜|切换镜头|转场|硬切|跳切|多镜头|第二个镜头)',
    ),
    '',
  );
}
