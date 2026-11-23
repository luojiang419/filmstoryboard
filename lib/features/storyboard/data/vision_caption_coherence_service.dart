import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

class VisionCaptionSource {
  const VisionCaptionSource({
    required this.sequenceNo,
    required this.caption,
    required this.scene,
    required this.bodyAction,
    required this.actionStage,
    required this.visualFocus,
    required this.lightingMood,
    required this.narrativeFunction,
    required this.transitionHint,
  });

  final int sequenceNo;
  final String caption;
  final String scene;
  final String bodyAction;
  final String actionStage;
  final String visualFocus;
  final String lightingMood;
  final String narrativeFunction;
  final String transitionHint;
}

class VisionChatCompletion {
  const VisionChatCompletion({
    required this.content,
    this.finishReason = '',
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
  });

  final String content;
  final String finishReason;
  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;
}

typedef VisionCaptionCompletionRequest =
    Future<VisionChatCompletion> Function({
      required String prompt,
      required int maxTokens,
    });

class VisionCaptionCoherenceResult {
  const VisionCaptionCoherenceResult({
    required this.captions,
    required this.storyContext,
    required this.rawResponse,
    required this.initialReturnedCount,
    required this.repairedSequenceNos,
    required this.localFallbackSequenceNos,
    required this.diagnostics,
  });

  final List<String> captions;
  final String storyContext;
  final String rawResponse;
  final int initialReturnedCount;
  final List<int> repairedSequenceNos;
  final List<int> localFallbackSequenceNos;
  final Map<String, Object?> diagnostics;
}

class VisionCaptionCoherenceService {
  const VisionCaptionCoherenceService({
    required this.request,
    this.shouldRethrow,
  });

  static const chunkSize = 12;
  static const contextSegmentSize = 24;
  static const repairChunkSize = 4;

  final VisionCaptionCompletionRequest request;
  final bool Function(Object error)? shouldRethrow;

