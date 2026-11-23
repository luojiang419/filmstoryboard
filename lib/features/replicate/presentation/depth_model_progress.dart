import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/person_depth_models.dart';

class DepthModelProgressPanel extends StatelessWidget {
  const DepthModelProgressPanel({super.key, required this.progress});
  final ValueListenable<DepthModelProgress?> progress;

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<DepthModelProgress?>(
    valueListenable: progress,
    builder: (context, value, child) {
      if (value == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(value.message)),
                Text(
                  '${value.percent}%',
                  key: const ValueKey('depth-model-percent'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: value.fraction, minHeight: 6),
            const SizedBox(height: 4),
            Text(
              '${(value.received / 1000000).toStringAsFixed(1)} / ${(value.total / 1000000).toStringAsFixed(1)} MB · 下载中断后可重新提取继续下载',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    },
  );
}
