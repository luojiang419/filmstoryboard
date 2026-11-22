import 'package:flutter/material.dart';

void main() => runApp(const FilmStoryboardDemo());

class FilmStoryboardDemo extends StatefulWidget {
  const FilmStoryboardDemo({super.key});

  @override
  State<FilmStoryboardDemo> createState() => _FilmStoryboardDemoState();
}

class _FilmStoryboardDemoState extends State<FilmStoryboardDemo> {
  ThemeMode _mode = ThemeMode.light;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'filmstoryboard',
        themeMode: _mode,
        theme: _appTheme(Brightness.light),
        darkTheme: _appTheme(Brightness.dark),
        home: _Website(
          dark: _mode == ThemeMode.dark,
          onTheme: () => setState(() {
            _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
          }),
        ),
      );
}

ThemeData _appTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff596273),
      brightness: brightness,
    ),
    scaffoldBackgroundColor: dark ? const Color(0xff181a1f) : const Color(0xfff6f6f7),
    dividerColor: dark ? const Color(0xff363942) : const Color(0xffd8dbe1),
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xff20232a) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}

class _Website extends StatelessWidget {
  const _Website({required this.dark, required this.onTheme});

  final bool dark;
  final VoidCallback onTheme;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: .62);
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1440),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
                    child: Row(children: [
                      const _WebsiteBrand(),
                      const Spacer(),
                      Text('本地优先 · 交互演示', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: muted)),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: dark ? '切换浅色模式' : '切换暗黑模式',
                        onPressed: onTheme,
                        icon: Icon(dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                child: Column(children: [
                  Text('把视频，变成可执行的分镜。', textAlign: TextAlign.center, style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1.1)),
                  const SizedBox(height: 8),
                  Text('下方 Demo 复刻桌面端的标题栏、工作区与底部功能 Dock。', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: muted)),
                ]),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 46),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1440),
                    child: const SizedBox(height: 560, child: DesktopDemo()),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebsiteBrand extends StatelessWidget {
  const _WebsiteBrand();

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(9)),
          child: Icon(Icons.auto_awesome_rounded, size: 18, color: Theme.of(context).colorScheme.onPrimary),
        ),
        const SizedBox(width: 9),
        const Text('FilmStoryboard', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      ]);
}

class DesktopDemo extends StatefulWidget {
  const DesktopDemo({super.key});

  @override
  State<DesktopDemo> createState() => _DesktopDemoState();
}

class _DesktopDemoState extends State<DesktopDemo> {
  static const _tabs = [
    _AppTab('设计分镜图', Icons.draw_rounded),
    _AppTab('视频解析', Icons.video_file_rounded),
    _AppTab('故事板', Icons.dashboard_customize_rounded),
    _AppTab('拍摄脚本', Icons.table_chart_rounded),
    _AppTab('导出', Icons.ios_share_rounded),
    _AppTab('设置', Icons.tune_rounded),
  ];

  int _tab = 0;
  int _selectedFrame = 2;
  bool _generated = false;
  bool _confirmed = false;
  bool _onlyCurrentFrame = false;
  String _style = '电影感';
  String _exportFormat = 'PNG';

  void _toast(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(children: [
          const _DesktopTitleBar(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              child: switch (_tab) {
                0 => _DesignWorkspace(key: const ValueKey('design'), style: _style, generated: _generated, onStyle: (value) => setState(() => _style = value), onGenerate: () { setState(() => _generated = true); _toast('已生成 8 张分镜图（演示）'); }),
                1 => _VideoWorkspace(key: const ValueKey('video'), frame: _selectedFrame, onlyCurrent: _onlyCurrentFrame, onFrame: (index) => setState(() => _selectedFrame = index), onFilter: () => setState(() => _onlyCurrentFrame = !_onlyCurrentFrame), onToast: _toast),
                2 => _StoryboardWorkspace(key: const ValueKey('board'), frame: _selectedFrame, onFrame: (index) => setState(() => _selectedFrame = index), onOpenScript: () => setState(() => _tab = 3)),
                3 => _ScriptWorkspace(key: const ValueKey('script'), frame: _selectedFrame, confirmed: _confirmed, onFrame: (index) => setState(() => _selectedFrame = index), onConfirm: () => setState(() => _confirmed = !_confirmed)),
                4 => _ExportWorkspace(key: const ValueKey('export'), format: _exportFormat, onFormat: (value) => setState(() => _exportFormat = value), onToast: _toast),
                _ => _SettingsWorkspace(key: const ValueKey('settings'), onToast: _toast),
              },
            ),
          ),
          _BottomDock(tabs: _tabs, selected: _tab, onSelected: (index) => setState(() => _tab = index)),
        ]),
      ),
    );
  }
}

