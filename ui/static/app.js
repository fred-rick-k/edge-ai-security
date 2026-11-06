/**
 * ui/static/app.js
 * ================
 * Frontend Controller for Jetson Edge Security Demo Live VLM & Telemetry.
 */

// History buffers for sparkline charts (last 30 samples = 15 seconds at 2Hz)
const MAX_SAMPLES = 30;
const historyData = {
  gpu: new Array(MAX_SAMPLES).fill(0),
  ram: new Array(MAX_SAMPLES).fill(0),
  power: new Array(MAX_SAMPLES).fill(0),
};

// State
let activeAbortController = null;
let wsTelemetry = null;
let isAutoLoop = false;
let autoLoopTimer = null;
let eventHistory = [];
let lastSeenEventId = null;       // highest DB events.id seen; null = not seeded yet (never 0 as a stand-in, Bug 1)
const AGENT_EVENTS_POLL_MS = 5000; // poll /api/vault/events for agent-side detections

// DOM Elements
const el = {
  // Status pills
  vlmPill: document.getElementById('vlm-status-pill'),
  telemetryPill: document.getElementById('telemetry-status-pill'),
  swapPill: document.getElementById('swap-status-pill'),

  // Video
  cameraStream: document.getElementById('camera-stream'),
  cameraBadge: document.getElementById('camera-stream-badge'),
  btnSnapshot: document.getElementById('btn-snapshot'),
  btnRefreshStream: document.getElementById('btn-refresh-stream'),

  // Prompt & Inference
  promptInput: document.getElementById('prompt-input'),
  tempSlider: document.getElementById('temp-slider'),
  tempVal: document.getElementById('temp-val'),
  autoInterval: document.getElementById('auto-interval'),
  btnSubmit: document.getElementById('btn-submit-prompt'),
  btnToggleAuto: document.getElementById('btn-toggle-auto'),
  btnStop: document.getElementById('btn-stop-prompt'),
  btnClear: document.getElementById('btn-clear-output'),
  inferenceOutput: document.getElementById('inference-output'),
  inferenceBadge: document.getElementById('inference-status-badge'),

  // Timeline
  btnClearEvents: document.getElementById('btn-clear-events'),
  timelineList: document.getElementById('timeline-list'),
  eventCount: document.getElementById('event-count'),

  // Metrics
  statTtft: document.getElementById('stat-ttft'),
  statTokens: document.getElementById('stat-tokens'),
  statSpeed: document.getElementById('stat-speed'),
  statLatency: document.getElementById('stat-latency'),

  // Telemetry Values
  valGpu: document.getElementById('val-gpu'),
  valEmc: document.getElementById('val-emc'),
  valTempGpu: document.getElementById('val-temp-gpu'),
  valRamPct: document.getElementById('val-ram-pct'),
  valRamUsed: document.getElementById('val-ram-used'),
  valRamAvail: document.getElementById('val-ram-avail'),
  valPower: document.getElementById('val-power'),
  valTempAo: document.getElementById('val-temp-ao'),
  valCpuOverall: document.getElementById('val-cpu-overall'),
  valTempCpu: document.getElementById('val-temp-cpu'),
  valSwap: document.getElementById('val-swap'),
  cpuBarsContainer: document.getElementById('cpu-bars-container'),

  // Canvases
  canvasGpu: document.getElementById('spark-gpu'),
  canvasRam: document.getElementById('spark-ram'),
  canvasPower: document.getElementById('spark-power'),
};

// ── Initialize App ───────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  initTabs();
  initTelemetryWebSocket();
  initPromptControls();
  loadDefaultPrompt();
  initVideoControls();
  checkInitialStatus();
  initOpenShellCard();
  initVaultWidgets();
});

// ── Tab shell (Session 5-3a) ──────────────────────────────────────────────────
// Pure DOM class switching. Panes are only hidden with CSS (display:none); no
// polling, WebSocket or timer is started, stopped or gated by the active tab.

const TAB_STORAGE_KEY = 'edgeDemo.activeTab';

// Tab 4 (Anomaly Engine) is feature-flagged. The flag is read from
// window.__featureAnomalyEngine === true or <body data-feature-anomaly-engine="true">.
// The real delivery mechanism is decided in Session 8-1 (Part B).
function isAnomalyFeatureEnabled() {
  return window.__featureAnomalyEngine === true ||
    document.body.dataset.featureAnomalyEngine === 'true';
}

function applyFeatureFlags() {
  const enabled = isAnomalyFeatureEnabled();
  const btn = document.getElementById('tab-btn-anomaly');
  if (btn) btn.classList.toggle('hidden', !enabled);
  // If the active tab just became unavailable, fall back to Live.
  const active = document.querySelector('.tab-btn.tab-active');
  if (!enabled && active && active.dataset.tab === 'anomaly') selectTab('live');
}

function selectTab(name) {
  const btn = document.querySelector(`.tab-btn[data-tab="${name}"]`);
  const pane = document.getElementById(`tab-${name}`);
  if (!btn || !pane || btn.classList.contains('hidden')) name = 'live';

  document.querySelectorAll('.tab-btn').forEach((b) => {
    const on = b.dataset.tab === name;
    b.classList.toggle('tab-active', on);
    b.setAttribute('aria-selected', String(on));
  });
  document.querySelectorAll('.tab-pane').forEach((p) => {
    p.classList.toggle('tab-active', p.id === `tab-${name}`);
  });
  try { localStorage.setItem(TAB_STORAGE_KEY, name); } catch (e) { /* storage unavailable */ }
}

function initTabs() {
  document.querySelectorAll('.tab-btn').forEach((b) => {
    b.addEventListener('click', () => selectTab(b.dataset.tab));
  });
  applyFeatureFlags();
  let saved = 'live';
  try { saved = localStorage.getItem(TAB_STORAGE_KEY) || 'live'; } catch (e) { /* ignore */ }
  selectTab(saved);
}

// ── Telemetry WebSocket (2Hz Stream) ──────────────────────────────────────────

function initTelemetryWebSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const wsUrl = `${protocol}//${window.location.host}/ws/telemetry`;

  function connect() {
    wsTelemetry = new WebSocket(wsUrl);

    wsTelemetry.onopen = () => {
      console.log('Connected to Telemetry WebSocket at 2Hz');
      el.telemetryPill.querySelector('.status-dot').className = 'status-dot green';
      el.telemetryPill.querySelector('.status-text').textContent = 'Telemetry 2Hz';
    };

    wsTelemetry.onmessage = (event) => {
      try {
        const snap = JSON.parse(event.data);
        updateTelemetryUI(snap);
      } catch (err) {
        console.error('Telemetry JSON parse error:', err);
      }
    };

    wsTelemetry.onclose = () => {
      console.warn('Telemetry WS closed. Retrying in 2s...');
      el.telemetryPill.querySelector('.status-dot').className = 'status-dot red';
      el.telemetryPill.querySelector('.status-text').textContent = 'Telemetry Disconnected';
      setTimeout(connect, 2000);
    };

    wsTelemetry.onerror = (err) => {
      console.error('Telemetry WS error:', err);
      wsTelemetry.close();
    };
  }

  connect();
}

