"""manga-colorizer ONNX 服务 (社区预览)。

仓库代码 Apache-2.0 (见 LICENSE/NOTICE)。模型权重 CC BY-NC-SA 4.0,
不随仓库分发, 使用者自行下载: https://huggingface.co/sharky172/manga-light-colorizer
默认 CPU, 不自动下载权重。

端点:
  GET  /health
  GET  /api/v1/capabilities
  POST /colorize_auto       multipart: image → PNG (全自动, 亮度回写原稿)
  POST /colorize_hints      multipart: image + hints(JSON) → PNG (色度扩散引擎)
  POST /colorize_reference  multipart: image + reference → PNG (主色迁移)
  POST /shutdown            仅回环: 释放模型显存/内存并请求服务优雅退出

长图说明: 长边超过 TILE=1024 自动分块推理 (OVERLAP=256, 线性羽化融合),
避免整页下采样到 1024 方形造成的精度损失。

启动: cd tool/colorizer_service && python -m uvicorn service:app --port 8788
"""
from __future__ import annotations

from collections import deque
from datetime import datetime
from io import BytesIO
import json
import logging
import os
from pathlib import Path
import threading
import time
import traceback

import cv2
from fastapi import FastAPI, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse, Response
from fastapi.staticfiles import StaticFiles
import numpy as np
import onnxruntime as ort
from PIL import Image, UnidentifiedImageError
from starlette.concurrency import run_in_threadpool

ROOT = Path(__file__).resolve().parents[2]
MODEL_DIR = Path(os.environ.get('COLORIZER_MODEL_DIR', str(ROOT / 'models' / 'manga-light-colorizer')))
GENERATOR = MODEL_DIR / 'v6_generator.onnx'
SAM_ENCODER = MODEL_DIR / 'v6_sam_encoder.onnx'
INFER_SIZE = 1024
OUTPUT_DIR = Path(os.environ.get('COLORIZER_OUTPUT_DIR', str(ROOT / 'out' / 'gallery')))
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
GALLERY_LEDGER = OUTPUT_DIR / 'gallery.jsonl'
SETTINGS_FILE = OUTPUT_DIR / 'settings.json'


def _load_settings() -> dict:
    try:
        return json.loads(SETTINGS_FILE.read_text(encoding='utf-8'))
    except Exception:
        return {}


def _save_settings(patch: dict) -> dict:
    data = _load_settings()
    data.update(patch)
    try:
        SETTINGS_FILE.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
    except Exception:
        logging.exception('save settings failed')
    return data
LOG_RING = deque(maxlen=600)

class _RingHandler(logging.Handler):
    def emit(self, record):
        try:
            LOG_RING.append({'seq': getattr(_RingHandler, '_seq', 0) + 1,
                             'ts': datetime.now().strftime('%m-%d %H:%M:%S'),
                             'level': record.levelname, 'message': record.getMessage()})
            _RingHandler._seq = LOG_RING[-1]['seq']
        except Exception:
            pass

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
logging.getLogger().addHandler(_RingHandler())
_log_file = os.environ.get('COLORIZER_LOG_FILE')
if _log_file:
    try:
        _fh = logging.FileHandler(_log_file, encoding='utf-8')
        _fh.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
        logging.getLogger().addHandler(_fh)
    except Exception:
        pass
logging.getLogger().setLevel(logging.INFO)
MAX_BYTES = 20 * 1024 * 1024
MAX_PIXELS = 16_000_000
DEVICE = os.environ.get('COLORIZER_DEVICE', 'cpu').lower()
if DEVICE not in ('cpu', 'auto', 'cuda'):
    raise ValueError('COLORIZER_DEVICE must be cpu, auto or cuda')
_state = {'gen': None, 'sam': None, 'providers': None}
_runtime_device = {'value': None}
_load_state = {'status': 'idle', 'error': None}  # idle | loading | ready | failed
# uvicorn Server 实例由启动入口注入；/shutdown 据此请求优雅退出
_server_ref = {'server': None}


_gpu_info_cache = {'info': None, 'ts': 0.0}


def _gpu_info() -> dict:
    """Best-effort GPU details: model, vram, driver. Empty dict when unavailable.

    结果缓存 5 分钟：nvidia-smi 是子进程调用，设备信息轮询接口不应每次拉起。
    """
    now = time.monotonic()
    if _gpu_info_cache['info'] is not None and now - _gpu_info_cache['ts'] < 300:
        return _gpu_info_cache['info']
    info: dict = {}
    try:
        import subprocess
        out = subprocess.run(
            ['nvidia-smi', '--query-gpu=name,memory.total,driver_version',
             '--format=csv,noheader'], capture_output=True, text=True, timeout=4)
        if out.returncode == 0 and out.stdout.strip():
            parts = [p.strip() for p in out.stdout.strip().split(',')]
            if len(parts) >= 3:
                info = {'name': parts[0], 'vram': parts[1], 'driver': parts[2], 'kind': 'nvidia'}
    except Exception:
        pass
    if not info:
        # DML covers non-NVIDIA GPUs too; mark generic accelerator when DML provider exists
        if 'DmlExecutionProvider' in ort.get_available_providers():
            info = {'name': 'DirectML 兼容 GPU', 'vram': None, 'driver': None, 'kind': 'directml'}
    _gpu_info_cache.update(info=info, ts=now)
    return info


