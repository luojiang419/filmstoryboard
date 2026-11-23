import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('所有页面级可折叠面板接入 Ctrl+B 公共域', () {
    final appShell = _source('lib/app/app_shell.dart');
    final gridCut = _source(
      'lib/features/grid_cut/presentation/grid_cut_page.dart',
    );
    final storyboard = _source(
      'lib/features/storyboard/presentation/storyboard_page.dart',
    );
    final shootingScript = _source(
      'lib/features/shooting_script/presentation/shooting_script_page.dart',
    );
    final replicate = _source(
      'lib/features/replicate/presentation/replicate_page.dart',
    );
    final videoGeneration = _source(
      'lib/features/video_generation/presentation/video_generation_page.dart',
    );

    expect(appShell, contains('CollapsiblePanelShortcutScope(child: content)'));
    expect(gridCut, contains('onExpandedChanged: _setImageSidebarExpanded'));
    expect(gridCut, contains('onExpandedChanged: _setInspectorPanelExpanded'));
    expect(storyboard, contains('onExpandedChanged: _setAssetSidebarExpanded'));
    expect(storyboard, contains('onExpandedChanged: _setInspectorExpanded'));
    expect(
      shootingScript,
      contains('onExpandedChanged: _setScriptPanelExpanded'),
    );
    expect(
      shootingScript,
      contains('onExpandedChanged: _setStepPanelExpanded'),
    );
    expect(replicate, contains('onExpandedChanged: _setExpanded'));
    expect(
      videoGeneration,
      contains('onExpandedChanged: _setWorkPanelExpanded'),
    );
  });

  test('新增页面面板状态使用项目数据库持久化', () {
    final shootingScript = _source(
      'lib/features/shooting_script/presentation/shooting_script_page.dart',
    );
    final replicate = _source(
      'lib/features/replicate/presentation/replicate_page.dart',
    );
    final videoGeneration = _source(
      'lib/features/video_generation/presentation/video_generation_page.dart',
    );

    expect(shootingScript, contains("'shootingScriptPageUiState'"));
    expect(shootingScript, contains("'shootingScriptStepPanelCollapsed'"));
    expect(shootingScript, contains("'scriptPanelCollapsed'"));
    expect(shootingScript, contains("'stepPanelCollapsed'"));
    expect(replicate, contains('setSetting(widget.uiStateKey'));
    expect(videoGeneration, contains("'videoGenerationPageUiState'"));
    expect(videoGeneration, contains("'workPanelCollapsed'"));
    expect(videoGeneration, contains("'workPanelWidth'"));
  });
}

String _source(String path) => File(path).readAsStringSync();
