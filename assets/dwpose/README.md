# DWPose bundled models

FilmStoryboard bundles the following DWPose inference weights so the Windows
application can run pose extraction without a separate download step:

- `models/yolox_l.onnx`
  - Source: `https://huggingface.co/yzd-v/DWPose/resolve/main/yolox_l.onnx`
  - Size: `216746733` bytes
  - SHA-256: `7860ae79de6c89a3c1eb72ae9a2756c0ccfbe04b7791bb5880afabd97855a411`
- `models/dw-ll_ucoco_384.onnx`
  - Source: `https://huggingface.co/yzd-v/DWPose/resolve/main/dw-ll_ucoco_384.onnx`
  - Size: `134399116` bytes
  - SHA-256: `724f4ff2439ed61afb86fb8a1951ec39c6220682803b4a8bd4f598cd913b1843`

The model repository declares the Apache License 2.0. The ONNX files are kept
in Git LFS because `yolox_l.onnx` exceeds GitHub's regular file size limit.
