# v0.3.0 三项界面改造说明与交接

> 2026-09-19 · 基线 v0.2.0-six-features (6aa20b6) → v0.3.0
> 三项：左上角换打包应用图标 / 设置区（模式·处理器·免责声明）/ 日志面板双主题

## 1. 改动清单

| # | 需求 | 实现 | 改动文件 |
|---|---|---|---|
| 1 | 左上角图标 | 品牌位（rail + 顶栏 + favicon）从内联 SVG 换成用户提供的打包应用图标 `app-icon.png`（3038B，与 EXE icon.ico 同源资源） | `web/dist/app-ui.html`、`web/dist/app-icon.png`、`src-tauri/icons/*` |
| 2 | 设置区 | 上色面板顶部新增 settings-panel：模式三选一（全自动/提示点/参考图，M3 分段单选）、处理器二选一（CPU/GPU，GPU 不可用置灰+原因）、免责声明勾选（未勾选拦截开始）、参考图选择器（选本地图片回显文件名） | `web/dist/app-ui.html`、`app-ui.css`、`app-ui.js` |
| 3 | 日志双主题 | 日志面板改用 M3 令牌（surface-container/on-surface/primary/error），自动跟随明暗；顶栏新增主题切换按钮，`html[data-theme]` 强制覆写块补齐手动切换 | `app-ui.css`、`app.css`（追加 data-theme 覆写）、`app-ui.html` |

## 2. 数据流与持久化

- 前端：localStorage key `manga-colorizer-settings`（mode/device/disclaimer_accepted/theme/refName），启动即恢复
- 服务端：POST /api/v1/settings 白名单校验后写 `gallery/settings.json`（GET 可查），形成可追踪设置台账
- 处理器切换：device=gpu → COLORIZER 运行时 auto（DML/CUDA 优先）；device=cpu → 强制 CPU；切换即清空已加载模型会话，下次任务按新设备重载（日志记「处理器切换: xxx」）
- 免责声明：未勾选点击「开始处理」→ 捕获阶段拦截 + 面板滚动提示，勾选后放行；状态持久化

## 3. 实测记录（本机 RTX 5060）

| 项 | 结果 |
|---|---|
| 设置持久化 | POST {mode:hints,device:gpu,disclaimer:true} → settings.json 落盘 ✓；重启进程 GET 返回一致 ✓ |
| 非法值拦截 | mode=xxx → 400 拒绝 ✓ |
| 处理器切换 | device=cpu → CPUExecutionProvider 生效（30.3s）；device=gpu → DmlExecutionProvider 生效（23.3s 冷启/10.7s 热）；台账与日志设备标签同步 ✓ |
| 安装版终验 | NSIS 0.3.0 /S 静默安装 exit 0；安装版 GPU 上色 1585708B/10.7s，台账 dev=gpu-directml，settings 持久化 {"mode":"auto","device":"gpu","disclaimer_accepted":true} ✓ |
| 安装包 | Manga Colorizer_0.3.0_x64-setup.exe = 99.9MB，注册表 DisplayVersion 0.3.0 |

## 4. 已知边界

- 「提示点/参考图」模式已接入真实端点（/colorize_hints 传空 hints、/colorize_reference 传所选参考图）；提示点画布精修仍在旧工作台（index.html），APP 界面的提示点编辑属后续迭代
- 日志双主题依赖 CSS 变量，若后续在 app.css 增删令牌需同步 data-theme 覆写块（文件末尾）
- 免责声明为通用占位文案，正式法务文案待用户确认后替换（改 app-ui.html 中 .disclaimer span 文本即可）

## 5. 回滚

卸载 0.3.0 → 安装 `DELIVERY\releases\v0.2.0-six-features\` 旧版；设置数据（settings.json/gallery）在 appdata 不受影响；代码回退 `git revert` 或 checkout `v0.2.0-six-features` tag。