def _gpu_available() -> bool:
    return any('Dml' in p or 'CUDA' in p for p in ort.get_available_providers())


def _expected_device() -> str:
    """Device that WILL be used for the next inference, even before model load.

    Mirrors _pick_providers(): explicit cpu stays cpu; otherwise GPU if any
    GPU provider exists (CUDA wins over DML), else cpu.
    """
    chosen = _runtime_device.get('value') or DEVICE
    if chosen == 'cpu':
        return 'cpu'
    available = ort.get_available_providers()
    if 'CUDAExecutionProvider' in available:
        return 'gpu-cuda'
    if 'DmlExecutionProvider' in available:
        return 'gpu-directml'
    return 'cpu'
_session_lock = threading.Lock()
_inference_lock = threading.Lock()
_cpu_state = {'gen': None, 'sam': None}


def _cpu_sessions():
    """按需加载的 CPU 备用会话：GPU(DirectML/CUDA) 单块推理失败时的回退路径。

    系统内存紧张时首次创建可能 bad_alloc，等 1s 重试一次。
    """
    with _session_lock:
        if _cpu_state['gen'] is None:
            if not GENERATOR.is_file() or not SAM_ENCODER.is_file():
                raise RuntimeError('模型未就绪：需要 v6_generator.onnx 和 v6_sam_encoder.onnx')
            last_exc = None
            for attempt in (1, 2):
                try:
                    gen = ort.InferenceSession(str(GENERATOR), providers=['CPUExecutionProvider'])
                    sam = ort.InferenceSession(str(SAM_ENCODER), providers=['CPUExecutionProvider'])
                    _cpu_state.update(gen=gen, sam=sam)
                    logging.info('CPU 备用会话已加载（GPU 推理失败时回退）')
                    break
                except Exception as exc:
                    last_exc = exc
                    if attempt == 1:
                        time.sleep(1.0)
            else:
                raise last_exc
        return _cpu_state['gen'], _cpu_state['sam']


def _pick_providers():
    chosen = _runtime_device.get('value') or DEVICE
    if chosen == 'cpu':
        return ['CPUExecutionProvider']
    available = ort.get_available_providers()
    if DEVICE == 'cuda' and 'CUDAExecutionProvider' not in available:
        raise RuntimeError('CUDAExecutionProvider 不可用，请安装 GPU 依赖或选择 cpu')
    return [p for p in ['CUDAExecutionProvider', 'DmlExecutionProvider', 'CPUExecutionProvider'] if p in available]


def _device_label(providers) -> str:
    if isinstance(providers, dict):
        providers = [p for lst in providers.values() for p in (lst or [])]
    for p in providers or []:
        if 'CUDA' in p:
            return 'gpu-cuda'
        if 'Dml' in p:
            return 'gpu-directml'
    return 'cpu'


def _sessions():
    _last_use['ts'] = time.monotonic()
    with _session_lock:
        if _state['gen'] is None:
            if not GENERATOR.is_file() or not SAM_ENCODER.is_file():
                raise RuntimeError('模型未就绪：需要 v6_generator.onnx 和 v6_sam_encoder.onnx')
            providers = _pick_providers()
            gen = ort.InferenceSession(str(GENERATOR), providers=providers)
            sam = ort.InferenceSession(str(SAM_ENCODER), providers=providers)
            actual = {'generator': gen.get_providers(), 'sam': sam.get_providers()}
            if DEVICE == 'cuda' and any('CUDAExecutionProvider' not in p for p in actual.values()):
                raise RuntimeError('CUDA 初始化失败，未允许回退；请检查 CUDA/cuDNN 依赖')
            _state.update(gen=gen, sam=sam, providers=actual)
            _load_state['status'] = 'ready'
            _load_state['error'] = None
            logging.info('模型已加载: provider=%s device=%s', actual, _device_label(actual))
        return _state['gen'], _state['sam'], _state['providers']


PRELOAD = os.environ.get('COLORIZER_PRELOAD', '1').lower() not in ('0', 'false', 'no')
# 空闲多久后释放模型会话（内存+显存归还系统）；0 = 常驻不释放
IDLE_UNLOAD_SECONDS = float(os.environ.get('COLORIZER_IDLE_UNLOAD', '600'))
_last_use = {'ts': time.monotonic()}


def _warmup():
    """加载会话并跑一次空推理：DirectML 的内核编译与显存预留发生在首次推理时，
    不预热的话用户提交的第一张图要等 10-20s（还会挤爆显存上限触发瞬时 OOM）。"""
    gen, sam, _ = _sessions()
    zeros = np.zeros((INFER_SIZE, INFER_SIZE), dtype=np.uint8)
    try:
        _run_pair(gen, sam, zeros)
    except Exception:
        logging.warning('预热推理失败，将依赖首次上色时的自动重试: %s', traceback.format_exc(limit=1))


