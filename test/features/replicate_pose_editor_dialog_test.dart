import 'package:filmstoryboard/features/replicate/domain/replicate_asset_preparation_models.dart';
import 'package:filmstoryboard/features/replicate/presentation/replicate_pose_editor_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('关节编辑器拖动点后标记人工调整并返回画布内坐标', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ReplicateEditablePoseData? saved;
    final pose = ReplicateEditablePoseData(
      sourceWidth: 100,
      sourceHeight: 100,
      people: [
        ReplicatePosePerson(
          id: 'pose-person-0',
          leftToRightOrder: 0,
          modelSlotIndex: 0,
          bounds: const ReplicatePoseBounds(
            x: 10,
            y: 10,
            width: 80,
            height: 80,
          ),
          keypoints: [
            for (var index = 0; index < 133; index++)
              ReplicatePoseKeypoint(
                index: index,
                x: index == 0 ? 20 : -1,
                y: index == 0 ? 20 : -1,
                confidence: index == 0 ? 0.9 : 0,
              ),
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  saved = await showReplicatePoseEditorDialog(
                    context: context,
                    initialPose: pose,
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    final canvas = find.byKey(const ValueKey('pose-editor-canvas'));
    final rect = tester.getRect(canvas);
    final scale = rect.height / 100;
    final horizontalInset = (rect.width - 100 * scale) / 2;
    final start =
        rect.topLeft + Offset(horizontalInset + 20 * scale, 20 * scale);
    final target =
        rect.topLeft + Offset(horizontalInset + 70 * scale, 60 * scale);
    await tester.dragFrom(start, target - start);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('save-pose-editor')));
    await tester.pumpAndSettle();

    final point = saved!.people.single.keypoints.first;
    expect(point.x, closeTo(70, 0.5));
    expect(point.y, closeTo(60, 0.5));
    expect(point.confidence, 1);
    expect(point.manuallyAdjusted, isTrue);
  });
}
