import 'package:flutter_test/flutter_test.dart';

import 'package:filmstoryboard_demo/main.dart';

void main() {
  testWidgets('官网首屏直接展示桌面端结构 Demo', (tester) async {
    await tester.pumpWidget(const FilmStoryboardDemo());

    expect(find.text('把视频，变成可执行的分镜。'), findsOneWidget);
    expect(find.text('filmstoryboard — A'), findsOneWidget);
    expect(find.text('分镜输入'), findsOneWidget);
    expect(find.text('设计分镜图'), findsWidgets);
    expect(find.text('拍摄脚本'), findsOneWidget);
  });
}
