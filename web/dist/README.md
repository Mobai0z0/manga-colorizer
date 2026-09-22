# web/dist — Manga Colorizer 前端

Material Design 3 风格前端，**零构建、零运行时依赖**（MD3 令牌以原生 CSS 变量实现，
未使用官方 `@material/web` npm 包；如需官方组件实现可另行替换，接口不变）。

服务端 `tool/colorizer_service/service.py` 检测到本目录存在时，自动将 `/` 挂载到本目录；
桌面壳（Tauri）的窗口也从打包内的本目录加载页面。跨源访问由服务端 CORS 中间件放行
（服务仅绑定 127.0.0.1，不暴露局域网）。

## 使用

```bash
# 1) 安装并启动服务（见仓库根 readme）
python -m pip install -r tool/colorizer_service/requirements.txt
python -m uvicorn tool.colorizer_service.service:app --port 8788

# 2) 浏览器打开工作台
http://127.0.0.1:8788/
```

## 功能

- 拖放 / 点选上传（PNG / JPEG / WebP，限制从 `/api/v1/capabilities` 读取）
- 服务状态徽标：就绪 / 权重缺失 / 未连接（轮询 `/health`）
- 三种上色模式：全自动 / 提示点（画布逐图落点精修）/ 参考图（色调迁移），均对应后端已实现端点
- 非商业许可确认勾选（CC BY-NC-SA 4.0 提示）
- 原图 / 结果切换对比、结果下载、耗时与尺寸显示
- 浅色 / 深色主题：跟随系统，可通过导航栏按钮手动切换并记忆，`prefers-reduced-motion` 降级动画

## 文件

| 文件 | 说明 |
|---|---|
| `index.html` + `app.js` | 唯一前端页面（浏览器工作台与桌面壳共用：导航 + 批量队列 + 提示点画布 + 参考图 + 图库台账 + 控制台日志） |
| `boot-shell.html` | 桌面壳首次启动的权重下载页（仅 Tauri 内使用） |
| `app.css` | M3 (Expressive) 令牌与组件样式（深浅主题令牌在此维护） |
| `app-shell.css` / `app-ui.css` | 导航壳层与 APP 功能组件样式 |

## 开发注意

- 后端默认只监听 127.0.0.1；对外部署请自行加反向代理、认证与 TLS。
- 前端的许可确认是提示，不构成法律意见，详见 `docs/licensing.md`。
- 改动 JS 后用 `node --check` 验语法；主题相关改动请在深/浅两种 `data-theme` 下目检。
