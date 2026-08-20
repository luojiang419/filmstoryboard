import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:filmstoryboard/features/bridge/data/bridge_package_service.dart';
import 'package:filmstoryboard/features/bridge/domain/bridge_manifest.dart';

void main() {
  test('exports film storyboard frames as a verified bridge package', () async {
    final directory = await Directory.systemTemp.createTemp('bridge-test-');
    addTearDown(() => directory.delete(recursive: true));
    final frame = File('${directory.path}/frame.png')
      ..writeAsBytesSync(const <int>[
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
        0,
        0,
        0,
        13,
        73,
        72,
        68,
        82,
        0,
        0,
        0,
        1,
        0,
        0,
        0,
        1,
        8,
        6,
        0,
        0,
        0,
        31,
        21,
        196,
        137,
        0,
        0,
        0,
        13,
        73,
        68,
        65,
        84,
        120,
        156,
        99,
        248,
        207,
        192,
        240,
        31,
        0,
        3,
        3,
        1,
        0,
        24,
        221,
        141,
        181,
        0,
        0,
        0,
        0,
        73,
        69,
        78,
        68,
        174,
        66,
        96,
        130,
      ]);
    final output = File('${directory.path}/export.filmbridge.zip');
    await const BridgePackageService().exportFilmToShiyin(
      outputFile: output,
      projectId: 'project-1',
      projectName: '测试工程',
      boardId: 'board-1',
      boardName: '测试故事板',
      frames: [
        BridgeFrameSource(
          path: frame,
          sourceName: '镜头 01',
          slotIndex: 0,
          shotNumber: 1,
          frameIndex: 0,
          timestampMs: 250,
          width: 1,
          height: 1,
        ),
      ],
    );
    expect(output.existsSync(), isTrue);
    final archive = ZipDecoder().decodeBytes(await output.readAsBytes());
    final manifestFile = archive.findFile('manifest.json');
    expect(manifestFile, isNotNull);
    final manifest =
        jsonDecode(utf8.decode(manifestFile!.content)) as Map<String, Object?>;
    expect(manifest['schema'], bridgeSchema);
    expect(manifest['direction'], 'film-to-shiyin');
    expect((manifest['storyboard'] as Map)['frames'], hasLength(1));
    expect(archive.findFile('images/original/0001.png'), isNotNull);
    expect(archive.findFile('checksums.json'), isNotNull);
  });

  test('rejects missing storyboard files', () async {
    final directory = await Directory.systemTemp.createTemp('bridge-test-');
    addTearDown(() => directory.delete(recursive: true));
    expect(
      () => const BridgePackageService().exportFilmToShiyin(
        outputFile: File('${directory.path}/export.zip'),
        projectId: 'project-1',
        projectName: '测试工程',
        boardId: 'board-1',
        boardName: '测试故事板',
        frames: [
          BridgeFrameSource(
            path: File('${directory.path}/missing.png'),
            sourceName: '镜头 01',
            slotIndex: 0,
            shotNumber: 1,
            frameIndex: 0,
            timestampMs: 0,
            width: 1,
            height: 1,
          ),
        ],
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
