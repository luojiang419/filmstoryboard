import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

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

  test('imports selected SHIYIN variant and parses shot fields', () async {
    final directory = await Directory.systemTemp.createTemp('bridge-import-');
    addTearDown(() => directory.delete(recursive: true));
    final imageBytes = File('${directory.path}/frame.png')
      ..writeAsBytesSync(img.encodePng(img.Image(width: 1, height: 1)));
    final bytes = await imageBytes.readAsBytes();
    final relativePath = 'images/line-art/0001.png';
    final checksum = sha256.convert(bytes).toString();
    final manifest = BridgeManifest(
      bridgeId: 'film:project-1:board-1',
      direction: BridgeDirection.shiyinToFilm,
      exportedAt: DateTime.now().toUtc(),
      source: const {'app': 'shiyin-ai', 'board_id': 'board-1'},
      boardName: '线稿故事板',
      selectedVariant: BridgeVariant.lineArt,
      variants: const [BridgeVariant.lineArt],
      frames: [
        BridgeFrameRecord(
          stableId: 'frame:board-1:0000:line-art',
          shotStableId: 'shot:board-1:1',
          slotIndex: 0,
          shotNumber: 1,
          frameIndex: 0,
          timestampMs: 0,
          sourceName: '线稿 01',
          relativePath: relativePath,
          width: 1,
          height: 1,
          variant: BridgeVariant.lineArt,
          sha256: checksum,
        ),
      ],
      shots: const [
        BridgeShotRecord(
          stableId: 'shot:board-1:1',
          shotNumber: 1,
          frameStableId: 'frame:board-1:0000:line-art',
          fields: {'prompt': '人物转身', 'shot_size': '中景'},
        ),
      ],
      checksums: {relativePath: checksum},
    );
    final archive = Archive()
      ..addFile(ArchiveFile.bytes(relativePath, bytes))
      ..addFile(
        ArchiveFile.bytes('manifest.json', utf8.encode(manifest.encode())),
      )
      ..addFile(
        ArchiveFile.bytes(
          'checksums.json',
          utf8.encode(jsonEncode({relativePath: checksum})),
        ),
      );
    final package = File('${directory.path}/return.filmbridge.zip')
      ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    final result = await const BridgePackageService().importShiyinToFilm(
      packageFile: package,
      destinationRoot: Directory('${directory.path}/imports'),
    );
    expect(result.frames, hasLength(1));
    expect(result.frames.single.file.existsSync(), isTrue);
    expect(
      p.basename(result.frames.single.file.path),
      contains(checksum.substring(0, 16)),
    );
    final repeated = await const BridgePackageService().importShiyinToFilm(
      packageFile: package,
      destinationRoot: Directory('${directory.path}/imports'),
    );
    expect(repeated.frames.single.file.path, result.frames.single.file.path);
    expect(repeated.obsoleteFiles, isEmpty);
    expect(result.manifest.shots.single.fields['prompt'], '人物转身');
    expect(result.manifest.selectedVariant, BridgeVariant.lineArt);
  });
}