class _DesktopTitleBar extends StatelessWidget {
  const _DesktopTitleBar();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 42,
      padding: const EdgeInsets.only(left: 16),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest.withValues(alpha: .86), border: Border(bottom: BorderSide(color: scheme.outlineVariant.withValues(alpha: .42)))),
      child: Row(children: [
        Container(width: 18, height: 18, decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(5)), child: Icon(Icons.auto_awesome_rounded, size: 12, color: scheme.onPrimary)),
        const SizedBox(width: 10),
        const Expanded(child: Text('filmstoryboard — A', overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
        IconButton(onPressed: () {}, tooltip: '新手引导', icon: const Icon(Icons.help_outline_rounded, size: 18)),
        const _TitleButton(Icons.remove_rounded),
        const _TitleButton(Icons.crop_square_rounded),
        const _TitleButton(Icons.close_rounded, danger: true),
      ]),
    );
  }
}

class _TitleButton extends StatelessWidget {
  const _TitleButton(this.icon, {this.danger = false});
  final IconData icon;
  final bool danger;
  @override
  Widget build(BuildContext context) => SizedBox(width: 46, height: 42, child: Icon(icon, size: 18, color: danger ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurfaceVariant));
}

class _BottomDock extends StatelessWidget {
  const _BottomDock({required this.tabs, required this.selected, required this.onSelected});
  final List<_AppTab> tabs;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 1240),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: scheme.surface.withValues(alpha: .94),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outlineVariant.withValues(alpha: .34)),
            boxShadow: [BoxShadow(color: scheme.shadow.withValues(alpha: .10), blurRadius: 18, offset: const Offset(0, 6))],
          ),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [for (var i = 0; i < tabs.length; i++) _DockButton(tab: tabs[i], selected: selected == i, onTap: () => onSelected(i))],
          ),
        ),
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({required this.tab, required this.selected, required this.onTap});
  final _AppTab tab;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tab.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 13),
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer.withValues(alpha: .9) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? scheme.primary.withValues(alpha: .32) : scheme.outlineVariant.withValues(alpha: .28)),
            boxShadow: selected ? [BoxShadow(color: scheme.primary.withValues(alpha: .14), blurRadius: 12, offset: const Offset(0, 3))] : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(tab.icon, size: 18, color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(tab.label, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500, color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

class _AppTab { const _AppTab(this.label, this.icon); final String label; final IconData icon; }

class _Workspace extends StatelessWidget {
  const _Workspace({required this.title, required this.subtitle, required this.actions, required this.child});
  final String title;
  final String subtitle;
  final List<Widget> actions;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)), Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant))])),
            const SizedBox(width: 12),
            Flexible(child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: actions)),
          ]),
          const SizedBox(height: 12),
          Expanded(child: child),
        ]),
      );
}

class _Pane extends StatelessWidget {
  const _Pane({required this.title, required this.child, this.actions = const []});
  final String title;
  final Widget child;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLowest, border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 8, 8, 7), child: Row(children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)), const Spacer(), ...actions])),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          Expanded(child: child),
        ]),
      );
}

