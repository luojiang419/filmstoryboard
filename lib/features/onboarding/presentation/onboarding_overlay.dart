import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/onboarding_controller.dart';
import '../domain/onboarding_step.dart';

class OnboardingOverlay extends StatelessWidget {
  const OnboardingOverlay({required this.controller, super.key});

  final OnboardingController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final step = controller.currentStep;
    return Positioned.fill(
      key: const ValueKey('onboarding-overlay'),
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): controller.skip,
          const SingleActivator(LogicalKeyboardKey.arrowLeft):
              controller.previous,
          const SingleActivator(LogicalKeyboardKey.arrowRight): controller.next,
        },
        child: Focus(
          autofocus: true,
          child: Material(
            color: Colors.black.withValues(alpha: 0.68),
            child: SafeArea(
              child: Stack(
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 72, 20, 24),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: (constraints.maxHeight - 96)
                                .clamp(0, double.infinity)
                                .toDouble(),
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 560),
                              child: _OnboardingCard(
                                controller: controller,
                                step: step,
                                scheme: scheme,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  Positioned(
                    top: 14,
                    right: 20,
                    child: TextButton.icon(
                      key: const ValueKey('onboarding-skip'),
                      onPressed: controller.skip,
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('跳过引导'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white.withValues(alpha: 0.82),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OnboardingCard extends StatelessWidget {
  const _OnboardingCard({
    required this.controller,
    required this.step,
    required this.scheme,
  });

  final OnboardingController controller;
  final OnboardingStep step;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(30, 26, 30, 24),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.primary.withValues(alpha: 0.3)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x99000000),
            blurRadius: 42,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '${controller.stepIndex + 1} / ${controller.stepCount}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text(
                '← → 切换 · Esc 跳过',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  scheme.primary.withValues(alpha: 0.2),
                  scheme.tertiary.withValues(alpha: 0.16),
                ],
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(step.section.icon, color: scheme.primary, size: 30),
          ),
          const SizedBox(height: 18),
          Text(
            step.eyebrow,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: scheme.primary,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            step.title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          Text(
            step.body,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
              height: 1.65,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 22),
          _StepDots(
            count: controller.stepCount,
            selectedIndex: controller.stepIndex,
            color: scheme.primary,
          ),
          const SizedBox(height: 22),
          Row(
            children: [
              TextButton.icon(
                key: const ValueKey('onboarding-previous'),
                onPressed: controller.canGoBack ? controller.previous : null,
                icon: const Icon(Icons.arrow_back_rounded),
                label: const Text('上一步'),
              ),
              const Spacer(),
              FilledButton.icon(
                key: const ValueKey('onboarding-next'),
                onPressed: controller.next,
                icon: Icon(
                  controller.isLastStep
                      ? Icons.check_rounded
                      : Icons.arrow_forward_rounded,
                ),
                label: Text(controller.isLastStep ? '开始使用' : '下一步'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepDots extends StatelessWidget {
  const _StepDots({
    required this.count,
    required this.selectedIndex,
    required this.color,
  });

  final int count;
  final int selectedIndex;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var index = 0; index < count; index += 1)
          AnimatedContainer(
            key: ValueKey('onboarding-step-dot-$index'),
            duration: const Duration(milliseconds: 180),
            width: index == selectedIndex ? 24 : 7,
            height: 7,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: index == selectedIndex
                  ? color
                  : color.withValues(alpha: 0.24),
              borderRadius: BorderRadius.circular(99),
            ),
          ),
      ],
    );
  }
}

extension on OnboardingSection {
  IconData get icon => switch (this) {
    OnboardingSection.overview => Icons.auto_awesome_rounded,
    OnboardingSection.design => Icons.draw_rounded,
    OnboardingSection.videoAnalysis => Icons.video_file_rounded,
    OnboardingSection.storyboard => Icons.dashboard_customize_rounded,
    OnboardingSection.shootingScript => Icons.table_chart_rounded,
    OnboardingSection.exporter => Icons.ios_share_rounded,
    OnboardingSection.settings => Icons.tune_rounded,
  };
}
