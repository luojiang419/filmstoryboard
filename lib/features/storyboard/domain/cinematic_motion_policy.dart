class CinematicMotionPolicy {
  const CinematicMotionPolicy._();

  static bool hasExplicitSlowMotionIntent(String value) {
    final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return false;
    for (final clause in normalized.split(RegExp(r'[，,。；;！!？?\n]+'))) {
      if (_isNegatedSlowMotionClause(clause)) continue;
      if (_slowMotionPatterns.any((pattern) => pattern.hasMatch(clause))) {
        return true;
      }
    }
    return false;
  }

  static bool containsUnauthorizedSlowMotion(String value) =>
      hasExplicitSlowMotionIntent(value);

  static String enforceRealtimePlayback(String value) {
    if (!containsUnauthorizedSlowMotion(value)) return value;
    return value
        .replaceAll(_slowMotionPhrase, '正常时间速度')
        .replaceAll(_highFrameRatePlaybackPhrase, '正常时间速度播放')
        .replaceAll(_englishSlowMotionPhrase, 'real-time playback')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static bool _isNegatedSlowMotionClause(String clause) => RegExp(
    r'(?:(?:不要|不得|禁止|避免|不应|无需|无须|不能|取消|去掉|移除|杜绝).{0,16}(?:慢动作|慢镜头|慢放|升格|高帧率慢放|高速摄影|slow[ -]?(?:motion|mo)|speed[ -]?ramp)|\b(?:no|without|avoid|disable|remove|do not)\b.{0,24}\b(?:slow[ -]?(?:motion|mo)|speed[ -]?ramp))',
    caseSensitive: false,
  ).hasMatch(clause);

  static final List<RegExp> _slowMotionPatterns = [
    RegExp(r'(?:慢动作|慢镜头|慢放|升格|高帧率慢放|高速摄影)'),
    RegExp(r'\bslow[ -]?(?:motion|mo)\b', caseSensitive: false),
    RegExp(r'\bspeed[ -]?ramp(?:ing)?\b', caseSensitive: false),
    RegExp(
      r'\b(?:48|50|60|100|120|240|480|960)\s*fps\b.{0,12}(?:慢放|回放|playback)',
      caseSensitive: false,
    ),
  ];

  static final RegExp _slowMotionPhrase = RegExp(
    r'(?:慢动作|慢镜头|慢放|升格|高帧率慢放|高速摄影)',
  );
  static final RegExp _highFrameRatePlaybackPhrase = RegExp(
    r'(?:48|50|60|100|120|240|480|960)\s*fps.{0,12}(?:慢放|回放)',
    caseSensitive: false,
  );
  static final RegExp _englishSlowMotionPhrase = RegExp(
    r'\b(?:slow[ -]?(?:motion|mo)|speed[ -]?ramp(?:ing)?)\b',
    caseSensitive: false,
  );
}