class _DesignWorkspace extends StatelessWidget {
  const _DesignWorkspace({super.key, required this.style, required this.generated, required this.onStyle, required this.onGenerate});
  final String style;
  final bool generated;
  final ValueChanged<String> onStyle;
  final VoidCallback onGenerate;
  @override
  Widget build(BuildContext context) => _Workspace(
        title: '设计分镜图', subtitle: '使用文本描述与参考图，生成可编辑的分镜画面。', actions: [OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.folder_open_rounded, size: 18), label: const Text('导入脚本')), FilledButton.icon(onPressed: onGenerate, icon: const Icon(Icons.auto_awesome_rounded, size: 18), label: Text(generated ? '再次生成' : '生成分镜图'))],
        child: LayoutBuilder(builder: (context, box) {
          final input = _Pane(title: '分镜输入', child: ListView(padding: const EdgeInsets.all(12), children: [
            const Text('画面描述', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 7),
            Container(height: 116, padding: const EdgeInsets.all(10), decoration: BoxDecoration(border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(8)), child: const Text('夏日时尚广告，女模特穿着蓝色牛仔背带裤，在阳光与海风中自然行走。画面保持轻盈、干净的品牌质感。', style: TextStyle(fontSize: 13))),
            const SizedBox(height: 14), const Text('视觉风格', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 7),
            Wrap(spacing: 6, runSpacing: 6, children: ['电影感', '时尚广告', '自然写实'].map((value) => ChoiceChip(label: Text(value), selected: style == value, onSelected: (_) => onStyle(value))).toList()),
            const SizedBox(height: 16), const Text('参考图片', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 8),
            SizedBox(height: 78, child: ListView(scrollDirection: Axis.horizontal, children: [for (final index in [1, 2, 3]) Padding(padding: const EdgeInsets.only(right: 7), child: ClipRRect(borderRadius: BorderRadius.circular(7), child: Image.asset(_frames[index].path, width: 104, fit: BoxFit.cover)))])),
            const SizedBox(height: 14), const _InfoLine('画幅比例', '16 : 9'), const _InfoLine('图像尺寸', '1K'), const _InfoLine('生成模型', 'Gemini 3 Pro Image'),
          ]));
          final result = _Pane(title: '生成结果', actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.grid_view_rounded, size: 18))], child: _ResultGrid(highlight: generated ? 5 : 2));
          return box.maxWidth < 600 ? Column(children: [Expanded(child: result), const SizedBox(height: 10), SizedBox(height: 220, child: input)]) : Row(children: [SizedBox(width: 300, child: input), const SizedBox(width: 12), Expanded(child: result)]);
        }),
      );
}

class _VideoWorkspace extends StatelessWidget {
  const _VideoWorkspace({super.key, required this.frame, required this.onlyCurrent, required this.onFrame, required this.onFilter, required this.onToast});
  final int frame; final bool onlyCurrent; final ValueChanged<int> onFrame; final VoidCallback onFilter; final ValueChanged<String> onToast;
  @override
  Widget build(BuildContext context) => _Workspace(
        title: '视频解析', subtitle: '参考视频：bebe-2025ss 夏季系列短片.mp4', actions: [IconButton(onPressed: () {}, tooltip: '撤销移除视频帧', icon: const Icon(Icons.undo_rounded)), IconButton(onPressed: () {}, tooltip: '恢复视频帧', icon: const Icon(Icons.redo_rounded)), OutlinedButton.icon(onPressed: () => onToast('本 Demo 使用预置视频'), icon: const Icon(Icons.video_file_rounded, size: 18), label: const Text('添加视频')), FilledButton.icon(onPressed: () => onToast('解析已完成：30 个画面'), icon: const Icon(Icons.auto_awesome_rounded, size: 18), label: const Text('开始解析'))],
        child: LayoutBuilder(builder: (context, box) {
          final list = _Pane(title: '参考视频', child: ListView(padding: const EdgeInsets.all(8), children: [
            _VideoRow(selected: true, onTap: () {}), const SizedBox(height: 8),
            _SmallStatus(icon: Icons.check_circle_rounded, label: '30 帧 · 已完成'),
          ]));
          final frames = _Pane(title: '候选视频帧', actions: [IconButton(onPressed: onFilter, tooltip: onlyCurrent ? '显示全部' : '仅看当前画面', icon: Icon(onlyCurrent ? Icons.filter_alt_rounded : Icons.filter_alt_outlined, size: 18))], child: _FrameGrid(selected: frame, indices: onlyCurrent ? [frame] : null, onTap: onFrame));
          final inspector = _Pane(title: '画面解析', child: _AnalysisDetail(frame: frame));
          return box.maxWidth < 840 ? Column(children: [Expanded(child: frames), const SizedBox(height: 10), SizedBox(height: 155, child: Row(children: [Expanded(child: list), const SizedBox(width: 10), Expanded(child: inspector)]))]) : Row(children: [SizedBox(width: 205, child: list), const SizedBox(width: 12), Expanded(child: frames), const SizedBox(width: 12), SizedBox(width: 260, child: inspector)]);
        }),
      );
}

