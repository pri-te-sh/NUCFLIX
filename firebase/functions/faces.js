// Face detection + recognition for X-Ray, on the function's CPU: OpenCV Zoo's YuNet (detector, 5 landmarks) and
// SFace (128-d embedding), both Apache-2.0, run with onnxruntime. This is a port of OpenCV's FaceDetectorYN and
// FaceRecognizerSF, so embeddings match what cv2 computes for the same image (checked on test frames).
// The models are not in git: fetch-models.sh downloads them into functions/models before a deploy.

import * as ort from 'onnxruntime-node';
import sharp from 'sharp';

const MODELS = new URL('./models/', import.meta.url);
const DET_SIZE = 640; // YuNet 2023mar has a fixed 640x640 input
const STRIDES = [8, 16, 32];
const SCORE_MIN = 0.6;
const NMS_IOU = 0.3;
const MAX_SIDE = 1280; // frames and photos are decoded at most this big
const MAX_FACES = 8;
const REFINE_CROP = 2.5; // second pass: a square this many face-sizes wide around each face
const REFINE_FACE = 200; // ...scaled so the face is about this many pixels

let models = null;
function load() {
  if (!models) {
    const opts = { logSeverityLevel: 3, intraOpNumThreads: 1 };
    models = Promise.all([
      ort.InferenceSession.create(new URL('yunet.onnx', MODELS).pathname, opts),
      ort.InferenceSession.create(new URL('sface.onnx', MODELS).pathname, opts)
    ]).catch(e => { models = null; throw e; });
  }
  return models;
}

/** JPEG/PNG/WebP bytes -> { data: RGB bytes, width, height }, scaled down to MAX_SIDE. */
async function decode(bytes) {
  const { data, info } = await sharp(bytes).rotate()
    .resize(MAX_SIDE, MAX_SIDE, { fit: 'inside', withoutEnlargement: true })
    .removeAlpha().raw().toBuffer({ resolveWithObject: true });
  return { data, width: info.width, height: info.height };
}

const iou = (a, b) => {
  const x1 = Math.max(a[0], b[0]), y1 = Math.max(a[1], b[1]);
  const x2 = Math.min(a[0] + a[2], b[0] + b[2]), y2 = Math.min(a[1] + a[3], b[1] + b[3]);
  const inter = Math.max(0, x2 - x1) * Math.max(0, y2 - y1);
  return inter / (a[2] * a[3] + b[2] * b[3] - inter || 1);
};

/** Runs YuNet on an image that fits in 640x640: [{ box, landmarks, score }] in that image's pixels. */
async function detectRaw(rgb, w, h) {
  const [det] = await load();
  // Top-left aligned on a black 640x640 canvas, planar BGR 0-255 (cv::dnn::blobFromImage without scaling).
  const plane = DET_SIZE * DET_SIZE;
  const input = new Float32Array(3 * plane);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const i = (y * w + x) * 3, o = y * DET_SIZE + x;
      input[o] = rgb[i + 2];
      input[plane + o] = rgb[i + 1];
      input[2 * plane + o] = rgb[i];
    }
  }
  const out = await det.run({ input: new ort.Tensor('float32', input, [1, 3, DET_SIZE, DET_SIZE]) });
  const found = [];
  for (const stride of STRIDES) {
    const cols = DET_SIZE / stride, rows = DET_SIZE / stride;
    const cls = out[`cls_${stride}`].data, obj = out[`obj_${stride}`].data;
    const bbox = out[`bbox_${stride}`].data, kps = out[`kps_${stride}`].data;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const idx = r * cols + c;
        const score = Math.sqrt(Math.min(1, Math.max(0, cls[idx])) * Math.min(1, Math.max(0, obj[idx])));
        if (score < SCORE_MIN) continue;
        const cx = (c + bbox[idx * 4]) * stride, cy = (r + bbox[idx * 4 + 1]) * stride;
        const bw = Math.exp(bbox[idx * 4 + 2]) * stride, bh = Math.exp(bbox[idx * 4 + 3]) * stride;
        const landmarks = [];
        for (let n = 0; n < 5; n++) landmarks.push([(kps[idx * 10 + 2 * n] + c) * stride, (kps[idx * 10 + 2 * n + 1] + r) * stride]);
        found.push({ box: [cx - bw / 2, cy - bh / 2, bw, bh], landmarks, score });
      }
    }
  }
  found.sort((a, b) => b.score - a.score);
  const kept = [];
  for (const f of found) if (!kept.some(k => iou(k.box, f.box) > NMS_IOU)) kept.push(f);
  return kept;
}

const raw = img => sharp(img.data, { raw: { width: img.width, height: img.height, channels: 3 } });

/**
 * Faces in an image as [{ box: [x, y, w, h], landmarks: [[x, y] x5], score }], biggest first. The whole frame is
 * searched at 640 px; each face is then detected again in a zoomed-in crop, because YuNet's landmarks (which
 * SFace aligns on) are only as sharp as the face is big, and the model input is fixed at 640x640.
 */