function updateTelemetryUI(snap) {
  // 1. GPU (GR3D)
  const gpuPct = snap.gpu?.gr3d_percent ?? 0;
  const emcPct = snap.gpu?.emc_percent ?? 0;
  const gpuTemp = snap.thermal?.gpu_c ?? '—';

  el.valGpu.textContent = `${gpuPct.toFixed(1)}%`;
  el.valEmc.textContent = `EMC Load: ${emcPct.toFixed(1)}%`;
  el.valTempGpu.textContent = `GPU: ${gpuTemp}°C`;

  historyData.gpu.shift();
  historyData.gpu.push(gpuPct);
  drawSparkline(el.canvasGpu, historyData.gpu, '#76b900', 100);

  // 2. RAM & VRAM
  const ramUsed = (snap.memory?.used_mb ?? 0) / 1024.0;
  const ramAvail = (snap.memory?.available_mb ?? 0) / 1024.0;
  const ramPct = snap.memory?.percent_used ?? 0;
  const swapUsedMb = snap.memory?.swap_used_mb ?? 0;

  el.valRamPct.textContent = `${ramPct.toFixed(1)}%`;
  el.valRamUsed.textContent = `Used: ${ramUsed.toFixed(2)} GB`;
  el.valRamAvail.textContent = `Avail: ${ramAvail.toFixed(2)} GB`;

  historyData.ram.shift();
  historyData.ram.push(ramPct);
  drawSparkline(el.canvasRam, historyData.ram, '#00b4d8', 100);

  // Zero swap check
  el.valSwap.textContent = `Swap: ${(swapUsedMb * 1024).toFixed(0)} kB`;
  if (snap.memory?.swap_healthy) {
    el.swapPill.querySelector('.status-dot').className = 'status-dot green';
    el.swapPill.querySelector('.status-text').textContent = 'Swap: 0 MB (Enforced)';
  } else {
    el.swapPill.querySelector('.status-dot').className = 'status-dot red';
    el.swapPill.querySelector('.status-text').textContent = `Swap Active: ${swapUsedMb.toFixed(0)} MB`;
  }

  // 3. Power
  const watts = snap.power?.watts ?? 0;
  const aoTemp = snap.thermal?.ao_c ?? '—';
  el.valPower.textContent = `${watts.toFixed(1)} W`;
  el.valTempAo.textContent = `AO Temp: ${aoTemp}°C`;

  historyData.power.shift();
  historyData.power.push(watts);
  drawSparkline(el.canvasPower, historyData.power, '#ffbe0b', 30);

  // 4. CPU Cores
  const cpuOverall = snap.cpu?.overall_percent ?? 0;
  const cpuTemp = snap.thermal?.cpu_c ?? '—';
  el.valCpuOverall.textContent = `${cpuOverall.toFixed(1)}%`;
  el.valTempCpu.textContent = `CPU: ${cpuTemp}°C`;

  const cores = snap.cpu?.cores ?? {};
  updateCpuCores(cores);
}

function updateCpuCores(cores) {
  const container = el.cpuBarsContainer;
  const coreKeys = Object.keys(cores);
  if (coreKeys.length === 0) return;

  if (container.children.length !== coreKeys.length) {
    container.innerHTML = '';
    coreKeys.forEach((k) => {
      const div = document.createElement('div');
      div.className = 'cpu-core-bar';
      div.innerHTML = `
        <div class="cpu-core-label">${k}</div>
        <div class="cpu-bar-bg">
          <div class="cpu-bar-fill" id="core-bar-${k}"></div>
        </div>
      `;
      container.appendChild(div);
    });
  }

  coreKeys.forEach((k) => {
    const bar = document.getElementById(`core-bar-${k}`);
    if (bar) {
      const pct = Math.min(100, Math.max(0, cores[k]));
      bar.style.width = `${pct}%`;
    }
  });
}

// ── Sparkline Canvas Renderer ─────────────────────────────────────────────────

function drawSparkline(canvas, data, strokeColor, maxVal = 100) {
  if (!canvas) return;
  const ctx = canvas.getContext('2d');
  const w = canvas.width;
  const h = canvas.height;

  ctx.clearRect(0, 0, w, h);

  ctx.strokeStyle = 'rgba(255, 255, 255, 0.05)';
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(0, h * 0.5);
  ctx.lineTo(w, h * 0.5);
  ctx.stroke();

  if (data.length < 2) return;

  const step = w / (data.length - 1);

  ctx.beginPath();
  ctx.moveTo(0, h);
  for (let i = 0; i < data.length; i++) {
    const val = Math.min(maxVal, Math.max(0, data[i]));
    const y = h - (val / maxVal) * (h - 6) - 3;
    const x = i * step;
    if (i === 0) ctx.lineTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.lineTo(w, h);
  ctx.closePath();

  ctx.fillStyle = strokeColor.replace(')', ', 0.15)').replace('rgb', 'rgba');
  if (strokeColor.startsWith('#')) {
    ctx.fillStyle = strokeColor + '26';
  }
  ctx.fill();

  ctx.beginPath();
  for (let i = 0; i < data.length; i++) {
    const val = Math.min(maxVal, Math.max(0, data[i]));
    const y = h - (val / maxVal) * (h - 6) - 3;
    const x = i * step;
    if (i === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.strokeStyle = strokeColor;
  ctx.lineWidth = 2;
  ctx.stroke();
}

// ── VLM Prompt & Inference Execution ──────────────────────────────────────────

function initPromptControls() {
  // Preset buttons
  document.querySelectorAll('.btn-preset').forEach((btn) => {
    btn.addEventListener('click', () => {
      const prompt = btn.getAttribute('data-prompt');
      el.promptInput.value = prompt;
      if (!isAutoLoop) {
        runInference(prompt);
      }
    });
  });

  // Temperature slider
  el.tempSlider.addEventListener('input', (e) => {
    el.tempVal.textContent = parseFloat(e.target.value).toFixed(1);
  });

  // Auto Interval change
  el.autoInterval.addEventListener('change', () => {
    if (!isAutoLoop) {
      el.btnToggleAuto.textContent = `▶ Auto Loop (${el.autoInterval.value}s)`;
    }
  });

  // Submit button (Run Once)
  el.btnSubmit.addEventListener('click', () => {
    const prompt = el.promptInput.value.trim() || getDefaultPrompt();
    stopAutoLoop();
    runInference(prompt);
  });

  // Auto Loop Toggle Button
  el.btnToggleAuto.addEventListener('click', () => {
    if (isAutoLoop) {
      stopAutoLoop();
    } else {
      startAutoLoop();
    }
  });

  // Stop button
  el.btnStop.addEventListener('click', () => {
    stopAutoLoop();
    if (activeAbortController) {
      activeAbortController.abort();
      activeAbortController = null;
    }
  });

  // Clear output
  el.btnClear.addEventListener('click', () => {
    el.inferenceOutput.innerHTML = `
      <div class="empty-state">
        <svg viewBox="0 0 24 24" width="36" height="36" fill="currentColor">
          <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 17.93c-3.95-.49-7-3.85-7-7.93 0-.62.08-1.21.21-1.79L9 15v1c0 1.1.9 2 2 2v1.93zm6.9-2.54c-.26-.81-1-1.39-1.9-1.39h-1v-3c0-.55-.45-1-1-1H8v-2h2c.55 0 1-.45 1-1V7h2c1.1 0 2-.9 2-2v-.41c2.93 1.19 5 4.06 5 7.41 0 2.08-.8 3.97-2.1 5.39z"/>
        </svg>
        <p>Inference output cleared. Click a Quick Action or enter a custom prompt above.</p>
      </div>`;
    el.statTtft.textContent = '— ms';
    el.statTokens.textContent = '—';
    el.statSpeed.textContent = '— tok/s';
    el.statLatency.textContent = '— s';
  });

  // Clear timeline events
  if (el.btnClearEvents) {
    el.btnClearEvents.addEventListener('click', () => {
      eventHistory = [];
      el.eventCount.textContent = '0 events';
      el.timelineList.innerHTML = '<div class="timeline-empty">Continuous analysis events will appear here in real time.</div>';
    });
  }
}

// Session 5-5d (Bug 4): the default prompt is the agent's profile prompt, fetched once from the server
// (GET /api/default-prompt reads agent/agent.py).  No second copy lives here and there is no fallback text:
// if the fetch fails, defaultPrompt stays '' and runInference() reports an error instead of sending something else.
let defaultPrompt = '';

async function loadDefaultPrompt() {
  try {
    const resp = await fetch('/api/default-prompt');
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    if (!data.prompt) throw new Error('empty prompt');
    defaultPrompt = data.prompt;
    if (!el.promptInput.value.trim()) el.promptInput.value = defaultPrompt;
  } catch (e) {
    console.error('Could not load the default prompt:', e);
  }
}

function getDefaultPrompt() {
  return defaultPrompt;
}

function startAutoLoop() {
  isAutoLoop = true;
  const intervalSec = parseFloat(el.autoInterval.value) || 1.0;
  el.btnToggleAuto.classList.add('active');
  el.btnToggleAuto.textContent = `⏹ Stop Auto Loop (${intervalSec}s)`;
  el.inferenceBadge.textContent = `AUTO LOOP (${intervalSec}s)`;
  el.inferenceBadge.className = 'badge badge-accent';

  const prompt = el.promptInput.value.trim() || getDefaultPrompt();
  runInference(prompt);
}

function stopAutoLoop() {
  isAutoLoop = false;
  if (autoLoopTimer) {
    clearTimeout(autoLoopTimer);
    autoLoopTimer = null;
  }
  const intervalSec = parseFloat(el.autoInterval.value) || 1.0;
  el.btnToggleAuto.classList.remove('active');
  el.btnToggleAuto.textContent = `▶ Auto Loop (${intervalSec}s)`;
  if (el.inferenceBadge.textContent.startsWith('AUTO LOOP')) {
    el.inferenceBadge.textContent = 'READY';
  }
}

async function runInference(promptText) {
  if (!promptText) {
    stopAutoLoop();
    el.inferenceOutput.innerHTML = '<span style="color:var(--accent-red)">No prompt: the default prompt could not be loaded from the server. Type a prompt or use a preset.</span>';
    return;
  }
  if (activeAbortController) {
    activeAbortController.abort();
  }
  activeAbortController = new AbortController();

  el.btnSubmit.classList.add('hidden');
  el.btnStop.classList.remove('hidden');
  el.inferenceBadge.textContent = isAutoLoop ? `ANALYZING...` : 'INFERRING...';
  el.inferenceBadge.className = 'badge badge-accent';

  el.inferenceOutput.innerHTML = '<span class="cursor-blink">▍</span>';

  const temperature = parseFloat(el.tempSlider.value);
  const payload = {
    prompt: promptText,
    temperature: temperature,
    max_tokens: 256,
  };

  let accumulatedContent = '';

  try {
    const resp = await fetch('/api/infer_stream', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      signal: activeAbortController.signal,
    });

    if (!resp.ok) {
      throw new Error(`Server returned HTTP ${resp.status}`);
    }

    const reader = resp.body.getReader();
    const decoder = new TextDecoder('utf-8');
    let buffer = '';

    while (true) {
      const { value, done } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });
      const lines = buffer.split('\n\n');
      buffer = lines.pop();

      for (const line of lines) {
        if (!line.trim() || !line.startsWith('data: ')) continue;
        const jsonStr = line.replace('data: ', '').trim();

        try {
          const evt = JSON.parse(jsonStr);

          if (evt.error) {
            el.inferenceOutput.innerHTML = `<span style="color:var(--accent-red)">Error: ${escHtml(evt.error)}</span>`;
            break;
          }

          if (evt.delta) {
            accumulatedContent += evt.delta;
          }

          renderInferenceText(accumulatedContent);

          if (evt.done) {
            el.statTtft.textContent = `${evt.ttft_ms} ms`;
            el.statTokens.textContent = `${evt.tokens}`;
            el.statSpeed.textContent = `${evt.tokens_per_sec} tok/s`;
            el.statLatency.textContent = `${evt.total_time} s`;

            addTimelineEvent(accumulatedContent, evt.total_time);

            // Manual runs (Run Once, presets, Capture) store the text the user just read;
            // Auto Loop never writes to the DB (Session 5-5c).  Same cleaning as renderInferenceText().
            if (!isAutoLoop) {
              let storeText = accumulatedContent.replace(/<think>[\s\S]*?<\/think>/g, '').replace(/<think>[\s\S]*/g, '').trim();
              if (!storeText) storeText = accumulatedContent.trim();
              if (storeText) {
                fetch('/api/vault/manual-event', {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ text: storeText.slice(0, 8000) }),
                }).catch(() => {});
              }
            }
          }
        } catch (e) {
          console.error('Error parsing SSE event:', e);
        }
      }
    }
  } catch (err) {
    if (err.name === 'AbortError') {
      console.log('Inference aborted by user.');
    } else {
      el.inferenceOutput.innerHTML = `<span style="color:var(--accent-red)">Inference failed: ${escHtml(err.message)}</span>`;
    }
  } finally {
    el.btnSubmit.classList.remove('hidden');
    el.btnStop.classList.add('hidden');
    el.inferenceBadge.textContent = isAutoLoop ? `AUTO LOOP (${el.autoInterval.value}s)` : 'READY';
    activeAbortController = null;

    // Schedule next iteration if Auto Loop is still active
    if (isAutoLoop) {
      const intervalMs = (parseFloat(el.autoInterval.value) || 2.0) * 1000;
      autoLoopTimer = setTimeout(() => {
        if (isAutoLoop) {
          const nextPrompt = el.promptInput.value.trim() || getDefaultPrompt();
          runInference(nextPrompt);
        }
      }, intervalMs);
    }
  }
}