class _StoryboardWorkspace extends StatelessWidget {
  const _StoryboardWorkspace({super.key, required this.frame, required this.onFrame, required this.onOpenScript});
  final int frame; final ValueChanged<int> onFrame; final VoidCallback onOpenScript;
  @override
  Widget build(BuildContext context) => _Workspace(
        title: '故事板', subtitle: '视频解析故事板 · 30 个视频画面已同步', actions: [OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.add_rounded, size: 18), label: const Text('新建画板')), IconButton(onPressed: () {}, tooltip: '撤销', icon: const Icon(Icons.undo_rounded)), IconButton(onPressed: () {}, tooltip: '重做', icon: const Icon(Icons.redo_rounded))],
        child: Column(children: [
          Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 6, children: [const Chip(label: Text('视频解析故事板')), ActionChip(label: const Text('拍摄脚本'), avatar: const Icon(Icons.table_chart_rounded, size: 16), onPressed: onOpenScript)])),
          const SizedBox(height: 10),
          Expanded(child: LayoutBuilder(builder: (context, box) {
            final assets = _Pane(title: '素材资源', actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.unfold_less_rounded, size: 17))], child: ListView(padding: const EdgeInsets.all(8), children: [for (var i = 0; i < 5; i++) _AssetTile(index: i, selected: i == frame, onTap: () => onFrame(i))]));
            final canvas = _StoryboardCanvas(frame: frame, onFrame: onFrame);
            final inspector = _CollapsedRail(label: '检查器', icon: Icons.tune_rounded);
            return Row(children: [if (box.maxWidth > 700) SizedBox(width: 210, child: assets), if (box.maxWidth > 700) const SizedBox(width: 10), Expanded(child: canvas), const SizedBox(width: 10), SizedBox(width: 44, child: inspector)]);
          }))
        ]),
      );
}

class _ScriptWorkspace extends StatelessWidget {
  const _ScriptWorkspace({super.key, required this.frame, required this.confirmed, required this.onFrame, required this.onConfirm});
  final int frame; final bool confirmed; final ValueChanged<int> onFrame; final VoidCallback onConfirm;
  @override
  Widget build(BuildContext context) => _Workspace(
        title: '拍摄脚本', subtitle: 'bebe-2025ss 夏季系列短片 · 视频解析故事板 · 拍摄脚本', actions: [OutlinedButton.icon(onPressed: () {}, icon: const Icon(Icons.auto_awesome_rounded, size: 18), label: const Text('智能补全')), FilledButton.icon(onPressed: onConfirm, icon: Icon(confirmed ? Icons.undo_rounded : Icons.check_rounded, size: 18), label: Text(confirmed ? '撤销确认' : '确认镜头'))],
        child: LayoutBuilder(builder: (context, box) {
          final library = _Pane(title: '资产库', actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.add_photo_alternate_outlined, size: 18))], child: ListView(padding: const EdgeInsets.all(8), children: const [ListTile(dense: true, leading: Icon(Icons.person_outline_rounded), title: Text('女模特'), subtitle: Text('人物')), ListTile(dense: true, leading: Icon(Icons.checkroom_outlined), title: Text('蓝色牛仔背带裤'), subtitle: Text('产品'))]));
          final table = _ScriptTable(frame: frame, confirmed: confirmed, onFrame: onFrame);
          return box.maxWidth < 820 ? table : Row(children: [SizedBox(width: 225, child: library), const SizedBox(width: 12), Expanded(child: table)]);
        }),
      );
}

