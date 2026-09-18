# web/ — Manga Colorizer 社区预览前端

Material Design 3 风格的浏览器工作台，**零构建、零运行时依赖**（MD3 令牌以原生 CSS 变量实现，
未使用官方 `@material/web` npm 包；如需官方组件实现可另行替换，接口不变）。

服务端 `tool/colorizer_service/service.py` 检测到本目录存在时，自动将 `/` 挂载到本目录
（同源访问，无 CORS 配置）。

## 使用

```bash
# 1) 安装并启动服务（见仓库根 readme）
python -m pip install -r tool/colorizer_service/requirements.txt
python -m uvicorn tool.colorizer_service.service:app --port 8788

# 2) 浏览器打开
http://127.0.0.1:8788/
```

## 功能

- 拖放 / 点选上传（PNG / JPEG / WebP，限制从 `/api/v1/capabilities` 读取）
- 服务状态徽标：就绪 / 权重缺失 / 未连接（15 秒轮询 `/health`）
- 上色模式选择（参考图 / 提示点在后端支持前禁用，不提供虚假入口）
- 非商业许可确认勾选（CC BY-NC-SA 4.0 提示）
- 原图 / 结果切换对比、结果下载、耗时与尺寸显示
- 浅色 / 深色主题跟随系统，`prefers-reduced-motion` 降级动画

## 文件

| 文件 | 说明 |
|---|---|
| `index.html` | 工作台页面（单页） |
| `app.css` | M3 (Expressive) 令牌与工作台组件样式 |
| `app.js` | 状态轮询、上传、对比、下载逻辑（无框架） |
| `app.html` | APP 界面（桌面 navigation-rail / 手机 navigation-bar 自适应，"上色"页内嵌工作台） |
| `app-shell.css` | APP 导航组件样式（navigation-rail / navigation-bar / fab / switch / list） |

## 开发注意

- 后端默认只监听 127.0.0.1；对外部署请自行加反向代理、认证与 TLS。
- 上色结果仅保存在浏览器内存（objectURL），刷新即失；服务端不落盘。
- 前端的许可确认是提示，不构成法律意见，详见 `docs/licensing.md`。