def _preload_worker():
    _load_state.update(status='loading', error=None)
    try:
        _warmup()
        _load_state['status'] = 'ready'
        logging.info('模型预热完成，可立即上色')
    except Exception as exc:
        _load_state.update(status='failed', error=str(exc).replace('\n', ' ')[:200])
        logging.warning('模型预热失败: %s', str(exc).replace('\n', ' ')[:200])


def _start_preload():
    if not PRELOAD:
        return
    if not (GENERATOR.is_file() and SAM_ENCODER.is_file()):
        return  # 权重缺失（等待下载），首个上色请求时再走正常加载报错
    threading.Thread(target=_preload_worker, daemon=True, name='model-preload').start()


def _idle_unload_worker():
    """空闲释放：模型会话常驻约 2-3GB 内存 + 显存，空闲超时后归还系统。

    推理进行中绝不释放（inference_lock 非阻塞探测）；运行中的请求持有
    会话引用，不受影响。下次上色时自动重新加载（预热约 10-20s）。
    """
    while True:
        time.sleep(30)
        if IDLE_UNLOAD_SECONDS <= 0:
            continue
        idle_for = time.monotonic() - _last_use['ts']
        if idle_for < IDLE_UNLOAD_SECONDS:
            continue
        if not _inference_lock.acquire(blocking=False):
            continue
        try:
            with _session_lock:
                if _state['gen'] is None:
                    continue
                if time.monotonic() - _last_use['ts'] < IDLE_UNLOAD_SECONDS:
                    continue
                _state.update(gen=None, sam=None, providers=None)
                _load_state['status'] = 'idle'
            logging.info('空闲 %.0fs，已释放模型（内存/显存归还系统，下次上色自动唤醒）', idle_for)
        finally:
            _inference_lock.release()


def _release_models():
    """释放所有 ONNX 会话；进程内归还内存/显存由调用方（退出或空闲卸载）保证。"""
    with _session_lock:
        _state.update(gen=None, sam=None, providers=None)
        _cpu_state.update(gen=None, sam=None)
    try:
        import gc
        gc.collect()
    except Exception:
        pass


def bind_server(server) -> None:
    """由启动入口注入 uvicorn Server，供 /shutdown 触发优雅退出。"""
    _server_ref['server'] = server


def _feather_weight(x0: int, x1: int, overlap: int) -> np.ndarray:
    """一维线性羽化权重: 两端 overlap 区域从 0 线性升到 1, 中间全 1。"""
    w = np.ones(x1 - x0, dtype=np.float32)
    lo = min(overlap, (x1 - x0) // 2)
    ramp = np.linspace(0.0, 1.0, lo, endpoint=False, dtype=np.float32) if lo > 0 else np.empty(0, np.float32)
    w[:lo] = ramp
    w[x1 - x0 - lo:] = np.minimum(w[x1 - x0 - lo:], ramp[::-1])
    return w


def _tile_bounds(total: int, tile: int, overlap: int) -> list[tuple[int, int]]:
    """覆盖窗口: 保证首块从 0 起、末块到 total 止, 相邻块重叠 overlap。"""
    if total <= tile:
        return [(0, total)]
    step = tile - overlap
    bounds = []
    start = 0
    while True:
        end = min(start + tile, total)
        bounds.append((start, end))
        if end >= total:
            break
        start = end - overlap if end - overlap > start else start + step
    return bounds


def _run_pair(gen, sam, scaled):
    """一次 SAM+generator 推理（输入为 1024² 灰度），返回模型原始 RGB 浮点输出。"""
    s_in = cv2.cvtColor(scaled, cv2.COLOR_GRAY2BGR)
    s_x = (s_in.astype(np.float32) / 127.5 - 1.0).transpose(2, 0, 1)[None]
    sam0, sam1 = sam.run(None, {sam.get_inputs()[0].name: s_x})
    feed = {
        'L_bw': (scaled.astype(np.float32) / 127.5 - 1.0)[None, None],
        'sam_level0': sam0,
        'sam_level1': sam1,
        'wd14_embedding': np.zeros((1, 1024), dtype=np.float32),
    }
    return gen.run(None, feed)[0][0].transpose(1, 2, 0)


def colorize_single(gray) -> np.ndarray:
    """单块推理: 缩 1024 方形 → SAM+generator → 放大回原尺寸 (RGB)。

    GPU 推理失败（如 DirectML 显存瞬时不足 OOM）时该块自动回退 CPU 重试，
    长页分块不再因单块 GPU 异常整体 500。
    """
    h, w = gray.shape
    scaled = cv2.resize(gray, (INFER_SIZE, INFER_SIZE), interpolation=cv2.INTER_AREA)
    gen, sam, _ = _sessions()
    try:
        rgb = _run_pair(gen, sam, scaled)
    except Exception as exc:
        if DEVICE == 'cpu':
            raise
        # DirectML 首次推理可能因显存瞬时不足失败，重试通常即成功
        logging.warning('GPU 推理失败，重试一次: %s', str(exc).replace('\n', ' ')[:160])
        try:
            rgb = _run_pair(gen, sam, scaled)
        except Exception as exc2:
            logging.warning('GPU 重试仍失败，本块回退 CPU: %s', str(exc2).replace('\n', ' ')[:160])
            # 先释放 GPU 会话再建 CPU 会话，避免两套模型同时驻留（低内存机器上
            # 同时持有会直接 bad_alloc）
            with _session_lock:
                _state.update(gen=None, sam=None, providers=None)
            c_gen, c_sam = _cpu_sessions()
            rgb = _run_pair(c_gen, c_sam, scaled)
    rgb = np.clip((rgb + 1.0) * 127.5, 0, 255).astype(np.uint8)
    return cv2.resize(rgb, (w, h), interpolation=cv2.INTER_CUBIC)


def colorize_tiled(gray: np.ndarray, tile: int = 1024, overlap: int = 256) -> np.ndarray:
    """长图分块: 每块独立 SAM+generator, 重叠区线性羽化融合 a/b 色度。

    相比整图缩 1024 方形, 分块保持有效采样密度, 长页细节不再被下采样抹掉。
    """
    h, w = gray.shape
    ys = _tile_bounds(h, tile, overlap)
    xs = _tile_bounds(w, tile, overlap)
    chroma = np.zeros((h, w, 2), dtype=np.float32)
    weight = np.zeros((h, w), dtype=np.float32)
    for (y0, y1) in ys:
        for (x0, x1) in xs:
            patch = gray[y0:y1, x0:x1]
            rgb = colorize_single(patch)  # 输出 = patch 原始分辨率
            lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB).astype(np.float32)
            m = _feather_weight(y0, y1, overlap)[:, None] * _feather_weight(x0, x1, overlap)[None, :]
            chroma[y0:y1, x0:x1, 0] += lab[..., 1] * m
            chroma[y0:y1, x0:x1, 1] += lab[..., 2] * m
            weight[y0:y1, x0:x1] += m
    weight = np.maximum(weight, 1e-6)
    lab_o = cv2.cvtColor(cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR), cv2.COLOR_BGR2LAB)
    lab_o[..., 1] = np.clip(chroma[..., 0] / weight, 0, 255).astype(np.uint8)
    lab_o[..., 2] = np.clip(chroma[..., 1] / weight, 0, 255).astype(np.uint8)
    return cv2.cvtColor(lab_o, cv2.COLOR_LAB2BGR)