class _ExportWorkspace extends StatelessWidget {
  const _ExportWorkspace({super.key, required this.format, required this.onFormat, required this.onToast});
  final String format; final ValueChanged<String> onFormat; final ValueChanged<String> onToast;
  @override
  Widget build(BuildContext context) => _Workspace(
        title: '导出', subtitle: '选择故事板，预览并导出制作资料。', actions: [FilledButton.icon(onPressed: () => onToast('已准备导出 $format 文件（演示）'), icon: const Icon(Icons.ios_share_rounded, size: 18), label: const Text('导出选中内容'))],
        child: LayoutBuilder(builder: (context, box) {
          final list = _Pane(title: '选择故事板', child: ListView(padding: const EdgeInsets.all(8), children: [CheckboxListTile(value: true, onChanged: (_) {}, title: const Text('视频解析故事板'), subtitle: const Text('30 个画面'), controlAffinity: ListTileControlAffinity.leading), CheckboxListTile(value: false, onChanged: (_) {}, title: const Text('夏日时尚广告'), subtitle: const Text('8 个画面'), controlAffinity: ListTileControlAffinity.leading)]));
          final preview = _Pane(title: '导出预览', child: _ExportPreview());
          final options = _Pane(title: '导出设置', child: ListView(padding: const EdgeInsets.all(12), children: [const Text('导出格式', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 7), SegmentedButton<String>(segments: const [ButtonSegment(value: 'PNG', label: Text('PNG', softWrap: false, overflow: TextOverflow.clip)), ButtonSegment(value: 'PDF', label: Text('PDF', softWrap: false, overflow: TextOverflow.clip)), ButtonSegment(value: 'XLSX', label: Text('XLSX', softWrap: false, overflow: TextOverflow.clip))], selected: {format}, onSelectionChanged: (value) => onFormat(value.first)), const SizedBox(height: 18), const _InfoLine('分辨率', '原图细节'), const _InfoLine('画板尺寸', '16 : 9'), const _InfoLine('已选择', '1 个故事板')]));
          return box.maxWidth < 850 ? Column(children: [Expanded(child: preview), const SizedBox(height: 10), SizedBox(height: 180, child: Row(children: [Expanded(child: list), const SizedBox(width: 10), Expanded(child: options)]))]) : Row(children: [SizedBox(width: 210, child: list), const SizedBox(width: 12), Expanded(child: preview), const SizedBox(width: 12), SizedBox(width: 280, child: options)]);
        }),
      );
}

class _SettingsWorkspace extends StatefulWidget { const _SettingsWorkspace({super.key, required this.onToast}); final ValueChanged<String> onToast; @override State<_SettingsWorkspace> createState() => _SettingsWorkspaceState(); }
class _SettingsWorkspaceState extends State<_SettingsWorkspace> {
  bool _welcome = true; bool _left = false; bool _automatic = true;
  @override
  Widget build(BuildContext context) => _Workspace(title: '设置', subtitle: '配置软件外观、工程、视频解析和 API 服务。', actions: const [], child: ListView(padding: const EdgeInsets.symmetric(horizontal: 4), children: [
    _SettingsSection(title: '外观', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('功能菜单位置', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 8), SegmentedButton<bool>(segments: const [ButtonSegment(value: false, label: Text('底部'), icon: Icon(Icons.vertical_align_bottom_rounded)), ButtonSegment(value: true, label: Text('左侧'), icon: Icon(Icons.vertical_align_center_rounded))], selected: {_left}, onSelectionChanged: (value) => setState(() => _left = value.first)), const SizedBox(height: 8), Text('演示版固定使用底部 Dock；此控件仅展示桌面端设置结构。', style: Theme.of(context).textTheme.bodySmall)])),
    _SettingsSection(title: '工程与启动', child: SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('启动时显示欢迎页'), subtitle: const Text('关闭后下次启动直接进入工程首页。'), value: _welcome, onChanged: (value) => setState(() => _welcome = value))),
    _SettingsSection(title: '视频解析', child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('自动选择高质量画面'), subtitle: const Text('解析完成后保留候选帧。'), value: _automatic, onChanged: (value) => setState(() => _automatic = value)), const _InfoLine('抽帧间隔', '1.00 秒'), const _InfoLine('场景阈值', '0.30')])),
    _SettingsSection(title: '导出目录', child: ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.folder_open_rounded), title: const Text('exports'), subtitle: const Text('本 Demo 不会写入本地文件'), trailing: OutlinedButton(onPressed: () => widget.onToast('Demo 不会打开文件选择器'), child: const Text('选择')))),
    _SettingsSection(title: '更新', child: ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.system_update_rounded), title: const Text('当前版本 1.0.0.140'), subtitle: const Text('Web Demo 构建版本'), trailing: OutlinedButton(onPressed: () => widget.onToast('已是最新演示版本'), child: const Text('检查更新')))),
  ]));
}