function renderInferenceText(rawText) {
  // Strip any <think> tags so only clean descriptive output displays
  let cleanText = rawText.replace(/<think>[\s\S]*?<\/think>/g, '').replace(/<think>[\s\S]*/g, '').trim();
  if (!cleanText) cleanText = rawText;

  // Escape HTML before injecting markup
  const escaped = escHtml(cleanText);
  const formatted = escaped
    .replace(/\n\n/g, '<br><br>')
    .replace(/\n/g, '<br>')
    .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>');

  el.inferenceOutput.innerHTML = formatted + ' <span class="cursor-blink">▍</span>';
}

function addTimelineEvent(text, latencyS) {
  const timeStr = new Date().toLocaleTimeString();
  let cleanText = text.replace(/<think>[\s\S]*?<\/think>/g, '').trim();
  if (cleanText.length > 120) {
    cleanText = cleanText.substring(0, 117) + '...';
  }

  const item = {
    time: timeStr,
    text: cleanText,
    latency: latencyS ?? null,
  };

  eventHistory.unshift(item);
  if (eventHistory.length > 8) {
    eventHistory.pop();
  }

  el.eventCount.textContent = `${eventHistory.length} events`;
  el.timelineList.innerHTML = eventHistory.map(e => `
    <div class="timeline-item">
      <span class="timeline-time">[${escHtml(e.time)}]</span>
      <span class="timeline-text">${escHtml(e.text)}</span>
    </div>
  `).join('');
}

// ── Agent-event poller ────────────────────────────────────────────────────────
// Polls /api/vault/events every AGENT_EVENTS_POLL_MS and merges any new rows
// (id > lastSeenEventId) into the timeline as agent-side detections.
// The first SUCCESSFUL response only seeds lastSeenEventId (it shows nothing). A failed read
// (HTTP error, {error:…} body, no events array) changes nothing, so a DB-credential outage can
// never make the next good response look like "8 new events" (Bug 1, Session 5-5a).
async function pollAgentEvents() {
  try {
    const r = await fetch('/api/vault/events?limit=8', { cache: 'no-store' });
    if (!r.ok) return;
    const d = await r.json();
    if (!d || !Array.isArray(d.events)) return;
    if (lastSeenEventId === null) {
      lastSeenEventId = d.events.reduce((m, ev) => Math.max(m, ev.id), 0);
      return;
    }
    const rows = d.events.filter(ev => ev.id > lastSeenEventId);
    // Any new row (also a skipped manual_inference one) reloads the "Stored events" panel.
    if (rows.length) refreshStoredEvents();
    // rows come back newest-first; process oldest-first so timeline order is correct
    for (const ev of rows.reverse()) {
      lastSeenEventId = Math.max(lastSeenEventId, ev.id);
      // A manual WebUI inference is already in the list (runInference() added its text); its stored
      // row would show the same event a second time (Session 5-5c).
      if (ev.event_type === 'manual_inference') continue;
      // Format: "object detected" / "motion detected" — readable, no internal noise
      const label = ev.event_type.replace(/_/g, ' ');
      addTimelineEvent(label, null);
    }
  } catch (_) { /* network blip — skip */ }
}

// ── Video Controls ────────────────────────────────────────────────────────────

function initVideoControls() {
  el.btnRefreshStream.addEventListener('click', async () => {
    const originalText = el.btnRefreshStream.textContent;
    el.btnRefreshStream.textContent = 'Reconnecting...';
    el.btnRefreshStream.disabled = true;

    try {
      const resp = await fetch('/api/reconnect_camera', { method: 'POST' });
      const data = await resp.json();
      if (data.connected) {
        if (el.cameraBadge) el.cameraBadge.textContent = 'LIVE RTSP';
      } else {
        if (el.cameraBadge) el.cameraBadge.textContent = 'SIMULATED FEED';
      }
    } catch (err) {
      console.warn('Backend camera reconnect error:', err);
    } finally {
      el.cameraStream.src = `/video_feed?t=${Date.now()}`;
      el.btnRefreshStream.textContent = originalText;
      el.btnRefreshStream.disabled = false;
    }
  });

  el.btnSnapshot.addEventListener('click', async () => {
    try {
      const resp = await fetch('/api/capture_frame?format=json');
      const data = await resp.json();
      if (data.image_b64) {
        runInference(el.promptInput.value.trim() || getDefaultPrompt());
      }
    } catch (err) {
      console.error('Capture snapshot failed:', err);
    }
  });
}

