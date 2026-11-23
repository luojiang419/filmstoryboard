from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import sys
import tempfile
import traceback
import types
from pathlib import Path
from typing import Any


WORKER_VERSION = "1.1.0"
PROTOCOL_VERSION = 1
DEPTH_INPUT_SIZE = 1078
MASK_INPUT_SIZE = 1024
TRUSTED_BIREFNET_FILES = {
    "BiRefNet_config.py": "e7b8c2a74f6cea6a59553d517f71d47f2c1d90e670a13416af17c25fe2f3dc52",
    "birefnet.py": "208771ae626f653d64128fbf2d6ac9f8e645c5cc5e286258a73ec3322bbfe5ef",
    "config.json": "c97ea21569daf66b205491a4635147dd3bc42c7c168b89d7d75b53f67ef548ae",
}


def validate_trusted_birefnet_code(
    model_path: Path,
    expected_hashes: dict[str, str] = TRUSTED_BIREFNET_FILES,
) -> None:
    root = Path(model_path).resolve()
    for relative, expected in expected_hashes.items():
        path = (root / relative).resolve()
        try:
            path.relative_to(root)
        except ValueError as exc:
            raise RuntimeError(f"BiRefNet 受信文件路径越界：{relative}") from exc
        if not path.is_file():
            raise RuntimeError(f"BiRefNet 受信文件缺失：{relative}")
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if not hmac.compare_digest(actual, expected):
            raise RuntimeError(f"BiRefNet 受信文件 SHA-256 不匹配：{relative}")


def install_birefnet_inference_compat() -> None:
    """Provide the training-only Kornia symbol without importing Kornia's JIT modules."""

    if "kornia.filters" in sys.modules:
        return
    package = types.ModuleType("kornia")
    package.__path__ = []
    filters = types.ModuleType("kornia.filters")

    def training_only_laplacian(*_args: Any, **_kwargs: Any) -> None:
        raise RuntimeError("BiRefNet worker 仅支持推理，不能调用训练期 Laplacian 分支")

    filters.laplacian = training_only_laplacian
    package.filters = filters
    sys.modules["kornia"] = package
    sys.modules["kornia.filters"] = filters