def colorize(gray: np.ndarray) -> np.ndarray:
    """灰度 uint8 [H,W] → BGR uint8 [H,W,3]; 长边 >1024 自动分块。"""
    if max(gray.shape) > INFER_SIZE:
        return colorize_tiled(gray)
    rgb = colorize_single(gray)
    lab_o = cv2.cvtColor(cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR), cv2.COLOR_BGR2LAB)
    # 模型输出 RGB；OpenCV 编码要求 BGR。不能在错误的通道空间回写亮度。
    lab_c = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB)
    lab_o[..., 1:] = lab_c[..., 1:]
    return cv2.cvtColor(lab_o, cv2.COLOR_LAB2BGR)


app = FastAPI(title='Manga Colorizer · Community Preview', version='0.4.0')

# 桌面壳（Tauri）的窗口固定运行在 http://tauri.localhost 源上，需要跨域读取本服务；
# 服务只绑定 127.0.0.1，放开 CORS 不会把服务暴露到局域网。
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402
app.add_middleware(
    CORSMiddleware,
    allow_origins=['*'],
    allow_methods=['*'],
    allow_headers=['*'],
)


def _device_payload() -> dict:
    providers = _state['providers']
    loaded = _device_label(providers) if providers else None
    return {'available': ort.get_available_providers(), 'active': providers,
            'device': loaded or _expected_device(), 'loaded_device': loaded,
            'requested': DEVICE,
            'gpu_available': _gpu_available(), 'runtime_device': _runtime_device.get('value'),
            'gpu_info': _gpu_info(),
            'output_dir': str(OUTPUT_DIR), 'settings': _load_settings()}


@app.get('/health')
def health():
    actual = _state['providers']
    gpu_active = False
    if actual:
        gpu_active = any('CUDA' in p or 'Dml' in p
                         for lst in actual.values() for p in (lst or []))
    # 仅当 auto 模式下实际落到 CPU 才算回退；DML/CUDA 正常运行不算
    fallback = bool(DEVICE == 'auto' and actual and not gpu_active)
    # 合并设备信息：前端只需一个 5s 轮询即可刷新服务状态 + 设备徽标
    return {
        'ok': True,
        'weights_present': GENERATOR.is_file() and SAM_ENCODER.is_file(),
        'generator_loaded': _state['gen'] is not None,
        'sam_loaded': _state['sam'] is not None,
        'model_status': _load_state['status'],
        'model_error': _load_state['error'],
        'requested_device': DEVICE,
        'available_providers': ort.get_available_providers(),
        'providers': actual,
        'fallback_reason': 'CUDA 未启用，实际使用 CPU；检查服务日志' if fallback else None,
        'device_info': _device_payload(),
    }


