import 'replicate_asset_preparation_models.dart';

class FullOutfitViewPolicy {
  const FullOutfitViewPolicy._();

  static ReplicateOutfitViewRole? inferRole(String subjectDirection) {
    final text = subjectDirection.trim().toLowerCase();
    if (text.isEmpty) return null;
    if (_containsAny(text, const ['背面', '背对', '后背', '背向'])) {
      return ReplicateOutfitViewRole.back;
    }
    if (_containsAny(text, const [
      '侧面',
      '侧身',
      '朝左',
      '朝右',
      '向左',
      '向右',
      '左侧',
      '右侧',
      '三分之二',
      '3/4',
      'profile',
      'side',
    ])) {
      return ReplicateOutfitViewRole.side;
    }
    if (_containsAny(text, const ['正面', '正对', '面向镜头', '面对镜头', 'front'])) {
      return ReplicateOutfitViewRole.front;
    }
    if (_containsAny(text, const ['背', '后方'])) {
      return ReplicateOutfitViewRole.back;
    }
    return null;
  }

  static String selectPrimaryViewId({
    required List<ReplicateFullOutfitView> views,
    required String subjectDirection,
  }) {
    final role = inferRole(subjectDirection);
    if (role == null) return '';
    for (final view in views) {
      if (view.role == role) return view.id;
    }
    return '';
  }

  static bool _containsAny(String source, List<String> needles) =>
      needles.any(source.contains);
}
