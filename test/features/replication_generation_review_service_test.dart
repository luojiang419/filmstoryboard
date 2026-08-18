import 'dart:io';

import 'package:filmstoryboard/features/replicate/data/replication_generation_review_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('审核解析只保留固定优先级最高的一个可验证问题', () {
    const service = ReplicationGenerationReviewService();
    final result = service.parseResponse('''
      {
        "passed": false,
        "issues": [
          {
            "code": "forbidden_text",
            "summary": "右下角出现水印",
            "evidence": "待审核图右下角可见两行白色字母",
            "correction": "移除右下角水印并补全墙面纹理"
          },
          {
            "code": "asset_authority",
            "summary": "产品使用了错误外观",
            "evidence": "待审核图瓶盖为圆形，与产品主视图的方形瓶盖不一致",
            "correction": "只把瓶盖恢复为产品主视图定义的方形结构"
          }
        ]
      }
      ''');

    expect(result.passed, isFalse);
    expect(result.issue?.code, 'asset_authority');
    expect(result.issue?.priority, 2);
    expect(result.issue?.summary, '产品使用了错误外观');
  });

  test('通过结果不携带问题，失败结果必须具有证据和单项修正要求', () {
    const service = ReplicationGenerationReviewService();

    expect(service.parseResponse('{"passed":true}').passed, isTrue);
    expect(
      () => service.parseResponse(
        '{"passed":false,"issue":{"code":"pose_contact","summary":"手部错误"}}',
      ),
      throwsFormatException,
    );
  });

  test('审核提示固定图片编号、冻结权威边界并禁止返回问题列表', () {
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
        generatedImage: File('generated.png'),
        structuredConstraints: '图片3是产品唯一权威来源；保持图片1机位。',
      ),
    );

    expect(prompt, contains('图片1是原帧编辑底图'));
    expect(prompt, contains('图片2至图片3'));
    expect(prompt, contains('图片4 是唯一待审核的生成结果'));
    expect(prompt, contains('不得重新解释任何资产的权威边界'));
    expect(prompt, contains('禁止返回问题列表'));
    expect(prompt, contains('图片3是产品唯一权威来源'));
  });

  test('续轮纠错指令严格限定为只修正一个问题', () {
    const issue = ReplicationGenerationReviewIssue(
      code: 'pose_contact',
      priority: 4,
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
  });
}