class _ResultGrid extends StatelessWidget { const _ResultGrid({required this.highlight}); final int highlight; @override Widget build(BuildContext context) => _FrameGrid(selected: highlight, onTap: (_) {}, showLabel: true); }

class _FrameGrid extends StatelessWidget {
  const _FrameGrid({required this.selected, required this.onTap, this.indices, this.showLabel = false});
  final int selected; final ValueChanged<int> onTap; final List<int>? indices; final bool showLabel;
  @override
  Widget build(BuildContext context) {
    final values = indices ?? List<int>.generate(_frames.length, (index) => index);
    return LayoutBuilder(builder: (context, box) {
      final count = box.maxWidth > 560 ? 3 : box.maxWidth > 270 ? 2 : 1;
      return GridView.builder(padding: const EdgeInsets.all(9), itemCount: values.length, gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: count, crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: showLabel ? 1.36 : 1.55), itemBuilder: (context, position) {
        final index = values[position]; final item = _frames[index]; final active = index == selected;
        return Material(
          color: active ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onTap(index),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Stack(fit: StackFit.expand, children: [
                  ClipRRect(borderRadius: BorderRadius.circular(5), child: Image.asset(item.path, fit: BoxFit.cover)),
                  Positioned(left: 5, top: 5, child: _NumberBadge(index + 1)),
                  if (active) Positioned(right: 5, top: 5, child: Icon(Icons.check_circle_rounded, size: 18, color: Theme.of(context).colorScheme.primary)),
                ])),
                if (showLabel) Padding(padding: const EdgeInsets.fromLTRB(3, 4, 3, 0), child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
              ]),
            ),
          ),
        );
      });
    });
  }
}

class _NumberBadge extends StatelessWidget { const _NumberBadge(this.number); final int number; @override Widget build(BuildContext context) => DecoratedBox(decoration: BoxDecoration(color: Colors.black.withValues(alpha: .68), borderRadius: BorderRadius.circular(4)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), child: Text(number.toString().padLeft(2, '0'), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)))); }

class _AnalysisDetail extends StatelessWidget { const _AnalysisDetail({required this.frame}); final int frame; @override Widget build(BuildContext context) { final item = _frames[frame]; return ListView(padding: const EdgeInsets.all(12), children: [ClipRRect(borderRadius: BorderRadius.circular(7), child: AspectRatio(aspectRatio: 16 / 9, child: Image.asset(item.path, fit: BoxFit.cover))), const SizedBox(height: 12), Text('画面 ${('${frame + 1}').padLeft(2, '0')}', style: const TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 7), Text(item.description, style: Theme.of(context).textTheme.bodySmall), const SizedBox(height: 16), const _InfoLine('时间点', '00:04.40'), const _InfoLine('画面状态', '已完成'), const _InfoLine('解析维度', '构图 · 光影 · 色彩 · 景别')]); } }