  Future<VisionCaptionCoherenceResult> rewrite({
    required List<VisionCaptionSource> sources,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (sources.isEmpty) {
      return const VisionCaptionCoherenceResult(
        captions: [],
        storyContext: '',
        rawResponse: '',
        initialReturnedCount: 0,
        repairedSequenceNos: [],
        localFallbackSequenceNos: [],
        diagnostics: {'chunkCount': 0},
      );
    }

    final ordered = [...sources]
      ..sort((left, right) => left.sequenceNo.compareTo(right.sequenceNo));
    final rawResponses = <String>[];
    final requestDiagnostics = <Map<String, Object?>>[];
    final storyContext = await _buildStoryContext(
      ordered,
      rawResponses: rawResponses,
      diagnostics: requestDiagnostics,
    );
    final captionsBySequence = <int, String>{};
    final repairedSequenceNos = <int>[];
    final localFallbackSequenceNos = <int>[];
    var initialReturnedCount = 0;
    var consecutiveRequestFailures = 0;
    final chunks = _chunks(ordered, chunkSize);

    for (var chunkIndex = 0; chunkIndex < chunks.length; chunkIndex++) {
      final chunk = chunks[chunkIndex];
      final previousCaptions = captionsBySequence.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key));
      final nextSources = chunkIndex + 1 < chunks.length
          ? chunks[chunkIndex + 1].take(2).toList()
          : const <VisionCaptionSource>[];
      _CaptionRequestResult initial;
      if (consecutiveRequestFailures >= 2) {
        initial = const _CaptionRequestResult.failed();
      } else {
        initial = await _requestCaptionItems(
          prompt: _captionChunkPrompt(
            chunk: chunk,
            storyContext: storyContext,
            previousCaptions: previousCaptions
                .skip(math.max(0, previousCaptions.length - 2))
                .toList(),
            nextSources: nextSources,
          ),
          maxTokens: math.max(1200, chunk.length * 125),
          validSequenceNos: chunk.map((item) => item.sequenceNo).toSet(),
          phase: 'caption_chunk',
          diagnostics: requestDiagnostics,
        );
      }
      if (initial.rawResponse.isNotEmpty) {
        rawResponses.add(initial.rawResponse);
      }
      if (initial.requestFailed) {
        consecutiveRequestFailures++;
      } else {
        consecutiveRequestFailures = 0;
      }
      captionsBySequence.addAll(initial.captionsBySequence);
      initialReturnedCount += initial.captionsBySequence.length;

      var missing = _missingForChunk(chunk, captionsBySequence);
      if (missing.isNotEmpty && consecutiveRequestFailures < 2) {
        for (final repairGroup in _chunks(missing, repairChunkSize)) {
          final repaired = await _requestCaptionItems(
            prompt: _captionRepairPrompt(
              sources: ordered,
              missingSequenceNos: repairGroup,
              storyContext: storyContext,
              existingCaptions: captionsBySequence,
            ),
            maxTokens: math.max(700, repairGroup.length * 180),
            validSequenceNos: repairGroup.toSet(),
            phase: 'caption_repair',
            diagnostics: requestDiagnostics,
          );
          if (repaired.rawResponse.isNotEmpty) {
            rawResponses.add(repaired.rawResponse);
          }
          if (repaired.requestFailed) {
            consecutiveRequestFailures++;
          } else {
            consecutiveRequestFailures = 0;
          }
          for (final entry in repaired.captionsBySequence.entries) {
            if (!captionsBySequence.containsKey(entry.key)) {
              captionsBySequence[entry.key] = entry.value;
              repairedSequenceNos.add(entry.key);
            }
          }
          if (consecutiveRequestFailures >= 2) {
            break;
          }
        }
      }

      missing = _missingForChunk(chunk, captionsBySequence);
      if (missing.isNotEmpty && consecutiveRequestFailures < 2) {
        for (final sequenceNo in missing) {
          final repaired = await _requestCaptionItems(
            prompt: _captionRepairPrompt(
              sources: ordered,
              missingSequenceNos: [sequenceNo],
              storyContext: storyContext,
              existingCaptions: captionsBySequence,
            ),
            maxTokens: 700,
            validSequenceNos: {sequenceNo},
            phase: 'caption_single_repair',
            diagnostics: requestDiagnostics,
          );
          if (repaired.rawResponse.isNotEmpty) {
            rawResponses.add(repaired.rawResponse);
          }
          final caption = repaired.captionsBySequence[sequenceNo];
          if (caption != null && !captionsBySequence.containsKey(sequenceNo)) {
            captionsBySequence[sequenceNo] = caption;
            repairedSequenceNos.add(sequenceNo);
            consecutiveRequestFailures = 0;
          } else if (repaired.requestFailed) {
            consecutiveRequestFailures++;
          }
          if (consecutiveRequestFailures >= 2) {
            break;
          }
        }
      }
      onProgress?.call(chunkIndex + 1, chunks.length);
    }

    for (var index = 0; index < ordered.length; index++) {
      final source = ordered[index];
      if (captionsBySequence.containsKey(source.sequenceNo)) {
        continue;
      }
      final previousSource = index == 0 ? null : ordered[index - 1];
      final previousCaption = captionsBySequence[previousSource?.sequenceNo];
      captionsBySequence[source.sequenceNo] = _localCoherentCaption(
        source: source,
        previousSource: previousSource,
        previousCaption: previousCaption,
        isLast: index == ordered.length - 1,
      );
      localFallbackSequenceNos.add(source.sequenceNo);
    }

