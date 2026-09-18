/* Manga Colorizer APP v2 逻辑：导航 / 服务与设备状态 / 批量队列 / 图库台账 / 控制台日志 */
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
      if (btn.classList.contains('fab')) return;
      btn.classList.toggle('is-active', btn.dataset.nav === name);
    });
    if (name === 'gallery') refreshGallery();
    if (name === 'logs') scrollConsole();
    window.scrollTo({ top: 0 });
  }

  /* ---------- Tauri 桥（存在才用） ---------- */
  const isTauri = !!(window.__TAURI__ && window.__TAURI__.core);
  const invoke = isTauri ? window.__TAURI__.core.invoke : null;

  /* ---------- 服务与设备状态 ---------- */
  async function pollHealth() {
    try {
      const j = await (await fetch('/health', { cache: 'no-store' })).json();
      const pill = $('svc-pill');
      if (j.weights_present && (j.generator_loaded || j.sam_loaded)) {
        pill.textContent = '服务就绪'; pill.className = 'm3-chip is-good';
      } else if (j.weights_present) {
        pill.textContent = '模型加载中…'; pill.className = 'm3-chip';
      } else {
        pill.textContent = '权重缺失'; pill.className = 'm3-chip is-bad';
      }
    } catch {
      const pill = $('svc-pill');
      pill.textContent = '服务未连接'; pill.className = 'm3-chip is-bad';
    }
  }
  async function loadDevice() {
    let d = null;
    try { d = await (await fetch('/api/v1/device', { cache: 'no-store' })).json(); } catch { }
    const gpu = d && d.device && d.device !== 'cpu';
    const label = !d ? '…'
      : d.device === 'gpu-cuda' ? 'GPU · CUDA'
      : d.device === 'gpu-directml' ? 'GPU · DirectML'
      : 'CPU 模式';
    const pill = $('dev-pill'), badge = $('dev-badge');
    pill.textContent = label; badge.textContent = label;
    pill.className = badge.className = gpu ? 'is-good' : 'is-warn';
    pill.classList.add('m3-chip'); badge.classList.add('device-chip');
    pill.title = badge.title = d ? '可用 Provider: ' + (d.available || []).join(', ') : '';
    if (d && d.output_dir) { outDir = d.output_dir; $('g-outdir').title = outDir; }
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
      queue.push({ file: f, status: 'wait', error: null, thumbUrl: null });
    }
    renderQueue();
  }
  function renderQueue() {
    const box = $('q-list');
    $('q-empty').hidden = queue.length > 0;
    box.innerHTML = '';
    for (const it of queue) {
      const row = document.createElement('div');
      row.className = 'q-item is-' + it.status;
      const th = document.createElement('img');
      th.className = 'q-thumb'; th.alt = '';
      if (!it.thumbUrl && it.status === 'wait') it.thumbUrl = URL.createObjectURL(it.file);
      th.src = it.thumbUrl || '';
      row.appendChild(th);
      const nm = document.createElement('span');
      nm.className = 'q-nm';
      nm.textContent = it.file.name;
      nm.title = it.file.name + ' · ' + (it.file.size / 1048576).toFixed(1) + 'MB' + (it.error ? ' · ' + it.error : '');
      row.appendChild(nm);
      const st = document.createElement('span');
      st.className = 'q-st';
      st.textContent = { wait: '等待', run: '处理中', ok: '完成', fail: '失败' }[it.status] || it.status;
      row.appendChild(st);
      box.appendChild(row);
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
    renderQueue();
  });
  $('btn-cancel').addEventListener('click', () => { cancelFlag = true; $('btn-cancel').disabled = true; });

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
          endpoint = '/colorize_hints';
          fd.append('hints', '[]');
        } else if (settings.mode === 'reference') {
          if (!refFile) throw new Error('参考图模式：请先选择参考图');
          endpoint = '/colorize_reference';
          fd.append('reference', refFile, refFile.name);
        }
        const r = await fetch(endpoint, { method: 'POST', body: fd });
        if (r.ok) { it.status = 'ok'; }
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
  });

  /* ---------- 图库 ---------- */
  let outDir = '';
  async function refreshGallery() {
    let j;
    try { j = await (await fetch('/api/v1/gallery?limit=200', { cache: 'no-store' })).json(); } catch { return; }
    const grid = $('g-grid');
    grid.innerHTML = '';
    const items = (j.items || []).filter((x) => x.status === 'ok' && x.result_file);
    $('g-empty').hidden = items.length > 0;
    for (const it of items) {
      const card = document.createElement('div');
      card.className = 'card media-card';
      const img = document.createElement('img');
      img.className = 'media-card__thumb'; img.loading = 'lazy'; img.alt = it.source_name || '';
      img.src = '/gallery/file/' + encodeURIComponent(it.result_file);
      card.appendChild(img);
      const meta = document.createElement('div');
      meta.className = 'g-meta';
      meta.innerHTML = '<div class="g-nm">' + esc(it.source_name || it.result_file) + '</div>' +
        '<div class="g-row"><span>' + esc((it.time || '').replace('T', ' ')) + '</span>' +
        '<span class="g-dev">' + esc((it.device || '').replace('gpu-', 'GPU ').replace('directml', 'DirectML').replace('cuda', 'CUDA')) + '</span>' +
        '<span>' + (it.elapsed_s != null ? it.elapsed_s + 's' : '') + '</span>' +
        (it.width ? '<span>' + it.width + '×' + it.height + '</span>' : '') + '</div>';
      card.appendChild(meta);
      card.addEventListener('click', () => openLightbox(it));
      grid.appendChild(card);
    }
  }
  $('g-refresh').addEventListener('click', refreshGallery);
  $('g-outdir').addEventListener('click', async () => {
    if (invoke && outDir) { try { await invoke('cmd_open_dir', { path: outDir }); } catch { } }
  });

  /* ---------- 大图查看 ---------- */
  function openLightbox(it) {
    $('lb-img').src = '/gallery/file/' + encodeURIComponent(it.result_file);
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
    try { j = await (await fetch('/api/v1/logs?after=' + logSeq, { cache: 'no-store' })).json(); } catch { return; }
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
  fetch('/api/v1/settings', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ mode: settings.mode, device: settings.device, disclaimer_accepted: settings.disclaimer_accepted }),
  }).catch(() => {});
}