async function checkInitialStatus() {
  try {
    const res = await fetch('/api/status');
    const data = await res.json();
    if (data.vlm_server?.healthy) {
      el.vlmPill.querySelector('.status-dot').className = 'status-dot green';
      el.vlmPill.querySelector('.status-text').textContent = 'VLM :8090 (Active)';
    } else {
      el.vlmPill.querySelector('.status-dot').className = 'status-dot red';
      el.vlmPill.querySelector('.status-text').textContent = 'VLM :8090 (Offline)';
    }
    if (data.camera && el.cameraBadge) {
      el.cameraBadge.textContent = data.camera.is_synthetic ? 'SIMULATED FEED' : 'LIVE RTSP';
    }
  } catch (e) {
    console.warn('Status check error:', e);
  }
}

// ── OpenShell Sandbox Card ────────────────────────────────────────────────────

const osEl = {
  statusBadge:  document.getElementById('openshell-status-badge'),
  refreshBtn:   document.getElementById('btn-openshell-refresh'),
  fsTbody:      document.getElementById('os-fs-tbody'),
  netTbody:     document.getElementById('os-net-tbody'),
  credsTbody:   document.getElementById('os-creds-tbody'),
  binaryPin:    document.getElementById('os-binary-pin'),
  eventsLog:      document.getElementById('os-events-log'),
  eventCount:     document.getElementById('os-event-count'),
  gatewayStatus:  document.getElementById('os-gateway-status'),
  auditLog:     document.getElementById('os-audit-log'),
  denyCount:    document.getElementById('os-deny-count'),
  denyFilter:   document.getElementById('os-deny-filter'),
};

// Sandbox-log "DENIED only" filter (client-side; the server already keeps every DENIED line).
let osDenyOnly = false;
let osLastAudit = null;   // last successful /api/openshell/audit body

// Multi-log correlation (Session 5-4 trace correlator)
let vaultLastAuditLines = [];
let gatewayLastEventLines = [];
let currentClockSkew = 0;

let osRefreshTimer = null;
const OS_POLL_INTERVAL_MS = 10000;  // refresh every 10 s

