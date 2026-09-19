# v0.3.2 三缺陷修复说明与验证台账

> 2026-09-19 · 基线 v0.3.1-gpu-fix (360aa43) → v0.3.2
> 三缺陷：深浅主题切换 / 服务器未连接提示 / GPU 检测不到
> 验证环境：Windows 11 25H2 x64 · RTX 5060 Laptop 8GB · 驱动 610.62 · onnxruntime-directml · Tauri 2.11.5

## 一、深浅主题切换

| 项 | 内容 |
|---|---|
| 复现 | 点击左下角主题按钮，手动覆写后偶现部分控件旧配色；重启后主题偶尔回跳 |
| 根因 | ① 切换时读当前主题用 matchMedia（系统偏好），与实际生效主题脱节，连点两次原地打转；② theme 只存 localStorage，服务端 settings.json 台账不含 theme，两端状态分叉 |
| 修复 | 新增 currentTheme() 以 html data-theme 属性为唯一事实源；saveSettings 统一持久化，theme 纳入服务端同步白名单（POST /api/v1/settings 校验 dark/light/null） |
| 改动 | web/dist/app-ui.js（currentTheme/toggleTheme/saveSettings payload）、tool/colorizer_service/service.py（settings 白名单 + 校验） |

验证：安装版 theme=light 写入回读 true → theme=dark 回读 true；settings.json 落盘含 theme:dark ✓。重启后 localStorage 恢复 applyTheme(settings.theme) 立即生效 ✓。

## 二、服务器未连接

| 项 | 内容 |
|---|---|
| 复现 | sidecar 启动慢（onefile 自解压 3-5s）或异常退出时，顶栏只显示「服务未连接」，无原因无重试说明 |
| 根因 | pollHealth 的 catch 分支丢弃错误详情，无尝试计数；权重缺失与服务未连接两种状态提示混在一起 |
| 修复 | 失败分支显示「服务未连接（第 N 次，自动重试中）」+ tooltip 含具体错误（目标 127.0.0.1:8788、错误摘要、排查指引）；权重缺失单独提示「权重缺失，请重启应用重新下载」；5s 自动轮询即重试入口，日志页可追溯 |
| 改动 | web/dist/app-ui.js（pollHealth 重构：svcFailCount、err 详情、title 诊断信息） |

验证：安装版 js 含 自动重试中 ✓；正常路径 5s 轮询命中「服务就绪」✓；服务不可达时 tooltip 显示连接 127.0.0.1:8788 失败原因 ✓。

## 三、GPU 检测不到

| 项 | 内容 |
|---|---|
| 复现 | 界面只显示「GPU · DirectML」，无显卡型号/显存/驱动，无法确认用的是哪块 GPU |
| 根因 | 后端只暴露 Provider 名称，无硬件探针 |
| 修复 | 后端新增 _gpu_info()：优先 nvidia-smi --query-gpu=name,memory.total,driver_version（4s 超时容错），NVIDIA 缺席而 DML 生效时标注「DirectML 兼容 GPU」；/api/v1/device 新增 gpu_info 字段；前端徽标拼接型号，tooltip 显示显存与驱动 |
| 改动 | tool/colorizer_service/service.py（_gpu_info + device 端点）、web/dist/app-ui.js（loadDevice 渲染） |

验证：安装版 /api/v1/device 返回 gpu_info.name=NVIDIA GeForce RTX 5060 Laptop GPU、vram=8151 MiB、driver=610.62 ✓；徽标显示 GPU · DirectML · NVIDIA GeForce RTX 5060 Laptop GPU ✓。无 GPU 机器走 DML 缺席分支 → GPU 选项置灰 + CPU 回退（v0.2.0 逻辑不变）✓。

## 回归测试清单

| # | 项 | 结果 |
|---|---|---|
| 1 | 静默安装（先杀进程）exit 0，四端 MD5 一致（69812196…） | ✓ |
| 2 | 安装版启动 → sidecar 自动拉起 → /health ok | ✓ |
| 3 | 回归上色 girl-bw.png：1,585,708B 输出正常 | ✓ |
| 4 | 设备徽标：加载前 gpu-directml + 型号 | ✓ |
| 5 | 主题 light/dark 双向写入并回读 | ✓ |
| 6 | settings.json 含 theme 字段 | ✓ |
| 7 | js node --check 通过、CSS 括号平衡 | ✓ |
| 8 | 注册表 DisplayVersion 0.3.2 | ✓ |

## 回滚

卸载 0.3.2 → 安装 DELIVERY\releases\v0.3.1-gpu-fix\（先杀 manga-colorizer* 进程，否则 NSIS 静默安装会静默跳过覆盖）；数据/设置不受影响；代码回退 git revert 或 checkout v0.3.1-gpu-fix。
