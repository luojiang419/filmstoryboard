#!/usr/bin/env python3
"""Run repeatable, read-only Windows Profile interaction scenarios.

The runner attaches to an already visible Flutter Windows Profile window,
starts the VM timeline capture tool, and performs only tab selection, card
selection, and scrolling. It never types, deletes, or edits project data.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


SCENARIOS: dict[str, tuple[str, tuple[tuple[Any, ...], ...]]] = {
    "video-analysis-grid-scroll": (
        "视频解析网格滚动与卡片选择",
        (
            ("click", 0.15, 0.91),
            ("sleep", 2.0),
            ("click", 0.39, 0.43),
            ("sleep", 0.5),
            ("scroll", 0.50, 0.56, -900, 6),
            ("sleep", 0.5),
            ("scroll", 0.50, 0.56, 900, 3),
        ),
    ),
    "video-analysis-detail-switch": (
        "视频解析多卡片选择与右侧详情切换",
        (
            ("click", 0.15, 0.91),
            ("sleep", 2.0),
            ("click", 0.39, 0.43),
            ("sleep", 0.5),
            ("click", 0.56, 0.43),
            ("sleep", 0.5),
            ("click", 0.46, 0.63),
            ("sleep", 0.5),
            ("click", 0.62, 0.63),
        ),
    ),
    "shooting-script-list-scroll": (
        "拍摄脚本章节镜头列表滚动与选择",
        (
            ("click", 0.32, 0.91),
            ("sleep", 2.0),
            ("click", 0.18, 0.43),
            ("sleep", 0.5),
            ("scroll", 0.18, 0.56, -900, 6),
            ("sleep", 0.5),
            ("scroll", 0.18, 0.56, 900, 3),
        ),
    ),
    "shooting-script-detail-switch": (
        "拍摄脚本镜头选择与右侧详情切换",
        (
            ("click", 0.32, 0.91),
            ("sleep", 2.0),
            ("click", 0.43, 0.45),
            ("sleep", 0.5),
            ("click", 0.62, 0.45),
            ("sleep", 0.5),
            ("click", 0.78, 0.45),
        ),
    ),
}


def _attach_window(title_regex: str):
    try:
        from pywinauto import Desktop
    except ImportError as exc:  # pragma: no cover - environment guard
        raise RuntimeError("需要 pywinauto：python -m pip install pywinauto") from exc
    window = Desktop(backend="uia").window(title_re=title_regex)
    if not window.exists(timeout=3):
        raise RuntimeError(f"找不到 Flutter Profile 窗口：{title_regex}")
    window.set_focus()
    return window


def _point(window, x_ratio: float, y_ratio: float) -> tuple[int, int]:
    rect = window.rectangle()
    return (
        int(rect.width() * x_ratio),
        int(rect.height() * y_ratio),
    )


def _screen_point(window, x_ratio: float, y_ratio: float) -> tuple[int, int]:
    rect = window.rectangle()
    return (
        int(rect.left + rect.width() * x_ratio),
        int(rect.top + rect.height() * y_ratio),
    )


def _run_action(window, action: tuple[Any, ...]) -> None:
    kind = action[0]
    if kind == "sleep":
        time.sleep(float(action[1]))
        return
    point = _point(window, float(action[1]), float(action[2]))
    if kind == "click":
        window.click_input(coords=point)
    elif kind == "scroll":
        from pywinauto import mouse

        scroll_point = _screen_point(window, float(action[1]), float(action[2]))
        mouse.scroll(coords=scroll_point, wheel_dist=int(action[3]))
        for _ in range(int(action[4]) - 1):
            time.sleep(0.22)
            mouse.scroll(coords=scroll_point, wheel_dist=int(action[3]))
    else:
        raise ValueError(f"未知场景动作：{kind}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="运行只读的 Flutter Windows Profile 固定交互场景")
    parser.add_argument("--list", action="store_true", help="列出场景后退出")
    parser.add_argument("--scenario", choices=sorted(SCENARIOS), help="场景名称")
    parser.add_argument("--vm-service-uri", help="flutter run --profile 输出的 VM Service HTTP 地址")
    parser.add_argument("--output-root", type=Path, default=Path("outputs/profile-scenarios-20260824"))
    parser.add_argument("--duration-seconds", type=float, default=18.0)
    parser.add_argument("--window-title", default="filmstoryboard.*")
    parser.add_argument("--no-capture", action="store_true", help="只执行窗口动作，用于坐标回归，不连接 VM Service")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.list:
        for name, (label, actions) in sorted(SCENARIOS.items()):
            print(f"{name}: {label}（{len(actions)} 个动作）")
        return 0
    if not args.scenario or (not args.vm_service_uri and not args.no_capture):
        raise SystemExit("运行场景必须同时提供 --scenario 和 --vm-service-uri；可先使用 --list")

    window = _attach_window(args.window_title)
    if args.no_capture:
        for action in SCENARIOS[args.scenario][1]:
            _run_action(window, action)
        print(f"场景动作完成（未采集 Timeline）：{args.scenario}")
        return 0

    capture_script = Path(__file__).with_name("capture_flutter_frame_timeline.py")
    output_dir = args.output_root / args.scenario
    command = [
        sys.executable,
        str(capture_script),
        "--vm-service-uri",
        args.vm_service_uri,
        "--output-dir",
        str(output_dir),
        "--duration-seconds",
        str(args.duration_seconds),
        "--scenario",
        args.scenario,
    ]
    process = subprocess.Popen(command)
    time.sleep(2.0)
    try:
        for action in SCENARIOS[args.scenario][1]:
            _run_action(window, action)
    finally:
        return_code = process.wait()
    if return_code != 0:
        raise SystemExit(f"场景采集失败，capture 脚本退出码：{return_code}")
    print(f"场景完成：{args.scenario} -> {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