function escHtml(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function initOpenShellCard() {
  if (!osEl.statusBadge) return;  // card not in DOM
  refreshOpenShellCard();
  osEl.refreshBtn.addEventListener('click', () => refreshOpenShellCard());
  if (osEl.denyFilter) {
    osEl.denyFilter.addEventListener('click', () => {
      osDenyOnly = !osDenyOnly;
      osEl.denyFilter.setAttribute('aria-pressed', String(osDenyOnly));
      osEl.denyFilter.classList.toggle('active', osDenyOnly);
      osEl.denyFilter.textContent = osDenyOnly ? 'Show all' : 'Show DENIED only';
      renderAudit();
    });
  }
  initTraceTracer();
}

async function refreshOpenShellCard() {
  if (osEl.statusBadge) {
    osEl.statusBadge.textContent = 'LOADING…';
    osEl.statusBadge.className = 'badge badge-openshell';
  }
  await Promise.all([
    fetchAndRenderPolicy(),
    fetchAndRenderEvents(),
    fetchAndRenderAudit(),
    fetchAndRenderVaultAudit(),
  ]);
  // Schedule next auto-refresh
  clearTimeout(osRefreshTimer);
  osRefreshTimer = setTimeout(refreshOpenShellCard, OS_POLL_INTERVAL_MS);
}

async function fetchAndRenderPolicy() {
  try {
    const res = await fetch('/api/openshell/policy');
    if (!res.ok) { renderPolicyError('endpoint error ' + res.status); return; }
    const body = await res.json();
    if (!body.ok || !body.data) { renderPolicyError(body.error || 'no data'); return; }
    const d = body.data;

    const landlock = document.getElementById('os-landlock');
    if (landlock) landlock.textContent = d.landlock || '—';

    // Filesystem (Landlock): read-only and read-write paths from the effective policy
    if (osEl.fsTbody) {
      const rows = [
        ...(d.fs_read_only || []).map(p => ({ path: p, access: 'read-only' })),
        ...(d.fs_read_write || []).map(p => ({ path: p, access: 'read-write' })),
      ];
      osEl.fsTbody.innerHTML = rows.length
        ? rows.map(r => `<tr><td>${escHtml(r.path)}</td><td class="${r.access === 'read-write' ? 'access-allow' : 'access-read'}">${escHtml(r.access)}</td></tr>`).join('')
        : '<tr><td colspan="2" class="loading-cell">No paths in policy</td></tr>';
    }

    // Network policies: one row per endpoint; anything not listed is denied by the supervisor
    if (osEl.netTbody) {
      osEl.netTbody.innerHTML = (d.network && d.network.length)
        ? d.network.map(r => `<tr>
            <td>${escHtml(r.policy)}</td>
            <td>${escHtml(r.host)}:${escHtml(r.port)}<br><span style="color:var(--text-muted)">${escHtml(r.protocol)}, ${escHtml(r.enforcement)}</span></td>
            <td class="action-allow">${(r.rules || []).map(escHtml).join('<br>') || '(none)'}</td>
            <td>${(r.binaries || []).map(escHtml).join('<br>')}</td>
          </tr>`).join('')
        : '<tr><td colspan="4" class="loading-cell">No network policies</td></tr>';
    }

    // Providers: names and credential KEY NAMES (values are never exposed)
    if (osEl.credsTbody) {
      if (d.providers_error) {
        osEl.credsTbody.innerHTML = `<tr><td colspan="2" class="loading-cell" style="color:var(--accent-red)">${escHtml(d.providers_error)}</td></tr>`;
      } else if (d.providers && d.providers.length) {
        osEl.credsTbody.innerHTML = d.providers.map(p =>
          `<tr><td>${escHtml(p.name)}</td><td style="color:var(--accent-orange)">${p.credential_keys.length ? p.credential_keys.map(escHtml).join(', ') : '(none)'}</td></tr>`
        ).join('');
      } else {
        osEl.credsTbody.innerHTML = '<tr><td colspan="2" class="loading-cell">No providers</td></tr>';
      }
    }

    // Policy identity
    if (osEl.binaryPin) {
      const proc = d.process || {};
      osEl.binaryPin.innerHTML =
        `<span style="color:var(--text-muted)">status:</span> <span style="color:var(--nvidia-green)">${escHtml(d.status || '—')}</span> ` +
        `<span style="color:var(--text-muted)">version:</span> ${escHtml(d.version ?? '—')}<br>` +
        `<span style="color:var(--text-muted)">sha256:</span> ${escHtml(d.hash || '—')}<br>` +
        `<span style="color:var(--text-muted)">run as:</span> uid ${escHtml(proc.run_as_user ?? '—')} / gid ${escHtml(proc.run_as_group ?? '—')}`;
    }

    if (osEl.statusBadge) {
      const effective = (d.status || '').toLowerCase() === 'effective';
      osEl.statusBadge.textContent = effective ? 'POLICY EFFECTIVE' : ('POLICY ' + (d.status || 'UNKNOWN').toUpperCase());
      osEl.statusBadge.className = 'badge badge-openshell ' + (effective ? 'active' : 'error');
    }
  } catch (err) {
    renderPolicyError(err.message);
  }
}

function renderPolicyError(msg) {
  const err = (n) => `<tr><td colspan="${n}" class="loading-cell" style="color:var(--accent-red)">${escHtml(msg)}</td></tr>`;
  if (osEl.fsTbody)    osEl.fsTbody.innerHTML = err(2);
  if (osEl.netTbody)   osEl.netTbody.innerHTML = err(4);
  if (osEl.credsTbody) osEl.credsTbody.innerHTML = err(2);
  if (osEl.binaryPin)  osEl.binaryPin.innerHTML = `<span style="color:var(--accent-red)">${escHtml(msg)}</span>`;
  if (osEl.statusBadge) {
    osEl.statusBadge.textContent = 'POLICY ERROR';
    osEl.statusBadge.className = 'badge badge-openshell error';
  }
}

// Parse a journal line of the form:
//   2026-10-14T14:20:13+02:00 jetson openshell-gateway[92715]: 2026-10-14T12:20:13.247Z  INFO module: message key=val…
// Also handles systemd own lines (no inner timestamp):
//   2026-10-14T14:20:13+02:00 jetson systemd[92667]: Stopping openshell-gateway…
function formatGatewayLine(line) {
  // Match: outer-ts  host  process[pid]:  rest
  const outer = line.match(/^(\S+)\s+\S+\s+(\S+\[\d+\]):\s+(.*)$/);
  if (!outer) return null;
  const [, outerTs, proc, rest] = outer;

  // Outer timestamp — strip timezone, keep date+time
  const ts = outerTs.replace('T', ' ').replace(/[+-]\d{2}:\d{2}$/, '');
  const epoch = Date.parse(outerTs) / 1000 || 0;

  // Is this a systemd own line (no inner openshell timestamp)?
  const isSystemd = proc.startsWith('systemd');

  // Try to strip the redundant inner ISO timestamp from openshell-gateway lines
  // Inner format: 2026-10-14T12:20:13.247168Z  LEVEL  module: message
  const innerMatch = rest.match(/^\S+Z?\s{1,2}(INFO|WARN|ERROR|DEBUG)\s+(\S+):\s+(.*)/);

  let level = 'INFO';
  let module = '';
  let message = rest;

  if (innerMatch) {
    level  = innerMatch[1];
    module = innerMatch[2].replace(/openshell_server::?/, '').replace(/_/g, ' ');
    message = innerMatch[3];
  } else if (isSystemd) {
    // systemd messages: "Stopping …", "Started …", "Stopped …"
    level = /stop/i.test(rest) ? 'WARN' : /start/i.test(rest) ? 'INFO' : 'INFO';
    module = 'systemd';
    message = rest;
  }

  // Classify for colour
  const lvlLower = level.toLowerCase();
  const msgLower = message.toLowerCase();
  let entryClass = '';
  if (lvlLower === 'error' || msgLower.includes('error') || msgLower.includes('failed') || msgLower.includes('eperm')) {
    entryClass = 'deny';
  } else if (lvlLower === 'warn' || msgLower.includes('shutdown') || msgLower.includes('stopping') || msgLower.includes('stopped')) {
    entryClass = 'warn';
  } else if (msgLower.includes('connected') || msgLower.includes('bound') || msgLower.includes('started') || msgLower.includes('starting') || msgLower.includes('tls enabled')) {
    entryClass = 'allow';
  }

  const levelCls = level === 'ERROR' ? 'action-deny' : level === 'WARN' ? 'os-level-warn' : 'os-level-info';

  return `<div class="os-audit-entry ${entryClass}" data-ts="${epoch}">
    <div class="os-audit-row">
      <span class="os-audit-ts">${escHtml(ts)}</span>
      <span class="os-audit-action ${levelCls}">${escHtml(level)}</span>
      <span class="os-audit-dest">${escHtml(module)}</span>
    </div>
    <div class="os-audit-detail">${escHtml(message)}</div>
  </div>`;
}

async function fetchAndRenderEvents() {
  if (!osEl.eventsLog) return;
  try {
    const res = await fetch('/api/openshell/events');
    const body = await res.json();

    // Render live gateway status badge
    if (osEl.gatewayStatus) {
      const up = body.gateway_active === true;
      osEl.gatewayStatus.textContent = up ? '● UP' : '● DOWN';
      osEl.gatewayStatus.className = 'os-gateway-status ' + (up ? 'gw-up' : 'gw-down');
    }

    const lines = body.lines || [];
    gatewayLastEventLines = lines; // Preserve in global state for time correlation
    if (lines.length === 0) {
      osEl.eventsLog.innerHTML = '<span class="os-placeholder">No journal entries for current session.</span>';
      if (osEl.eventCount) osEl.eventCount.textContent = '';
      return;
    }

    osEl.eventsLog.innerHTML = lines.map(line => {
      const formatted = formatGatewayLine(line);
      if (formatted) return formatted;
      // Fallback: plain line with basic colour hint
      const lower = line.toLowerCase();
      const cls = lower.includes('error') || lower.includes('eperm') ? 'deny'
        : lower.includes('warn') || lower.includes('stop') ? 'warn'
        : lower.includes('connect') || lower.includes('start') ? 'allow' : '';
      return `<div class="os-log-line ${cls}">${escHtml(line)}</div>`;
    }).join('');

    osEl.eventsLog.scrollTop = osEl.eventsLog.scrollHeight;
    if (osEl.eventCount) osEl.eventCount.textContent = `${lines.length} lines`;
  } catch (err) {
    osEl.eventsLog.innerHTML = `<span class="os-placeholder" style="color:var(--accent-red)">Error fetching events: ${escHtml(err.message)}</span>`;
  }
}

// Format one OCSF sandbox log line. Measured shape (openshell logs <sb> --source sandbox):
//   [1792303232.805] [sandbox] [OCSF ] [ocsf] NET:OPEN [INFO] ALLOWED /usr/bin/python3.12(0) -> host:8095 [policy:NAME engine:opa]
//   [..] [sandbox] [OCSF ] [ocsf] HTTP:GET [INFO] ALLOWED GET http://host:8095/frame.jpg [policy:NAME engine:l7]
//   [..] [sandbox] [OCSF ] [ocsf] NET:OPEN [MED] DENIED <detail> [reason:...]
// Unparsable lines are shown verbatim (never dropped).
function formatSandboxLine(line) {
  const m = line.match(/^\[(\d+(?:\.\d+)?)\]\s+\[\w+\]\s+\[OCSF\s*\]\s+\[\w+\]\s+(\S+)\s+\[(\w+)\]\s+(ALLOWED|DENIED)\s+(.*)$/);
  if (!m) return `<div class="os-log-line">${escHtml(line)}</div>`;
  const [, epoch, cls, sev, verdict, rest] = m;
  const ts = new Date(parseFloat(epoch) * 1000).toLocaleTimeString();
  const denied = verdict === 'DENIED';
  return `<div class="os-audit-entry ${denied ? 'deny' : 'allow'}" data-ts="${epoch}">
      <div class="os-audit-row">
        <span class="os-audit-ts">${escHtml(ts)}</span>
        <span class="os-audit-action ${denied ? 'action-deny' : 'action-allow'}">${verdict}</span>
        <span class="os-audit-dest">${escHtml(cls)} [${escHtml(sev)}]</span>
      </div>
      <div class="os-audit-detail">${escHtml(rest)}</div>
    </div>`;
}

function renderAudit() {
  if (!osEl.auditLog || !osLastAudit) return;
  const body = osLastAudit;
  let lines = body.lines || [];
  if (lines.length === 0) {
    osEl.auditLog.innerHTML = '<span class="os-placeholder">No sandbox log entries in the current window.</span>';
    if (osEl.denyCount) osEl.denyCount.textContent = '';
    return;
  }
  if (osDenyOnly) {
    lines = lines.filter(l => l.includes(' DENIED '));
    if (lines.length === 0) {
      osEl.auditLog.innerHTML = '<span class="os-placeholder">No DENIED entries in the current window.</span>';
      if (osEl.denyCount) osEl.denyCount.textContent = `${body.denied} DENIED in last ${body.window_lines} lines`;
      return;
    }
  }
  osEl.auditLog.innerHTML = lines.map(formatSandboxLine).join('');
  osEl.auditLog.scrollTop = osEl.auditLog.scrollHeight;
  if (osEl.denyCount) {
    osEl.denyCount.textContent = `${body.denied} DENIED in last ${body.window_lines} lines`;
  }
}

async function fetchAndRenderAudit() {
  if (!osEl.auditLog) return;
  try {
    const res = await fetch('/api/openshell/audit');
    const body = await res.json();
    if (!body.ok) {
      osLastAudit = null;
      osEl.auditLog.innerHTML = `<span class="os-placeholder" style="color:var(--accent-red)">${escHtml(body.error || 'sandbox log unavailable')}</span>`;
      if (osEl.denyCount) osEl.denyCount.textContent = '';
      return;
    }
    osLastAudit = body;
    renderAudit();
  } catch (err) {
    osEl.auditLog.innerHTML = `<span class="os-placeholder" style="color:var(--accent-red)">Error fetching sandbox log: ${escHtml(err.message)}</span>`;
  }
}

function formatVaultAuditLine(obj) {
  const isoTime = obj.time || '';
  const ts = isoTime ? isoTime.split('T')[1]?.split('.')[0] || isoTime : '—';
  const epoch = isoTime ? Date.parse(isoTime) / 1000 : 0;
  
  const type = obj.type || 'request';
  const req = obj.request || {};
  const op = req.operation || '—';
  const path = req.path || '—';
  
  const auth = obj.auth || {};
  const policies = auth.token_policies || auth.policies || [];
  const roleName = auth.metadata?.role_name || auth.metadata?.username || '—';
  
  const isError = obj.error ? true : false;
  const isDeny = isError || op === 'deny' || path.includes('denied');
  const entryClass = isDeny ? 'deny' : 'allow';

  const detailText = isError
    ? `Error: ${obj.error}`
    : `${op.toUpperCase()} ${path} (role: ${roleName}, policies: [${policies.join(', ')}])`;

  return `<div class="os-audit-entry ${entryClass}" data-ts="${epoch}">
      <div class="os-audit-row">
        <span class="os-audit-ts">${escHtml(ts)}</span>
        <span class="os-audit-action ${isDeny ? 'action-deny' : 'action-allow'}">${escHtml(op.toUpperCase())}</span>
        <span class="os-audit-dest">${escHtml(path)}</span>
      </div>
      <div class="os-audit-detail">${escHtml(detailText)}</div>
    </div>`;
}

async function fetchAndRenderVaultAudit() {
  const vaultLogEl = document.getElementById('vault-audit-log');
  const skewEl = document.getElementById('vault-skew-status');
  if (!vaultLogEl) return;

  try {
    const res = await fetch('/api/vault/audit-log?limit=50');
    if (!res.ok) {
      const errBody = await res.json().catch(() => ({}));
      vaultLogEl.innerHTML = `<span class="os-placeholder" style="color:var(--accent-red)">Error: ${escHtml(errBody.error || 'HTTP ' + res.status)}</span>`;
      if (skewEl) {
        skewEl.textContent = 'LOG ERROR';
        skewEl.className = 'vault-skew-status skew-red';
      }
      return;
    }
    const body = await res.json();
    const lines = body.lines || [];
    vaultLastAuditLines = lines; // Preserve in global state for time correlation
    currentClockSkew = body.clock_skew_s || 0; // Preserve in global state for clock skew compensation

    if (skewEl) {
      const skew = body.clock_skew_s;
      if (skew < 5) {
        skewEl.textContent = `CLOCK SYNCED (SKEW: ${skew}s)`;
        skewEl.className = 'vault-skew-status skew-green';
      } else {
        skewEl.textContent = `CLOCK SKEW WARNING (${skew}s)`;
        skewEl.className = 'vault-skew-status skew-red';
      }
    }

    if (lines.length === 0) {
      vaultLogEl.innerHTML = '<span class="os-placeholder">No Vault audit log entries.</span>';
      return;
    }

    vaultLogEl.innerHTML = lines.map(formatVaultAuditLine).join('');
    vaultLogEl.scrollTop = vaultLogEl.scrollHeight;

  } catch (err) {
    vaultLogEl.innerHTML = `<span class="os-placeholder" style="color:var(--accent-red)">Error: ${escHtml(err.message)}</span>`;
    if (skewEl) {
      skewEl.textContent = 'FETCH ERROR';
      skewEl.className = 'vault-skew-status skew-red';
    }
  }
}

// ── "Test any URL" (Session 3-6) ─────────────────────────────────────────────

const tuEl = {
  input:        document.getElementById('testurl-input'),
  btn:          document.getElementById('btn-test-url'),
  result:       document.getElementById('testurl-result'),
  verdictBadge: document.getElementById('testurl-verdict-badge'),
  httpCode:     document.getElementById('testurl-http-code'),
  denyLine:     document.getElementById('testurl-deny-line'),
  errorMsg:     document.getElementById('testurl-error-msg'),
};

// Populate quick-example buttons
document.querySelectorAll('.testurl-example').forEach(btn => {
  btn.addEventListener('click', () => {
    if (tuEl.input) tuEl.input.value = btn.dataset.url || '';
    if (tuEl.input) tuEl.input.focus();
  });
});

// Allow Enter key in the input to trigger the test
if (tuEl.input) {
  tuEl.input.addEventListener('keydown', e => {
    if (e.key === 'Enter') runTestUrl();
  });
}

if (tuEl.btn) {
  tuEl.btn.addEventListener('click', runTestUrl);
}

async function runTestUrl() {
  const url = (tuEl.input && tuEl.input.value || '').trim();
  if (!url) {
    showTestUrlError('Please enter a URL.');
    return;
  }

  // Client-side pre-check: scheme only
  if (!/^https?:\/\//i.test(url)) {
    showTestUrlError('Only http:// and https:// URLs are supported.');
    return;
  }

  // Show spinner state
  if (tuEl.btn) { tuEl.btn.disabled = true; tuEl.btn.textContent = 'Testing…'; }
  if (tuEl.result) tuEl.result.classList.add('hidden');

  try {
    const res = await fetch('/api/openshell/test-url', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ url }),
    });

    const body = await res.json();

    if (!body.ok) {
      showTestUrlError(body.error || `HTTP ${res.status}`);
      return;
    }

    renderTestUrlResult(body);
  } catch (err) {
    showTestUrlError('Network error: ' + err.message);
  } finally {
    if (tuEl.btn) { tuEl.btn.disabled = false; tuEl.btn.textContent = 'Test from sandbox'; }
  }
}