class _VideoRow extends StatelessWidget { const _VideoRow({required this.selected, required this.onTap}); final bool selected; final VoidCallback onTap; @override Widget build(BuildContext context) => Material(color: selected ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent, borderRadius: BorderRadius.circular(8), child: InkWell(borderRadius: BorderRadius.circular(8), onTap: onTap, child: const Padding(padding: EdgeInsets.all(9), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('bebe-2025ss 夏季系列短片.mp4', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), SizedBox(height: 4), Text('00:22 · 1920×1080', style: TextStyle(fontSize: 11)), Text('30 帧 · 已完成', style: TextStyle(fontSize: 11))])))); }
class _SmallStatus extends StatelessWidget { const _SmallStatus({required this.icon, required this.label}); final IconData icon; final String label; @override Widget build(BuildContext context) => Row(children: [Icon(icon, color: Theme.of(context).colorScheme.primary, size: 16), const SizedBox(width: 5), Text(label, style: Theme.of(context).textTheme.labelSmall)]); }

class _AssetTile extends StatelessWidget { const _AssetTile({required this.index, required this.selected, required this.onTap}); final int index; final bool selected; final VoidCallback onTap; @override Widget build(BuildContext context) => Material(color: selected ? Theme.of(context).colorScheme.primaryContainer : Colors.transparent, borderRadius: BorderRadius.circular(7), child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(7), child: Padding(padding: const EdgeInsets.all(5), child: Row(children: [ClipRRect(borderRadius: BorderRadius.circular(5), child: Image.asset(_frames[index].path, height: 40, width: 64, fit: BoxFit.cover)), const SizedBox(width: 7), Expanded(child: Text('视频画面 ${index + 1}', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))])))); }

class _StoryboardCanvas extends StatelessWidget { const _StoryboardCanvas({required this.frame, required this.onFrame}); final int frame; final ValueChanged<int> onFrame; @override Widget build(BuildContext context) => DecoratedBox(decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .38), border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(10)), child: Column(children: [Padding(padding: const EdgeInsets.all(8), child: Row(children: [const Icon(Icons.dashboard_customize_rounded, size: 17), const SizedBox(width: 6), const Text('视频解析故事板', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)), const Spacer(), IconButton(onPressed: () {}, icon: const Icon(Icons.lock_open_rounded, size: 17)), IconButton(onPressed: () {}, icon: const Icon(Icons.zoom_in_rounded, size: 17))])), Expanded(child: GridView.builder(padding: const EdgeInsets.all(14), itemCount: 6, gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 9, mainAxisSpacing: 9, childAspectRatio: 1.28), itemBuilder: (context, index) => _StoryboardCell(index: index, selected: index == frame, onTap: () => onFrame(index))))])); }
class _StoryboardCell extends StatelessWidget { const _StoryboardCell({required this.index, required this.selected, required this.onTap}); final int index; final bool selected; final VoidCallback onTap; @override Widget build(BuildContext context) => Material(color: selected ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).colorScheme.surfaceContainerLowest, borderRadius: BorderRadius.circular(7), child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(7), child: Padding(padding: const EdgeInsets.all(4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(5), child: Image.asset(_frames[index].path, fit: BoxFit.cover, width: double.infinity))), Padding(padding: const EdgeInsets.fromLTRB(3, 4, 3, 0), child: Text('${index + 1}. ${_frames[index].label}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)))])))); }
class _CollapsedRail extends StatelessWidget { const _CollapsedRail({required this.label, required this.icon}); final String label; final IconData icon; @override Widget build(BuildContext context) => DecoratedBox(decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerLowest, border: Border.all(color: Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(9)), child: InkWell(borderRadius: BorderRadius.circular(9), onTap: () {}, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(icon, size: 19), const SizedBox(height: 7), RotatedBox(quarterTurns: 3, child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)))]))); }

