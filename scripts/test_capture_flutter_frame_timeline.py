import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture_flutter_frame_timeline as capture  # noqa: E402


class CaptureFlutterFrameTimelineTest(unittest.TestCase):
    def test_websocket_uri_preserves_auth_path(self):
        self.assertEqual(
            capture.websocket_uri('http://127.0.0.1:1234/token/'),
            'ws://127.0.0.1:1234/token/ws',
        )

    def test_summary_pairs_ui_and_raster_begin_end_events(self):
        summary = capture.summarize_timeline(
            {
                'timeOriginMicros': 10,
                'timeExtentMicros': 100,
                'traceEvents': [
                    {'name': 'Frame', 'cat': 'Dart', 'tid': 1, 'ph': 'b', 'id': 'frame-1', 'ts': 100},
                    {'name': 'Frame', 'cat': 'Dart', 'tid': 1, 'ph': 'e', 'id': 'frame-1', 'ts': 300},
                    {'name': 'LAYOUT', 'cat': 'Dart', 'tid': 1, 'ph': 'B', 'ts': 100},
                    {'name': 'LAYOUT', 'cat': 'Dart', 'tid': 1, 'ph': 'E', 'ts': 300},
                    {'name': 'GPURasterizer::Draw', 'cat': 'Embedder', 'tid': 2, 'ph': 'B', 'ts': 100},
                    {'name': 'GPURasterizer::Draw', 'cat': 'Embedder', 'tid': 2, 'ph': 'E', 'ts': 500},
                ],
            }
        )
        self.assertEqual(summary['ui_p95_ms'], 0.2)
        self.assertEqual(summary['raster_p95_ms'], 0.4)
        self.assertEqual(summary['frame_p95_ms'], 0.2)
        self.assertEqual(summary['raster_frame_p95_ms'], 0.4)
        self.assertTrue(summary['ui_raster_evidence_complete'])


if __name__ == '__main__':
    unittest.main()