function renderTestUrlResult(body) {
  if (!tuEl.result) return;

  const blocked = body.verdict === 'BLOCKED';
  const inconclusive = body.verdict === 'INCONCLUSIVE';

  // Verdict badge
  if (tuEl.verdictBadge) {
    tuEl.verdictBadge.textContent = blocked ? '🚫 BLOCKED' : inconclusive ? '❓ INCONCLUSIVE' : '✅ ALLOWED';
    tuEl.verdictBadge.className = 'testurl-verdict ' + (blocked ? 'verdict-blocked' : inconclusive ? '' : 'verdict-allowed');
  }

  // HTTP status code (empty string when blocked before a response was received)
  if (tuEl.httpCode) {
    tuEl.httpCode.textContent = body.http_code ? `HTTP ${body.http_code}` : '';
    tuEl.httpCode.className = 'testurl-http-code';
  }

  // Deny log line (only shown when BLOCKED and a line was found)
  if (tuEl.denyLine) {
    if (blocked && body.deny_log_line) {
      tuEl.denyLine.textContent = body.deny_log_line;
      tuEl.denyLine.classList.remove('hidden');
    } else if (inconclusive) {
      tuEl.denyLine.textContent = '(No HTTP response and no matching DENIED line in the sandbox log — not shown as allowed or blocked.)';
      tuEl.denyLine.classList.remove('hidden');
    } else {
      tuEl.denyLine.textContent = '';
      tuEl.denyLine.classList.add('hidden');
    }
  }

  // Clear error
  if (tuEl.errorMsg) {
    tuEl.errorMsg.textContent = '';
    tuEl.errorMsg.classList.add('hidden');
  }

  if (tuEl.result) tuEl.result.classList.remove('hidden');
}

function showTestUrlError(msg) {
  if (tuEl.result) tuEl.result.classList.remove('hidden');
  if (tuEl.verdictBadge) { tuEl.verdictBadge.textContent = ''; tuEl.verdictBadge.className = 'testurl-verdict'; }
  if (tuEl.httpCode) { tuEl.httpCode.textContent = ''; }
  if (tuEl.denyLine) { tuEl.denyLine.textContent = ''; tuEl.denyLine.classList.add('hidden'); }
  if (tuEl.errorMsg) {
    tuEl.errorMsg.textContent = msg;
    tuEl.errorMsg.classList.remove('hidden');
  }
}


// ── Vault-backed widgets (Session 5-3b) ───────────────────────────────────────
// Widget 1: identity strip      GET  /api/vault/identity         every 30 s, TTL ticks locally each second
// Widget 2: dynamic credentials GET  /api/vault/db-credential    every 15 s, POST /api/vault/rotate-credential
// Widget 3: payload decrypt     GET  /api/vault/events + POST /api/vault/decrypt per row, while the toggle is on
// Every number shown comes from the endpoints; nothing is simulated. Errors are shown as errors.

