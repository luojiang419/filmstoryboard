import 'dart:io';

import 'package:filmstoryboard/features/replicate/data/replication_generation_review_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('姿势审核解析通过、需校正和无法判断三种结果', () {
    const service = ReplicationGenerationReviewService();
    expect(
      service.parseResponse('{"decision":"passed","issue":null}').passed,
      isTrue,
    );

    final result = service.parseResponse('''
      {"decision":"correction_required","issue":{
        "code":"depth_geometry",
        "summary":"右手没有握住产品",
        "evidence":"待审核图右手与瓶身之间有明显空隙，姿势图中二者接触",
        "correction":"只让右手手指贴合瓶身并形成自然握持"
      }}
    ''');

    expect(result.requiresCorrection, isTrue);
    expect(result.issue?.code, 'depth_geometry');
    expect(result.issue?.priority, 1);
    expect(result.issue?.summary, '右手没有握住产品');

    final inconclusive = service.parseResponse(
      '{"decision":"inconclusive","reason":"右臂被前景完全遮挡"}',
    );
    expect(inconclusive.isInconclusive, isTrue);
    expect(inconclusive.diagnostic, '右臂被前景完全遮挡');
  });

  test('只接受具有证据和单项修正要求的 depth_geometry 问题', () {
    const service = ReplicationGenerationReviewService();

    expect(
      () => service.parseResponse(
        '{"decision":"correction_required","issue":{"code":"depth_geometry","summary":"手部错误"}}',
      ),
      throwsFormatException,
    );
    expect(
      () => service.parseResponse(
        '{"decision":"correction_required","issue":{"code":"asset_authority","summary":"瓶盖错误","evidence":"瓶盖不同","correction":"改瓶盖"}}',
      ),
      throwsFormatException,
    );
  });

  test('审核提示固定 高精度深度图 编号并严格排除模块6及通用质量问题', () {
    const service = ReplicationGenerationReviewService();
    final prompt = service.buildPrompt(
      ReplicationGenerationReviewInput(
        shotNumber: 7,
        originalFrame: File('original.png'),
        orderedReferenceImages: [
          File('original.png'),
          File('pose.png'),
          File('product.png'),
        ],
        depthReferenceImageNumber: 2,
        generatedImage: File('generated.png'),
        structuredConstraints: '图片3是产品唯一权威来源；保持图片1机位。',
      ),
    );

    expect(prompt, contains('图片1是原帧编辑底图'));
    expect(prompt, contains('图片2至图片3'));
    expect(prompt, contains('图片2是本次唯一高精度深度结构证据'));
    expect(prompt, contains('图片4 是唯一待审核的生成结果'));
    expect(prompt, contains('不得重新解释任何资产的权威边界'));
    expect(prompt, contains('只核验动作、遮挡、接触与可辨认表面几何'));
    expect(prompt, contains('产品局部细节'));
    expect(prompt, contains('均不属于本模块'));
    expect(prompt, contains('"decision":"inconclusive"'));
    expect(prompt, contains('图片3是产品唯一权威来源'));
  });

  test('续轮纠错指令严格限定为只修正一个问题', () {
    const issue = ReplicationGenerationReviewIssue(
      code: 'depth_geometry',
      priority: 1,
      summary: '右手没有握住产品',
      evidence: '待审核图中右手与瓶身之间有明显空隙',
      correction: '只让右手手指贴合瓶身并形成自然握持',
    );

    final prompt = ReplicationGenerationReviewService.buildCorrectionPrompt(
      issue,
    );
    expect(prompt, startsWith('只修正以下一个问题，其他内容不变。'));
    expect(prompt, contains(issue.evidence));
    expect(prompt, contains('不得新增、删除或顺带改动其他元素'));
    expect(prompt, contains('不得修补产品局部细节'));
    expect(prompt, contains('不得修补产品局部细节或改动任何 Logo/文字'));
  });
}
