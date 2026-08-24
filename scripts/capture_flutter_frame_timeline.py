#!/usr/bin/env python3
"""Capture Flutter UI/Raster timeline events from a running Profile VM service.

The script intentionally keeps interaction manual: start the Profile app, run this
script, then scroll/edit in the app during the capture window. It writes the raw
VM timeline and a conservative summary. Missing Flutter/Raster events are reported
as missing evidence instead of being converted into fake P95 values.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterable


DEFAULT_STREAMS = ("Dart", "Embedder", "Flutter", "GC", "Microtask", "API")
PROFILE_EXTENSIONS = (
    "ext.flutter.profileWidgetBuilds",
    "ext.flutter.profileUserWidgetBuilds",
    "ext.flutter.profileRenderObjectLayouts",
    "ext.flutter.profileRenderObjectPaints",
)


def websocket_uri(vm_service_uri: str) -> str:
    """Convert the printed VM service HTTP URI into its authenticated WS URI."""
    parsed = urllib.parse.urlparse(vm_service_uri)
    if parsed.scheme in ("ws", "wss"):
        return vm_service_uri.rstrip("/")
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"不支持的 VM Service 地址：{vm_service_uri}")
    scheme = "wss" if parsed.scheme == "https" else "ws"
    path = parsed.path.rstrip("/") + "/ws"
    return urllib.parse.urlunparse((scheme, parsed.netloc, path, "", parsed.query, ""))


def http_endpoint(vm_service_uri: str, method: str, query: dict[str, Any] | None = None) -> str:
    parsed = urllib.parse.urlparse(vm_service_uri)
    path = parsed.path.rstrip("/") + "/" + method.lstrip("/")
    params = dict(urllib.parse.parse_qsl(parsed.query))
    if query:
        params.update({key: str(value) for key, value in query.items()})
    return urllib.parse.urlunparse(
        (parsed.scheme, parsed.netloc, path, "", urllib.parse.urlencode(params), "")
    )


async def rpc_call(websocket: Any, request_id: int, method: str, params: dict[str, Any]) -> dict[str, Any]:
    await websocket.send(json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}))
    while True:
        message = json.loads(await websocket.recv())
        if message.get("id") != request_id:
            continue
        if "error" in message:
            raise RuntimeError(f"VM Service {method} 失败：{message['error']}")
        return message.get("result", {})


async def configure_timeline(vm_service_uri: str, streams: Iterable[str]) -> dict[str, Any]:
    try:
        import websockets
    except ImportError as exc:  # pragma: no cover - environment guard
        raise RuntimeError("需要 Python websockets 包：python -m pip install websockets") from exc

    result: dict[str, Any] = {"stream_names": list(streams), "extensions": {}}
    async with websockets.connect(websocket_uri(vm_service_uri), open_timeout=10) as websocket:
        vm = await rpc_call(websocket, 1, "getVM", {})
        isolates = vm.get("isolates") or []
        isolate_id = isolates[0].get("id") if isolates else None
        result["isolate_id"] = isolate_id
        flags = await rpc_call(websocket, 2, "getVMTimelineFlags", {})
        available = set(flags.get("availableStreams") or [])
        requested = list(streams)
        selected = [stream for stream in requested if stream in available]
        result["available_streams"] = sorted(available)
        result["unavailable_streams"] = [stream for stream in requested if stream not in available]
        if not selected:
            raise RuntimeError(f"VM Service 没有可用的 Timeline stream：{requested}")
        await rpc_call(websocket, 3, "setVMTimelineFlags", {"recordedStreams": selected})
        result["recorded_streams"] = selected
        await rpc_call(websocket, 4, "clearVMTimeline", {})

        if isolate_id:
            for extension in PROFILE_EXTENSIONS:
                endpoint = http_endpoint(
                    vm_service_uri,
                    extension,
                    {"isolateId": isolate_id, "enabled": "true"},
                )
                try:
                    with urllib.request.urlopen(endpoint, timeout=10) as response:
                        result["extensions"][extension] = response.status == 200
                except Exception as exc:  # noqa: BLE001 - diagnostics must continue
                    result["extensions"][extension] = f"失败：{exc}"
    return result


def fetch_timeline(vm_service_uri: str) -> dict[str, Any]:
    endpoint = http_endpoint(vm_service_uri, "getVMTimeline")
    with urllib.request.urlopen(endpoint, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    # VM Service HTTP returns a JSON-RPC envelope, while the WebSocket RPC
    # returns the result object directly. Normalize both forms for the parser.
    if isinstance(payload, dict) and isinstance(payload.get("result"), dict):
        return payload["result"]
    return payload


def _events(timeline: dict[str, Any]) -> list[dict[str, Any]]:
    events = timeline.get("traceEvents") or timeline.get("events") or []
    return [event for event in events if isinstance(event, dict)]


def _duration_ms(event: dict[str, Any]) -> float | None:
    value = event.get("dur")
    if not isinstance(value, (int, float)) or value <= 0:
        return None
    return float(value) / 1000.0


def _duration_samples(events: list[dict[str, Any]], predicate) -> list[float]:
    """Read X events and pair B/E scoped events into milliseconds."""
    samples: list[float] = []
    starts: dict[tuple[Any, str], list[float]] = {}
    for event in events:
        if not predicate(event):
            continue
        direct = _duration_ms(event)
        if direct is not None:
            samples.append(direct)
            continue
        phase = event.get("ph")
        key = (event.get("tid"), str(event.get("name", "")), event.get("id"))
        timestamp = event.get("ts")
        if not isinstance(timestamp, (int, float)):
            continue
        if phase in ("B", "b"):
            starts.setdefault(key, []).append(float(timestamp))
        elif phase in ("E", "e") and starts.get(key):
            samples.append(max(0.0, float(timestamp) - starts[key].pop()) / 1000.0)
    return samples


def _percentile(values: list[float], percentile: float) -> float | None:
    if not values:
        return None
    values = sorted(values)
    rank = (len(values) - 1) * percentile
    lower, upper = math.floor(rank), math.ceil(rank)
    if lower == upper:
        return round(values[lower], 3)
    return round(values[lower] + (values[upper] - values[lower]) * (rank - lower), 3)


def _is_ui_event(event: dict[str, Any]) -> bool:
    text = f"{event.get('name', '')} {event.get('cat', '')}".lower()
    return any(token in text for token in ("flutter", "frame", "build", "layout", "paint", "pipeline"))


def _is_raster_event(event: dict[str, Any]) -> bool:
    text = f"{event.get('name', '')} {event.get('cat', '')}".lower()
    return any(token in text for token in ("raster", "gpu", "compositor", "scene_display"))


def _is_frame_event(event: dict[str, Any]) -> bool:
    return str(event.get("name", "")) in {
        "Frame",
        "Animator::BeginFrame",
        "Animator::Render",
    }


def _is_raster_frame_event(event: dict[str, Any]) -> bool:
    return str(event.get("name", "")) in {
        "CompositorContext::ScopedFrame::Raster",
        "GPURasterizer::Draw",
    }


def summarize_timeline(timeline: dict[str, Any]) -> dict[str, Any]:
    events = _events(timeline)
    ui_durations = _duration_samples(events, _is_ui_event)
    raster_durations = _duration_samples(events, _is_raster_event)
    frame_durations = _duration_samples(events, _is_frame_event)
    raster_frame_durations = _duration_samples(events, _is_raster_frame_event)
    return {
        "event_count": len(events),
        "time_origin_micros": timeline.get("timeOriginMicros"),
        "time_extent_micros": timeline.get("timeExtentMicros"),
        "ui_event_count": sum(1 for event in events if _is_ui_event(event)),
        "raster_event_count": sum(1 for event in events if _is_raster_event(event)),
        "ui_p95_ms": _percentile(ui_durations, 0.95),
        "raster_p95_ms": _percentile(raster_durations, 0.95),
        "frame_event_count": len(frame_durations),
        "frame_p95_ms": _percentile(frame_durations, 0.95),
        "raster_frame_event_count": len(raster_frame_durations),
        "raster_frame_p95_ms": _percentile(raster_frame_durations, 0.95),
        "ui_raster_evidence_complete": bool(frame_durations and raster_frame_durations),
        "event_name_samples": sorted({str(event.get("name", "")) for event in events})[:80],
    }


def write_capture(output_dir: Path, config: dict[str, Any], timeline: dict[str, Any]) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    summary = summarize_timeline(timeline)
    summary["capture"] = config
    (output_dir / "timeline.json").write_text(json.dumps(timeline, ensure_ascii=False, indent=2), encoding="utf-8")
    (output_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    ui = summary["frame_p95_ms"]
    raster = summary["raster_frame_p95_ms"]
    lines = [
        "# Flutter Profile 帧事件采集",
        "",
        f"采集事件数：{summary['event_count']}",
        f"UI Frame 事件：{summary['frame_event_count']}，P95：{ui if ui is not None else '无证据'} ms",
        f"Raster Frame 事件：{summary['raster_frame_event_count']}，P95：{raster if raster is not None else '无证据'} ms",
        "",
        "只有同时采集到带持续时间的 UI 与 Raster 事件，`ui_raster_evidence_complete` 才为 true。",
        "本报告不把 Dart/API 事件耗时替代 Flutter UI/Raster 帧耗时。",
        "",
        "原始数据：`timeline.json`；机器可读摘要：`summary.json`。",
    ]
    (output_dir / "README.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="采集运行中 Flutter Profile 应用的 UI/Raster VM Timeline 事件")
    parser.add_argument("--vm-service-uri", required=True, help="flutter run --profile 输出的 VM Service HTTP/WS 地址")
    parser.add_argument("--output-dir", required=True, type=Path, help="采集结果输出目录")
    parser.add_argument("--scenario", default="manual", help="固定交互场景名称，写入采集摘要")
    parser.add_argument("--duration-seconds", type=float, default=20.0, help="保留给人工滚动/编辑的采集窗口，默认 20 秒")
    parser.add_argument("--streams", nargs="+", default=list(DEFAULT_STREAMS), help="recordedStreams，默认包含 Flutter/Embedder")
    return parser.parse_args()


async def main() -> int:
    args = parse_args()
    started_at = time.time()
    config = {
        "vm_service_uri": args.vm_service_uri,
        "scenario": args.scenario,
        "duration_seconds": args.duration_seconds,
        "streams": args.streams,
        "started_at_unix": started_at,
    }
    try:
        config.update(await configure_timeline(args.vm_service_uri, args.streams))
        print(f"已连接 VM Service，isolate={config.get('isolate_id')}。请在 {args.duration_seconds:g} 秒内滚动或编辑页面。")
        await asyncio.sleep(max(args.duration_seconds, 0))
        timeline = fetch_timeline(args.vm_service_uri)
        write_capture(args.output_dir, config, timeline)
        summary = summarize_timeline(timeline)
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001 - command line diagnostics
        print(f"帧事件采集失败：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