const IDENTITY_POLL_MS = 30000;
const CRED_POLL_MS = 15000;
const CRED_LEASE_FALLBACK_S = 300;
const identityState = { edge: null, gateway: null };   // { expireAtMs } per token
const credState = { expireAtMs: null, durationS: CRED_LEASE_FALLBACK_S };
let decryptOn = false;
let decryptRun = 0;

function fmtDuration(totalS) {
  if (totalS == null || isNaN(totalS)) return '—';
  const s = Math.max(0, Math.floor(totalS));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = s % 60;
  if (h > 0) return `${h}h ${String(m).padStart(2, '0')}m`;
  return `${m}m ${String(sec).padStart(2, '0')}s`;
}

function escapeHtml(t) {
  return String(t).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function initVaultWidgets() {
  refreshIdentity();
  refreshCredential();
  setInterval(refreshIdentity, IDENTITY_POLL_MS);
  setInterval(refreshCredential, CRED_POLL_MS);
  setInterval(tickVaultCountdowns, 1000);
  const rot = document.getElementById('btn-rotate-secret');
  if (rot) rot.addEventListener('click', rotateSecretNow);
  const tog = document.getElementById('btn-decrypt-toggle');
  if (tog) tog.addEventListener('click', toggleDecrypt);
  // Show stored-events panel immediately with ciphertext rows.
  const box = document.getElementById('stored-events');
  if (box) box.classList.remove('hidden');
  loadStoredEventsCipher();
  // First call seeds lastSeenEventId (shows nothing); later calls show only NEW agent events.
  pollAgentEvents();
  setInterval(pollAgentEvents, AGENT_EVENTS_POLL_MS);
}

// ── Widget 1 ──
async function refreshIdentity() {
  let data;
  try {
    const r = await fetch('/api/vault/identity', { cache: 'no-store' });
    data = await r.json();
  } catch (e) {
    data = { edge: { error: 'unreachable' }, gateway: { error: 'unreachable' } };
  }
  for (const who of ['edge', 'gateway']) renderIdentity(who, data[who] || { error: 'no data' });
}

function renderIdentity(who, t) {
  const cell = document.getElementById(`idc-${who}`);
  const name = document.getElementById(`idc-${who}-name`);
  const pol = document.getElementById(`idc-${who}-policies`);
  const ttl = document.getElementById(`idc-${who}-ttl`);
  if (!cell) return;
  if (t.error) {
    identityState[who] = null;
    cell.classList.add('idc-error');
    cell.classList.remove('ttl-green', 'ttl-amber', 'ttl-red');
    name.textContent = t.error === 'unreadable' ? 'unreadable (permission denied)' : `unavailable${t.detail ? ' — ' + t.detail : ''}`;
    pol.textContent = '';
    ttl.textContent = '—';
    return;
  }
  cell.classList.remove('idc-error');
  name.textContent = t.display_name || '—';
  pol.textContent = (t.policies || []).join(', ');
  const expire = t.expire_time ? Date.parse(t.expire_time) : NaN;
  identityState[who] = { expireAtMs: isNaN(expire) ? Date.now() + (t.ttl || 0) * 1000 : expire };
  tickVaultCountdowns();
}

function tickVaultCountdowns() {
  // identity: green > 1 h, amber < 30 min (between: neutral); red when expired
  for (const who of ['edge', 'gateway']) {
    const st = identityState[who];
    const cell = document.getElementById(`idc-${who}`);
    const ttl = document.getElementById(`idc-${who}-ttl`);
    if (!st || !cell) continue;
    const rem = (st.expireAtMs - Date.now()) / 1000;
    ttl.textContent = rem > 0 ? fmtDuration(rem) : 'expired';
    cell.classList.remove('ttl-green', 'ttl-amber', 'ttl-red');
    if (rem <= 0) cell.classList.add('ttl-red');
    else if (rem > 3600) cell.classList.add('ttl-green');
    else if (rem < 1800) cell.classList.add('ttl-amber');
  }
  // credential lease: 5-min range, green > 2 min, amber < 1 min
  if (credState.expireAtMs != null) {
    const rem = Math.max(0, (credState.expireAtMs - Date.now()) / 1000);
    const fill = document.getElementById('cred-bar-fill');
    const lbl = document.getElementById('cred-ttl');
    const pct = Math.min(100, (rem / (credState.durationS || CRED_LEASE_FALLBACK_S)) * 100);
    fill.style.width = `${pct}%`;
    fill.classList.remove('ttl-green', 'ttl-amber', 'ttl-red');
    if (rem > 120) fill.classList.add('ttl-green');
    else if (rem < 60) fill.classList.add(rem <= 0 ? 'ttl-red' : 'ttl-amber');
    lbl.textContent = fmtDuration(rem);
  }
}

// ── Widget 2 ──
function maskUser(u) {
  if (!u) return '—';
  return u;
}

// A failed poll keeps the last good values and shows "reconnecting…" (Session 5-5e); the next
// poll (every CRED_POLL_MS) replaces it as soon as the backend answers again.
async function refreshCredential() {
  const userEl = document.getElementById('cred-username');
  if (!userEl) return;
  try {
    const r = await fetch('/api/vault/db-credential', { cache: 'no-store' });
    const d = await r.json();
    if (!r.ok || d.error) throw new Error(d.error || `HTTP ${r.status}`);
    applyCredential(d);
  } catch (e) {
    userEl.textContent = credState.lastUser ? `${credState.lastUser} (reconnecting…)` : 'reconnecting…';
    userEl.title = e.message;
  }
}

function applyCredential(d) {
  credState.lastUser = maskUser(d.db_username);
  document.getElementById('cred-username').title = '';
  document.getElementById('cred-username').textContent = maskUser(d.db_username);
  credState.durationS = d.lease_duration_s || CRED_LEASE_FALLBACK_S;
  credState.expireAtMs = Date.now() + (d.lease_ttl_s || 0) * 1000;
  tickVaultCountdowns();
}

async function rotateSecretNow() {
  const btn = document.getElementById('btn-rotate-secret');
  const out = document.getElementById('cred-result');
  btn.disabled = true;
  const label = btn.textContent;
  btn.textContent = 'Rotating…';
  out.classList.remove('hidden', 'cred-result-error');
  out.textContent = 'Requesting a fresh lease, swapping, revoking the old one…';
  try {
    const r = await fetch('/api/vault/rotate-credential', { method: 'POST' });
    const d = await r.json();
    if (!r.ok || d.error) throw new Error(d.error || `HTTP ${r.status}`);
    out.innerHTML =
      `${escapeHtml(maskUser(d.old_username))} &rarr; ${escapeHtml(maskUser(d.new_username))}<br>` +
      `old lease revoked: ${d.old_lease_revoked ? 'yes' : 'NO (' + escapeHtml(d.revoke_detail || '?') + ')'}<br>` +
      `rows inserted during the rotate window: ${d.rows_written_since_rotate} ` +
      `(${d.rows_before_swap} before the swap, ${d.rows_after_swap} after) &middot; window ${d.rotate_window_ms} ms`;
    if (!d.old_lease_revoked) out.classList.add('cred-result-error');
    await refreshCredential();
  } catch (e) {
    out.classList.add('cred-result-error');
    out.textContent = `Rotation failed: ${e.message}`;
  } finally {
    btn.disabled = false;
    btn.textContent = label;
  }
}

// ── Widget 3 ──
// Load ciphertext rows into the stored-events list.  Called on page load and
// whenever the panel needs refreshing.  Does NOT trigger decryption.
let storedRetryTimer = null;
async function loadStoredEventsCipher() {
  const list = document.getElementById('stored-events-list');
  if (!list) return;
  clearTimeout(storedRetryTimer);
  if (!list.querySelector('.stored-event[data-id]')) {
    list.innerHTML = '<div class="timeline-empty">Loading stored events…</div>';
  }
  let events;
  try {
    const r = await fetch('/api/vault/events?limit=8', { cache: 'no-store' });
    const d = await r.json();
    if (!r.ok || d.error) throw new Error(d.error || `HTTP ${r.status}`);
    events = d.events || [];
  } catch (e) {
    // Keep the last good list (if any) and retry; no permanent error text (Session 5-5e).
    if (!list.querySelector('.stored-event[data-id]')) {
      list.innerHTML = `<div class="timeline-empty">Reconnecting to the database… (${escapeHtml(e.message)})</div>`;
    }
    if (!decryptOn) storedRetryTimer = setTimeout(loadStoredEventsCipher, AGENT_EVENTS_POLL_MS);
    return;
  }
  if (!events.length) {
    list.innerHTML = '<div class="timeline-empty">No stored events yet.</div>';
    return;
  }
  list.innerHTML = events.map((ev) => `
    <div class="stored-event" data-id="${ev.id}">
      <div class="se-meta">#${ev.id} &middot; ${escapeHtml(ev.occurred_at)} &middot; ${escapeHtml(ev.event_type)}/${escapeHtml(ev.state)}</div>
      <pre class="se-body cipher" data-cipher="${escapeHtml(ev.raw_payload.slice(0, 64))}…">${escapeHtml(ev.raw_payload.slice(0, 64))}…</pre>
    </div>`).join('');
}

// Called when pollAgentEvents() sees a new row (agent motion/scene or a manual WebUI inference).
// Keeps the current view: ciphertext stays ciphertext, plaintext is decrypted again.
function refreshStoredEvents() {
  if (decryptOn) decryptStoredEvents(++decryptRun);
  else loadStoredEventsCipher();
}

async function toggleDecrypt() {
  const btn = document.getElementById('btn-decrypt-toggle');
  const list = document.getElementById('stored-events-list');
  const badge = document.getElementById('decrypt-badge');
  decryptOn = !decryptOn;
  btn.setAttribute('aria-pressed', String(decryptOn));
  const myRun = ++decryptRun;
  if (!decryptOn) {
    // Back to ciphertext view — reload rows from the server (drop any plaintext).
    btn.textContent = '🔓 Decrypt stored events';
    badge.classList.add('hidden');
    await loadStoredEventsCipher();
    return;
  }
  btn.textContent = '🔒 Hide plaintext';
  await decryptStoredEvents(myRun);
}

// Decrypt mode: fetch fresh rows then decrypt each one.  Shared by the toggle and by
// refreshStoredEvents() (new row seen by pollAgentEvents, Session 5-5e follow-up).
async function decryptStoredEvents(myRun) {
  const list = document.getElementById('stored-events-list');
  const badge = document.getElementById('decrypt-badge');
  await loadStoredEventsCipher();
  let okCount = 0;
  const rows = list.querySelectorAll('.stored-event[data-id]');
  // Re-fetch to get encrypted_datakey alongside raw_payload.
  let events;
  try {
    const r = await fetch('/api/vault/events?limit=8', { cache: 'no-store' });
    const d = await r.json();
    if (!r.ok || d.error) throw new Error(d.error || `HTTP ${r.status}`);
    events = d.events || [];
  } catch (e) { return; }
  for (const ev of events) {
    if (myRun !== decryptRun || !decryptOn) return;
    const row = list.querySelector(`.stored-event[data-id="${ev.id}"]`);
    if (!row || !ev.raw_payload) continue;
    const body = row.querySelector('.se-body');
    try {
      const r = await fetch('/api/vault/decrypt', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ciphertext: ev.raw_payload, encrypted_datakey: ev.encrypted_datakey }),
      });
      const d = await r.json();
      if (!r.ok || d.error) throw new Error(d.error || `HTTP ${r.status}`);
      if (myRun !== decryptRun || !decryptOn) return;
      let shown = d.plaintext;
      try { shown = JSON.stringify(JSON.parse(d.plaintext), null, 2); } catch (e) { /* plain text payload */ }
      body.textContent = shown;
      body.className = 'se-body';
      row.classList.add('decrypted');
      okCount += 1;
      badge.classList.remove('hidden');
    } catch (e) {
      body.textContent = `decrypt failed: ${e.message}`;
      body.className = 'se-body err';
    }
  }
  if (okCount === 0) badge.classList.add('hidden');
}

