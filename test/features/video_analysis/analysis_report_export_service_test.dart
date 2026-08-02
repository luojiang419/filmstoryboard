import 'dart:io';

import 'package:archive/archive.dart';
import 'package:filmstoryboard/features/video_analysis/data/analysis_report_export_service.dart';
import 'package:filmstoryboard/features/video_analysis/domain/video_analysis_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('分析报告导出 XLSX/PDF/PNG/JPG 且 XLSX 包含四个工作表', () async {
    final root = await Directory.systemTemp.createTemp('analysis_report_');
    addTearDown(() => root.delete(recursive: true));
    final fixture = _fixture();
    const service = AnalysisReportExportService();

    final xlsx = await service.export(
      format: AnalysisReportFormat.xlsx,
      outputDirectory: root,
      video: fixture.video,
      frames: fixture.frames,
      frameAnalyses: fixture.analyses,
      summary: fixture.summary,
      marketingAnalyses: fixture.marketing,
    );
    final archive = ZipDecoder().decodeBytes(
      await xlsx.files.single.readAsBytes(),
    );
    final names = archive.map((entry) => entry.name).toSet();
    expect(
      names,
      containsAll([
        'xl/worksheets/sheet1.xml',
        'xl/worksheets/sheet2.xml',
        'xl/worksheets/sheet3.xml',
        'xl/worksheets/sheet4.xml',
      ]),
    );

    final pdf = await service.export(
      format: AnalysisReportFormat.pdf,
      outputDirectory: root,
      video: fixture.video,
      frames: fixture.frames,
      frameAnalyses: fixture.analyses,
      summary: fixture.summary,
      marketingAnalyses: fixture.marketing,
    );
    expect(
      String.fromCharCodes((await pdf.files.single.readAsBytes()).take(4)),
      '%PDF',
    );

    final png = await service.export(
      format: AnalysisReportFormat.png,
      outputDirectory: root,
      video: fixture.video,
      frames: fixture.frames,
      frameAnalyses: fixture.analyses,
      summary: fixture.summary,
      marketingAnalyses: fixture.marketing,
    );
    expect(png.files.length, greaterThanOrEqualTo(2));
    expect((await png.files.first.readAsBytes()).take(8), [
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
    ]);
    expect(png.files.first.path, contains('第01页.png'));

    final jpg = await service.export(
      format: AnalysisReportFormat.jpg,
      outputDirectory: root,
      video: fixture.video,
      frames: fixture.frames,
      frameAnalyses: fixture.analyses,
      summary: fixture.summary,
      marketingAnalyses: fixture.marketing,
    );
    expect((await jpg.files.first.readAsBytes()).take(2), [0xFF, 0xD8]);
    expect(jpg.files.first.path, contains('第01页.jpg'));
  });
}

_ReportFixture _fixture() {
  final now = DateTime.utc(2026, 8, 2);
  final video = SourceVideo(
    id: 'video-1',
    originalPath: r'C:\input\demo.mp4',
    fileName: 'demo.mp4',
    storedPath: 'videos/demo/video.mp4',
    durationMs: 5000,
    frameRate: 25,
    width: 1920,
    height: 1080,
    hasAudio: true,
    frameCount: 1,
    successfulFrames: 1,
    failedFrames: 0,
    status: ProcessingStatus.completed,
    errorMessage: '',
    createdAt: now,
    updatedAt: now,
  );
  final frame = VideoFrame(
    id: 'frame-1',
    videoId: video.id,
    index: 0,
    timestampMs: 0,
    path: 'frames/demo/00001.jpg',
    width: 1920,
    height: 1080,
    sharpness: 0.8,
    brightness: 0.5,
    motionScore: 0,
    perceptualHash: '0123456789abcdef',
    isFocus: true,
    isSelected: true,
    status: ProcessingStatus.completed,
    errorMessage: '',
    createdAt: now,
  );
  final analysis = VideoFrameAnalysis(
    id: 'analysis-1',
    videoId: video.id,
    frameId: frame.id,
    sequenceNo: 1,
    dimensions: const {
      'caption': '女模特在明亮厨房中拿起产品，镜头聚焦包装。',
      'scene': '明亮厨房',
      'people': '女模特',
      'bodyAction': '拿起产品',
      'shotSize': '中景',
      'cameraMovement': '缓慢推近',
      'composition': '主体居中',
    },
    rawResponse: '{"caption":"测试"}',
    status: ProcessingStatus.completed,
    errorMessage: '',
    createdAt: now,
    updatedAt: now,
  );
  final summary = VideoSummary(
    id: 'summary-1',
    videoId: video.id,
    fields: const {'outline': '展示产品并强调包装细节', 'content': '女模特在厨房展示产品。'},
    rawResponse: '{"outline":"测试"}',
    status: ProcessingStatus.completed,
    errorMessage: '',
    updatedAt: now,
  );
  final marketing = MarketingAnalysis(
    id: 'marketing-1',
    videoId: video.id,
    scope: 'video',
    dimensions: {
      for (final group in videoAnalysisDimensionGroups.values)
        for (final field in group) field: '$field 的专业分析结果',
    },
    rawResponse: '{}',
    status: ProcessingStatus.completed,
    errorMessage: '',
    createdAt: now,
    updatedAt: now,
  );
  return _ReportFixture(
    video: video,
    frames: [frame],
    analyses: [analysis],
    summary: summary,
    marketing: [marketing],
  );
}

class _ReportFixture {
  const _ReportFixture({
    required this.video,
    required this.frames,
    required this.analyses,
    required this.summary,
    required this.marketing,
  });

  final SourceVideo video;
  final List<VideoFrame> frames;
  final List<VideoFrameAnalysis> analyses;
  final VideoSummary summary;
  final List<MarketingAnalysis> marketing;
}
