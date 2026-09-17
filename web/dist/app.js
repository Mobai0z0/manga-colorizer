/* Manga Colorizer 社区预览前端：同源调用 /health、/api/v1/capabilities、/colorize_auto */
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
    viewOriginal: $('view-original'), resultImg: $('result-img'),
    resultMeta: $('result-meta'), snackbar: $('snackbar'),
  };

  const state = { file: null, resultUrl: null, busy: false };
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
      const onCpu = !p || p === 'CPUExecutionProvider';
      setStatus(p === 'CUDAExecutionProvider' ? 'ok' : (j.generator_loaded ? 'ok' : 'ok'), onCpu ? '服务就绪 · CPU' : `服务就绪 · ${p.replace('ExecutionProvider', '')}`);
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

  /* ---- 文件选择 ---- */
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
    els.submit.disabled = !state.file || !els.licenseOk.checked || state.busy;
  }

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

  /* ---- 提交上色 ---- */
  els.submit.addEventListener('click', async () => {
    if (!state.file || state.busy) return;
    state.busy = true;
    updateSubmit();
    els.progress.hidden = false;
    els.progressText.hidden = false;
    const t0 = performance.now();
    try {
      const fd = new FormData();
      fd.append('image', state.file);
      const res = await fetch('/colorize_auto', { method: 'POST', body: fd });
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
      els.resultImg.hidden = false;
      els.viewOriginal.src = URL.createObjectURL(state.file);
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
      els.resultMeta.textContent = `输出 ${bmp.width}×${bmp.height} · ${fmtBytes(blob.size)} · 耗时 ${dt}s`;
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
  els.compareSeg.addEventListener('click', (e) => {
    const btn = e.target.closest('.seg-btn');
    if (!btn) return;
    els.compareSeg.querySelectorAll('.seg-btn').forEach((b) => {
      const active = b === btn;
      b.classList.toggle('is-active', active);
      b.setAttribute('aria-selected', String(active));
    });
    const view = btn.dataset.view;
    els.viewOriginal.hidden = view !== 'original';
    els.resultImg.hidden = view !== 'result';
  });
})();
