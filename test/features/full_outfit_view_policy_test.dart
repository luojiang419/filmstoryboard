import 'package:filmstoryboard/features/replicate/domain/full_outfit_view_policy.dart';
import 'package:filmstoryboard/features/replicate/domain/replicate_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('只使用已保存原帧朝向确定正侧背主视图', () {
    expect(
      FullOutfitViewPolicy.inferRole('身体面向画面右侧'),
      ReplicateOutfitViewRole.side,
    );
    expect(
      FullOutfitViewPolicy.inferRole('人物三分之二侧面朝左'),
      ReplicateOutfitViewRole.side,
    );
    expect(
      FullOutfitViewPolicy.inferRole('人物背对镜头'),
      ReplicateOutfitViewRole.back,
    );
    expect(
      FullOutfitViewPolicy.inferRole('人物正面面对镜头'),
      ReplicateOutfitViewRole.front,
    );
    expect(FullOutfitViewPolicy.inferRole('人物站立'), isNull);
  });

  test('朝向未知时不黑盒指定主视图', () {
    const views = [
      ReplicateFullOutfitView(
        id: 'front',
        scriptAssetId: 'asset-front',
        role: ReplicateOutfitViewRole.front,
      ),
      ReplicateFullOutfitView(
        id: 'side',
        scriptAssetId: 'asset-side',
        role: ReplicateOutfitViewRole.side,
      ),
      ReplicateFullOutfitView(
        id: 'back',
        scriptAssetId: 'asset-back',
        role: ReplicateOutfitViewRole.back,
      ),
    ];

    expect(
      FullOutfitViewPolicy.selectPrimaryViewId(
        views: views,
        subjectDirection: '面向画面左侧',
      ),
      'side',
    );
    expect(
      FullOutfitViewPolicy.selectPrimaryViewId(
        views: views,
        subjectDirection: '人物站立',
      ),
      isEmpty,
    );
  });
}