class PersonDepthEngine:
    def __init__(self, component_root: Path) -> None:
        self.component_root = Path(component_root).resolve()
        self.depth_model_path = self.component_root / "models" / "depth-anything-v2-large"
        self.mask_model_path = self.component_root / "models" / "birefnet"
        self._depth_processor = None
        self._depth_model = None
        self._mask_model = None
        self._device = None
        self._dtype = None

    def _load(self) -> None:
        if self._depth_model is not None:
            return
        import torch
        from transformers import AutoImageProcessor, AutoModelForDepthEstimation, AutoModelForImageSegmentation

        if not self.depth_model_path.is_dir() or not self.mask_model_path.is_dir():
            raise RuntimeError("person-depth 模型目录不完整")
        validate_trusted_birefnet_code(self.mask_model_path)
        install_birefnet_inference_compat()
        self._device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        self._dtype = torch.float16 if self._device.type == "cuda" else torch.float32
        self._depth_processor = AutoImageProcessor.from_pretrained(
            self.depth_model_path,
            local_files_only=True,
        )
        self._depth_processor.size = {"height": DEPTH_INPUT_SIZE, "width": DEPTH_INPUT_SIZE}
        self._depth_model = AutoModelForDepthEstimation.from_pretrained(
            self.depth_model_path,
            local_files_only=True,
            dtype=self._dtype,
        ).to(self._device).eval()
        self._mask_model = AutoModelForImageSegmentation.from_pretrained(
            self.mask_model_path,
            local_files_only=True,
            trust_remote_code=True,
            dtype=self._dtype,
        ).to(self._device).eval()

    @staticmethod
    def _normalize_foreground_depth(depth, mask):
        import numpy as np

        foreground = depth[mask > 0.5]
        if foreground.size < 16:
            foreground = depth.reshape(-1)
        low, high = np.percentile(foreground, (1.0, 99.0))
        return np.clip((depth - low) / max(float(high - low), 1e-6), 0.0, 1.0).astype(np.float32)

    def estimate(
        self,
        input_path: Path,
        output_path: Path,
        bit_depth: int,
        subject: str = "person",
    ) -> dict[str, int | str]:
        import cv2
        import numpy as np
        import torch
        from PIL import Image, ImageOps
        from torchvision.transforms import Compose, Normalize, Resize, ToTensor

        if bit_depth not in {8, 16}:
            raise ValueError("bit_depth 只支持 8 或 16")
        if subject not in {"person", "scene"}:
            raise ValueError("subject 只支持 person 或 scene")
        self._load()
        with Image.open(input_path) as source:
            image = ImageOps.exif_transpose(source).convert("RGB")
            image.load()
        inputs = self._depth_processor(images=image, return_tensors="pt")
        pixel_values = inputs["pixel_values"].to(device=self._device, dtype=self._dtype)
        with torch.inference_mode():
            if self._device.type == "cuda":
                with torch.autocast(device_type="cuda", dtype=torch.float16):
                    prediction = self._depth_model(pixel_values=pixel_values).predicted_depth
            else:
                prediction = self._depth_model(pixel_values=pixel_values).predicted_depth
        depth = torch.nn.functional.interpolate(
            prediction.unsqueeze(1),
            size=(image.height, image.width),
            mode="bicubic",
            align_corners=False,
        ).squeeze().float().cpu().numpy()

        if subject == "person":
            transform = Compose(
                [
                    Resize((MASK_INPUT_SIZE, MASK_INPUT_SIZE)),
                    ToTensor(),
                    Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
                ]
            )
            tensor = transform(image).unsqueeze(0).to(device=self._device, dtype=self._dtype)
            with torch.inference_mode():
                if self._device.type == "cuda":
                    with torch.autocast(device_type="cuda", dtype=torch.float16):
                        logits = self._mask_model(tensor)[-1]
                else:
                    logits = self._mask_model(tensor)[-1]
            mask = torch.sigmoid(logits)[0, 0].float().cpu().numpy()
            mask = np.clip(
                cv2.resize(mask, (image.width, image.height), interpolation=cv2.INTER_CUBIC),
                0.0,
                1.0,
            )
            normalized = self._normalize_foreground_depth(depth, mask)
            alpha = np.clip((mask - 0.03) / 0.92, 0.0, 1.0)
            output_depth = normalized * alpha
        else:
            scene_mask = np.ones(depth.shape, dtype=np.float32)
            output_depth = self._normalize_foreground_depth(depth, scene_mask)
        maximum = 65535 if bit_depth == 16 else 255
        dtype = np.uint16 if bit_depth == 16 else np.uint8
        encoded_data = np.round(output_depth * maximum).astype(dtype)
        success, encoded = cv2.imencode(".png", encoded_data)
        if not success:
            raise RuntimeError("高精度人物深度 PNG 编码失败")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        encoded.tofile(output_path)
        return {
            "width": image.width,
            "height": image.height,
            "bit_depth": bit_depth,
            "subject": subject,
        }

    def smoke(self) -> None:
        from PIL import Image

        with tempfile.TemporaryDirectory(prefix="person-depth-smoke-") as temp_root:
            root = Path(temp_root)
            source = root / "input.png"
            output = root / "output.png"
            Image.new("RGB", (64, 96), (127, 127, 127)).save(source)
            result = self.estimate(source, output, 8)
            if result["width"] != 64 or result["height"] != 96 or not output.is_file():
                raise RuntimeError("person-depth smoke 输出不符合协议")


def write_response(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def run_stdio(engine: PersonDepthEngine) -> int:
    for line in sys.stdin:
        request_id = ""
        try:
            request = json.loads(line)
            request_id = str(request.get("id") or "")
            operation = str(request.get("op") or "")
            if operation == "shutdown":
                return 0
            if operation == "hello":
                write_response(
                    {
                        "id": request_id,
                        "ok": True,
                        "worker_version": WORKER_VERSION,
                        "protocol_version": PROTOCOL_VERSION,
                    }
                )
                continue
            if operation == "smoke":
                engine.smoke()
                write_response({"id": request_id, "ok": True})
                continue
            if operation != "estimate":
                raise ValueError("不支持的 worker 操作")
            result = engine.estimate(
                Path(str(request.get("input") or "")),
                Path(str(request.get("output") or "")),
                int(request.get("bit_depth") or 8),
                str(request.get("subject") or "person"),
            )
            write_response({"id": request_id, "ok": True, **result})
        except Exception as exc:  # noqa: BLE001
            traceback.print_exc(file=sys.stderr)
            write_response({"id": request_id, "ok": False, "error": str(exc) or exc.__class__.__name__})
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--component-root", type=Path, default=Path.cwd())
    parser.add_argument("--stdio", action="store_true")
    parser.add_argument("--smoke-test", action="store_true")
    args = parser.parse_args()
    engine = PersonDepthEngine(args.component_root)
    if args.smoke_test:
        engine.smoke()
        return 0
    if args.stdio:
        return run_stdio(engine)
    parser.error("必须指定 --stdio 或 --smoke-test")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