    final finishReasons = <String>[];
    var promptTokens = 0;
    var completionTokens = 0;
    var totalTokens = 0;
    for (final diagnostic in requestDiagnostics) {
      final finishReason = diagnostic['finishReason']?.toString() ?? '';
      if (finishReason.isNotEmpty) finishReasons.add(finishReason);
      promptTokens += (diagnostic['promptTokens'] as int?) ?? 0;
      completionTokens += (diagnostic['completionTokens'] as int?) ?? 0;
      totalTokens += (diagnostic['totalTokens'] as int?) ?? 0;
    }
    repairedSequenceNos.sort();
    localFallbackSequenceNos.sort();
    return VisionCaptionCoherenceResult(
      captions: [
        for (final source in ordered) captionsBySequence[source.sequenceNo]!,
      ],
      storyContext: storyContext,
      rawResponse: rawResponses.join('\n\n[下一阶段响应]\n'),
      initialReturnedCount: initialReturnedCount,
      repairedSequenceNos: repairedSequenceNos,
      localFallbackSequenceNos: localFallbackSequenceNos,
      diagnostics: {
        'chunkCount': chunks.length,
        'storyContextLength': storyContext.length,
        'requestCount': requestDiagnostics.length,
        'finishReasons': finishReasons,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'totalTokens': totalTokens,
        'repairedSequenceNos': repairedSequenceNos,
        'localFallbackSequenceNos': localFallbackSequenceNos,
        'requests': requestDiagnostics,
      },
    );
  }

  Future<String> _buildStoryContext(
    List<VisionCaptionSource> sources, {
    required List<String> rawResponses,
    required List<Map<String, Object?>> diagnostics,
  }) async {
    final localFallback = _localStoryContext(sources);
    if (sources.length <= chunkSize) {
      return localFallback;
    }
    final segmentContexts = <String>[];
    for (final segment in _chunks(sources, contextSegmentSize)) {
      final result = await _requestContext(
        _storyContextPrompt(segment),
        phase: 'story_context_segment',
        diagnostics: diagnostics,
      );
      if (result.rawResponse.isNotEmpty) rawResponses.add(result.rawResponse);
      segmentContexts.add(
        result.storyContext.isEmpty
            ? _localStoryContext(segment)
            : result.storyContext,
      );
    }
    if (segmentContexts.length == 1) {
      return segmentContexts.single;
    }
    final synthesis = await _requestContext(
      _storyContextSynthesisPrompt(segmentContexts),
      phase: 'story_context_synthesis',
      diagnostics: diagnostics,
    );
    if (synthesis.rawResponse.isNotEmpty) {
      rawResponses.add(synthesis.rawResponse);
    }
    return synthesis.storyContext.isEmpty
        ? segmentContexts.join('；')
        : synthesis.storyContext;
  }

  Future<_ContextRequestResult> _requestContext(
    String prompt, {
    required String phase,
    required List<Map<String, Object?>> diagnostics,
  }) async {
    try {
      final completion = await _requestWithRetry(
        prompt: prompt,
        maxTokens: 900,
      );
      diagnostics.add(_diagnosticFor(phase, prompt, 900, completion));
      final context = _storyContextFromContent(completion.content);
      return _ContextRequestResult(
        storyContext: context,
        rawResponse: completion.content,
      );
    } catch (error) {
      if (_shouldRethrow(error)) rethrow;
      diagnostics.add({
        'phase': phase,
        'promptCharacters': prompt.length,
        'error': _compactError(error),
      });
      return const _ContextRequestResult(storyContext: '', rawResponse: '');
    }
  }

  Future<_CaptionRequestResult> _requestCaptionItems({
    required String prompt,
    required int maxTokens,
    required Set<int> validSequenceNos,
    required String phase,
    required List<Map<String, Object?>> diagnostics,
  }) async {
    try {
      final completion = await _requestWithRetry(
        prompt: prompt,
        maxTokens: maxTokens,
      );
      final parsed = _captionsFromContent(
        completion.content,
        validSequenceNos: validSequenceNos,
      );
      diagnostics.add({
        ..._diagnosticFor(phase, prompt, maxTokens, completion),
        'validSequenceNos': validSequenceNos.toList()..sort(),
        'parsedCount': parsed.captionsBySequence.length,
        'truncatedOrIncomplete':
            completion.finishReason == 'length' || !parsed.completeJson,
      });
      return _CaptionRequestResult(
        captionsBySequence: parsed.captionsBySequence,
        rawResponse: completion.content,
        requestFailed: false,
      );
    } catch (error) {
      if (_shouldRethrow(error)) rethrow;
      diagnostics.add({
        'phase': phase,
        'promptCharacters': prompt.length,
        'maxTokens': maxTokens,
        'validSequenceNos': validSequenceNos.toList()..sort(),
        'error': _compactError(error),
      });
      return const _CaptionRequestResult.failed();
    }
  }

  Future<VisionChatCompletion> _requestWithRetry({
    required String prompt,
    required int maxTokens,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        return await request(prompt: prompt, maxTokens: maxTokens);
      } catch (error) {
        if (_shouldRethrow(error)) rethrow;
        lastError = error;
        if (!_isRetryable(error) || attempt == 2) break;
        await Future<void>.delayed(
          Duration(milliseconds: attempt == 0 ? 150 : 350),
        );
      }
    }
    throw lastError!;
  }

  bool _shouldRethrow(Object error) => shouldRethrow?.call(error) ?? false;

  bool _isRetryable(Object error) {
    final text = error.toString().toLowerCase();
    if (RegExp(r'[:：\s](401|403)\b').hasMatch(text)) {
      return false;
    }
    return text.contains('timeout') ||
        text.contains('timed out') ||
        text.contains('connection') ||
        text.contains('socket') ||
        RegExp(r'[:：\s](408|429|500|502|503|504)\b').hasMatch(text);
  }

  Map<String, Object?> _diagnosticFor(
    String phase,
    String prompt,
    int maxTokens,
    VisionChatCompletion completion,
  ) {
    return {
      'phase': phase,
      'promptCharacters': prompt.length,
      'maxTokens': maxTokens,
      'finishReason': completion.finishReason,
      if (completion.promptTokens != null)
        'promptTokens': completion.promptTokens,
      if (completion.completionTokens != null)
        'completionTokens': completion.completionTokens,
      if (completion.totalTokens != null) 'totalTokens': completion.totalTokens,
    };
  }

  String _storyContextPrompt(List<VisionCaptionSource> sources) {
    return '请理解以下连续镜头并归纳统一故事脉络。只返回 JSON：'
        '{"storyContext":"不超过180字的故事脉络"}。不要逐图复述。\n'
        '${_compactSources(sources)}';
  }

  String _storyContextSynthesisPrompt(List<String> contexts) {
    return '请把以下分段故事脉络合成一个统一、连续且不编造画外情节的故事脉络。'
        '只返回 JSON：{"storyContext":"不超过220字的故事脉络"}。\n'
        '${contexts.indexed.map((item) => '${item.$1 + 1}. ${item.$2}').join('\n')}';
  }

  String _captionChunkPrompt({
    required List<VisionCaptionSource> chunk,
    required String storyContext,
    required List<MapEntry<int, String>> previousCaptions,
    required List<VisionCaptionSource> nextSources,
  }) {
    final expected = chunk.map((item) => item.sequenceNo).join(', ');
    final buffer = StringBuffer()
      ..writeln('请把以下逐图视觉解析结果改写成连贯的故事板宫格文本。')
      ..writeln('只返回一个 JSON 对象，不要使用 Markdown，不要添加解释。')
      ..writeln('返回 captions 数组，数量必须与输入图片数量完全一致（仅指本批）。')
      ..writeln('必须保留 sequenceNo，只允许返回编号：$expected。')
      ..writeln('每条 text 控制在 45 字以内，像连续镜头的一部分。')
      ..writeln('优先体现视觉焦点、光色氛围、镜头功能和剪辑承接。')
      ..writeln('不要写成孤立标签，不要使用“镜头1/镜头2”等编号。')
      ..writeln('称呼规范：成年女性称“女模特”，成年男性称“男模特”。')
      ..writeln('全局故事脉络：$storyContext');
    if (previousCaptions.isNotEmpty) {
      buffer.writeln('上一批已确认文本：');
      for (final entry in previousCaptions) {
        buffer.writeln('${entry.key}. ${entry.value}');
      }
    }
    if (nextSources.isNotEmpty) {
      buffer.writeln('下一批相邻镜头提示（只用于承接，不要返回）：');
      buffer.writeln(_compactSources(nextSources));
    }
    buffer
      ..writeln('本批镜头：')
      ..writeln(_compactSources(chunk))
      ..writeln('JSON 格式：')
      ..writeln('{"storyContext":"可选的批次理解","captions":[')
      ..writeln('{"sequenceNo":${chunk.first.sequenceNo},"text":"连贯文本"}')
      ..writeln(']}');
    return buffer.toString();
  }

  String _captionRepairPrompt({
    required List<VisionCaptionSource> sources,
    required List<int> missingSequenceNos,
    required String storyContext,
    required Map<int, String> existingCaptions,
  }) {
    final wanted = missingSequenceNos.toSet();
    final nearby = sources.where((source) {
      return missingSequenceNos.any(
        (sequenceNo) => (source.sequenceNo - sequenceNo).abs() <= 2,
      );
    }).toList();
    final buffer = StringBuffer()
      ..writeln('补全同一故事板中遗漏的连贯文本。')
      ..writeln('只返回 JSON 对象，只返回编号：${missingSequenceNos.join(', ')}。')
      ..writeln('每项保留 sequenceNo，text 控制在 45 字以内。')
      ..writeln('全局故事脉络：$storyContext')
      ..writeln('相邻已确认文本：');
    final sortedExisting = existingCaptions.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    for (final entry in sortedExisting) {
      if (wanted.any((id) => (entry.key - id).abs() <= 2)) {
        buffer.writeln('${entry.key}. ${entry.value}');
      }
    }
    buffer
      ..writeln('缺失镜头及相邻内容：')
      ..writeln(_compactSources(nearby))
      ..writeln(
        '{"captions":[{"sequenceNo":${missingSequenceNos.first},"text":"补全后的连贯文本"}]}',
      );
    return buffer.toString();
  }

  String _compactSources(List<VisionCaptionSource> sources) {
    final buffer = StringBuffer();
    for (final source in sources) {
      buffer
        ..writeln('${source.sequenceNo}. 原文：${source.caption}')
        ..writeln(
          '场景：${source.scene}；动作：${source.bodyAction}；阶段：${source.actionStage}',
        )
        ..writeln(
          '焦点：${source.visualFocus}；光色：${source.lightingMood}；功能：${source.narrativeFunction}；承接：${source.transitionHint}',
        );
    }
    return buffer.toString();
  }

  _ParsedCaptionContent _captionsFromContent(
    String content, {
    required Set<int> validSequenceNos,
  }) {
    final captions = <int, String>{};
    var completeJson = false;
    Map<String, dynamic>? complete;
    try {
      complete = _extractCompleteJsonObject(content);
      completeJson = true;
      _collectCaptionsFromValue(
        complete['captions'],
        captions,
        validSequenceNos,
      );
    } catch (_) {
      complete = null;
    }
    if (captions.length < validSequenceNos.length) {
      for (final object in _completeJsonObjects(content)) {
        _collectCaptionMap(object, captions, validSequenceNos);
      }
    }
    return _ParsedCaptionContent(
      captionsBySequence: captions,
      completeJson: completeJson,
    );
  }

  void _collectCaptionsFromValue(
    Object? value,
    Map<int, String> target,
    Set<int> validSequenceNos,
  ) {
    if (value is! List) return;
    final legacyStrings =
        value.every((item) => item is String) &&
        value.length == validSequenceNos.length;
    if (legacyStrings) {
      final orderedIds = validSequenceNos.toList()..sort();
      for (var index = 0; index < value.length; index++) {
        final text = _normalizeCaption(value[index].toString());
        if (text.isNotEmpty) target[orderedIds[index]] = text;
      }
      return;
    }
    for (final item in value) {
      if (item is Map<String, dynamic>) {
        _collectCaptionMap(item, target, validSequenceNos);
      } else if (item is Map) {
        _collectCaptionMap(
          item.map((key, value) => MapEntry(key.toString(), value)),
          target,
          validSequenceNos,
        );
      }
    }
  }

  void _collectCaptionMap(
    Map<String, dynamic> item,
    Map<int, String> target,
    Set<int> validSequenceNos,
  ) {
    final rawSequence =
        item['sequenceNo'] ??
        item['sequence_no'] ??
        item['index'] ??
        item['id'];
    final sequenceNo = rawSequence is int
        ? rawSequence
        : int.tryParse(rawSequence?.toString() ?? '');
    final rawText = item['text'] ?? item['caption'] ?? item['value'];
    final text = _normalizeCaption(rawText?.toString() ?? '');
    if (sequenceNo == null ||
        !validSequenceNos.contains(sequenceNo) ||
        text.isEmpty ||
        target.containsKey(sequenceNo)) {
      return;
    }
    target[sequenceNo] = text;
  }

  Map<String, dynamic> _extractCompleteJsonObject(String content) {
    final cleaned = content
        .replaceAll('```json', '')
        .replaceAll('```JSON', '')
        .replaceAll('```', '')
        .trim();
    final start = cleaned.indexOf('{');
    final end = cleaned.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw const FormatException('JSON 对象不完整');
    }
    final decoded = jsonDecode(cleaned.substring(start, end + 1));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('JSON 对象格式异常');
    }
    return decoded;
  }

  Iterable<Map<String, dynamic>> _completeJsonObjects(String content) sync* {
    for (var start = 0; start < content.length; start++) {
      if (content.codeUnitAt(start) != 0x7b) continue;
      var depth = 0;
      var inString = false;
      var escaped = false;
      for (var index = start; index < content.length; index++) {
        final code = content.codeUnitAt(index);
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (code == 0x5c) {
            escaped = true;
          } else if (code == 0x22) {
            inString = false;
          }
          continue;
        }
        if (code == 0x22) {
          inString = true;
        } else if (code == 0x7b) {
          depth++;
        } else if (code == 0x7d) {
          depth--;
          if (depth == 0) {
            try {
              final decoded = jsonDecode(content.substring(start, index + 1));
              if (decoded is Map<String, dynamic>) yield decoded;
            } catch (_) {
              // 继续扫描后续完整条目。
            }
            break;
          }
        }
      }
    }
  }

  String _storyContextFromContent(String content) {
    try {
      final json = _extractCompleteJsonObject(content);
      return (json['storyContext'] ?? json['story_context'] ?? json['context'])
              ?.toString()
              .trim() ??
          '';
    } catch (_) {
      return '';
    }
  }

  List<int> _missingForChunk(
    List<VisionCaptionSource> chunk,
    Map<int, String> captionsBySequence,
  ) {
    return [
      for (final source in chunk)
        if (!captionsBySequence.containsKey(source.sequenceNo))
          source.sequenceNo,
    ];
  }

  String _localStoryContext(List<VisionCaptionSource> sources) {
    final scenes = <String>[];
    for (final source in sources) {
      final scene = source.scene.trim();
      if (scene.isNotEmpty && !scenes.contains(scene)) scenes.add(scene);
      if (scenes.length >= 4) break;
    }
    final sceneText = scenes.isEmpty ? '连续场景' : scenes.join('、');
    final focus = sources
        .map((source) => source.narrativeFunction.trim())
        .firstWhere((value) => value.isNotEmpty, orElse: () => '人物行动');
    return '故事围绕$focus展开，镜头依次经过$sceneText，并以相邻动作和视线关系保持连续。';
  }

  String _localCoherentCaption({
    required VisionCaptionSource source,
    required VisionCaptionSource? previousSource,
    required String? previousCaption,
    required bool isLast,
  }) {
    var base = source.caption.trim();
    if (base.isEmpty) {
      base = [source.bodyAction, source.visualFocus, source.scene]
          .map((value) => value.trim())
          .firstWhere((value) => value.isNotEmpty, orElse: () => '画面继续推进');
    }
    base = base.replaceFirst(RegExp(r'^[，。；、\s]+'), '');
    String prefix;
    if (source.sequenceNo == 1) {
      prefix = '开场，';
    } else if (isLast || source.actionStage.contains('结束')) {
      prefix = '最后，';
    } else if (previousSource != null &&
        source.scene.trim().isNotEmpty &&
        source.scene.trim() != previousSource.scene.trim()) {
      prefix = '随后镜头转向${source.scene.trim()}，';
    } else if (previousCaption?.startsWith('随后') == true) {
      prefix = '接着，';
    } else {
      prefix = '随后，';
    }
    var result = '$prefix${_trimSentenceEnd(base)}';
    if (result.length > 44) result = result.substring(0, 44);
    return '$result。';
  }

  String _normalizeCaption(String value) {
    final trimmed = _trimSentenceEnd(value.trim());
    return trimmed.isEmpty ? '' : '$trimmed。';
  }

  String _trimSentenceEnd(String value) {
    return value.replaceFirst(RegExp(r'[。！？!?；;，,\s]+$'), '').trim();
  }

  String _compactError(Object error) {
    final compact = error.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return compact.length <= 500 ? compact : '${compact.substring(0, 500)}...';
  }

  List<List<T>> _chunks<T>(List<T> values, int size) {
    return [
      for (var start = 0; start < values.length; start += size)
        values.sublist(start, math.min(values.length, start + size)),
    ];
  }
}

class _CaptionRequestResult {
  const _CaptionRequestResult({
    required this.captionsBySequence,
    required this.rawResponse,
    required this.requestFailed,
  });

  const _CaptionRequestResult.failed()
    : captionsBySequence = const {},
      rawResponse = '',
      requestFailed = true;

  final Map<int, String> captionsBySequence;
  final String rawResponse;
  final bool requestFailed;
}

class _ContextRequestResult {
  const _ContextRequestResult({
    required this.storyContext,
    required this.rawResponse,
  });

  final String storyContext;
  final String rawResponse;
}

class _ParsedCaptionContent {
  const _ParsedCaptionContent({
    required this.captionsBySequence,
    required this.completeJson,
  });

  final Map<int, String> captionsBySequence;
  final bool completeJson;
}
