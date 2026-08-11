import '../../settings/domain/video_generation_api_config.dart';
import '../domain/h3_prompt_style.dart';
import 'bundled_video_skill_library.dart';

class VideoSkillRoute {
  const VideoSkillRoute({
    required this.backendKind,
    required this.promptStyle,
    required this.automaticallySelected,
  });

  final BundledVideoSkillKind? backendKind;
  final H3PromptStyle promptStyle;
  final bool automaticallySelected;

  bool get supportsH3NarrativeSkill =>
      backendKind == BundledVideoSkillKind.minimaxH3;
}

/// 先以设置页选中的视频模型做硬门控，再从当前镜头剧情中至多选择一个专项 Skill。
///
/// 路由完全在本地执行，不增加视觉模型请求。手动选择的非通用风格是明确覆盖；
/// `general` 表示允许按当前剧情自动匹配，未达到阈值时保持通用 H3。
class VideoSkillRouter {
  const VideoSkillRouter();

  static const int _minimumAutomaticScore = 3;

  static const Map<String, Map<String, int>> _signalsByStyleId = {
    '3d-animation-short': {
      '3d动画': 5,
      '3d 动画': 5,
      '三维动画': 5,
      '皮克斯': 4,
      'c4d': 4,
      '卡通短片': 3,
      '风格化3d': 4,
      '风格化 3d': 4,
    },
    'brand-promo': {
      '品牌宣传': 6,
      '品牌片': 5,
      '宣传短片': 4,
      '行动号召': 4,
      '品牌故事': 4,
      '品牌功能': 3,
      'cta': 3,
    },
    'co-op-game-intro': {
      '双人合作游戏': 7,
      '合作游戏': 5,
      '双人主菜单': 6,
      'player 1': 4,
      'player 2': 4,
      '游戏开场': 4,
      '游戏主菜单': 4,
      'loading 100%': 3,
    },
    'handdrawn-live': {
      '手绘实拍': 7,
      '实拍手绘': 7,
      '手绘线条': 4,
      '发光笔触': 4,
      '蜡笔线条': 4,
      '粉笔线条': 4,
      '慢半拍追拍': 5,
    },
    'minimalist-product-ad': {
      '极简产品广告': 7,
      '极简产品': 5,
      '产品广告': 4,
      '产品展示': 3,
      'apple风': 4,
      'apple 风': 4,
      '高级产品片': 4,
      '材质特写': 3,
    },
    'music-video-subtitle': {
      '音乐mv': 7,
      '音乐 mv': 7,
      '歌词贴字': 6,
      '空间歌词': 6,
      '说唱mv': 6,
      '说唱 mv': 6,
      '音乐视频': 4,
      '歌词字幕': 4,
      '卡点字幕': 4,
    },
    'paper-collage-explainer': {
      '纸拼贴讲解': 7,
      '纸拼贴': 6,
      '半调拼贴': 5,
      '撕纸拼贴': 5,
      '拼贴动画': 4,
      '视觉隐喻': 3,
    },
    'papercraft-stop-motion': {
      '纸艺定格科普': 8,
      '纸艺定格': 7,
      '纸雕科普': 6,
      '分层纸雕': 5,
      '立体书': 4,
      '纸偶': 3,
      '纸机关': 4,
    },
  };

  VideoSkillRoute resolve({
    required VideoGenerationApiConfig? config,
    required String narrativeText,
    H3PromptStyle preferredStyle = H3PromptStyle.general,
  }) {
    final backendKind = BundledVideoSkillLibrary.kindForConfig(config);
    if (backendKind != BundledVideoSkillKind.minimaxH3) {
      return VideoSkillRoute(
        backendKind: backendKind,
        promptStyle: H3PromptStyle.general,
        automaticallySelected: false,
      );
    }
    if (!preferredStyle.isGeneral) {
      return VideoSkillRoute(
        backendKind: backendKind,
        promptStyle: preferredStyle,
        automaticallySelected: false,
      );
    }

    final normalized = narrativeText.toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    var bestStyle = H3PromptStyle.general;
    var bestScore = 0;
    for (final style in H3PromptStyle.values.where((item) => !item.isGeneral)) {
      final signals = _signalsByStyleId[style.id] ?? const <String, int>{};
      var score = 0;
      for (final entry in signals.entries) {
        if (normalized.contains(entry.key)) score += entry.value;
      }
      if (score > bestScore) {
        bestStyle = style;
        bestScore = score;
      }
    }
    final matched = bestScore >= _minimumAutomaticScore;
    return VideoSkillRoute(
      backendKind: backendKind,
      promptStyle: matched ? bestStyle : H3PromptStyle.general,
      automaticallySelected: matched,
    );
  }
}
