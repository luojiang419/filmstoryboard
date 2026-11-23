import 'dart:convert';

import 'package:filmstoryboard/features/storyboard/data/vision_caption_coherence_service.dart';
import 'package:test/test.dart';

void main() {
  test('截断于最后一条时保留完整条目并只补全缺失编号', () async {
    var requestCount = 0;
    final service = VisionCaptionCoherenceService(
      request: ({required prompt, required maxTokens}) async {
        requestCount++;
        if (requestCount == 1) {
          final completeItems = [
            for (var index = 1; index <= 11; index++)
              jsonEncode({'sequenceNo': index, 'text': '连贯文本$index'}),
          ].join(',');
          return VisionChatCompletion(
            content:
                '{"storyContext":"统一故事","captions":[$completeItems,'
                '{"sequenceNo":12,"text":"输出在这里被截断',
            finishReason: 'length',
            promptTokens: 1800,
            completionTokens: 1500,
            totalTokens: 3300,
          );
        }
        return VisionChatCompletion(
          content: jsonEncode({
            'captions': [
              {'sequenceNo': 12, 'text': '最后画面自然收束'},
            ],
          }),
          finishReason: 'stop',
        );
      },
    );

    final result = await service.rewrite(sources: _sources(12));

    expect(result.captions, hasLength(12));
    expect(result.initialReturnedCount, 11);
    expect(result.repairedSequenceNos, [12]);
    expect(result.localFallbackSequenceNos, isEmpty);
    expect(result.captions.first, '连贯文本1。');
    expect(result.captions.last, '最后画面自然收束。');
    expect(requestCount, 2);
    expect(result.diagnostics['finishReasons'], contains('length'));
  });

  test('84 张画板先分段规划再按 12 张分块改写', () async {
    var requestCount = 0;
    final captionMaxTokens = <int>[];
    final progress = <String>[];
    final service = VisionCaptionCoherenceService(
      request: ({required prompt, required maxTokens}) async {
        requestCount++;
        if (prompt.startsWith('请理解以下连续镜头')) {
          return const VisionChatCompletion(
            content: '{"storyContext":"分段故事脉络"}',
            finishReason: 'stop',
          );
        }
        if (prompt.startsWith('请把以下分段故事脉络')) {
          return const VisionChatCompletion(
            content: '{"storyContext":"贯穿全部八十四个镜头的统一故事脉络"}',
            finishReason: 'stop',
          );
        }
        final match = RegExp(r'只允许返回编号：([0-9, ]+)').firstMatch(prompt);
        expect(match, isNotNull);
        final ids = match!
            .group(1)!
            .split(',')
            .map((value) => int.parse(value.trim()))
            .toList();
        captionMaxTokens.add(maxTokens);
        return VisionChatCompletion(
          content: jsonEncode({
            'captions': [
              for (final id in ids) {'sequenceNo': id, 'text': '连贯镜头$id'},
            ],
          }),
          finishReason: 'stop',
          promptTokens: 600,
          completionTokens: 500,
          totalTokens: 1100,
        );
      },
    );

    final result = await service.rewrite(
      sources: _sources(84),
      onProgress: (completed, total) => progress.add('$completed/$total'),
    );

    expect(result.captions, hasLength(84));
    expect(result.captions.every((caption) => caption.isNotEmpty), isTrue);
    expect(result.localFallbackSequenceNos, isEmpty);
    expect(result.diagnostics['chunkCount'], 7);
    expect(captionMaxTokens, hasLength(7));
    expect(captionMaxTokens.every((tokens) => tokens <= 1500), isTrue);
    expect(progress.last, '7/7');
    expect(requestCount, 12);
  });

  test('模型持续断连时返回本地连贯文本且不抛出异常', () async {
    var requestCount = 0;
    final sources = _sources(5);
    final service = VisionCaptionCoherenceService(
      request: ({required prompt, required maxTokens}) async {
        requestCount++;
        throw Exception('Connection closed before full header was received');
      },
    );

    final result = await service.rewrite(sources: sources);

    expect(result.captions, hasLength(5));
    expect(result.captions.every((caption) => caption.isNotEmpty), isTrue);
    expect(result.localFallbackSequenceNos, [1, 2, 3, 4, 5]);
    expect(result.captions.first, isNot(sources.first.caption));
    expect(result.captions.first, startsWith('开场，'));
    expect(result.captions.last, startsWith('最后，'));
    expect(requestCount, 6);
  });

  test('429 限流会自动退避重试并保留完整连贯结果', () async {
    var requestCount = 0;
    final service = VisionCaptionCoherenceService(
      request: ({required prompt, required maxTokens}) async {
        requestCount++;
        if (requestCount == 1) {
          throw Exception('视觉模型请求失败：429 rate limited');
        }
        return VisionChatCompletion(
          content: jsonEncode({
            'captions': [
              {'sequenceNo': 1, 'text': '开场建立环境'},
              {'sequenceNo': 2, 'text': '随后动作继续推进'},
            ],
          }),
          finishReason: 'stop',
        );
      },
    );

    final result = await service.rewrite(sources: _sources(2));

    expect(requestCount, 2);
    expect(result.localFallbackSequenceNos, isEmpty);
    expect(result.captions, ['开场建立环境。', '随后动作继续推进。']);
  });
}

List<VisionCaptionSource> _sources(int count) {
  return [
    for (var index = 1; index <= count; index++)
      VisionCaptionSource(
        sequenceNo: index,
        caption: '女模特完成动作$index',
        scene: '场景${(index - 1) ~/ 6 + 1}',
        bodyAction: '动作$index',
        actionStage: index == count ? '收束' : '进行',
        visualFocus: '人物动作',
        lightingMood: '暖色光线',
        narrativeFunction: index == 1 ? '建立' : '推进',
        transitionHint: '承接相邻镜头',
      ),
  ];
}