async function detect(img) {
  const s = Math.min(DET_SIZE / img.width, DET_SIZE / img.height, 1);
  const w = Math.max(1, Math.round(img.width * s)), h = Math.max(1, Math.round(img.height * s));
  const coarse = (await detectRaw(await raw(img).resize(w, h, { fit: 'fill' }).toBuffer(), w, h))
    .map(f => ({ box: f.box.map(v => v / s), landmarks: f.landmarks, score: f.score }))
    .sort((a, b) => b.box[2] * b.box[3] - a.box[2] * a.box[3]).slice(0, MAX_FACES);
  const out = [];
  for (const f of coarse) {
    const size = Math.max(f.box[2], f.box[3]);
    const side = Math.round(size * REFINE_CROP);
    const left = Math.round(f.box[0] + f.box[2] / 2 - side / 2), top = Math.round(f.box[1] + f.box[3] / 2 - side / 2);
    const x0 = Math.max(0, left), y0 = Math.max(0, top);
    const cw = Math.min(img.width, left + side) - x0, ch = Math.min(img.height, top + side) - y0;
    const z = REFINE_FACE / size;
    const zw = Math.min(DET_SIZE, Math.max(1, Math.round(cw * z))), zh = Math.min(DET_SIZE, Math.max(1, Math.round(ch * z)));
    let best = null;
    if (cw > 8 && ch > 8) {
      const crop = await raw(img).extract({ left: x0, top: y0, width: cw, height: ch }).resize(zw, zh, { fit: 'fill' }).toBuffer();
      const sx = cw / zw, sy = ch / zh;
      const cx = f.box[0] + f.box[2] / 2, cy = f.box[1] + f.box[3] / 2;
      for (const g of await detectRaw(crop, zw, zh)) {
        const box = [x0 + g.box[0] * sx, y0 + g.box[1] * sy, g.box[2] * sx, g.box[3] * sy];
        const d = Math.hypot(box[0] + box[2] / 2 - cx, box[1] + box[3] / 2 - cy);
        if (d < size / 2 && (!best || d < best.d)) best = { d, box, landmarks: g.landmarks.map(([x, y]) => [x0 + x * sx, y0 + y * sy]), score: g.score };
      }
    }
    // Landmarks of the whole-frame pass are in 640-px units: back to image pixels.
    out.push(best ? { box: best.box, landmarks: best.landmarks, score: best.score }
      : { box: f.box, landmarks: f.landmarks.map(([x, y]) => [x / s, y / s]), score: f.score });
  }
  return out;
}

// ArcFace's 112x112 template: eyes, nose tip, mouth corners.
const TEMPLATE = [[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366], [41.5493, 92.3655], [70.7299, 92.2041]];

/** Least-squares similarity transform taking the landmarks onto TEMPLATE: [a, b, tx, ty] for x' = ax - by + tx. */
function similarity(src) {
  const mean = pts => pts.reduce((m, p) => [m[0] + p[0] / pts.length, m[1] + p[1] / pts.length], [0, 0]);
  const ms = mean(src), md = mean(TEMPLATE);
  let num = 0, cross = 0, den = 0;
  src.forEach((p, i) => {
    const xs = p[0] - ms[0], ys = p[1] - ms[1], xd = TEMPLATE[i][0] - md[0], yd = TEMPLATE[i][1] - md[1];
    num += xs * xd + ys * yd;
    cross += xs * yd - ys * xd;
    den += xs * xs + ys * ys;
  });
  const a = num / (den || 1), b = cross / (den || 1);
  return [a, b, md[0] - (a * ms[0] - b * ms[1]), md[1] - (b * ms[0] + a * ms[1])];
}

/** The face aligned to 112x112 (bilinear, like cv::warpAffine) as planar RGB floats for SFace. */
function align(img, face) {
  const [a, b, tx, ty] = similarity(face.landmarks);
  const det = a * a + b * b || 1;
  const out = new Float32Array(3 * 112 * 112);
  const { data, width, height } = img;
  const px = (x, y, ch) => (x < 0 || y < 0 || x >= width || y >= height ? 0 : data[(y * width + x) * 3 + ch]);
  for (let v = 0; v < 112; v++) {
    for (let u = 0; u < 112; u++) {
      // Inverse of [[a, -b], [b, a]] applied to (u - tx, v - ty).
      const dx = u - tx, dy = v - ty;
      const x = (a * dx + b * dy) / det, y = (-b * dx + a * dy) / det;
      const x0 = Math.floor(x), y0 = Math.floor(y), fx = x - x0, fy = y - y0;
      for (let ch = 0; ch < 3; ch++) {
        out[ch * 12544 + v * 112 + u] =
          (px(x0, y0, ch) * (1 - fx) + px(x0 + 1, y0, ch) * fx) * (1 - fy) +
          (px(x0, y0 + 1, ch) * (1 - fx) + px(x0 + 1, y0 + 1, ch) * fx) * fy;
      }
    }
  }
  return out;
}

async function embed(img, face) {
  const [, rec] = await load();
  const out = await rec.run({ data: new ort.Tensor('float32', align(img, face), [1, 3, 112, 112]) });
  const v = Array.from(out.fc1.data);
  const n = Math.hypot(...v) || 1;
  return v.map(x => x / n);
}

/** Every face in an image with its embedding (unit length): [{ box, score, embedding }], biggest first. */
export async function facesIn(bytes) {
  const img = await decode(bytes);
  const faces = await detect(img);
  const out = [];
  for (const f of faces) out.push({ box: f.box.map(Math.round), score: f.score, embedding: await embed(img, f) });
  return out;
}

/** Cosine similarity of two unit embeddings (OpenCV's FR_COSINE; same person from about 0.36). */
export const similarityOf = (a, b) => a.reduce((s, x, i) => s + x * b[i], 0);
