/* Manga Colorizer 前端逻辑（唯一脚本，供 index.html 使用）：
   导航 / 服务与设备状态 / 批量队列 / 提示点画布编辑 / 参考图 / 图库台账 / 控制台日志 / 设置持久化。
   后端接口见 tool/colorizer_service/service.py。 */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  /* ---------- 导航 ---------- */
  const screens = { home: 'screen-home', colorize: 'screen-colorize', gallery: 'screen-gallery', logs: 'screen-logs' };
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
  async function pollHealth() {
    const pill = $('svc-pill');
    try {
      const r = await fetch(api('/health'), { cache: 'no-store' });
      const j = await r.json();
      svcFailCount = 0;
      if (j.model_status === 'failed') {
        pill.textContent = '模型加载失败，请重启应用';
        pill.className = 'm3-chip is-bad';
        pill.title = (j.model_error || '') + '\n若反复失败，请查看日志页并确认系统可用内存充足';
      } else if (j.weights_present && (j.generator_loaded || j.sam_loaded)) {
        pill.textContent = '服务就绪'; pill.className = 'm3-chip is-good';
      } else if (j.weights_present && j.model_status === 'idle') {
        pill.textContent = '模型休眠中 · 上色时自动唤醒';
        pill.className = 'm3-chip';
        pill.title = '空闲超时已释放模型内存/显存；提交上色后会自动重新加载（约 10-20 秒）';
      } else if (j.weights_present) {
        pill.textContent = '模型预热中…'; pill.className = 'm3-chip';
        pill.title = '模型正在后台加载（首次约 10-20 秒），完成后上色不再等待';
      } else {
        pill.textContent = '权重缺失，请重启应用重新下载'; pill.className = 'm3-chip is-bad';
        pill.title = '权重目录: ' + (j.model_dir || '%LOCALAPPDATA%\\manga-colorizer\\weights');
      }
      applyDevice(j.device_info);
    } catch (err) {
      svcFailCount += 1;
      pill.textContent = '服务未连接（第 ' + svcFailCount + ' 次，自动重试中）';
      pill.className = 'm3-chip is-bad';
      pill.title = '连接 127.0.0.1:8788 失败: ' + String(err).slice(0, 120)
        + '\nsidecar 由应用自动拉起；持续失败请查看日志页';
      applyDevice(null);
    }
  }
  function applyDevice(d) {
    const gpu = d && d.device && d.device !== 'cpu';
    const label = !d ? '…'
      : d.device === 'gpu-cuda' ? 'GPU · CUDA'
      : d.device === 'gpu-directml' ? 'GPU · DirectML'
      : 'CPU 模式';
    const pill = $('dev-pill');
    const gi = d && d.gpu_info ? d.gpu_info : null;
    pill.textContent = gi && gi.name ? label + ' · ' + gi.name : label;
    pill.className = 'm3-chip ' + (gpu ? 'is-good' : 'is-warn');
    pill.title = d ? ('可用 Provider: ' + (d.available || []).join(', ')
                     + (d.loaded_device ? '' : '（模型加载前为预估设备）')
                     + (gi && gi.vram ? '\n显存: ' + gi.vram : '')
                     + (gi && gi.driver ? '\n驱动: ' + gi.driver : '')) : '';
    if (d && d.output_dir) { outDir = d.output_dir; $('g-outdir').title = outDir; }
    updateDeviceAbility(d);
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
        it.thumbUrl = it.thumbUrl || URL.createObjectURL(it.file);
        th.src = it.thumbUrl;
        const nm = document.createElement('span');
        nm.className = 'q-nm';
        nm.textContent = it.file.name;
        const st = document.createElement('span');
        st.className = 'q-st';
        row.append(th, nm, st);
        row.addEventListener('click', () => selectItem(it));
        row.tabIndex = 0;
        row.setAttribute('role', 'button');
        row.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); selectItem(it); }
        });
        it.row = row; it.nameEl = nm; it.statusEl = st;
        box.appendChild(row);
      }
      it.row.className = 'q-item is-' + it.status + (selected === it ? ' is-sel' : '');
      it.statusEl.textContent = { wait: '等待', run: '处理中', ok: '完成', fail: '失败' }[it.status] || it.status;
      it.nameEl.title = it.file.name + ' · ' + (it.file.size / 1048576).toFixed(1) + 'MB'
        + (it.hints.length ? ' · ' + it.hints.length + ' 个提示点' : '')
        + (it.error ? ' · ' + it.error : '');
    }
    $('q-count').textContent = queue.length + ' 项';
    $('btn-run').disabled = running || queue.length === 0;
    $('btn-cancel').disabled = !running;
    $('btn-clear').disabled = running || queue.length === 0;
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
    $('swatches').querySelectorAll('.swatch').forEach((b) => b.classList.toggle('is-active', b === btn));
    activeColor = btn.dataset.color;
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
    $('hints-count').textContent = !selected ? '未选择图片'
      : selected.file.name + ' · 已放 ' + selected.hints.length + ' 个提示点';
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
      dot.title = `提示点 ${i + 1} · 双击删除`;
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
          if (!it.hints.length) { it.status = 'fail'; it.error = '请先在画布上为该图放置提示点'; renderQueue(); continue; }
          endpoint = '/colorize_hints';
          fd.append('hints', hintsPayload(it));
        } else if (settings.mode === 'reference') {
          if (!refFile) throw new Error('参考图模式：请先选择参考图');
          endpoint = '/colorize_reference';
          fd.append('reference', refFile, refFile.name);
        }
        const r = await fetch(api(endpoint), { method: 'POST', body: fd });
        if (r.status === 429) { it.status = 'fail'; it.error = '模型忙碌，请稍后重试'; }
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
    s.innerHTML = (cancelFlag ? '已取消 — ' : '全部完成 — ') +
      '成功 <b>' + ok + '</b> · 失败 <b>' + bad + '</b>' + (skip ? ' · 未处理 ' + skip : '') +
      ' · 总耗时 ' + secs + 's。成品已入图库。';
    toast('批量处理完成：成功 ' + ok + ' / 失败 ' + bad, bad > 0);
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


  /* ---------- 设置面板：模式 / 处理器 / 免责声明 / 主题 ---------- */
  const SET_KEY = 'mc-settings-v1';
  const settings = Object.assign(
    { mode: 'auto', device: 'auto', disclaimer_accepted: false, theme: null, refName: '' },
    JSON.parse(localStorage.getItem(SET_KEY) || '{}')
  );

  function saveSettings(patch) {
    Object.assign(settings, patch);
    localStorage.setItem(SET_KEY, JSON.stringify(settings));
    const payload = { mode: settings.mode, device: settings.device, disclaimer_accepted: settings.disclaimer_accepted };
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
    if (settings.refName) $('ref-name').textContent = settings.refName;
    // device: default by machine ability after pollHealth() probes; explicit choice wins
    if (settings.device && settings.device !== 'auto') {
      const dInput = document.querySelector('input[name=device][value="' + settings.device + '"]');
      if (dInput && !dInput.disabled) dInput.checked = true;
    }
    $('disclaimer').checked = !!settings.disclaimer_accepted;
  }

  // 模式附属面板：参考图选择行 / 提示点画布
  function toggleModePanels() {
    $('ref-row').hidden = settings.mode !== 'reference';
    $('hint-card').hidden = settings.mode !== 'hints';
    if (settings.mode === 'hints') {
      if (!selected && queue.length) selected = queue[0];
      syncHintCanvas();
    }
  }

  document.querySelectorAll('input[name=mode]').forEach((el) =>
    el.addEventListener('change', () => { if (el.checked) { saveSettings({ mode: el.value }); toggleModePanels(); } }));

  document.querySelectorAll('input[name=device]').forEach((el) =>
    el.addEventListener('change', () => { if (el.checked) {
      saveSettings({ device: el.value });
      const hint = $('set-hint');
      hint.hidden = false;
      hint.textContent = '处理器已切换为 ' + (el.value === 'gpu' ? 'GPU' : 'CPU') + '，将在下次处理时生效。';
      setTimeout(() => { hint.hidden = true; }, 4000);
    } }));

  /* reference image picker */
  let refFile = null;
  $('btn-ref-pick').addEventListener('click', () => $('ref-input').click());
  $('ref-input').addEventListener('change', () => {
    const f = $('ref-input').files[0];
    if (!f) return;
    if (!/\.(png|jpe?g|webp)$/i.test(f.name)) { $('ref-name').textContent = '不支持的格式'; return; }
    refFile = f;
    $('ref-name').textContent = f.name + '（' + (f.size / 1048576).toFixed(1) + 'MB）';
  });

  /* disclaimer gate: block run when unchecked */
  $('disclaimer').addEventListener('change', () =>
    saveSettings({ disclaimer_accepted: $('disclaimer').checked }));
  $('btn-run').addEventListener('click', () => {
    if (!$('disclaimer').checked) {
      const hint = $('set-hint');
      hint.hidden = false;
      hint.textContent = '请先勾选免责声明，再开始上色。';
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
      note.textContent = '服务未连接，暂无法检测 GPU（就绪后自动恢复）';
      return;
    }
    if (!gpuOk) {
      gpuInput.disabled = true;
      note.hidden = false;
      note.textContent = '本机未检测到可用 GPU（需要 DirectML 或 CUDA Provider）';
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

  /* theme toggle: dark/light, persisted; console follows tokens automatically */
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
    syncThemeButton();
  }
  function currentTheme() {
    return document.documentElement.getAttribute('data-theme')
      || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  }
  function syncThemeButton() {
    const dark = currentTheme() === 'dark';
    const btn = $('theme-toggle');
    // 图标显示点击后将切换到的主题
    btn.innerHTML = dark ? THEME_ICON.light : THEME_ICON.dark;
    btn.title = dark ? '切换到浅色主题' : '切换到深色主题';
  }
  function toggleTheme() {
    const next = currentTheme() === 'dark' ? 'light' : 'dark';
    saveSettings({ theme: next });
    applyTheme(next);
  }
  $('theme-toggle').addEventListener('click', toggleTheme);
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (!document.documentElement.hasAttribute('data-theme')) syncThemeButton();
  });
  applyTheme(settings.theme);


  /* ---------- 启动 ---------- */
  // 页面不可见（Tauri 窗口最小化 / 浏览器后台标签）时暂停一切轮询，回前台立即补一次
  // 页面可见即完成首轮状态拉取前，先按本地设置还原一次控件状态
  applySettingsToUI();
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