@app.get('/api/v1/capabilities')
def capabilities():
    return {
        'backend': 'manga-light-colorizer',
        'modes': ['auto', 'hints', 'reference'],
        'endpoints': {'auto': '/colorize_auto', 'hints': '/colorize_hints',
                      'reference': '/colorize_reference'},
        'max_hints': 4096,
        'license': {'id': 'CC-BY-NC-SA-4.0', 'commercial_use': False,
                    'url': 'https://creativecommons.org/licenses/by-nc-sa/4.0/',
                    'source': 'https://huggingface.co/sharky172/manga-light-colorizer'},
        'limits': {'max_bytes': MAX_BYTES, 'max_pixels': MAX_PIXELS},
    }


def _decode(data: bytes) -> np.ndarray:
    with Image.open(BytesIO(data)) as probe:
        if probe.format not in ('PNG', 'JPEG', 'WEBP'):
            raise ValueError('仅支持 PNG、JPEG、WebP')
        if probe.width * probe.height > MAX_PIXELS:
            raise ValueError(f'图像超过 {MAX_PIXELS // 1_000_000}M 像素')
        probe.verify()
    bgr = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if bgr is None:
        raise ValueError('无法解码图像')
    return bgr


def _encode_png(out_bgr: np.ndarray) -> Response:
    ok, buf = cv2.imencode('.png', out_bgr)
    if not ok:
        raise RuntimeError('PNG 编码失败')
    return Response(buf.tobytes(), media_type='image/png', headers={'Cache-Control': 'no-store'})


def _gallery_insert(*, source_name: str, mode: str, device: str, elapsed_s: float,
                    src_bgr=None, out_png: bytes = None, error: str = None, out_path=None):
    """Append one record to gallery.jsonl; save result/preview files. Never raises."""
    try:
        rec = {
            'id': datetime.now().strftime('%Y%m%d%H%M%S') + f'_{int(elapsed_s*1000):04d}',
            'time': datetime.now().isoformat(timespec='seconds'),
            'mode': mode, 'device': device, 'elapsed_s': round(elapsed_s, 2),
            'source_name': source_name, 'status': 'ok' if (out_png or out_path) else 'failed',
        }
        if error:
            rec['error'] = error
        if out_path:
            rec['result_path'] = str(out_path)
            rec['result_file'] = Path(out_path).name
            try:
                img = cv2.imread(str(out_path))
                h, w = img.shape[:2]
                rec['width'], rec['height'] = w, h
                # 网格缩略图：避免前端把整页成品原图当缩略图加载（图库列表曾因此
                # 一次拉取上百张全尺寸 PNG）
                scale = 320 / max(h, w)
                thumb = cv2.resize(img, (max(1, int(w * scale)), max(1, int(h * scale))),
                                   interpolation=cv2.INTER_AREA) if scale < 1 else img
                thumb_file = OUTPUT_DIR / (Path(out_path).stem + '_thumb.jpg')
                ok, buf = cv2.imencode('.jpg', thumb, [cv2.IMWRITE_JPEG_QUALITY, 82])
                if ok:
                    thumb_file.write_bytes(buf.tobytes())
                    rec['thumb_file'] = thumb_file.name
            except Exception:
                pass
        if src_bgr is not None:
            src_file = OUTPUT_DIR / (rec['id'] + '_src.png')
            ok, buf = cv2.imencode('.png', src_bgr)
            if ok:
                src_file.write_bytes(buf.tobytes())
                rec['source_file'] = src_file.name
        with open(GALLERY_LEDGER, 'a', encoding='utf-8') as f:
            f.write(json.dumps(rec, ensure_ascii=False) + '\n')
    except Exception:
        logging.exception('gallery insert failed')


def _process(data: bytes, source_name: str = 'image.png') -> Response:
    if not _inference_lock.acquire(blocking=False):
        return JSONResponse({'error': '模型忙碌，请稍后重试'}, status_code=429)
    t0 = datetime.now()
    try:
        try:
            bgr = _decode(data)
        except ValueError as exc:
            _gallery_insert(source_name=source_name, mode='auto', device='-', elapsed_s=0.0, error=str(exc))
            return JSONResponse({'error': str(exc)}, status_code=400)
        out = colorize(cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY))
        resp = _encode_png(out)
        device = _device_label(_state['providers'])
        elapsed = (datetime.now() - t0).total_seconds()
        stamp = datetime.now().strftime('%Y%m%d%H%M%S')
        out_path = OUTPUT_DIR / (stamp + '_auto.png')
        try:
            out_path.write_bytes(resp.body)
        except Exception:
            out_path = None
        _gallery_insert(source_name=source_name, mode='auto', device=device, elapsed_s=elapsed,
                        src_bgr=bgr, out_path=out_path)
        logging.info('上色完成: %s mode=auto device=%s elapsed=%.1fs size=%dx%d',
                     source_name, device, elapsed, bgr.shape[1], bgr.shape[0])
        return resp
    except RuntimeError as exc:
        logging.exception('Model unavailable')
        return JSONResponse({'error': str(exc)}, status_code=503)
    except Exception:
        logging.exception('Colorization failed')
        return JSONResponse({'error': '上色失败，请查看服务日志'}, status_code=500)
    finally:
        _inference_lock.release()


