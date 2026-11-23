import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/remote_app.dart';
import '../workspace/remote_app_controller.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({super.key, required this.controller});

  final RemoteAppController controller;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _codeController = TextEditingController();
  final _nameController = TextEditingController(text: '导演浏览器');

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: _AmbientBackground()),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final wide = constraints.maxWidth >= 820;
                      final intro = _PairingIntro(wide: wide);
                      final form = _PairingCard(
                        controller: widget.controller,
                        codeController: _codeController,
                        nameController: _nameController,
                        onSubmit: _submit,
                      );
                      return wide
                          ? Row(
                              children: [
                                Expanded(child: intro),
                                const SizedBox(width: 64),
                                SizedBox(width: 390, child: form),
                              ],
                            )
                          : Column(
                              children: [
                                intro,
                                const SizedBox(height: 34),
                                form,
                              ],
                            );
                    },
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 18,
            right: 22,
            child: _HostStatus(color: scheme.primary),
          ),
        ],
      ),
    );
  }

  void _submit() {
    if (_codeController.text.trim().length != 6) return;
    widget.controller.pair(
      code: _codeController.text.trim(),
      clientName: _nameController.text.trim(),
    );
  }
}

class _PairingIntro extends StatelessWidget {
  const _PairingIntro({required this.wide});

  final bool wide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: wide
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandMark(size: 46),
            const SizedBox(width: 14),
            Text(
              'FilmStoryboard',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w900,
                letterSpacing: -.4,
              ),
            ),
          ],
        ),
        const SizedBox(height: 42),
        Text(
          '片场之外，\n也能一起定镜头。',
          textAlign: wide ? TextAlign.left : TextAlign.center,
          style: Theme.of(context).textTheme.displayMedium?.copyWith(
            fontWeight: FontWeight.w900,
            height: 1.08,
            letterSpacing: -1.8,
          ),
        ),
        const SizedBox(height: 20),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Text(
            '安全连接剪辑电脑上的当前工程。审阅分镜、调整拍摄脚本、跟进生成状态，所有修改实时回到桌面端。',
            textAlign: wide ? TextAlign.left : TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              height: 1.7,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 30),
        const Wrap(
          spacing: 12,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: [
            _FeatureChip(Icons.sync_rounded, '桌面实时同步'),
            _FeatureChip(Icons.lock_outline_rounded, '短时安全配对'),
            _FeatureChip(Icons.devices_rounded, '电脑 · 平板 · 手机'),
          ],
        ),
      ],
    );
  }
}

class _PairingCard extends StatelessWidget {
  const _PairingCard({
    required this.controller,
    required this.codeController,
    required this.nameController,
    required this.onSubmit,
  });

  final RemoteAppController controller;
  final TextEditingController codeController;
  final TextEditingController nameController;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '连接工作台',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text(
              '在桌面软件「设置 → 远程访问」中生成配对码。',
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: 24),
            TextField(
              key: const ValueKey('pairing-code'),
              controller: codeController,
              autofocus: true,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.next,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: 10,
              ),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: '6 位配对码',
                counterText: '',
                prefixIcon: Icon(Icons.pin_outlined),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const ValueKey('client-name'),
              controller: nameController,
              maxLength: 80,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '这台设备的名称',
                counterText: '',
                prefixIcon: Icon(Icons.devices_other_rounded),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
            if (controller.errorMessage.isNotEmpty) ...[
              const SizedBox(height: 14),
              _InlineError(message: controller.errorMessage),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const ValueKey('connect-workspace'),
              onPressed: controller.busy ? null : onSubmit,
              icon: controller.busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward_rounded),
              label: Text(controller.busy ? '正在连接…' : '进入导演工作台'),
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.verified_user_outlined,
                  size: 18,
                  color: scheme.primary,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    '会话由桌面主机授权，可随时在桌面端撤销。模型密钥不会发送到浏览器。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AmbientBackground extends StatelessWidget {
  const _AmbientBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(-.78, -.82),
          radius: 1.35,
          colors: [
            scheme.primary.withValues(alpha: .2),
            scheme.surface.withValues(alpha: 0),
          ],
        ),
      ),
      child: CustomPaint(painter: _GridPainter(scheme.outlineVariant)),
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: .08)
      ..strokeWidth = 1;
    const gap = 48.0;
    for (var x = 0.0; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y < size.height; y += gap) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _FeatureChip extends StatelessWidget {
  const _FeatureChip(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
    decoration: BoxDecoration(
      color: Theme.of(
        context,
      ).colorScheme.surfaceContainer.withValues(alpha: .8),
      borderRadius: BorderRadius.circular(100),
      border: Border.all(
        color: Theme.of(
          context,
        ).colorScheme.outlineVariant.withValues(alpha: .5),
      ),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17),
        const SizedBox(width: 7),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

class _HostStatus extends StatelessWidget {
  const _HostStatus({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: .85),
      borderRadius: BorderRadius.circular(100),
      border: Border.all(color: color.withValues(alpha: .35)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        const Text(
          '主机可连接',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 9),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}
