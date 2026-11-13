/* Manga Colorizer 前端逻辑（唯一脚本，供 index.html 使用）：
   导航 / 服务与设备状态 / 批量队列（拖拽排序、单条移除）/ 提示点画布编辑 / 参考图 / 图库台账 / 控制台日志 / 设置持久化。
   后端接口见 tool/colorizer_service/service.py。 */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  /* ---------- 中英文案 ---------- */
  const I18N = {
    zh: {
      'app.title': 'Manga Colorizer · 漫画上色工作台',
      'app.sub': '黑白漫画语义上色',
      'nav.main': '主导航',
      'nav.home': '首页', 'nav.colorize': '上色', 'nav.gallery': '图库',
      'nav.logs': '日志', 'nav.settings': '设置',
      'chip.device': '设备检测中…', 'chip.service': '服务检测中…',
      'home.h2': '黑白漫画，一键上色',
      'home.p': '深度模型语义配色：发 / 肤 / 瞳 / 背景自动上色，支持批量排队、提示点精修与参考图色调迁移，亮度始终保真。GPU 自动加速，无 GPU 时回退 CPU。',
      'home.start': '开始上色', 'home.gallery': '浏览图库', 'home.logs': '查看日志',
      'home.f1.t': 'GPU 自动加速',
      'home.f1.d': 'DirectML / CUDA 自适应；日志标明实际设备，不可用时自动回退 CPU 并说明原因',
      'home.f2.t': '批量排队处理',
      'home.f2.d': '多选或拖拽加入队列，按顺序逐个处理，单个失败不阻断，支持中途取消',
      'home.f3.t': '成果图库与台账',
      'home.f3.d': '每次上色自动入库（时间 / 设备 / 耗时），重启后历史完整保留，可定位成品与原图文件',
      'colorize.title': '批量上色',
      'colorize.sub': '按加入顺序逐个处理；完成品自动进入图库。单张 ≤ 20MiB，一次最多 32 张。',
      'set.mode': '上色模式', 'set.mode.auto': '全自动', 'set.mode.hints': '提示点', 'set.mode.reference': '参考图',
      'set.scheme': '色彩方案',
      'scheme.standard': '标准（修复偏黄偏灰）', 'scheme.vivid-cel': '鲜明赛璐璐',
      'scheme.soft-pastel': '柔和淡彩', 'scheme.impasto': '厚涂浓郁', 'scheme.retro-showa': '昭和复古',
      'set.ref': '参考图', 'set.ref.pick': '选择参考图…', 'set.ref.none': '未选择',
      'set.ref.options': '迁移选项', 'set.ref.reinhard': '氛围对齐', 'set.ref.histogram': '分布对齐',
      'set.strength': '强度',
      'set.device': '推理后端', 'set.device.cpu': 'CPU', 'set.device.gpu': 'GPU',
      'set.disclaimer': '我确认对处理内容拥有合法权利；上色结果仅供个人创作与预览，不用于商业发布（模型权重 CC BY-NC-SA 4.0）。',
      'hints.title': '提示点编辑', 'hints.none': '未选择图片',
      'hints.hint': '点击下方队列中的图片载入画布；先选颜色再点画布落点，双击圆点删除。',
      'hints.placeholder': '从队列中选择一张图片，在此画布上放置提示点。',
      'hints.selected': '{name} · 已放 {n} 个提示点', 'hints.selected1': '{name} · 已放 {n} 个提示点',
      'hints.dot': '提示点 {n} · 双击删除',
      'swatch.red': '红色', 'swatch.orange': '橙色', 'swatch.yellow': '黄色', 'swatch.green': '绿色',
      'swatch.blue': '蓝色', 'swatch.purple': '紫色', 'swatch.skin': '肤色', 'swatch.brown': '深棕',
      'swatch.custom': '自定义颜色',
      'queue.drop': '拖拽图片到此处，或点击选择',
      'queue.dropHint': 'PNG / JPEG / WebP · 长图自动分块推理',
      'queue.add': '添加图片',
      'queue.run': '开始处理', 'queue.cancel': '取消', 'queue.clear': '清空队列',
      'queue.title': '队列', 'queue.count0': '0 项', 'queue.count': '{n} 项', 'queue.count1': '{n} 项',
      'queue.empty': '队列空空如也。添加图片开始吧。',
      'queue.status.wait': '等待', 'queue.status.run': '处理中', 'queue.status.ok': '完成', 'queue.status.fail': '失败',
      'queue.remove': '移除 {name}', 'queue.itemHints': '{n} 个提示点', 'queue.itemHints1': '{n} 个提示点',
      'queue.summary.cancel': '已取消', 'queue.summary.done': '全部完成',
      'queue.summary.counts': '成功 {ok} · 失败 {bad}',
      'queue.summary.skip': '未处理 {n}',
      'queue.summary.time': '总耗时 {secs}s。成品已入图库。',
      'gallery.title': '图库', 'gallery.sub': '上色成品按时间倒序',
      'gallery.openDir': '打开输出文件夹', 'gallery.refresh': '刷新',
      'gallery.empty': '还没有成品。去「上色」处理第一张图吧。',
      'logs.title': '控制台日志',
      'logs.sub': '实时滚动，含时间戳与级别（信息 / 警告 / 错误），同步写入 logs\\app-*.log',
      'lightbox.alt': '上色结果大图', 'lightbox.openDir': '打开输出文件夹', 'lightbox.close': '关闭',
      'theme.toDark': '切换到深色主题', 'theme.toLight': '切换到浅色主题', 'theme.toggle': '切换深浅主题',
      'settings.title': '设置', 'settings.sub': '外观、模型与设备诊断',
      'settings.appearance': '外观',
      'settings.language': '语言', 'settings.lang.auto': '跟随系统', 'settings.lang.zh': '中文', 'settings.lang.en': 'English',
      'settings.theme': '主题', 'settings.theme.auto': '跟随系统', 'settings.theme.light': '浅色', 'settings.theme.dark': '深色',
      'settings.background': '背景', 'settings.bg.monet': '莫奈流动', 'settings.bg.plain': '默认',
      'settings.bg.hint': '莫奈流动＝暖纸画布上三色球漫游；默认＝纯色画布，低端机或省电时更省 GPU。',
      'settings.model': '模型',
      'settings.source': '下载源', 'settings.source.auto': '自动（推荐）',
      'settings.source.primary': '仅主站', 'settings.source.mirror': '仅镜像',
      'settings.source.hint.auto': '主站优先，失败自动改走镜像续传',
      'settings.source.hint.primary': '国内网络通常无法直连，可能失败',
      'settings.source.hint.mirror': '直连镜像站，不经主站',
      'settings.source.note': '下载源在下次获取模型权重时生效。',
      'settings.weights': '权重状态', 'settings.openWeights': '打开权重目录',
      'settings.weights.ready': '已就绪 · {ver} · {size}',
      'settings.weights.partial': '未完成 · {done} / {total}',
      'settings.weights.missing': '未下载', 'settings.weights.unavailable': '仅桌面版可查看',
      'settings.device': '设备',
      'settings.gpu.hardware': '硬件', 'settings.gpu.provider': 'Provider',
      'settings.gpu.vram': '显存', 'settings.gpu.driver': '驱动', 'settings.gpu.redetect': '重新检测',
      'settings.gpu.active': 'GPU 加速已启用 · {label}',
      'settings.gpu.cpuSelected': '当前使用 CPU（GPU 可用）',
      'settings.gpu.noProvider': '检测到 GPU，但当前服务缺少 DirectML / CUDA 运行库',
      'settings.gpu.none': '未检测到独立 GPU',
      'settings.gpu.fix': '{name}：当前为 CPU 运行时，暂无法使用 GPU。请安装 GPU 版（DirectML）安装包，或用 requirements-directml.txt 重新构建桌面服务。',
      'settings.about': '关于', 'settings.version': '版本', 'settings.license': '许可',
      'settings.license.text': '代码 Apache-2.0；模型权重 CC BY-NC-SA 4.0（不随安装包分发）。',
      'svc.failed': '模型加载失败，请重启应用',
      'svc.failed.title': '若反复失败，请查看日志页并确认系统可用内存充足',
      'svc.ready': '服务就绪',
      'svc.sleeping': '模型休眠中 · 上色时自动唤醒',
      'svc.sleeping.title': '空闲超时已释放模型内存/显存；提交上色后会自动重新加载（约 10-20 秒）',
      'svc.preloading': '模型预热中…',
      'svc.preloading.title': '模型正在后台加载（首次约 10-20 秒），完成后上色不再等待',
      'svc.noWeights': '权重缺失，请重启应用重新下载',
      'svc.noWeights.title': '权重目录: {dir}',
      'svc.offline': '服务未连接（第 {n} 次，自动重试中）',
      'svc.offline.title': '连接 127.0.0.1:8788 失败: {err}\nsidecar 由应用自动拉起；持续失败请查看日志页',
      'gpu.cuda': 'GPU · CUDA', 'gpu.dml': 'GPU · DirectML',
      'gpu.cpu': 'CPU 模式', 'gpu.cpuNoAccel': 'CPU · GPU 未加速',
      'gpu.pill.providers': '可用 Provider: {list}',
      'gpu.pill.estimated': '（模型加载前为预估设备）',
      'gpu.pill.vram': '显存: {vram}', 'gpu.pill.driver': '驱动: {driver}',
      'gpu.pill.hwOnly': '检测到 GPU 硬件，但当前服务是 CPU 运行时（缺少 DirectML/CUDA Provider），请安装 GPU 版',
      'gpu.note.noProvider': '检测到 {name}，但当前服务缺少 DirectML/CUDA 运行库，暂以 CPU 运行；请安装 GPU 版',
      'gpu.note.none': '本机未检测到可用 GPU（需要 DirectML 或 CUDA Provider）',
      'gpu.note.serviceOff': '服务未连接，暂无法检测 GPU（就绪后自动恢复）',
      'toast.batchDone': '批量处理完成：成功 {ok} / 失败 {bad}',
      'toast.needDisclaimer': '请先勾选免责声明，再开始上色。',
      'toast.deviceHint': '推理后端已切换为 {dev}，将在下次处理时生效。',
      'toast.needHints': '请先在画布上为该图放置提示点',
      'toast.needRef': '参考图模式：请先选择参考图',
      'toast.busy': '模型忙碌，请稍后重试',
      'toast.badFormat': '不支持的格式',
    },
    en: {
      'app.title': 'Manga Colorizer · Manga colorization studio',
      'app.sub': 'Semantic colorization for black-and-white manga',
      'nav.main': 'Main navigation',
      'nav.home': 'Home', 'nav.colorize': 'Colorize', 'nav.gallery': 'Gallery',
      'nav.logs': 'Logs', 'nav.settings': 'Settings',
      'chip.device': 'Detecting device…', 'chip.service': 'Checking service…',
      'home.h2': 'Black-and-white manga, colored in one click',
      'home.p': 'A deep model assigns colors by semantics—hair, skin, eyes, background—with batch queues, hint-point refinement, and reference-image color transfer. Luminance stays true. GPU acceleration is automatic, with CPU fallback.',
      'home.start': 'Start colorizing', 'home.gallery': 'Browse gallery', 'home.logs': 'View logs',
      'home.f1.t': 'Automatic GPU acceleration',
      'home.f1.d': 'Adapts to DirectML or CUDA, logs the device in use, and falls back to CPU with a clear reason.',
      'home.f2.t': 'Batch queue',
      'home.f2.d': 'Add images by multi-select or drag-and-drop; process in order, continue past failures, and cancel anytime.',
      'home.f3.t': 'Result gallery and ledger',
      'home.f3.d': 'Every run is catalogued (time, device, duration) and kept across restarts, with links to results and source files.',
      'colorize.title': 'Batch colorize',
      'colorize.sub': 'Processed in queue order; results go straight to the gallery. Up to 20 MiB per image, 32 images per run.',
      'set.mode': 'Mode', 'set.mode.auto': 'Auto', 'set.mode.hints': 'Hints', 'set.mode.reference': 'Reference',
      'set.scheme': 'Palette',
      'scheme.standard': 'Standard (fixes yellow/gray cast)', 'scheme.vivid-cel': 'Vivid cel',
      'scheme.soft-pastel': 'Soft pastel', 'scheme.impasto': 'Impasto', 'scheme.retro-showa': 'Retro Showa',
      'set.ref': 'Reference', 'set.ref.pick': 'Choose image…', 'set.ref.none': 'None',
      'set.ref.options': 'Transfer', 'set.ref.reinhard': 'Mood match', 'set.ref.histogram': 'Histogram match',
      'set.strength': 'Strength',
      'set.device': 'Inference backend', 'set.device.cpu': 'CPU', 'set.device.gpu': 'GPU',
      'set.disclaimer': 'I confirm I have the rights to the content I process; results are for personal creation and preview only, not commercial publication (model weights: CC BY-NC-SA 4.0).',
      'hints.title': 'Hint editor', 'hints.none': 'No image selected',
      'hints.hint': 'Click an image in the queue to load it. Pick a color, then click the canvas to place a hint; double-click a dot to remove it.',
      'hints.placeholder': 'Select an image from the queue to place hints on this canvas.',
      'hints.selected': '{name} · {n} hints', 'hints.selected1': '{name} · {n} hint',
      'hints.dot': 'Hint {n} · double-click to remove',
      'swatch.red': 'Red', 'swatch.orange': 'Orange', 'swatch.yellow': 'Yellow', 'swatch.green': 'Green',
      'swatch.blue': 'Blue', 'swatch.purple': 'Purple', 'swatch.skin': 'Skin', 'swatch.brown': 'Dark brown',
      'swatch.custom': 'Custom color',
      'queue.drop': 'Drop images here, or click to choose',
      'queue.dropHint': 'PNG / JPEG / WebP · tall images are tiled automatically',
      'queue.add': 'Add images',
      'queue.run': 'Start', 'queue.cancel': 'Cancel', 'queue.clear': 'Clear queue',
      'queue.title': 'Queue', 'queue.count0': '0 items', 'queue.count': '{n} items', 'queue.count1': '{n} item',
      'queue.empty': 'The queue is empty. Add some images to begin.',
      'queue.status.wait': 'Waiting', 'queue.status.run': 'Processing', 'queue.status.ok': 'Done', 'queue.status.fail': 'Failed',
      'queue.remove': 'Remove {name}', 'queue.itemHints': '{n} hints', 'queue.itemHints1': '{n} hint',
      'queue.summary.cancel': 'Cancelled', 'queue.summary.done': 'All done',
      'queue.summary.counts': '{ok} succeeded · {bad} failed',
      'queue.summary.skip': '{n} skipped',
      'queue.summary.time': 'Total {secs}s. Results are in the gallery.',
      'gallery.title': 'Gallery', 'gallery.sub': 'Newest results first',
      'gallery.openDir': 'Open output folder', 'gallery.refresh': 'Refresh',
      'gallery.empty': 'No results yet. Head to Colorize to process your first image.',
      'logs.title': 'Console log',
      'logs.sub': 'Live stream with timestamps and levels (info / warning / error), mirrored to logs\\app-*.log',
      'lightbox.alt': 'Full-size colorized result', 'lightbox.openDir': 'Open output folder', 'lightbox.close': 'Close',
      'theme.toDark': 'Switch to dark theme', 'theme.toLight': 'Switch to light theme', 'theme.toggle': 'Toggle light/dark theme',
      'settings.title': 'Settings', 'settings.sub': 'Appearance, model and device diagnostics',
      'settings.appearance': 'Appearance',
      'settings.language': 'Language', 'settings.lang.auto': 'System', 'settings.lang.zh': '中文', 'settings.lang.en': 'English',
      'settings.theme': 'Theme', 'settings.theme.auto': 'System', 'settings.theme.light': 'Light', 'settings.theme.dark': 'Dark',
      'settings.background': 'Background', 'settings.bg.monet': 'Monet flow', 'settings.bg.plain': 'Plain',
      'settings.bg.hint': 'Monet flow animates three soft color fields on warm paper; Plain uses a solid canvas and saves GPU on low-end or battery-powered machines.',
      'settings.model': 'Model',
      'settings.source': 'Download source', 'settings.source.auto': 'Auto (recommended)',
      'settings.source.primary': 'Primary only', 'settings.source.mirror': 'Mirror only',
      'settings.source.hint.auto': 'Primary first; falls back to the mirror and resumes on failure',
      'settings.source.hint.primary': 'May fail on mainland networks that cannot reach the primary site',
      'settings.source.hint.mirror': 'Uses the mirror directly, skipping the primary site',
      'settings.source.note': 'The source applies the next time model weights are downloaded.',
      'settings.weights': 'Weights', 'settings.openWeights': 'Open weights folder',
      'settings.weights.ready': 'Ready · {ver} · {size}',
      'settings.weights.partial': 'Incomplete · {done} / {total}',
      'settings.weights.missing': 'Not downloaded', 'settings.weights.unavailable': 'Available in the desktop app only',
      'settings.device': 'Device',
      'settings.gpu.hardware': 'Hardware', 'settings.gpu.provider': 'Provider',
      'settings.gpu.vram': 'VRAM', 'settings.gpu.driver': 'Driver', 'settings.gpu.redetect': 'Detect again',
      'settings.gpu.active': 'GPU acceleration enabled · {label}',
      'settings.gpu.cpuSelected': 'Running on CPU (GPU available)',
      'settings.gpu.noProvider': 'GPU found, but this service lacks the DirectML / CUDA runtime',
      'settings.gpu.none': 'No discrete GPU detected',
      'settings.gpu.fix': '{name}: this build runs the CPU runtime, so the GPU is unavailable. Install the GPU (DirectML) build, or rebuild the desktop service with requirements-directml.txt.',
      'settings.about': 'About', 'settings.version': 'Version', 'settings.license': 'License',
      'settings.license.text': 'Code: Apache-2.0. Model weights: CC BY-NC-SA 4.0 (not bundled).',
      'svc.failed': 'Model failed to load. Restart the app.',
      'svc.failed.title': 'If it keeps failing, check the Logs page and make sure enough system memory is free.',
      'svc.ready': 'Service ready',
      'svc.sleeping': 'Model asleep · wakes on colorize',
      'svc.sleeping.title': 'Idle timeout released model memory/VRAM; colorizing reloads it automatically (about 10-20 s).',
      'svc.preloading': 'Preloading model…',
      'svc.preloading.title': 'The model is loading in the background (about 10-20 s on first run); colorizing will not wait once it is ready.',
      'svc.noWeights': 'Weights missing. Restart the app to download them.',
      'svc.noWeights.title': 'Weights folder: {dir}',
      'svc.offline': 'Service offline (attempt {n}, retrying)',
      'svc.offline.title': 'Failed to reach 127.0.0.1:8788: {err}\nThe sidecar is started automatically; check the Logs page if it keeps failing.',
      'gpu.cuda': 'GPU · CUDA', 'gpu.dml': 'GPU · DirectML',
      'gpu.cpu': 'CPU mode', 'gpu.cpuNoAccel': 'CPU · GPU idle',
      'gpu.pill.providers': 'Available providers: {list}',
      'gpu.pill.estimated': '(device is estimated before the model loads)',
      'gpu.pill.vram': 'VRAM: {vram}', 'gpu.pill.driver': 'Driver: {driver}',
      'gpu.pill.hwOnly': 'GPU hardware detected, but this service uses the CPU runtime (no DirectML/CUDA provider). Install the GPU build.',
      'gpu.note.noProvider': '{name} detected, but the service lacks the DirectML/CUDA runtime and runs on CPU. Install the GPU build.',
      'gpu.note.none': 'No usable GPU detected (DirectML or CUDA provider required)',
      'gpu.note.serviceOff': 'Service offline — GPU detection resumes when it is ready',
      'toast.batchDone': 'Batch finished: {ok} succeeded / {bad} failed',
      'toast.needDisclaimer': 'Accept the disclaimer before colorizing.',
      'toast.deviceHint': 'Inference backend switched to {dev}; it takes effect on the next run.',
      'toast.needHints': 'Place at least one hint on this image first',
      'toast.needRef': 'Reference mode: choose a reference image first',
      'toast.busy': 'Model busy — try again shortly',
      'toast.badFormat': 'Unsupported format',
    },
  };

  let lang = 'zh';
  const resolveLang = (pref) => {
    if (pref === 'zh' || pref === 'en') return pref;
    return String(navigator.language || 'zh').toLowerCase().startsWith('zh') ? 'zh' : 'en';
  };
  function t(key, vars) {
    const table = I18N[lang] || I18N.zh;
    let text = table[key];
    if (text == null) text = I18N.zh[key];
    if (text == null) return key;
    return String(text).replace(/\{(\w+)\}/g, (m, name) =>
      (vars && Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : m));
  }
  function applyI18n() {
    document.documentElement.lang = lang === 'zh' ? 'zh-CN' : 'en';
    document.title = t('app.title');
    document.querySelectorAll('[data-i18n]').forEach((el) => { el.textContent = t(el.dataset.i18n); });
    document.querySelectorAll('[data-i18n-title]').forEach((el) => { el.title = t(el.dataset.i18nTitle); });
    document.querySelectorAll('[data-i18n-aria]').forEach((el) => { el.setAttribute('aria-label', t(el.dataset.i18nAria)); });
    document.querySelectorAll('[data-i18n-alt]').forEach((el) => { el.alt = t(el.dataset.i18nAlt); });
    if (typeof syncThemeButton === 'function') syncThemeButton();
  }

  /* ---------- 导航 ---------- */
  const screens = {
    home: 'screen-home', colorize: 'screen-colorize', gallery: 'screen-gallery',
    logs: 'screen-logs', settings: 'screen-settings',
  };
  document.addEventListener('click', (e) => {
    const btn = e.target.closest('[data-nav]');
    if (btn) show(btn.dataset.nav);
  });
  function show(name) {
    if (!screens[name]) return;
    for (const [k, id] of Object.entries(screens)) $(id).hidden = k !== name;
    document.querySelectorAll('[data-nav]').forEach((btn) => {
      btn.classList.toggle('is-active', btn.dataset.nav === name);
    });
    if (name === 'gallery') refreshGallery();
    if (name === 'logs') scrollConsole();
    if (name === 'settings') { refreshWeights(); pollHealth(); }
    window.scrollTo({ top: 0 });
  }

  /* ---------- Tauri 桥（存在才用） ---------- */
  // API base: 页面由 sidecar 同源提供（浏览器打开 127.0.0.1:8788）时用相对路径；
  // 打包窗口固定运行在 http://tauri.localhost 源上，必须直连 sidecar 绝对地址
  //（sidecar 已放开 CORS，见 service.py）。
  const SERVICE_PORT = '8788';
  const API = location.port === SERVICE_PORT ? '' : 'http://127.0.0.1:' + SERVICE_PORT;
  const api = (path) => API + path;
  const isTauri = !!(window.__TAURI__ && window.__TAURI__.core);
  const invoke = isTauri ? window.__TAURI__.core.invoke : null;

  /* ---------- 消息条（M3 snackbar） ---------- */
  let snackTimer = 0;
  function toast(msg, isErr = false) {
    const el = $('snackbar');
    el.textContent = msg;
    el.classList.toggle('err', isErr);
    el.hidden = false;
    clearTimeout(snackTimer);
    snackTimer = setTimeout(() => { el.hidden = true; }, isErr ? 6000 : 3500);
  }

  /* ---------- 服务与设备状态（/health 单次轮询同时刷新两个徽标） ---------- */
  let svcFailCount = 0;
  let lastDevice = null;
  async function pollHealth() {
    const pill = $('svc-pill');
    try {
      const r = await fetch(api('/health'), { cache: 'no-store' });
      const j = await r.json();
      svcFailCount = 0;
      if (j.model_status === 'failed') {
        pill.textContent = t('svc.failed');
        pill.className = 'm3-chip is-bad';
        pill.title = (j.model_error || '') + '\n' + t('svc.failed.title');
      } else if (j.weights_present && (j.generator_loaded || j.sam_loaded)) {
        pill.textContent = t('svc.ready'); pill.className = 'm3-chip is-good';
      } else if (j.weights_present && j.model_status === 'idle') {
        pill.textContent = t('svc.sleeping');
        pill.className = 'm3-chip';
        pill.title = t('svc.sleeping.title');
      } else if (j.weights_present) {
        pill.textContent = t('svc.preloading'); pill.className = 'm3-chip';
        pill.title = t('svc.preloading.title');
      } else {
        pill.textContent = t('svc.noWeights'); pill.className = 'm3-chip is-bad';
        pill.title = t('svc.noWeights.title', {
          dir: j.model_dir || '%LOCALAPPDATA%\\manga-colorizer\\weights',
        });
      }
      applyDevice(j.device_info);
    } catch (err) {
      svcFailCount += 1;
      pill.textContent = t('svc.offline', { n: svcFailCount });
      pill.className = 'm3-chip is-bad';
      pill.title = t('svc.offline.title', { err: String(err).slice(0, 120) });
      applyDevice(null);
    }
  }
  function applyDevice(d) {
    lastDevice = d || null;
    const gpu = d && d.device && d.device !== 'cpu';
    const gi = d && d.gpu_info ? d.gpu_info : null;
    const hwName = gi && gi.name && gi.kind !== 'directml' ? gi.name : '';
    let label = '…';
    if (d) {
      if (d.device === 'gpu-cuda') label = t('gpu.cuda');
      else if (d.device === 'gpu-directml') label = t('gpu.dml');
      else label = hwName ? t('gpu.cpuNoAccel') : t('gpu.cpu');
    }
    const pill = $('dev-pill');
    pill.textContent = gi && gi.name ? label + ' · ' + gi.name : label;
    pill.className = 'm3-chip ' + (gpu ? 'is-good' : 'is-warn');
    if (d) {
      let title = t('gpu.pill.providers', { list: (d.available || []).join(', ') || '—' });
      if (!d.loaded_device) title += '\n' + t('gpu.pill.estimated');
      if (gi && gi.vram) title += '\n' + t('gpu.pill.vram', { vram: gi.vram });
      if (gi && gi.driver) title += '\n' + t('gpu.pill.driver', { driver: gi.driver });
      if (!gpu && hwName) title += '\n' + t('gpu.pill.hwOnly');
      pill.title = title;
    } else {
      pill.title = '';
    }
    if (d && d.output_dir) { outDir = d.output_dir; $('g-outdir').title = outDir; }
    updateDeviceAbility(d);
    renderGpuDiagnostics(d);
  }

  /* ---------- 批量队列 ---------- */
  const queue = [];
  const MAXN = 32;
  let running = false, cancelFlag = false;
  const drop = $('drop'), input = $('file-input');

  const openPicker = () => input.click();
  drop.addEventListener('click', openPicker);
  drop.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openPicker(); } });
  input.addEventListener('change', () => { addFiles(input.files); input.value = ''; });
  ['dragover', 'dragenter'].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.add('over'); }));
  ['dragleave', 'drop'].forEach((ev) => drop.addEventListener(ev, (e) => { e.preventDefault(); drop.classList.remove('over'); }));
  drop.addEventListener('drop', (e) => addFiles(e.dataTransfer.files));
  document.addEventListener('dragover', (e) => e.preventDefault());
  document.addEventListener('drop', (e) => e.preventDefault());

  function addFiles(list) {
    for (const f of list) {
      if (queue.length >= MAXN) break;
      if (!/\.(png|jpe?g|webp)$/i.test(f.name)) continue;
      queue.push({ file: f, status: 'wait', error: null, thumbUrl: null, hints: [] });
    }
    renderQueue();
  }

  function renderQueue() {
    const box = $('q-list');
    $('q-empty').hidden = queue.length > 0;
    // 增量更新：行元素与缩略图 objectURL 复用，状态变化只刷新文本/class；
    // 整表 innerHTML 重建会让每张缩略图随每次状态轮转重新解码
    while (box.children.length > queue.length) box.removeChild(box.lastChild);
    for (const it of queue) {
      if (!it.row) {
        const row = document.createElement('div');
        row.className = 'q-item';
        const th = document.createElement('img');
        th.className = 'q-thumb'; th.alt = '';
        th.draggable = false; // 让拖拽作用于行排序, 而不是触发浏览器默认的图片拖拽
        it.thumbUrl = it.thumbUrl || URL.createObjectURL(it.file);
        th.src = it.thumbUrl;
        const nm = document.createElement('span');
        nm.className = 'q-nm';
        nm.textContent = it.file.name;
        const st = document.createElement('span');
        st.className = 'q-st';
        const del = document.createElement('button');
        del.className = 'q-del';
        del.type = 'button';
        del.textContent = '×';
        del.setAttribute('aria-label', t('queue.remove', { name: it.file.name }));
        del.addEventListener('click', (e) => { e.stopPropagation(); removeItem(it); });
        // Enter/Space 已由按钮本身处理, 不再冒泡到行（避免同时触发选中）
        del.addEventListener('keydown', (e) => e.stopPropagation());
        row.append(th, nm, st, del);
        row.tabIndex = 0;
        row.setAttribute('role', 'button');
        row.addEventListener('click', () => selectItem(it));
        row.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); selectItem(it); }
        });
        attachDragHandlers(row, it);
        it.row = row; it.nameEl = nm; it.statusEl = st; it.delEl = del;
        box.appendChild(row);
      }
      it.row.className = 'q-item is-' + it.status + (selected === it ? ' is-sel' : '');
      it.row.draggable = !running;
      it.delEl.disabled = running;
      it.delEl.title = t('queue.remove', { name: it.file.name });
      it.statusEl.textContent = t('queue.status.' + it.status);
      it.nameEl.title = it.file.name + ' · ' + (it.file.size / 1048576).toFixed(1) + 'MB'
        + (it.hints.length ? ' · ' + t(it.hints.length === 1 ? 'queue.itemHints1' : 'queue.itemHints', { n: it.hints.length }) : '')
        + (it.error ? ' · ' + it.error : '');
    }
    // 行按队列当前顺序重排（appendChild 移动已有节点, 不重建、不重新解码缩略图）
    for (const it of queue) box.appendChild(it.row);
    $('q-count').textContent = t(queue.length === 1 ? 'queue.count1' : 'queue.count', { n: queue.length });
    $('btn-run').disabled = running || queue.length === 0;
    $('btn-cancel').disabled = !running;
    $('btn-clear').disabled = running || queue.length === 0;
  }

  function removeItem(it) {
    if (running) return;
    const i = queue.indexOf(it);
    if (i < 0) return;
    queue.splice(i, 1);
    if (it.row) { it.row.remove(); it.row = null; }
    if (it.thumbUrl) URL.revokeObjectURL(it.thumbUrl);
    if (selected === it) { selected = null; syncHintCanvas(); }
    renderQueue();
  }

  /* 行拖拽排序：HTML5 DnD，行中点判定插入到目标之前/之后 */
  let dragItem = null;
  function clearDropMarkers() {
    document.querySelectorAll('.q-item.drop-above, .q-item.drop-below')
      .forEach((r) => r.classList.remove('drop-above', 'drop-below'));
  }
  function attachDragHandlers(row, it) {
    row.addEventListener('dragstart', (e) => {
      if (running) { e.preventDefault(); return; }
      dragItem = it;
      row.classList.add('is-dragging');
      e.dataTransfer.effectAllowed = 'move';
      e.dataTransfer.setData('text/plain', it.file.name);
    });
    row.addEventListener('dragend', () => {
      dragItem = null;
      row.classList.remove('is-dragging');
      clearDropMarkers();
    });
    row.addEventListener('dragover', (e) => {
      if (!dragItem || dragItem === it) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      const rect = row.getBoundingClientRect();
      const before = e.clientY < rect.top + rect.height / 2;
      row.classList.toggle('drop-above', before);
      row.classList.toggle('drop-below', !before);
    });
    row.addEventListener('dragleave', () => row.classList.remove('drop-above', 'drop-below'));
    row.addEventListener('drop', (e) => {
      if (!dragItem || dragItem === it) return;
      e.preventDefault();
      e.stopPropagation();
      const rect = row.getBoundingClientRect();
      moveItem(dragItem, it, e.clientY < rect.top + rect.height / 2);
    });
  }
  function moveItem(drag, over, before) {
    const from = queue.indexOf(drag), to = queue.indexOf(over);
    if (from < 0 || to < 0) return;
    queue.splice(from, 1);
    // 摘除后目标索引前移一位（from < to 时）
    queue.splice(from < to ? (before ? to - 1 : to) : (before ? to : to + 1), 0, drag);
    renderQueue();
  }

  $('btn-clear').addEventListener('click', () => {
    if (running) return;
    queue.forEach((it) => it.thumbUrl && URL.revokeObjectURL(it.thumbUrl));
    queue.length = 0;
    $('q-summary').hidden = true;
    selected = null;
    renderQueue();
    syncHintCanvas();
  });
  $('btn-cancel').addEventListener('click', () => { cancelFlag = true; $('btn-cancel').disabled = true; });

  /* ---------- 提示点画布编辑（提示点模式，逐队列项保存） ---------- */
  let selected = null;               // 当前在画布上编辑的队列项
  let activeColor = '#e53935';
  const viewImg = $('view-original');

  $('swatches').addEventListener('click', (e) => {
    const btn = e.target.closest('.swatch');
    if (!btn) return;
    if (!btn.dataset.color) return; // 自定义色圆点（无 data-color）：交给 input 事件
    $('swatches').querySelectorAll('.swatch').forEach((b) => b.classList.toggle('is-active', b === btn));
    activeColor = btn.dataset.color;
  });

  // 自定义颜色：原生 input[type=color]，input 事件随拖动实时生效；
  // 选中后圆点填充所选色并转实线描边（标记 is-custom-picked）。
  const customColorInput = $('custom-color');
  const customSwatch = customColorInput.closest('.swatch');
  customColorInput.addEventListener('input', () => {
    customSwatch.style.setProperty('--sw', customColorInput.value);
    customSwatch.classList.add('is-custom-picked');
    $('swatches').querySelectorAll('.swatch').forEach((b) => b.classList.toggle('is-active', b === customSwatch));
    activeColor = customColorInput.value;
  });

  function selectItem(it) {
    selected = it;
    renderQueue();
    syncHintCanvas();
  }

  // 按当前模式/选项同步画布：载入选中图或回到空占位
  function syncHintCanvas() {
    const has = Boolean(selected);
    $('hint-placeholder').hidden = has;
    $('canvas-stage').hidden = !has;
    if (has) {
      if (viewImg.src !== selected.thumbUrl) viewImg.src = selected.thumbUrl;
      renderHints();
    }
    updateHintsCount();
  }

  function updateHintsCount() {
    $('hints-count').textContent = !selected ? t('hints.none')
      : t(selected.hints.length === 1 ? 'hints.selected1' : 'hints.selected', { name: selected.file.name, n: selected.hints.length });
  }

  // 提示点以原图像素坐标保存；绘制时按显示尺寸缩放
  function renderHints() {
    const layer = $('hint-layer');
    layer.innerHTML = '';
    if (!selected || !viewImg.naturalWidth) return;
    const sx = viewImg.clientWidth / viewImg.naturalWidth;
    const sy = viewImg.clientHeight / viewImg.naturalHeight;
    selected.hints.forEach((h, i) => {
      const dot = document.createElement('button');
      dot.className = 'hint-dot';
      dot.style.left = `${h.x * sx}px`;
      dot.style.top = `${h.y * sy}px`;
      dot.style.background = h.color;
      dot.title = t('hints.dot', { n: i + 1 });
      dot.addEventListener('dblclick', () => {
        selected.hints.splice(i, 1);
        renderHints();
        updateHintsCount();
      });
      layer.appendChild(dot);
    });
  }

  $('hint-layer').addEventListener('click', (e) => {
    if (settings.mode !== 'hints' || !selected || !viewImg.naturalWidth) return;
    // 点在提示点上：留给 dblclick 删除，不再新增；多击（detail>1）也不落点
    if (e.target.closest('.hint-dot') || e.detail > 1) return;
    const rect = viewImg.getBoundingClientRect();
    const x = Math.round((e.clientX - rect.left) / rect.width * viewImg.naturalWidth);
    const y = Math.round((e.clientY - rect.top) / rect.height * viewImg.naturalHeight);
    selected.hints.push({ x, y, color: activeColor });
    renderHints();
    updateHintsCount();
  });
  viewImg.addEventListener('load', renderHints);
  window.addEventListener('resize', () => { if (settings.mode === 'hints') renderHints(); });

  function hintsPayload(it) {
    return JSON.stringify(it.hints.map((h) => ({
      x: h.x, y: h.y,
      r: parseInt(h.color.slice(1, 3), 16),
      g: parseInt(h.color.slice(3, 5), 16),
      b: parseInt(h.color.slice(5, 7), 16),
    })));
  }

  /* ---------- 队列执行（按模式路由端点） ---------- */
  function isDisclaimerOk() { return $('disclaimer').checked; }
  $('btn-run').addEventListener('click', async () => {
    if (!isDisclaimerOk()) return; // gated; hint handled by capture listener
    if (running || !queue.length) return;
    running = true; cancelFlag = false;
    renderQueue();
    const t0 = performance.now();
    for (const it of queue) {
      if (cancelFlag) continue;
      it.status = 'run'; renderQueue();
      try {
        const fd = new FormData();
        fd.append('image', it.file, it.file.name);
        let endpoint = '/colorize_auto';
        if (settings.mode === 'hints') {
          if (!it.hints.length) { it.status = 'fail'; it.error = t('toast.needHints'); renderQueue(); continue; }
          endpoint = '/colorize_hints';
          fd.append('hints', hintsPayload(it));
        } else if (settings.mode === 'reference') {
          if (!refFile) throw new Error(t('toast.needRef'));
          endpoint = '/colorize_reference';
          fd.append('reference', refFile, refFile.name);
          fd.append('method', settings.refMethod);
          fd.append('strength', String(settings.refStrength));
        } else {
          fd.append('scheme', settings.scheme);
        }
        const r = await fetch(api(endpoint), { method: 'POST', body: fd });
        if (r.status === 429) { it.status = 'fail'; it.error = t('toast.busy'); }
        else if (r.ok) { it.status = 'ok'; }
        else {
          let msg = 'HTTP ' + r.status;
          try { msg = (await r.json()).error || msg; } catch { }
          it.status = 'fail'; it.error = msg;
        }
      } catch (err) { it.status = 'fail'; it.error = String(err); }
      renderQueue();
    }
    running = false; renderQueue();
    const ok = queue.filter((i) => i.status === 'ok').length;
    const bad = queue.filter((i) => i.status === 'fail').length;
    const skip = queue.length - ok - bad;
    const secs = ((performance.now() - t0) / 1000).toFixed(1);
    const s = $('q-summary');
    s.hidden = false;
    s.textContent = t(cancelFlag ? 'queue.summary.cancel' : 'queue.summary.done') + ' — '
      + t('queue.summary.counts', { ok, bad })
      + (skip ? ' · ' + t('queue.summary.skip', { n: skip }) : '')
      + ' · ' + t('queue.summary.time', { secs });
    toast(t('toast.batchDone', { ok, bad }), bad > 0);
  });

  /* ---------- 图库 ---------- */
  let outDir = '';
  let lastGalleryKey = '';
  async function refreshGallery() {
    let j;
    try { j = await (await fetch(api('/api/v1/gallery?limit=200'), { cache: 'no-store' })).json(); } catch { return; }
    const items = (j.items || []).filter((x) => x.status === 'ok' && x.result_file);
    // 台账无变化时跳过重渲染（定时轮询下避免反复重建 DOM/重新拉图）
    const key = (j.count || 0) + '|' + (items.length ? items[0].id : '');
    if (key === lastGalleryKey) return;
    lastGalleryKey = key;
    const grid = $('g-grid');
    grid.innerHTML = '';
    $('g-empty').hidden = items.length > 0;
    for (const it of items) {
      const card = document.createElement('div');
      card.className = 'card media-card';
      const img = document.createElement('img');
      img.className = 'media-card__thumb'; img.loading = 'lazy'; img.alt = it.source_name || '';
      // 网格用服务端生成的 320px 缩略图；点开 lightbox 才加载全尺寸成品
      img.src = api('/gallery/file/') + encodeURIComponent(it.thumb_file || it.result_file);
      card.appendChild(img);
      const meta = document.createElement('div');
      meta.className = 'g-meta';
      meta.innerHTML = '<div class="g-nm">' + esc(it.source_name || it.result_file) + '</div>' +
        '<div class="g-row"><span>' + esc((it.time || '').replace('T', ' ')) + '</span>' +
        '<span class="g-dev">' + esc((it.device || '').replace('gpu-', 'GPU ').replace('directml', 'DirectML').replace('cuda', 'CUDA')) + '</span>' +
        '<span>' + (it.elapsed_s != null ? it.elapsed_s + 's' : '') + '</span>' +
        (it.width ? '<span>' + it.width + '×' + it.height + '</span>' : '') + '</div>';
      card.appendChild(meta);
      card.tabIndex = 0;
      card.setAttribute('role', 'button');
      card.addEventListener('click', () => openLightbox(it));
      card.addEventListener('keydown', (e) => {
        if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openLightbox(it); }
      });
      grid.appendChild(card);
    }
  }
  $('g-refresh').addEventListener('click', refreshGallery);

  /* ---------- 打开输出文件夹（仅桌面壳可用） ---------- */
  // 浏览器工作台无法调用系统文件管理器，隐藏入口避免点击无反应的困惑。
  async function openOutDir() {
    if (!invoke || !outDir) return;
    try { await invoke('cmd_open_dir', { path: outDir }); } catch { }
  }
  $('g-outdir').addEventListener('click', openOutDir);
  $('lb-open-src').addEventListener('click', openOutDir);
  if (!isTauri) {
    $('outdir-wrap').hidden = true;
    $('lb-open-src').hidden = true;
  }

  /* ---------- 大图查看 ---------- */
  function openLightbox(it) {
    $('lb-img').src = api('/gallery/file/') + encodeURIComponent(it.result_file);
    $('lb-cap').textContent = (it.source_name || '') + ' · ' + (it.time || '').replace('T', ' ') +
      ' · ' + (it.device || '') + ' · ' + (it.elapsed_s != null ? it.elapsed_s + 's' : '') +
      (it.width ? ' · ' + it.width + '×' + it.height : '');
    $('lightbox').hidden = false;
  }
  $('lb-close').addEventListener('click', () => { $('lightbox').hidden = true; });
  $('lb-backdrop').addEventListener('click', () => { $('lightbox').hidden = true; });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') $('lightbox').hidden = true; });

  /* ---------- 控制台日志 ---------- */
  let logSeq = 0;
  async function pollLogs() {
    let j;
    try { j = await (await fetch(api('/api/v1/logs?after=') + logSeq, { cache: 'no-store' })).json(); } catch { return; }
    if (!j.items || !j.items.length) return;
    logSeq = j.next;
    const box = $('console');
    const stick = box.scrollTop + box.clientHeight >= box.scrollHeight - 40;
    for (const it of j.items) {
      const line = document.createElement('div');
      line.className = 'log-line';
      line.innerHTML = '<span class="ts">' + esc(it.ts) + '</span>' +
        '<span class="lv ' + esc(it.level) + '">' + esc(it.level) + '</span>' +
        '<span class="msg">' + esc(it.message) + '</span>';
      box.appendChild(line);
    }
    while (box.children.length > 600) box.removeChild(box.firstChild);
    if (stick) box.scrollTop = box.scrollHeight;
  }
  function scrollConsole() { const box = $('console'); box.scrollTop = box.scrollHeight; }


  /* ---------- 设置：模式 / 方案 / 处理器 / 免责声明 / 主题 / 语言 / 下载源 ---------- */
  const SET_KEY = 'mc-settings-v1';
  let savedSettings = {};
  try { savedSettings = JSON.parse(localStorage.getItem(SET_KEY) || '{}') || {}; } catch { savedSettings = {}; }
  if (typeof savedSettings !== 'object') savedSettings = {};
  const settings = Object.assign(
    { mode: 'auto', device: 'auto', disclaimer_accepted: false, theme: null, refName: '',
      scheme: 'standard', refMethod: 'reinhard', refStrength: 1.0, monetBg: true,
      lang: 'auto', downloadSource: 'auto' },
    savedSettings
  );

  function saveSettings(patch) {
    Object.assign(settings, patch);
    localStorage.setItem(SET_KEY, JSON.stringify(settings));
    const payload = { mode: settings.mode, device: settings.device, disclaimer_accepted: settings.disclaimer_accepted,
      scheme: settings.scheme, ref_method: settings.refMethod, ref_strength: settings.refStrength };
    if (settings.theme) payload.theme = settings.theme;
    fetch(api('/api/v1/settings'), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    }).catch(() => {});
  }

  function applySettingsToUI() {
    const modeInput = document.querySelector('input[name=mode][value="' + settings.mode + '"]');
    if (modeInput) modeInput.checked = true;
    toggleModePanels();
    if ($('scheme-select')) $('scheme-select').value = settings.scheme;
    const rm = document.querySelector('input[name=ref-method][value="' + settings.refMethod + '"]');
    if (rm) rm.checked = true;
    $('ref-strength').value = Math.round((settings.refStrength ?? 1.0) * 100);
    $('ref-strength-val').textContent = Math.round((settings.refStrength ?? 1.0) * 100) + '%';
    // device: default by machine ability after pollHealth() probes; explicit choice wins
    if (settings.device && settings.device !== 'auto') {
      const dInput = document.querySelector('input[name=device][value="' + settings.device + '"]');
      if (dInput && !dInput.disabled) dInput.checked = true;
    }
    $('disclaimer').checked = !!settings.disclaimer_accepted;
    // 主题 / 语言 / 下载源 / 背景
    const themeVal = settings.theme || 'auto';
    const themeInput = document.querySelector('input[name=theme][value="' + themeVal + '"]');
    if (themeInput) themeInput.checked = true;
    const langInput = document.querySelector('input[name=lang][value="' + (settings.lang || 'auto') + '"]');
    if (langInput) langInput.checked = true;
    const srcInput = document.querySelector('input[name=download-source][value="' + (settings.downloadSource || 'auto') + '"]');
    if (srcInput) srcInput.checked = true;
    updateSourceHint();
    applyMonetBg();
  }

  /* 背景样式：莫奈流动（默认，.monet-canvas 三球漫游）或纯色画布（body 自带
     surface 底色，隐藏画布即回退）——低端机/省电可关。localStorage 持久化，
     不随 POST /api/v1/settings 下发（后端无关）。设置页与上色页共用同一组 radio。 */
  function applyMonetBg() {
    const canvas = document.querySelector('.monet-canvas');
    if (canvas) canvas.style.display = settings.monetBg ? '' : 'none';
    const bgInput = document.querySelector('input[name=bg-style][value="' + (settings.monetBg ? 'monet' : 'plain') + '"]');
    if (bgInput) bgInput.checked = true;
  }
  document.querySelectorAll('input[name=bg-style]').forEach((el) => {
    el.addEventListener('change', () => {
      const on = el.value === 'monet';
      if (on === settings.monetBg) return;
      saveSettings({ monetBg: on });
      applyMonetBg();
    });
  });

  // 模式附属面板：色彩方案（全自动）/ 参考图选择与迁移选项 / 提示点画布
  function toggleModePanels() {
    $('ref-row').hidden = settings.mode !== 'reference';
    $('ref-opt-row').hidden = settings.mode !== 'reference';
    $('scheme-row').hidden = settings.mode !== 'auto';
    $('hint-card').hidden = settings.mode !== 'hints';
    if (settings.mode === 'hints') {
      if (!selected && queue.length) selected = queue[0];
      syncHintCanvas();
    }
  }

  document.querySelectorAll('input[name=mode]').forEach((el) =>
    el.addEventListener('change', () => { if (el.checked) { saveSettings({ mode: el.value }); toggleModePanels(); } }));

  /* 色彩方案与参考图迁移选项 */
  if ($('scheme-select')) $('scheme-select').addEventListener('change', () =>
    saveSettings({ scheme: $('scheme-select').value }));
  document.querySelectorAll('input[name=ref-method]').forEach((el) =>
    el.addEventListener('change', () => { if (el.checked) saveSettings({ refMethod: el.value }); }));
  $('ref-strength').addEventListener('input', () => {
    const v = Number($('ref-strength').value);
    $('ref-strength-val').textContent = v + '%';
    saveSettings({ refStrength: v / 100 });
  });

  document.querySelectorAll('input[name=device]').forEach((el) =>
    el.addEventListener('change', () => { if (el.checked) {
      saveSettings({ device: el.value });
      const hint = $('set-hint');
      hint.hidden = false;
      hint.textContent = t('toast.deviceHint', { dev: el.value === 'gpu' ? 'GPU' : 'CPU' });
      setTimeout(() => { hint.hidden = true; }, 4000);
    } }));

  /* reference image picker */
  let refFile = null;
  function renderRefName() {
    if (!refFile) { $('ref-name').textContent = t('set.ref.none'); return; }
    const size = (refFile.size / 1048576).toFixed(1) + 'MB';
    $('ref-name').textContent = refFile.name + (lang === 'zh' ? '（' + size + '）' : ' (' + size + ')');
  }
  $('btn-ref-pick').addEventListener('click', () => $('ref-input').click());
  $('ref-input').addEventListener('change', () => {
    const f = $('ref-input').files[0];
    if (!f) return;
    if (!/\.(png|jpe?g|webp)$/i.test(f.name)) { $('ref-name').textContent = t('toast.badFormat'); return; }
    refFile = f;
    renderRefName();
  });

  /* disclaimer gate: block run when unchecked */
  $('disclaimer').addEventListener('change', () =>
    saveSettings({ disclaimer_accepted: $('disclaimer').checked }));
  $('btn-run').addEventListener('click', () => {
    if (!$('disclaimer').checked) {
      const hint = $('set-hint');
      hint.hidden = false;
      hint.textContent = t('toast.needDisclaimer');
      $('settings-panel').scrollIntoView({ behavior: 'smooth', block: 'center' });
      setTimeout(() => { hint.hidden = true; }, 4000);
    }
  }, true); // capture: run before the queue handler

  /* GPU availability: gray out when no DML/CUDA provider.
     随 /health 轮询反复执行：sidecar 冷启动期间拿不到设备信息时先占位，
     服务就绪后自动恢复判定，不会永久灰掉。 */
  function updateDeviceAbility(d) {
    const gpuOk = !!(d && d.gpu_available);
    const gpuInput = document.querySelector('input[name=device][value="gpu"]');
    const note = $('gpu-note');
    if (!d) {
      // 服务未就绪时不要误报“无 GPU”，等下一轮轮询再判定
      gpuInput.disabled = true;
      note.hidden = false;
      note.className = 'set-note';
      note.textContent = t('gpu.note.serviceOff');
      return;
    }
    if (!gpuOk) {
      gpuInput.disabled = true;
      note.hidden = false;
      note.className = 'set-note is-warn';
      const hw = d.gpu_info && d.gpu_info.name;
      note.textContent = hw ? t('gpu.note.noProvider', { name: hw }) : t('gpu.note.none');
      // 曾经选过 GPU 但当前运行库不支持：退回 auto（等同 CPU），避免提交必失败
      if (settings.device === 'gpu') saveSettings({ device: 'auto' });
      const cpuInput = document.querySelector('input[name=device][value="cpu"]');
      if (cpuInput) cpuInput.checked = true;
    } else {
      gpuInput.disabled = false;
      note.hidden = true;
      if (settings.device === 'auto' || !settings.device) {
        settings.device = 'gpu';
        localStorage.setItem(SET_KEY, JSON.stringify(settings));
        gpuInput.checked = true;
      }
    }
    applySettingsToUI();
  }

  /* ---------- 设置页：下载源 / 权重状态 / GPU 诊断 / 关于 ---------- */
  function fmtMB(n) { return (Number(n || 0) / 1048576).toFixed(1) + ' MB'; }

  function updateSourceHint() {
    const el = $('source-hint');
    if (!el) return;
    el.textContent = t('settings.source.hint.' + (settings.downloadSource || 'auto'));
  }

  async function refreshWeights() {
    const text = $('weights-text'), dot = $('weights-dot'), open = $('weights-open');
    if (!text) return;
    if (!invoke) {
      text.textContent = t('settings.weights.unavailable');
      dot.className = 'dot';
      open.hidden = true;
      return;
    }
    open.hidden = false;
    try {
      const st = await invoke('cmd_weights_status');
      if (st.allReady) {
        text.textContent = t('settings.weights.ready', { ver: st.manifestVersion, size: fmtMB(st.totalBytes) });
        dot.className = 'dot is-ok';
      } else if (st.doneBytes > 0) {
        text.textContent = t('settings.weights.partial', { done: fmtMB(st.doneBytes), total: fmtMB(st.totalBytes) });
        dot.className = 'dot is-warn';
      } else {
        text.textContent = t('settings.weights.missing');
        dot.className = 'dot is-bad';
      }
    } catch {
      text.textContent = t('settings.weights.unavailable');
      dot.className = 'dot';
    }
  }

  function renderGpuDiagnostics(d) {
    const dot = $('gpu-dot');
    if (!dot) return;
    const gs = d && d.gpu_state;
    const hw = (gs && gs.hardware) || (d && d.gpu_info) || {};
    let state = gs ? gs.state
      : (!d ? 'unknown' : (d.gpu_available ? 'ready' : (hw && hw.name ? 'no_provider' : 'none')));
    if (!d) state = 'unknown';
    dot.className = 'dot ' + ({ ready: 'is-ok', no_provider: 'is-warn', none: 'is-bad' }[state] || '');
    const status = $('gpu-status');
    if (state === 'ready') {
      status.textContent = d.device === 'cpu'
        ? t('settings.gpu.cpuSelected')
        : t('settings.gpu.active', {
          label: d.device === 'gpu-cuda' ? 'CUDA' : (d.device === 'gpu-directml' ? 'DirectML' : 'GPU'),
        });
    } else if (state === 'no_provider') {
      status.textContent = t('settings.gpu.noProvider');
    } else if (state === 'none') {
      status.textContent = t('settings.gpu.none');
    } else {
      status.textContent = '—';
    }
    $('gpu-hw').textContent = hw.name || '—';
    $('gpu-provider').textContent = d && d.available && d.available.length ? d.available.join(', ') : '—';
    $('gpu-vram').textContent = hw.vram || '—';
    $('gpu-driver').textContent = hw.driver || '—';
    const fix = $('gpu-fix');
    if (state === 'no_provider') {
      fix.hidden = false;
      fix.textContent = t('settings.gpu.fix', { name: hw.name || 'GPU' });
    } else {
      fix.hidden = true;
    }
  }

  document.querySelectorAll('input[name=download-source]').forEach((el) =>
    el.addEventListener('change', async () => {
      if (!el.checked) return;
      settings.downloadSource = el.value;
      localStorage.setItem(SET_KEY, JSON.stringify(settings));
      updateSourceHint();
      if (invoke) {
        try { await invoke('cmd_set_download_source', { source: el.value }); }
        catch (err) { toast(String(err), true); }
      }
    }));

  $('weights-open').addEventListener('click', async () => {
    if (!invoke) return;
    try { await invoke('cmd_open_weights_dir'); } catch { }
  });
  $('gpu-redetect').addEventListener('click', () => { pollHealth(); });

  /* ---------- 语言 / 主题 ---------- */
  function setLanguage(pref) {
    settings.lang = pref;
    localStorage.setItem(SET_KEY, JSON.stringify(settings));
    lang = resolveLang(pref);
    applyI18n();
    // 重新渲染 JS 生成的文案
    applyDevice(lastDevice);
    renderQueue();
    updateHintsCount();
    renderRefName();
    updateSourceHint();
    refreshWeights();
    $('q-summary').hidden = true;
    pollHealth();
  }
  document.querySelectorAll('input[name=lang]').forEach((el) =>
    el.addEventListener('change', () => { if (el.checked) setLanguage(el.value); }));

  /* theme: system / light / dark; persisted; console follows tokens automatically */
  const THEME_ICON = {
    dark: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M12 3a9 9 0 1 0 9 9c0-.46-.04-.92-.1-1.36a5.389 5.389 0 0 1-4.4 2.26 5.403 5.403 0 0 1-3.14-9.8c-.44-.06-.9-.1-1.36-.1z"/></svg>',
    light: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M12 7c-2.76 0-5 2.24-5 5s2.24 5 5 5 5-2.24 5-5-2.24-5-5-5zM2 13h2c.55 0 1-.45 1-1s-.45-1-1-1H2c-.55 0-1 .45-1 1s.45 1 1 1zm18 0h2c.55 0 1-.45 1-1s-.45-1-1-1h-2c-.55 0-1 .45-1 1s.45 1 1 1zM11 2v2c0 .55.45 1 1 1s1-.45 1-1V2c0-.55-.45-1-1-1s-1 .45-1 1zm0 18v2c0 .55.45 1 1 1s1-.45 1-1v-2c0-.55-.45-1-1-1s-1 .45-1 1zM5.99 4.58c-.39-.39-1.03-.39-1.41 0-.39.39-.39 1.03 0 1.41l1.06 1.06c.39.39 1.03.39 1.41 0s.39-1.03 0-1.41L5.99 4.58zm12.37 12.37c-.39-.39-1.03-.39-1.41 0-.39.39-.39 1.03 0 1.41l1.06 1.06c.39.39 1.03.39 1.41 0 .39-.39.39-1.03 0-1.41l-1.06-1.06zm1.06-10.96c.39-.39.39-1.03 0-1.41-.39-.39-1.03-.39-1.41 0l-1.06 1.06c-.39.39-.39 1.03 0 1.41s1.03.39 1.41 0l1.06-1.06zM7.05 18.36c.39-.39.39-1.03 0-1.41-.39-.39-1.03-.39-1.41 0l-1.06 1.06c-.39.39-.39 1.03 0 1.41s1.03.39 1.41 0l1.06-1.06z"/></svg>',
  };
  function applyTheme(theme) {
    const root = document.documentElement;
    if (theme === 'light') {
      root.setAttribute('data-theme', 'light');
      root.style.colorScheme = 'light';
    } else if (theme === 'dark') {
      root.setAttribute('data-theme', 'dark');
      root.style.colorScheme = 'dark';
    } else {
      root.removeAttribute('data-theme');
      root.style.colorScheme = '';
    }
    const themeInput = document.querySelector('input[name=theme][value="' + (theme || 'auto') + '"]');
    if (themeInput) themeInput.checked = true;
    syncThemeButton();
  }
  function currentTheme() {
    return document.documentElement.getAttribute('data-theme')
      || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  }
  function syncThemeButton() {
    const dark = currentTheme() === 'dark';
    const btn = $('theme-toggle');
    if (!btn) return;
    // 图标显示点击后将切换到的主题
    btn.innerHTML = dark ? THEME_ICON.light : THEME_ICON.dark;
    btn.title = dark ? t('theme.toLight') : t('theme.toDark');
    btn.setAttribute('aria-label', t('theme.toggle'));
  }
  function toggleTheme() {
    const next = currentTheme() === 'dark' ? 'light' : 'dark';
    saveSettings({ theme: next });
    applyTheme(next);
  }
  $('theme-toggle').addEventListener('click', toggleTheme);
  document.querySelectorAll('input[name=theme]').forEach((el) =>
    el.addEventListener('change', () => {
      if (!el.checked) return;
      const theme = el.value === 'auto' ? null : el.value;
      saveSettings({ theme });
      applyTheme(theme);
    }));
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (!document.documentElement.hasAttribute('data-theme')) syncThemeButton();
  });

  /* 版本（仅桌面壳） */
  async function loadVersion() {
    if (!isTauri || !window.__TAURI__.app || !window.__TAURI__.app.getVersion) return;
    try { $('about-version').textContent = await window.__TAURI__.app.getVersion(); } catch { }
  }

  /* ---------- 启动 ---------- */
  // 页面不可见（Tauri 窗口最小化 / 浏览器后台标签）时暂停一切轮询，回前台立即补一次
  // 页面可见即完成首轮状态拉取前，先按本地设置还原一次控件状态
  lang = resolveLang(settings.lang);
  applyTheme(settings.theme);
  applyI18n();
  applySettingsToUI();
  renderQueue();
  updateHintsCount();
  renderGpuDiagnostics(null);
  refreshWeights();
  loadVersion();
  // 桌面壳：下载源以 Rust 侧持久化为准（boot 下载页在 UI 之前运行）
  if (invoke) {
    invoke('cmd_get_download_source').then((src) => {
      settings.downloadSource = src;
      localStorage.setItem(SET_KEY, JSON.stringify(settings));
      applySettingsToUI();
    }).catch(() => {});
  }
  pollHealth(); pollLogs();
  setInterval(() => { if (!document.hidden) pollHealth(); }, 5000);
  setInterval(() => { if (!document.hidden) pollLogs(); }, 2500);
  setInterval(() => { if (!document.hidden && !$('screen-gallery').hidden) refreshGallery(); }, 15000);
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) return;
    pollHealth(); pollLogs();
    if (!$('screen-gallery').hidden) refreshGallery();
  });
})();