# ---- 提示点模式 ----
# 在服务端做提示点色度扩散（亮度相似邻域内的加权平均，Levin 交互式上色的轻量近似），
# 再叠加到模型的全自动语义底色之上：提示点覆盖区取提示色，其余保留模型色。
# 需要精确全局求解时使用 CLI（packages/manga_colorizer_cli）。

def _hint_colorize(bgr: np.ndarray, hints: list[dict]) -> np.ndarray:
    gray = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    h, w = gray.shape
    lab = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    chroma = np.zeros((h, w, 2), dtype=np.float32)
    weight = np.zeros((h, w), dtype=np.float32)
    for hint in hints[:4096]:
        x, y = int(hint['x']), int(hint['y'])
        if not (0 <= x < w and 0 <= y < h):
            continue
        b, g, r = hint.get('b', 0), hint.get('g', 0), hint.get('r', 0)
        hlab = cv2.cvtColor(np.uint8([[[b, g, r]]]), cv2.COLOR_BGR2LAB)[0, 0].astype(np.float32)
        # 局部窗口 (64px) 内亮度相近的像素接受该提示色, 权重 = 亮度相似度
        x0, x1 = max(0, x - 64), min(w, x + 64)
        y0, y1 = max(0, y - 64), min(h, y + 64)
        patch = gray[y0:y1, x0:x1].astype(np.float32)
        sim = np.exp(-((patch - float(gray[y, x])) / 12.0) ** 2)
        chroma[y0:y1, x0:x1, 0] += float(hlab[1]) * sim
        chroma[y0:y1, x0:x1, 1] += float(hlab[2]) * sim
        weight[y0:y1, x0:x1] += sim
    weight = np.maximum(weight, 1e-6)
    lab[..., 1] = np.where(weight > 1e-6, chroma[..., 0] / weight, lab[..., 1])
    lab[..., 2] = np.where(weight > 1e-6, chroma[..., 1] / weight, lab[..., 2])
    return cv2.cvtColor(lab.astype(np.uint8), cv2.COLOR_LAB2BGR)


def _reference_transfer(bgr: np.ndarray, ref: np.ndarray) -> np.ndarray:
    """参考图主色迁移: 参考图 Lab 色度统计 (均值+方差) 匹配到原稿。

    保留原稿亮度结构, 色度按参考图整体色调重新分布 (Reinhard 颜色迁移)。
    """
    lab_s = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
    lab_r = cv2.cvtColor(ref, cv2.COLOR_BGR2LAB).astype(np.float32)
    for c in (1, 2):
        src_ch = lab_s[..., c]
        ref_mean, ref_std = lab_r[..., c].mean(), lab_r[..., c].std() + 1e-6
        src_mean, src_std = src_ch.mean(), src_ch.std() + 1e-6
        lab_s[..., c] = (src_ch - src_mean) * (ref_std / src_std) + ref_mean
    return cv2.cvtColor(np.clip(lab_s, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR)


def _persist_gallery(resp: Response, bgr: np.ndarray, *, source_name: str, mode: str,
                     t0, suffix: str):
    """auto 之外的模式同样入图库台账：结果先落盘（含缩略图生成），再记一行。"""
    device = _device_label(_state['providers'])
    elapsed = (datetime.now() - t0).total_seconds()
    stamp = datetime.now().strftime('%Y%m%d%H%M%S')
    out_path = OUTPUT_DIR / (stamp + suffix)
    try:
        out_path.write_bytes(resp.body)
    except Exception:
        out_path = None
    _gallery_insert(source_name=source_name, mode=mode, device=device, elapsed_s=elapsed,
                    src_bgr=bgr, out_path=out_path)
    logging.info('上色完成: %s mode=%s device=%s elapsed=%.1fs size=%dx%d',
                 source_name, mode, device, elapsed, bgr.shape[1], bgr.shape[0])


def _process_hints(data: bytes, hints_raw: str, source_name: str = 'image.png') -> Response:
    if not _inference_lock.acquire(blocking=False):
        return JSONResponse({'error': '模型忙碌，请稍后重试'}, status_code=429)
    t0 = datetime.now()
    try:
        try:
            bgr = _decode(data)
        except ValueError as exc:
            return JSONResponse({'error': str(exc)}, status_code=400)
        try:
            hints = json.loads(hints_raw)
            if not isinstance(hints, list):
                raise ValueError
        except (json.JSONDecodeError, ValueError):
            return JSONResponse({'error': 'hints 必须是 JSON 数组'}, status_code=400)
        # 语义底色 + 提示点色度叠加: 先全自动上色, 再用提示点精修局部
        auto = colorize(cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY))
        hinted = _hint_colorize(bgr, hints)
        # 提示点作用区 (色度幅值显著高于中性) 用 hinted 的色度, 其余保留模型色
        lab_a = cv2.cvtColor(auto, cv2.COLOR_BGR2LAB).astype(np.float32)
        lab_h = cv2.cvtColor(hinted, cv2.COLOR_BGR2LAB).astype(np.float32)
        out = auto.copy()
        lab_o = cv2.cvtColor(out, cv2.COLOR_BGR2LAB).astype(np.float32)
        chroma_mag = np.sqrt(lab_h[..., 1] ** 2 + lab_h[..., 2] ** 2)
        auto_mag = np.sqrt(lab_a[..., 1] ** 2 + lab_a[..., 2] ** 2)
        mask = (chroma_mag > 6) & (chroma_mag > auto_mag * 0.5)
        lab_o[..., 1:3] = np.where(mask[..., None], lab_h[..., 1:3], lab_o[..., 1:3])
        out = cv2.cvtColor(lab_o.astype(np.uint8), cv2.COLOR_LAB2BGR)
        resp = _encode_png(out)
        _persist_gallery(resp, bgr, source_name=source_name, mode='hints', t0=t0, suffix='_hints.png')
        return resp
    except RuntimeError as exc:
        logging.exception('Model unavailable')
        return JSONResponse({'error': str(exc)}, status_code=503)
    except Exception:
        logging.exception('Hint colorization failed')
        return JSONResponse({'error': '上色失败，请查看服务日志'}, status_code=500)
    finally:
        _inference_lock.release()