function applySettingsToUI() {
  const modeInput = document.querySelector('input[name=mode][value="' + settings.mode + '"]');
  if (modeInput) modeInput.checked = true;
  toggleRefRow();
  if (settings.refName) $('ref-name').textContent = settings.refName;
  // device: default by machine ability after loadDevice() probes; explicit choice wins
  if (settings.device && settings.device !== 'auto') {
    const dInput = document.querySelector('input[name=device][value="' + settings.device + '"]');
    if (dInput && !dInput.disabled) dInput.checked = true;
  }
  $('disclaimer').checked = !!settings.disclaimer_accepted;
}

function toggleRefRow() {
  $('ref-row').hidden = settings.mode !== 'reference';
}

document.querySelectorAll('input[name=mode]').forEach((el) =>
  el.addEventListener('change', () => { if (el.checked) { saveSettings({ mode: el.value }); toggleRefRow(); } }));

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
const _origRun = $('btn-run');
_origRun.addEventListener('click', () => {
  if (!$('disclaimer').checked) {
    const hint = $('set-hint');
    hint.hidden = false;
    hint.textContent = '请先勾选免责声明，再开始上色。';
    $('settings-panel').scrollIntoView({ behavior: 'smooth', block: 'center' });
    setTimeout(() => { hint.hidden = true; }, 4000);
  }
}, true); // capture: run before the queue handler

/* GPU availability: gray out when no DML/CUDA provider */
async function applyDeviceAbility() {
  let d = null;
  try { d = await (await fetch('/api/v1/device', { cache: 'no-store' })).json(); } catch { }
  const gpuOk = !!(d && d.gpu_available);
  const gpuInput = document.querySelector('input[name=device][value="gpu"]');
  const note = $('gpu-note');
  if (!gpuOk) {
    gpuInput.disabled = true;
    note.hidden = false;
    note.textContent = '本机未检测到可用 GPU（DML/CUDA Provider 缺失）';
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
}
$('theme-toggle').addEventListener('click', () => {
  const cur = settings.theme || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
  const next = cur === 'dark' ? 'light' : 'dark';
  saveSettings({ theme: next });
  applyTheme(next);
});
applyTheme(settings.theme);


  /* ---------- 启动 ---------- */
  pollHealth(); loadDevice(); pollLogs(); applyDeviceAbility();
  setInterval(pollHealth, 5000);
  setInterval(loadDevice, 15000);
  setInterval(pollLogs, 1200);
  setInterval(() => { if (!$('screen-gallery').hidden) refreshGallery(); }, 8000);
})();
