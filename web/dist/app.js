/* Manga Colorizer 社区预览前端
   同源调用 /health、/api/v1/capabilities、/colorize_auto|_hints|_reference */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const els = {
    statusDot: $('status-dot'), statusText: $('status-text'),
    dropzone: $('dropzone'), fileInput: $('file-input'),
    fileChip: $('file-chip'), fileName: $('file-name'), fileSize: $('file-size'), fileClear: $('file-clear'),
    limitsText: $('limits-text'),
    licenseOk: $('license-ok'), submit: $('submit'), download: $('download'),
    progress: $('progress'), progressText: $('progress-text'),
    compareSeg: $('compare-seg'), placeholder: $('placeholder'),
    canvasStage: $('canvas-stage'), canvasWrap: $('canvas-wrap'),
    viewOriginal: $('view-original'), resultImg: $('result-img'),
    hintLayer: $('hint-layer'),
    hintsPanel: $('hints-panel'), hintsCount: $('hints-count'),
    swatches: $('swatches'),
    referencePanel: $('reference-panel'), refDrop: $('ref-drop'),
    refInput: $('ref-input'), refThumb: $('ref-thumb'), refLabel: $('ref-label'),
    resultMeta: $('result-meta'), snackbar: $('snackbar'),
  };

  const state = {
    file: null, resultUrl: null, busy: false,
    mode: 'auto', refFile: null,
    hints: [],            // {x, y, color} 原图坐标
    activeColor: '#e53935',
  };
  let limits = { max_bytes: 20 * 1024 * 1024, max_pixels: 16_000_000 };
  let snackbarTimer = 0;

  function toast(msg, isErr = false) {
    els.snackbar.textContent = msg;
    els.snackbar.classList.toggle('err', isErr);
    els.snackbar.hidden = false;
    clearTimeout(snackbarTimer);
    snackbarTimer = setTimeout(() => { els.snackbar.hidden = true; }, isErr ? 6000 : 3500);
  }

  function setStatus(cls, text) {
    els.statusDot.className = `status-dot ${cls}`;
    els.statusText.textContent = text;
  }

  function fmtBytes(n) {
    return n >= 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.round(n / 1024)} KB`;
  }

  /* ---- 服务状态 ---- */
  async function pollHealth() {
    try {
      const r = await fetch('/health', { cache: 'no-store' });
      const j = await r.json();
      if (!j.weights_present) {
        setStatus('warn', '权重缺失 · 请先下载模型');
        return;
      }
      const p = j.providers && j.providers.generator ? j.providers.generator[0] : null;
      setStatus('ok', p && p !== 'CPUExecutionProvider'
        ? `服务就绪 · ${p.replace('ExecutionProvider', '')}` : '服务就绪 · CPU');
    } catch {
      setStatus('err', '服务未连接');
    }
  }
  pollHealth();
  setInterval(pollHealth, 15000);

  /* ---- 能力与限制 ---- */
  fetch('/api/v1/capabilities', { cache: 'no-store' })
    .then((r) => r.json())
    .then((cap) => {
      limits = cap.limits || limits;
      els.limitsText.textContent = `PNG / JPEG / WebP · 单文件 ≤ ${fmtBytes(limits.max_bytes)} · ≤ ${Math.round(limits.max_pixels / 1e6)}M 像素`;
    })
    .catch(() => {});

  /* ---- 原稿文件选择 ---- */
  function setFile(file) {
    if (!file) return;
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) {
      toast('仅支持 PNG、JPEG、WebP', true); return;
    }
    if (file.size > limits.max_bytes) {
      toast(`文件 ${fmtBytes(file.size)} 超过上限 ${fmtBytes(limits.max_bytes)}`, true); return;
    }
    state.file = file;
    els.fileName.textContent = file.name;
    els.fileSize.textContent = fmtBytes(file.size);
    els.fileChip.hidden = false;
    els.dropzone.classList.add('has-file');
    const img = new Image();
    img.onload = () => {
      if (img.width * img.height > limits.max_pixels) {
        toast(`图像 ${img.width}×${img.height} 超过 ${Math.round(limits.max_pixels / 1e6)}M 像素上限`, true);
        clearFile();
      }
      URL.revokeObjectURL(img.src);
    };
    img.src = URL.createObjectURL(file);
    updateSubmit();
  }

  function clearFile() {
    state.file = null;
    els.fileChip.hidden = true;
    els.dropzone.classList.remove('has-file');
    els.fileInput.value = '';
    updateSubmit();
  }

  function updateSubmit() {
    els.submit.disabled = !state.file || !els.licenseOk.checked || state.busy
      || (state.mode === 'reference' && !state.refFile);
  }

  /* ---- 模式切换 ---- */
  function setMode(mode) {
    state.mode = mode;
    els.hintsPanel.hidden = mode !== 'hints';
    els.referencePanel.hidden = mode !== 'reference';
    // 提示点模式显示可点画布
    const hasImage = Boolean(state.file);
    els.canvasStage.hidden = !(mode === 'hints' && hasImage);
    els.resultImg.hidden = mode === 'hints' || !state.resultUrl || view !== 'result';
    els.placeholder.hidden = hasImage || Boolean(state.resultUrl);
    if (mode === 'hints' && hasImage) {
      els.viewOriginal.src = URL.createObjectURL(state.file);
      els.canvasStage.hidden = false;
    }
  }

  document.querySelectorAll('input[name="mode"]').forEach((r) => {
    r.addEventListener('change', () => setMode(r.value));
  });

  /* ---- 色板 ---- */
  els.swatches.addEventListener('click', (e) => {
    const btn = e.target.closest('.swatch');
    if (!btn) return;
    els.swatches.querySelectorAll('.swatch').forEach((b) => b.classList.toggle('is-active', b === btn));
    state.activeColor = btn.dataset.color;
  });

  /* ---- 提示点画布交互 ---- */
  function renderHints() {
    const layer = els.hintLayer;
    layer.innerHTML = '';
    const img = els.viewOriginal;
    if (!img.naturalWidth) return;
    const sx = img.clientWidth / img.naturalWidth;
    const sy = img.clientHeight / img.naturalHeight;
    for (const [i, h] of state.hints.entries()) {
      const dot = document.createElement('button');
      dot.className = 'hint-dot';
      dot.style.left = `${h.x * sx}px`;
      dot.style.top = `${h.y * sy}px`;
      dot.style.background = h.color;
      dot.title = `提示点 ${i + 1} · 双击删除`;
      dot.addEventListener('dblclick', () => {
        state.hints.splice(i, 1);
        renderHints();
      });
      layer.appendChild(dot);
    }
    els.hintsCount.textContent = `已放 ${state.hints.length} 个提示点`;
  }

  els.viewOriginal.addEventListener('load', renderHints);
  window.addEventListener('resize', renderHints);

  document.getElementById('hint-layer').addEventListener('click', (e) => {
    if (state.mode !== 'hints' || !els.viewOriginal.naturalWidth) return;
    // 点在提示点上：留给 dblclick 删除，不再新增；多击（detail>1）也不落点
    if (e.target.closest('.hint-dot') || e.detail > 1) return;
    const rect = els.viewOriginal.getBoundingClientRect();
    const x = Math.round((e.clientX - rect.left) / rect.width * els.viewOriginal.naturalWidth);
    const y = Math.round((e.clientY - rect.top) / rect.height * els.viewOriginal.naturalHeight);
    state.hints.push({ x, y, color: state.activeColor });
    renderHints();
  });

  /* ---- 参考图选择 ---- */
  function setRef(file) {
    if (!file || !['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) {
      toast('参考图仅支持 PNG、JPEG、WebP', true); return;
    }
    if (file.size > limits.max_bytes) {
      toast(`参考图超过 ${fmtBytes(limits.max_bytes)} 上限`, true); return;
    }
    state.refFile = file;
    els.refThumb.src = URL.createObjectURL(file);
    els.refThumb.hidden = false;
    els.refLabel.textContent = file.name;
    updateSubmit();
  }
  els.refDrop.addEventListener('click', () => els.refInput.click());
  els.refInput.addEventListener('change', () => setRef(els.refInput.files[0]));

  /* ---- 原稿拖放（沿用） ---- */
  els.dropzone.addEventListener('click', () => els.fileInput.click());
  els.dropzone.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); els.fileInput.click(); }
  });
  els.fileInput.addEventListener('change', () => setFile(els.fileInput.files[0]));
  ['dragover', 'dragenter'].forEach((ev) => els.dropzone.addEventListener(ev, (e) => {
    e.preventDefault(); els.dropzone.classList.add('is-drag');
  }));
  ['dragleave', 'drop'].forEach((ev) => els.dropzone.addEventListener(ev, (e) => {
    e.preventDefault(); els.dropzone.classList.remove('is-drag');
  }));
  els.dropzone.addEventListener('drop', (e) => setFile(e.dataTransfer.files[0]));
  els.fileClear.addEventListener('click', clearFile);
  els.licenseOk.addEventListener('change', updateSubmit);

  /* ---- 提交上色（按模式路由） ---- */
  els.submit.addEventListener('click', async () => {
    if (!state.file || state.busy) return;
    if (state.mode === 'hints' && state.hints.length === 0) {
      toast('提示点模式：请先在画布上至少放一个提示点', true); return;
    }
    if (state.mode === 'reference' && !state.refFile) {
      toast('参考图模式：请先上传参考图', true); return;
    }
    state.busy = true;
    updateSubmit();
    els.progress.hidden = false;
    els.progressText.hidden = false;
    const t0 = performance.now();
    try {
      const fd = new FormData();
      fd.append('image', state.file);
      let url = '/colorize_auto';
      if (state.mode === 'hints') {
        fd.append('hints', JSON.stringify(state.hints.map((h) => {
          const c = h.color;
          return { x: h.x, y: h.y,
                   r: parseInt(c.slice(1, 3), 16),
                   g: parseInt(c.slice(3, 5), 16),
                   b: parseInt(c.slice(5, 7), 16) };
        })));
        url = '/colorize_hints';
      } else if (state.mode === 'reference') {
        fd.append('reference', state.refFile);
        url = '/colorize_reference';
      }
      const res = await fetch(url, { method: 'POST', body: fd });
      if (res.status === 429) { toast('模型忙碌，请稍后再试', true); return; }
      if (!res.ok) {
        let msg = `HTTP ${res.status}`;
        try { msg = (await res.json()).error || msg; } catch { /* 保留状态码 */ }
        throw new Error(msg);
      }
      const blob = await res.blob();
      if (state.resultUrl) URL.revokeObjectURL(state.resultUrl);
      state.resultUrl = URL.createObjectURL(blob);
      els.resultImg.src = state.resultUrl;
      els.viewOriginal.src = URL.createObjectURL(state.file);
      els.canvasStage.hidden = true;    // 成功后一律先展示结果图; 提示点模式可经"原图"切回画布
      els.resultImg.hidden = false;
      els.placeholder.hidden = true;
      els.compareSeg.hidden = false;
      els.download.hidden = false;
      els.download.onclick = () => {
        const a = document.createElement('a');
        a.href = state.resultUrl;
        a.download = state.file.name.replace(/\.\w+$/, '') + '-colored.png';
        a.click();
      };
      const dt = ((performance.now() - t0) / 1000).toFixed(1);
      const bmp = await createImageBitmap(blob);
      els.resultMeta.hidden = false;
      els.resultMeta.textContent = `输出 ${bmp.width}×${bmp.height} · ${fmtBytes(blob.size)} · 耗时 ${dt}s`
        + (state.mode === 'hints' ? ` · ${state.hints.length} 个提示点` : '')
        + (state.mode === 'reference' ? ' · 参考图迁移' : '');
      bmp.close();
      toast('上色完成');
    } catch (err) {
      toast(err.message === 'Failed to fetch' ? '无法连接服务，请确认 uvicorn 正在运行' : `上色失败：${err.message}`, true);
    } finally {
      state.busy = false;
      els.progress.hidden = true;
      els.progressText.hidden = true;
      updateSubmit();
    }
  });

  /* ---- 视图切换 ---- */
  let view = 'result';
  els.compareSeg.addEventListener('click', (e) => {
    const btn = e.target.closest('.segmented-button__option');
    if (!btn) return;
    els.compareSeg.querySelectorAll('.seg-btn').forEach((b) => {
      const active = b === btn;
      b.classList.toggle('is-active', active);
      b.setAttribute('aria-selected', String(active));
    });
    view = btn.dataset.view;
    // "原图"切回画布（可继续落点 / 查看原稿），"上色"显示结果图
    if (view === 'original' && state.file) {
      els.canvasStage.hidden = false;
      els.resultImg.hidden = true;
    } else {
      els.canvasStage.hidden = true;
      els.resultImg.hidden = view !== 'result';
    }
  });
})();
