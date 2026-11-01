#!/bin/bash
# Downloads the X-Ray face models (OpenCV Zoo, Apache-2.0) into functions/models, checking their hashes.
# They are not in git; firebase.json runs this before every functions deploy.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p models
fetch() { # name url sha256
  if [ -f "models/$1" ] && echo "$3  models/$1" | shasum -a 256 -c --status; then return; fi
  curl -fsSL -o "models/$1.part" "$2"
  echo "$3  models/$1.part" | shasum -a 256 -c --status || { echo "fetch-models: $1 hash mismatch" >&2; rm -f "models/$1.part"; exit 1; }
  mv "models/$1.part" "models/$1"
}
ZOO=https://github.com/opencv/opencv_zoo/raw/main/models
fetch yunet.onnx "$ZOO/face_detection_yunet/face_detection_yunet_2023mar.onnx" 8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4
fetch sface.onnx "$ZOO/face_recognition_sface/face_recognition_sface_2021dec.onnx" 0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
