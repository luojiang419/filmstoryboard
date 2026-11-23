import '../../features/settings/domain/app_settings.dart';

/// App-wide MiniMax request gate. All visual-analysis pages share the same
/// sliding 60-second window so concurrent page operations cannot exceed the
/// active API card's quota together.
class VisionRequestRateLimiter {
  VisionRequestRateLimiter._();

  static const _window = Duration(minutes: 1);
  static final List<DateTime> _miniMaxRequestTimes = [];

  static bool usesMiniMax(AppSettings settings) {
    final model = settings.visionModel.trim().toLowerCase();
    final host =
        Uri.tryParse(settings.visionApiBaseUrl.trim())?.host.toLowerCase() ??
        '';
    return model == 'minimax-m3' && host.endsWith('minimaxi.com');
  }

  static int maxConcurrentRequestsFor(AppSettings settings) =>
      usesMiniMax(settings) ? settings.visionMaxRequestsPerMinute : 1;

  static Future<void> waitForRequestSlot(AppSettings settings) async {
    if (!usesMiniMax(settings)) return;
    final limit = settings.visionMaxRequestsPerMinute.clamp(1, 200);
    while (true) {
      final now = DateTime.now();
      _miniMaxRequestTimes.removeWhere(
        (time) => now.difference(time) >= _window,
      );
      if (_miniMaxRequestTimes.length < limit) {
        _miniMaxRequestTimes.add(now);
        return;
      }
      final nextAvailableAt = _miniMaxRequestTimes.first.add(_window);
      final delay = nextAvailableAt.difference(now);
      await Future<void>.delayed(
        delay.isNegative || delay == Duration.zero
            ? const Duration(milliseconds: 1)
            : delay,
      );
    }
  }

  /// Test-only reset hook. It is harmless in production and avoids retaining
  /// quota history between isolated test cases.
  static void resetForTesting() => _miniMaxRequestTimes.clear();
}
