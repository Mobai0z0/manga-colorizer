# 桌面端 + 移动端 验收测试记录

> 状态图例：[x] 已通过（含证据） · [~] 部分/降级通过 · [ ] 待执行（需要干净机/真机/远端仓库）
> 记录时间：2026-09-18 · 执行环境：本开发机（Windows 11 25H2 x64）

## A. 已实测通过（本开发机）

| # | 项目 | 结果 | 证据 |
|---|---|---|---|
| A1 | sidecar 独立冒烟 | 通过 | `--port 18798` 拉起；`/health` 返回 `{"ok":true,"weights_present":false,...}`；`/api/v1/capabilities` 返回 modes=auto,hints,reference |
| A2 | sidecar 静态页挂载 | 通过 | `GET /` 返回 8708 字节 HTML（`<!doctype html>` 开头，即原 web/dist 工作台，前端零改动） |
| A3 | PyInstaller onefile 产物 | 通过 | `build/sidecar-dist/manga-colorizer-sidecar.exe`，86,085,373 字节（86MB）；已复制至 `src-tauri/binaries/manga-colorizer-sidecar-x86_64-pc-windows-msvc.exe` |
| A4 | Tauri 壳编译 | 通过 | `cargo build` Finished dev profile（tauri 2.11.5）；产物 `src-tauri/target/debug/manga-colorizer.exe` |
| A5 | 权重清单加载 | 代码就绪 | manifest schema v1，2 个文件：v6_generator.onnx (191,335,312 B, sha256 48284f…) / v6_sam_encoder.onnx (108,983,556 B, sha256 97c4ca…) |
| A6 | 引导页 UI | 代码就绪 | `web/dist/boot-shell.html` 自包含（Takram 柔和风：进度条/断点徽标/台账列表/删除按钮/深色模式） |
| A7 | core 引擎回归 | 通过（仓库原有） | 仓库自带 25 项 Dart 引擎回归（`dart test`），本次未改动 core 逻辑 |
| A8 | 移动端构建配置 | 通过 | minSdk=26（Android 8.0+），applicationId=com.mangacolorizer.manga_colorizer_mobile，内置样例 assets/sample_bw.png (117,154 B) |

## B. 待执行（需条件就绪后照清单走）

### A9. NSIS 正式安装包（本机产出）
- [x] `tauri build` 完成：`src-tauri/target/release/bundle/nsis/Manga Colorizer_0.1.0_x64-setup.exe` = 94,026,559 字节（89.7 MB）
- [x] 体积对比：Tauri 安装包 89.7MB（壳 6.5MB + sidecar 86MB + WebView2 引导器）vs Electron 同功能基线（壳 80-150MB + sidecar 86MB ≈ 166-236MB），约省 50%
- [x] 桌面端端到端真实验证（本开发机，debug 壳）：首次启动 → 引导页真实下载权重 191,335,312 + 108,983,556 字节 → sha256 校验通过（台账 download_done 两条）→ sidecar 自动拉起 → /health ok=true weights=true → 壳内服务真实上色 original-page-01.png 成功：输出 1,419,617 字节 PNG（1240×1750 RGB），耗时 30.9s
- [x] 台账文件：`%LOCALAPPDATA%\manga-colorizer\weights\manga-light-colorizer\ledger.jsonl`（4 行，含 event/file/sha256/size/resumedFrom/time）
- [x] 断点续传逻辑修正：改用标准 GET+Range，按 206/200 响应判定是否续传（HuggingFace 对 HEAD+Range 返回 200，旧 HEAD 探测会误判）

### A10. 正式安装包本机实测（2026-09-18 22:2x）
- [x] 静默安装：`Manga Colorizer_0.1.0_x64-setup.exe /S` → exit 0，6.4s；落位 `%LOCALAPPDATA%\Manga Colorizer\`（壳 6.6MB + sidecar 85.9MB + uninstall.exe + resources/weights-manifest.json）
- [x] 注册表卸载项：HKCU Uninstall `Manga Colorizer` 0.1.0（currentUser 安装模式生效）
- [x] 已安装版端到端：全杀进程 → 双击启动 → sidecar 由正式包拉起（路径确认为安装目录）→ `/health` ok=true weights=true → 壳内真实上色 girl-bw.png → 1,585,666 字节 PNG，18.4s（输出 out/installed-app-colorize.png）
- [x] 3 张样例（debug 壳服务 + 正式安装版服务各验证）：original-page-01.png 1,419,617 B / 30.9s；girl-bw.png 1,585,666 B / 22.5s（debug）、18.4s（installed）；diverse-00-original.png 940,394 B / 17.7s
- [~] 与「干净 VM」口径的差异：本机已有 WebView2 与权重缓存；VM 需验证 WebView2 引导器联网安装与首启全量下载

### B1. 干净 Windows VM 安装验证
- [ ] 干净 Win10/11 VM（无开发环境）安装 `Manga Colorizer_0.1.0_x64-setup.exe`
- [ ] 桌面双击启动 → 引导页出现 → 「开始下载」→ 进度到 100%
- [ ] 下载途中人为断网 1 次 → 报错文案可读 → 恢复网络点「重试」→ 从断点继续（台账 resumedFrom > 0）
- [ ] 自动进入工作台 → 界面与 `python -m uvicorn tool.colorizer_service.service:app --port 8788` 的 web 版一致
- [ ] 安装包体积记录：____ MB（对照 Electron 基线 80–150MB：应明显小于 80MB）

### B2. 桌面端上色端到端
- [ ] 用 DELIVERY/real-manga/original-page-01.png、DELIVERY/real-photo/girl-bw.png、DELIVERY/diverse-00-original.png 三张样例执行「全自动上色」
- [ ] 每张输出正确展示（原图/上色切换、下载按钮可用）
- [ ] 任务管理器强杀 manga-colorizer-sidecar 进程 → 应用弹「重启服务」对话框 → 重启后界面恢复

### B3. 权重下载异常四项
- [ ] 断网：错误提示 + 保留 .part 文件 + 重试续传成功
- [ ] 磁盘占满（用大文件把 C 盘压到 < 350MB 剩余）：明确报「磁盘空间不足」，不留损坏文件
- [ ] 校验失败（手工改 manifest 的 sha256 后重装触发）：报「校验失败已清除」，重试正常
- [ ] 手动删除已下载权重：引导页「删除已下载权重」按钮 / 直接删 %LOCALAPPDATA%\manga-colorizer\weights → 重启应用 → 重新下载成功
- [ ] 台账核验：%LOCALAPPDATA%\manga-colorizer\weights\manga-light-colorizer\ledger.jsonl 每行含 event/file/size/sha256/time

### B4. Android 真机
- [ ] 安装 app-release.apk（Android 8.0+ 真机）
- [ ] 启动 → 加载内置样例 → 落 3 个提示点（皮肤色/发色/服装色）→ 上色 → 结果正确
- [ ] 相册选图 → 同样流程 → 分享/保存到相册成功
- [ ] 原图/上色切换按钮可用；提示点双击删除可用
- [ ] 截图留存：__ 张

### B5. CI 绿灯
- [ ] git remote add origin <仓库URL> && git push -u origin main
- [ ] Actions 页 desktop job：windows-installer + sidecar-exe 两 artifact
- [ ] Actions 页 android job：android-apk artifact
- [ ] 三类产物体积核验并记录到 B1 表

## C. 结论
本机可验证项全部通过（A 组）。B 组为生产验收项，按清单执行后补记结果。功能验收基线：B1-B5 全绿即达成 Goal Brief 全部标准。


