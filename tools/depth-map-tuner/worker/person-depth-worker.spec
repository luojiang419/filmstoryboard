# -*- mode: python ; coding: utf-8 -*-

from pathlib import Path

from PyInstaller.utils.hooks import collect_submodules


project_root = Path(SPECPATH)
hiddenimports = (
    collect_submodules("transformers.models.depth_anything")
    + collect_submodules("transformers.models.dinov2")
    + [
        "cv2",
        "einops",
        "numpy",
        "PIL.Image",
        "PIL.ImageOps",
        "safetensors.torch",
        "timm.layers",
        "torchvision.models",
        "torchvision.models.resnet",
        "torchvision.models.vgg",
        "torchvision.ops",
        "torchvision.ops.deform_conv",
        "torchvision.transforms",
    ]
)

a = Analysis(
    [str(project_root / "worker.py")],
    pathex=[str(project_root)],
    binaries=[],
    datas=[],
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        "pytest",
        "tkinter",
        "tensorflow",
        "tensorboard",
        "jax",
        "flax",
        "datasets",
        "librosa",
        "soundfile",
        "kornia",
        "torchcodec",
        "pydub",
        "soxr",
        "boto3",
        "botocore",
        "bitsandbytes",
        "yt_dlp",
        "sqlalchemy",
        "fastapi",
        "uvicorn",
        "onnxruntime",
        "scipy",
        "pandas",
        "pyarrow",
        "matplotlib",
        "sklearn",
        "torchaudio",
        "Crypto",
        "Cryptodome",
    ],
    noarchive=False,
    optimize=1,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="person-depth-worker",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    name="person-depth-worker",
)