def _process_reference(data: bytes, ref_data: bytes, source_name: str = 'image.png') -> Response:
    if not _inference_lock.acquire(blocking=False):
        return JSONResponse({'error': '模型忙碌，请稍后重试'}, status_code=429)
    t0 = datetime.now()
    try:
        try:
            bgr = _decode(data)
            ref = _decode(ref_data)
        except ValueError as exc:
            return JSONResponse({'error': str(exc)}, status_code=400)
        # 语义结构来自模型 (auto), 色彩统计来自参考图
        auto = colorize(cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY))
        styled = _reference_transfer(bgr, ref)
        # 融合: 模型提供语义色相, 参考图提供全局色调统计 → 在 Lab 上按 5:5 混合
        lab_a = cv2.cvtColor(auto, cv2.COLOR_BGR2LAB).astype(np.float32)
        lab_s = cv2.cvtColor(styled, cv2.COLOR_BGR2LAB).astype(np.float32)
        lab_o = cv2.cvtColor(bgr, cv2.COLOR_BGR2LAB).astype(np.float32)
        lab_o[..., 1] = 0.5 * lab_a[..., 1] + 0.5 * lab_s[..., 1]
        lab_o[..., 2] = 0.5 * lab_a[..., 2] + 0.5 * lab_s[..., 2]
        out = cv2.cvtColor(np.clip(lab_o, 0, 255).astype(np.uint8), cv2.COLOR_LAB2BGR)
        resp = _encode_png(out)
        _persist_gallery(resp, bgr, source_name=source_name, mode='reference', t0=t0, suffix='_ref.png')
        return resp
    except RuntimeError as exc:
        logging.exception('Model unavailable')
        return JSONResponse({'error': str(exc)}, status_code=503)
    except Exception:
        logging.exception('Reference colorization failed')
        return JSONResponse({'error': '上色失败，请查看服务日志'}, status_code=500)
    finally:
        _inference_lock.release()


@app.post('/colorize_auto')
async def colorize_auto(image: UploadFile = File(...)):
    try:
        data = await image.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            return JSONResponse({'error': '文件超过 20 MiB'}, status_code=413)
        name = image.filename or 'image.png'
        return await run_in_threadpool(_process, data, name)
    finally:
        await image.close()


@app.post('/colorize_hints')
async def colorize_hints(image: UploadFile = File(...), hints: str = Form('[]')):
    try:
        data = await image.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            return JSONResponse({'error': '文件超过 20 MiB'}, status_code=413)
        return await run_in_threadpool(_process_hints, data, hints, image.filename or 'image.png')
    finally:
        await image.close()


@app.post('/colorize_reference')
async def colorize_reference(image: UploadFile = File(...), reference: UploadFile = File(...)):
    try:
        data = await image.read(MAX_BYTES + 1)
        ref_data = await reference.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES or len(ref_data) > MAX_BYTES:
            return JSONResponse({'error': '文件超过 20 MiB'}, status_code=413)
        return await run_in_threadpool(_process_reference, data, ref_data, image.filename or 'image.png')
    finally:
        await image.close()
        await reference.close()


# ---- 批量队列: 按提交顺序逐个处理, 单个失败不阻断 ----
@app.post('/api/v1/batch')
async def batch_colorize(files: list[UploadFile] = File(...)):
    results = []
    for uf in files[:32]:
        name = uf.filename or 'image.png'
        try:
            data = await uf.read(MAX_BYTES + 1)
        finally:
            await uf.close()
        if len(data) > MAX_BYTES:
            results.append({'name': name, 'status': 'failed', 'error': '文件超过 20 MiB'})
            continue
        resp = await run_in_threadpool(_process, data, name)
        if resp.status_code == 200:
            results.append({'name': name, 'status': 'ok', 'bytes': len(resp.body)})
        else:
            try:
                err = json.loads(resp.body.decode('utf-8')).get('error', '处理失败')
            except Exception:
                err = '处理失败'
            results.append({'name': name, 'status': 'failed', 'error': err})
    ok_n = sum(1 for r in results if r['status'] == 'ok')
    logging.info('批量任务汇总: %d/%d 成功', ok_n, len(results))
    return {'total': len(results), 'ok': ok_n, 'failed': len(results) - ok_n, 'results': results}