/* ── Multi-Log Event Correlator (Session 5-4) ────────────────────────────── */

function initTraceTracer() {
  const containers = ['os-events-log', 'os-audit-log', 'vault-audit-log'];
  containers.forEach(id => {
    const el = document.getElementById(id);
    if (!el) return;
    el.addEventListener('click', (ev) => {
      const entry = ev.target.closest('.os-audit-entry');
      if (!entry) return;
      const tsAttr = entry.getAttribute('data-ts');
      if (!tsAttr) return;
      const clickedTs = parseFloat(tsAttr);
      if (clickedTs > 0) {
        showTraceOverlay(clickedTs, id);
      }
    });
  });
}

function showTraceOverlay(clickedTs, sourceId) {
  const WINDOW_S = 2.0;

  // 1. Correlate OCSF Sandbox Log entries (Jetson relative time)
  const ocsfMatches = [];
  if (osLastAudit && osLastAudit.lines) {
    osLastAudit.lines.forEach(line => {
      const m = line.match(/^\[(\d+(?:\.\d+)?)\]/);
      if (m) {
        const t = parseFloat(m[1]);
        const targetTs = (sourceId === 'vault-audit-log') ? (clickedTs - currentClockSkew) : clickedTs;
        if (Math.abs(t - targetTs) <= WINDOW_S) {
          ocsfMatches.push({ ts: t, formatted: formatSandboxLine(line) });
        }
      }
    });
  }

  // 2. Correlate Gateway Journal lines (Jetson relative time)
  const gatewayMatches = [];
  gatewayLastEventLines.forEach(line => {
    const outer = line.match(/^(\S+)\s+/);
    if (outer) {
      const t = Date.parse(outer[1]) / 1000;
      const targetTs = (sourceId === 'vault-audit-log') ? (clickedTs - currentClockSkew) : clickedTs;
      if (t && Math.abs(t - targetTs) <= WINDOW_S) {
        gatewayMatches.push({ ts: t, formatted: formatGatewayLine(line) });
      }
    }
  });

  // 3. Correlate Vault Audit Log entries (Mac relative time)
  const vaultMatches = [];
  vaultLastAuditLines.forEach(obj => {
    const isoTime = obj.time || '';
    if (isoTime) {
      const vMacTime = Date.parse(isoTime) / 1000;
      const targetMacTime = (sourceId === 'vault-audit-log') ? clickedTs : (clickedTs + currentClockSkew);
      if (vMacTime && Math.abs(vMacTime - targetMacTime) <= WINDOW_S) {
        vaultMatches.push({ ts: vMacTime, formatted: formatVaultAuditLine(obj) });
      }
    }
  });

  // 4. Create and inject modal overlay DOM
  let modal = document.getElementById('trace-tracer-modal');
  if (!modal) {
    modal = document.createElement('div');
    modal.id = 'trace-tracer-modal';
    modal.className = 'modal-overlay';
    document.body.appendChild(modal);
  }

  modal.innerHTML = `
    <div class="modal-content trace-modal">
      <div class="modal-header">
        <h3>🔍 Multi-Log Event Correlator (±${WINDOW_S}s Trace)</h3>
        <button class="btn-close" id="btn-close-trace">&times;</button>
      </div>
      <div class="modal-body">
        <div class="trace-grid">
          <div class="trace-column">
            <h4>📋 Gateway / Agent Events</h4>
            <div class="trace-log-list">
              ${gatewayMatches.length ? gatewayMatches.map(m => m.formatted).join('') : '<span class="os-placeholder">No correlated events</span>'}
            </div>
          </div>
          <div class="trace-column">
            <h4>🛡️ Sandbox Log (OCSF)</h4>
            <div class="trace-log-list">
              ${ocsfMatches.length ? ocsfMatches.map(m => m.formatted).join('') : '<span class="os-placeholder">No correlated events</span>'}
            </div>
          </div>
          <div class="trace-column">
            <h4>🔒 Vault Audit Log</h4>
            <div class="trace-log-list">
              ${vaultMatches.length ? vaultMatches.map(m => m.formatted).join('') : '<span class="os-placeholder">No correlated events</span>'}
            </div>
          </div>
        </div>
        <div class="trace-footer-info">
          <span>Clock Skew: ${currentClockSkew}s</span> | 
          <span>Base Timestamp: ${new Date(clickedTs * 1000).toLocaleTimeString()}</span>
        </div>
      </div>
    </div>
  `;

  modal.classList.add('active');

  // Modal dismiss click listeners
  const closeModal = () => modal.classList.remove('active');
  modal.addEventListener('click', (e) => {
    if (e.target === modal) closeModal();
  });
  document.getElementById('btn-close-trace').addEventListener('click', closeModal);
}