class _ScriptTable extends StatelessWidget { const _ScriptTable({required this.frame, required this.confirmed, required this.onFrame}); final int frame; final bool confirmed; final ValueChanged<int> onFrame; @override Widget build(BuildContext context) { const heads = ['镜头', '画面', '内容描述', '景别', '运镜', '状态']; return _Pane(title: '镜头明细', actions: [IconButton(onPressed: () {}, icon: const Icon(Icons.unfold_more_rounded, size: 18))], child: Column(children: [Container(color: Theme.of(context).colorScheme.surfaceContainerHigh, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8), child: Row(children: [for (final head in heads) Expanded(flex: head == '内容描述' ? 3 : 1, child: Text(head, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)))])), Expanded(child: ListView.separated(itemCount: _frames.length, separatorBuilder: (_, _) => Divider(height: 1, color: Theme.of(context).dividerColor), itemBuilder: (context, index) { final active = index == frame; return Material(color: active ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .7) : Colors.transparent, child: InkWell(onTap: () => onFrame(index), child: Padding(padding: const EdgeInsets.all(7), child: Row(children: [Expanded(child: Text('${index + 1}'.padLeft(2, '0'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))), Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.asset(_frames[index].path, height: 35, fit: BoxFit.cover))), Expanded(flex: 3, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text(_frames[index].description, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)))), const Expanded(child: Text('中景', style: TextStyle(fontSize: 11))), const Expanded(child: Text('跟拍', style: TextStyle(fontSize: 11))), Expanded(child: Row(children: [Icon(active && confirmed ? Icons.verified_rounded : Icons.check_circle_outline_rounded, size: 15, color: active && confirmed ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant), const SizedBox(width: 3), Text(active && confirmed ? '已确认' : '已解析', style: const TextStyle(fontSize: 10))]))])))); }))])); } }

class _ExportPreview extends StatelessWidget { @override Widget build(BuildContext context) => Center(child: AspectRatio(aspectRatio: 16 / 9, child: Container(margin: const EdgeInsets.all(18), padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, border: Border.all(color: Theme.of(context).dividerColor), boxShadow: [BoxShadow(color: Theme.of(context).colorScheme.shadow.withValues(alpha: .12), blurRadius: 16)]), child: Column(children: [const Text('视频解析故事板', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)), const SizedBox(height: 7), Expanded(child: GridView.builder(physics: const NeverScrollableScrollPhysics(), itemCount: 6, gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 5, crossAxisSpacing: 5, childAspectRatio: 1.35), itemBuilder: (_, index) => Image.asset(_frames[index].path, fit: BoxFit.cover)))])))); }

class _SettingsSection extends StatelessWidget { const _SettingsSection({required this.title, required this.child}); final String title; final Widget child; @override Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(15), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)), const SizedBox(height: 8), child]))); }
class _InfoLine extends StatelessWidget { const _InfoLine(this.label, this.value); final String label; final String value; @override Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 9), child: Row(children: [Text(label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)), const Spacer(), Flexible(child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)))])); }

class _DemoFrame { const _DemoFrame(this.path, this.label, this.description); final String path; final String label; final String description; }
const _frames = [
  _DemoFrame('assets/frames/00001-00m00s000ms.jpg', '品牌开场', '米色墙面上斑驳叶影摇曳，白色品牌标识静置于光影之间，建立柔和氛围。'),
  _DemoFrame('assets/frames/00003-00m01s120ms.jpg', '夏日人物', '女模特立于蓝天之下，米色亮片吊带裙映着阳光，神情从容望向镜头。'),
  _DemoFrame('assets/frames/00007-00m04s400ms.jpg', '动态细节', '镜头靠近人物上半身，轻盈材质与自然风感共同强化夏日质感。'),
  _DemoFrame('assets/frames/00011-00m06s480ms.jpg', '人物定格', '人物与建筑留出呼吸感，画面以干净的空间关系保持时尚广告节奏。'),
  _DemoFrame('assets/frames/00015-00m09s960ms.jpg', '光影特写', '阳光落在服装纹理上，突出面料细节与柔和的暖色调。'),
  _DemoFrame('assets/frames/00020-00m13s720ms.jpg', '夏日行走', '人物在开放空间中自然行走，镜头跟随动作，画面连贯舒展。'),
  _DemoFrame('assets/frames/00024-00m16s440ms.jpg', '服装展示', '侧向取景保留人物轮廓，让服装线条和场景色彩形成对照。'),
  _DemoFrame('assets/frames/00030-00m21s400ms.jpg', '收束画面', '镜头以明亮空间收束，延续品牌的轻盈、清爽与夏日情绪。'),
];
