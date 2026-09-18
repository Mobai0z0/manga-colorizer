# v0.2.0 六项升级说明与交接

> 2026-09-18 · 基线 v0.1.0-desktop-mobile (0bae4e0) → v0.2.0
> 六项：GPU 加速 / 多文件排队 / 应用图标 / 新界面 / 成果图库 / 控制台日志

## 1. 功能与实现位置

| # | 功能 | 实现 | 关键文件 |
|---|---|---|---|
| 1 | GPU 加速 | onnxruntime-directml（DmlExecutionProvider），`COLORIZER_DEVICE=auto` 自动选择，无 GPU/驱动异常自动回退 CPU 并在日志说明；设备标签区分 gpu-cuda / gpu-directml / cpu | `tool/colorizer_service/service.py`（_pick_providers/_device_label）、`src-tauri/src/sidecar_mgr.rs`（注入 env） |
| 2 | 多文件排队 | 前端按加入顺序逐个 POST /colorize_auto；服务端另有 /api/v1/batch（≤32 张，单失败不阻断）；支持中途取消、完成后汇总 | `web/dist/app-ui.js`、`service.py` |
| 3 | 应用图标 | 恢复 v0.1.0 打包图标（深绿底调色盘+画笔），窗口/任务栏/EXE 同源 `src-tauri/icons/icon.ico` | `src-tauri/icons/*`、`Pillow 生成脚本记录于本文 §4` |
| 4 | 新界面 | 沿用用户 app.html 的 M3 设计语言（app.css 令牌 + top-app-bar/navigation-rail/fab/card/list），扩展队列/图库/日志三屏与设备徽标；light/dark 双主题；桌面 rail / 移动底栏自适应 | `web/dist/app-ui.html/css/js` |
| 5 | 成果图库 | 每次上色自动写 `gallery.jsonl` 台账（时间/设备/耗时/尺寸/成品与原图文件名），成品 PNG 落 `gallery/`；前端缩略网格 + 大图 + 打开文件夹（Tauri cmd_open_dir） | `service.py`（_gallery_insert、/api/v1/gallery、/gallery/file/{name}）、`app-ui.js` |
| 6 | 控制台日志 | Python logging 环形缓冲 600 条 → `/api/v1/logs?after=seq` 增量拉取；同时 FileHandler 写 `logs/app-*.log`（COLORIZER_LOG_FILE 由壳注入） | `service.py`、`sidecar_mgr.rs` |

## 2. 实测数据（本机 RTX 5060 Laptop 8GB）

| 项 | 结果 |
|---|---|
| GPU 识别 | `DmlExecutionProvider` 活跃，标签 gpu-directml（/api/v1/device 与日志一致） |
| GPU vs CPU 耗时（1280×740 单张） | GPU 冷启 10.2s（含模型编译）→ 热跑 3.8s；CPU 同图 18–22s；约 4–5× 加速 |
| 打包版 GPU | 安装版（NSIS /S）端到端：girl-bw 57.5s 冷启 / diverse-00 11.3s；台账 dev=gpu-directml |
| 批量队列 | 4 张混合（含 1 张损坏 PNG）：3 成功 1 失败，58.9s，失败不阻断，汇总正确 |
| 图库台账 | gallery.jsonl 逐条记录，status/device/elapsed_s/width/height 齐全，文件服务 200 image/png |
| 日志 | 界面环形缓冲增量拉取 + `%LOCALAPPDATA%\manga-colorizer\logs\app-*.log` 落盘（ERROR 级含堆栈行） |
| 安装包 | Manga Colorizer_0.2.0_x64-setup.exe = 99.9MB（+DirectML 运行时 ≈10MB），静默安装 exit 0 |

## 3. 已修缺陷（本轮发现即修）

1. `_device_label` 收 dict 误报 cpu → 兼容 dict/list 两种形态
2. `_gallery_insert` 状态判定用错参数 → 成品记录误标 failed → 改 `out_png or out_path`
3. 安装版输出目录落到 `C:\Users\…\AppData\Local\out\gallery`（onefile ROOT 解析到临时目录）→ 壳注入 `COLORIZER_OUTPUT_DIR` 指向 appdata\gallery
4. 安装版 GPU 不生效（缺 COLORIZER_DEVICE）→ 壳注入 `COLORIZER_DEVICE=auto`

## 4. 维护指南

- **改界面**：`web/dist/app-ui.html`（结构）+ `app-ui.css`（样式，令牌在 app.css）+ `app-ui.js`（队列/图库/日志逻辑）。主题色改 `app.css` 的 `--md-sys-color-primary` 系列即可全局生效。
- **改图标**：运行 §附录 的 Pillow 脚本重新生成 `src-tauri/icons/` 六件套。
- **改服务**：`tool/colorizer_service/service.py`；新增端点后记得 `python -m PyInstaller sidecar/manga-colorizer-sidecar.spec …` 重打包并复制到 `src-tauri/binaries/`。
- **切换 CUDA**：装 `onnxruntime-gpu`（替换 directml，两者不可共存）+ CUDA/cuDNN；代码已兼容 CUDA provider 优先。
- **构建安装包**：`cd src-tauri && tauri build`（前置：sidecar 已复制到 binaries/）。

## 5. 回滚

1. 卸载 0.2.0（控制面板或 `%LOCALAPPDATA%\Manga Colorizer\uninstall.exe`）
2. 安装归档旧版：`DELIVERY\releases\v0.1.0-desktop-mobile\Manga Colorizer_0.1.0_x64-setup.exe`
3. 图库/日志/权重数据在 `%LOCALAPPDATA%\manga-colorizer\` 与 `out\gallery`（旧版不读新台账，但数据保留不损坏）
4. 代码回退：`git revert` 或 checkout `v0.1.0-desktop-mobile` tag

## 附录：图标生成脚本（Pillow）

```python
# 见 git 历史 src-tauri/icons 生成记录；深绿 (47,109,94) 圆角底 + 白色调色盘 + 红黄蓝绿四点 + 深色画笔斜线
```
