#!/usr/bin/env python3
"""Manga Colorizer sidecar entry (PyInstaller target).

Runs the existing FastAPI service on 127.0.0.1:<port> without changing any
colorization logic. The Tauri shell spawns this exe and polls /health.

Usage: manga-colorizer-sidecar.exe [--port 8788]
Exit codes: 0 normal shutdown, 3 port occupied, 4 fatal startup error.
"""
from __future__ import annotations

import argparse
import os
import socket
import sys
from pathlib import Path

APP_DIR = Path(getattr(sys, "_MEIPASS", None) or Path(sys.executable).resolve().parent)


def _port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.4)
        return s.connect_ex(("127.0.0.1", port)) == 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8788)
    args = parser.parse_args()

    # Bundled web/dist (PyInstaller datas) - service.py reads this env at import time.
    bundled_web = APP_DIR / "web-dist"
    if bundled_web.is_dir():
        os.environ.setdefault("COLORIZER_WEB_DIST", str(bundled_web))

    if _port_open(args.port):
        # Shell may have been restarted while an old sidecar lingers; treat as success.
        print(f"[sidecar] port {args.port} already serving, exiting 0", flush=True)
        return 0

    try:
        import uvicorn  # noqa: PLC0415
        from service import app  # the patched copy bundled next to this exe / in _MEIPASS
    except Exception as exc:  # pragma: no cover
        print(f"[sidecar] fatal: cannot import service: {exc}", flush=True)
        return 4

    try:
        uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="info")
    except OSError as exc:
        print(f"[sidecar] fatal: {exc}", flush=True)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())