@app.get('/api/v1/gallery')
def gallery_list(limit: int = 200):
    records = []
    if GALLERY_LEDGER.is_file():
        with open(GALLERY_LEDGER, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except Exception:
                        pass
    return {'count': len(records), 'items': list(reversed(records[-limit:]))}


@app.get('/api/v1/logs')
def logs_tail(after: int = 0):
    items = [x for x in LOG_RING if x['seq'] > after]
    return {'items': items, 'next': items[-1]['seq'] if items else after}


@app.get('/api/v1/device')
def device_info():
    return _device_payload()


@app.get('/gallery/file/{name}')
def gallery_file(name: str):
    safe = Path(name).name
    if safe != name or '..' in name:
        return JSONResponse({'error': '非法路径'}, status_code=400)
    path = OUTPUT_DIR / safe
    if not path.is_file():
        return JSONResponse({'error': '文件不存在'}, status_code=404)
    media = {'.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp'}.get(
        path.suffix.lower(), 'image/png')
    return Response(path.read_bytes(), media_type=media,
                    headers={'Cache-Control': 'max-age=86400'})


# ---- 设置: 模式 / 处理器 / 免责声明 (本地持久化 settings.json) ----
@app.get('/api/v1/settings')
def settings_get():
    return _load_settings()


@app.post('/api/v1/settings')
async def settings_set(request: Request):
    body = await request.json()
    allowed = {'mode', 'device', 'disclaimer_accepted', 'theme'}
    patch = {k: v for k, v in (body or {}).items() if k in allowed}
    if 'device' in patch:
        if patch['device'] not in ('cpu', 'gpu', 'auto'):
            return JSONResponse({'error': 'device 必须是 cpu/gpu/auto'}, status_code=400)
        if patch['device'] == 'gpu' and not _gpu_available():
            return JSONResponse({'error': '本机没有可用的 GPU Provider'}, status_code=400)
    if 'mode' in patch and patch['mode'] not in ('auto', 'hints', 'reference'):
        return JSONResponse({'error': 'mode 必须是 auto/hints/reference'}, status_code=400)
    if 'disclaimer_accepted' in patch and not isinstance(patch['disclaimer_accepted'], bool):
        return JSONResponse({'error': 'disclaimer_accepted 必须是布尔值'}, status_code=400)
    if 'theme' in patch and patch['theme'] not in ('dark', 'light', None):
        return JSONResponse({'error': 'theme 必须是 dark/light/null'}, status_code=400)
    old_dev = _runtime_device.get('value')
    data = _save_settings(patch)
    new_dev = data.get('device', 'auto')
    mapped = {'gpu': 'auto', 'cpu': 'cpu'}.get(new_dev, DEVICE)
    if mapped != old_dev:
        _runtime_device['value'] = mapped
        with _session_lock:
            _state.update(gen=None, sam=None, providers=None)
        logging.info('处理器切换: %s (预热新设备)', mapped)
        _start_preload()
    return data


@app.post('/shutdown')
def shutdown(request: Request):
    """桌面壳退出时调用：先释放模型（归还内存/显存），再请求服务优雅退出。

    仅接受回环地址；服务本身只绑定 127.0.0.1，这里再校验一层，避免被
    同源页面上的脚本误触发。找不到 uvicorn Server 句柄时退化为进程退出，
    由操作系统回收显存。
    """
    client = request.client.host if request.client else ''
    if client not in ('127.0.0.1', '::1'):
        return JSONResponse({'error': 'forbidden'}, status_code=403)
    _release_models()
    logging.info('收到 /shutdown，服务即将退出')
    srv = _server_ref['server']
    if srv is not None:
        srv.should_exit = True
    else:
        threading.Thread(
            target=lambda: (time.sleep(0.2), os._exit(0)),
            daemon=True, name='sidecar-exit').start()
    return {'ok': True}


# 同源静态前端：开发/浏览器场景由本服务直接挂载本目录。

web_dist = Path(os.environ.get('COLORIZER_WEB_DIST', str(ROOT / 'web' / 'dist')))
if web_dist.is_dir():
    app.mount('/', StaticFiles(directory=web_dist, html=True), name='web')

# 启动即后台预热模型（加载 + 空推理），用户首次上色无需等待 10-20s 加载
_start_preload()
# 空闲超时自动释放模型（内存/显存归还系统）；COLORIZER_IDLE_UNLOAD=0 可关闭
threading.Thread(target=_idle_unload_worker, daemon=True, name='model-idle-unload').start()

if __name__ == '__main__':
    import uvicorn
    import argparse
    _ap = argparse.ArgumentParser()
    _ap.add_argument('--port', type=int, default=8788)
    _argv_port = _ap.parse_args().port
    _cfg = uvicorn.Config(app, host='127.0.0.1', port=_argv_port, access_log=False)
    _srv = uvicorn.Server(_cfg)
    bind_server(_srv)
    _srv.run()
