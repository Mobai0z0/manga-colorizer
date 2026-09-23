# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for the manga-colorizer Python sidecar (onefile).

Build:  pyinstaller sidecar/manga-colorizer-sidecar.spec --noconfirm
Output: dist/manga-colorizer-sidecar.exe  -> copy to src-tauri/binaries/
"""
import os

block_cipher = None

a = Analysis(
    ["sidecar_entry.py"],
    pathex=[os.path.abspath(os.path.join(SPECPATH, "..", "tool", "colorizer_service"))],
    binaries=[],
    datas=[
        (os.path.abspath(os.path.join(SPECPATH, "..", "web", "dist")), "web-dist"),
    ],
    hiddenimports=[
        "uvicorn",
        "uvicorn.logging",
        "uvicorn.loops",
        "uvicorn.loops.auto",
        "uvicorn.protocols",
        "uvicorn.protocols.http",
        "uvicorn.protocols.http.auto",
        "uvicorn.protocols.websockets",
        "uvicorn.protocols.websockets.auto",
        "uvicorn.lifespan",
        "uvicorn.lifespan.on",
        "python_multipart",
        "service",
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=["tkinter", "matplotlib", "pytest", "PyQt5"],
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name="manga-colorizer-sidecar",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
)
