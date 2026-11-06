/**
 * ui/static/arch-anim.js  v2
 * ==========================
 * Tab 3 split-pane visualiser.
 *
 * TOP PANEL  — SVG architecture overview.  Nodes light up as sub-steps advance.
 * BOTTOM PANEL — Flow selector tabs (11 flows) + sequence diagram that reveals
 *                messages one at a time.  Both panels stay in sync.
 *
 * Depends on arch-scene.js loaded first:
 *   SCENE_W, SCENE_H, LANES, NODES, EDGES, PARTICIPANTS, FLOWS
 *
 * No fetch() / XMLHttpRequest / WebSocket. No external dependencies.
 */

'use strict';

(function () {

const SVG_NS = 'http://www.w3.org/2000/svg';

// ─────────────────────────────────────────────────────────────────────────────
// Tiny DOM helpers
// ─────────────────────────────────────────────────────────────────────────────
function svgEl(tag, attrs) {
  const el = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs || {})) el.setAttribute(k, v);
  return el;
}
function h(tag, attrs, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === 'class') el.className = v;
    else if (k === 'text') el.textContent = v;
    else el.setAttribute(k, v);
  }
  for (const c of children) {
    if (c == null) continue;
    el.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
  }
  return el;
}

const REDUCED = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

// ─────────────────────────────────────────────────────────────────────────────
// Colours
// ─────────────────────────────────────────────────────────────────────────────
const TRUST_FILL   = { edge:'#0a1520', untrusted:'#2a0d0d', trusted:'#0d1c0d', vault:'#2a280d', hardware:'#1a1a2e', threat:'#3d1010' };
const TRUST_STROKE = { edge:'#58A6FF', untrusted:'#F85149', trusted:'#76B900', vault:'#FFD814', hardware:'#C084FC', threat:'#F85149' };
const TRUST_TEXT   = { edge:'#99c8ff', untrusted:'#ff9492', trusted:'#a3d977', vault:'#ffe566', hardware:'#d8b4fe', threat:'#ff9492' };
const KIND_COLOR   = { credential:'#FFD814', data:'#2dd4bf', denied:'#F85149', admin:'#C084FC' };
const KIND_DASH    = { credential:'none', data:'none', denied:'6,3', admin:'none' };

// ─────────────────────────────────────────────────────────────────────────────
// State
// ─────────────────────────────────────────────────────────────────────────────
let activeFlowIdx  = 0;   // index into FLOWS
let activeSubStep  = -1;  // -1 = overview (all sub-steps hidden)
let isPlaying      = false;
let playTimer      = null;
let playSpeed      = 1;
const STEP_MS      = 2800;

// packet animation handles
let packetHandles = [];

// ─────────────────────────────────────────────────────────────────────────────
// Fast lookups
// ─────────────────────────────────────────────────────────────────────────────
const nodeMap = {};
NODES.forEach(n => { nodeMap[n.id] = n; });
const edgeMap = {};
EDGES.forEach(e => { edgeMap[e.id] = e; });

// ─────────────────────────────────────────────────────────────────────────────
// Geometry
// ─────────────────────────────────────────────────────────────────────────────
function nodeBorder(node, tx, ty) {
  const hw = node.w / 2, hh = node.h / 2;
  const dx = tx - node.x, dy = ty - node.y;
  if (Math.abs(dx) < 0.01 && Math.abs(dy) < 0.01) return { x: node.x, y: node.y };
  const s = Math.min(hw / Math.abs(dx), hh / Math.abs(dy));
  return { x: node.x + dx * s, y: node.y + dy * s };
}
function bezCtrl(x1, y1, x2, y2, c) {
  const mx = (x1+x2)/2, my = (y1+y2)/2;
  const dx = x2-x1, dy = y2-y1, l = Math.sqrt(dx*dx+dy*dy)||1;
  return { cx: mx - dy/l*c, cy: my + dx/l*c };
}
function bezAt(x1,y1,cx,cy,x2,y2,t) {
  const u=1-t;
  return { x: u*u*x1+2*u*t*cx+t*t*x2, y: u*u*y1+2*u*t*cy+t*t*y2 };
}
function edgePathD(edge) {
  const s = nodeMap[edge.from], d = nodeMap[edge.to];
  if (!s || !d) return '';
  const sp = nodeBorder(s, d.x, d.y);
  const dp = nodeBorder(d, s.x, s.y);
  const c = (edge.curve !== undefined) ? edge.curve : 35;
  const {cx,cy} = bezCtrl(sp.x,sp.y,dp.x,dp.y, c);
  return `M ${sp.x} ${sp.y} Q ${cx} ${cy} ${dp.x} ${dp.y}`;
}

// ─────────────────────────────────────────────────────────────────────────────
// SVG architecture overview (top panel)
// ─────────────────────────────────────────────────────────────────────────────
let svgRoot, edgeGroup, nodeGroup, packetGroup, tooltipEl;

function buildSVG(container) {
  svgRoot = svgEl('svg', {
    viewBox:`0 0 ${SCENE_W} ${SCENE_H}`,
    preserveAspectRatio:'xMidYMid meet',
    class:'arch-svg', width:'100%',
    role:'img', 'aria-label':'Architecture overview',
  });

  // defs: arrowheads
  const defs = svgEl('defs');
  for (const [kind, col] of Object.entries(KIND_COLOR)) {
    const m = svgEl('marker',{id:`arr-${kind}`,markerWidth:'10',markerHeight:'7',refX:'9',refY:'3.5',orient:'auto'});
    m.appendChild(svgEl('polygon',{points:'0 0,10 3.5,0 7',fill:col}));
    defs.appendChild(m);
  }
  svgRoot.appendChild(defs);

  // background
  svgRoot.appendChild(svgEl('rect',{x:0,y:0,width:SCENE_W,height:SCENE_H,fill:'#0d1117'}));

  // lane bands
  const lg = svgEl('g');
  for (const lane of LANES) {
    lg.appendChild(svgEl('rect',{x:lane.x,y:0,width:lane.w,height:SCENE_H,rx:'7',ry:'7',fill:lane.fill,stroke:lane.stroke,'stroke-width':'1',opacity:'0.55'}));
    lg.appendChild(svgEl('rect',{x:lane.x,y:0,width:lane.w,height:28,rx:'7',ry:'7',fill:lane.stroke,opacity:'0.15'}));
    const lt = svgEl('text',{x:lane.x+lane.w/2,y:18,'text-anchor':'middle','font-size':'12','font-weight':'700',
      'font-family':'-apple-system,sans-serif',fill:lane.stroke});
    lt.textContent = lane.label;
    lg.appendChild(lt);
  }
  svgRoot.appendChild(lg);

  // edges (behind nodes)
  edgeGroup = svgEl('g',{class:'arch-edges'});
  for (const edge of EDGES) {
    const g = svgEl('g',{id:`aedge-${edge.id}`,class:'arch-edge','data-kind':edge.kind});
    const p = svgEl('path',{d:edgePathD(edge),stroke:KIND_COLOR[edge.kind]||'#888',
      'stroke-width':'1.5',fill:'none','stroke-dasharray':edge.dash||KIND_DASH[edge.kind]||'none',
      'marker-end':`url(#arr-${edge.kind})`,opacity:'0.35'});
    g.appendChild(p);
    // edge label at midpoint — dark background pill for legibility
    if (edge.label) {
      const s = nodeMap[edge.from], d = nodeMap[edge.to];
      if (s && d) {
        const sp = nodeBorder(s,d.x,d.y), dp = nodeBorder(d,s.x,s.y);
        const ec = (edge.curve !== undefined) ? edge.curve : 35;
        const {cx,cy} = bezCtrl(sp.x,sp.y,dp.x,dp.y,ec);
        const mid = bezAt(sp.x,sp.y,cx,cy,dp.x,dp.y,0.5);
        const shortL = edge.label.length>34 ? edge.label.slice(0,33)+'…' : edge.label;
        // Pill background: width estimated from char count, height fixed
        const pillW = shortL.length * 5.2 + 10;
        const pillH = 13;
        const pill = svgEl('rect',{
          x: mid.x - pillW/2, y: mid.y - pillH - 2,
          width: pillW, height: pillH,
          rx: '3', ry: '3',
          fill: '#0d1117', opacity: '0', class: 'arch-elabel arch-elabel-pill',
          'data-mx': String(mid.x), 'data-def': shortL,
        });
        const et = svgEl('text',{x:mid.x, y:mid.y-7, 'text-anchor':'middle', 'font-size':'9',
          'font-weight':'600',
          'font-family':'-apple-system,sans-serif', fill:'#e6edf3', opacity:'0', class:'arch-elabel arch-elabel-text',
          'data-def': shortL});
        et.textContent = shortL;
        g.appendChild(pill);
        g.appendChild(et);
      }
    }
    edgeGroup.appendChild(g);
  }
  svgRoot.appendChild(edgeGroup);

  // nodes
  nodeGroup = svgEl('g',{class:'arch-nodes'});
  for (const node of NODES) {
    const fill = TRUST_FILL[node.trust]||'#1a1a1a';
    const stroke = TRUST_STROKE[node.trust]||'#555';
    const text = TRUST_TEXT[node.trust]||'#ccc';
    const hw = node.w/2, hh = node.h/2;
    const g = svgEl('g',{id:`anode-${node.id}`,class:'arch-node','data-trust':node.trust,
      tabindex:'0',role:'button','aria-label':`${node.label.replace(/\n/,' ')} — ${node.holds}`});
    g.appendChild(svgEl('rect',{x:node.x-hw,y:node.y-hh,width:node.w,height:node.h,
      rx:'7',ry:'7',fill,stroke,'stroke-width':'1.5'}));
    const gl = svgEl('text',{x:node.x-hw+15,y:node.y+1,'font-size':'15','dominant-baseline':'middle','text-anchor':'middle'});
    gl.textContent = node.glyph;
    g.appendChild(gl);
    const lines = node.label.split('\n');
    const lh = 14, startY = node.y - (lines.length*lh)/2 + lh/2;
    const lt = svgEl('text',{x:node.x-hw+30,y:startY,'font-size':'11.5',
      'font-family':'-apple-system,sans-serif',fill:text,'dominant-baseline':'middle'});
    lines.forEach((line,i) => {
      const ts = svgEl('tspan',{x:node.x-hw+30,dy:i===0?'0':`${lh}`});
      ts.textContent = line;
      lt.appendChild(ts);
    });
    g.appendChild(lt);
    g.addEventListener('mouseenter', e => showTip(node, e));
    g.addEventListener('focus',      e => showTip(node, e));
    g.addEventListener('mouseleave', hideTip);
    g.addEventListener('blur',       hideTip);
    nodeGroup.appendChild(g);
  }
  svgRoot.appendChild(nodeGroup);

  packetGroup = svgEl('g',{class:'arch-packets','aria-hidden':'true'});
  svgRoot.appendChild(packetGroup);

  container.appendChild(svgRoot);
}

// ─── Tooltip ─────────────────────────────────────────────────────────────────
function buildTip(host) {
  tooltipEl = h('div',{class:'arch-tooltip',role:'tooltip','aria-live':'polite'});
  tooltipEl.style.display = 'none';
  host.appendChild(tooltipEl);
}
function showTip(node, evt) {
  tooltipEl.innerHTML = '';
  tooltipEl.appendChild(h('strong',{},node.label.replace(/\n/,' ')));
  // Strip parenthetical verification refs like "(*verified* 3-5e)" for a cleaner non-expert tooltip
  const cleanHolds = node.holds.replace(/\s*\(\*[^)]+\)/g, '');
  tooltipEl.appendChild(h('div',{class:'arch-tip-holds'},cleanHolds));
  tooltipEl.style.display = 'block';
  const pr = tooltipEl.parentElement.getBoundingClientRect();
  const cx = (evt.clientX||pr.left) - pr.left + 14;
  const cy = (evt.clientY||pr.top)  - pr.top  - 10;
  tooltipEl.style.left = Math.min(cx, pr.width - 290) + 'px';
  tooltipEl.style.top  = Math.max(4, cy) + 'px';
}
function hideTip() { if (tooltipEl) tooltipEl.style.display = 'none'; }

// ─── Architecture highlight ───────────────────────────────────────────────────
// activePacketEdge tracks which edge has a flipped arrowhead so we can restore it
let activePacketEdgeEl = null;
let activePacketEdgeOrigMarker = null;

function applyArchHighlight(nodeIds, edgeIds, packetReverse) {
  document.querySelectorAll('.arch-node').forEach(g => {
    g.classList.toggle('arch-lit', nodeIds.includes(g.id.replace('anode-','')));
    g.classList.toggle('arch-dim', !nodeIds.includes(g.id.replace('anode-','')));
  });
  document.querySelectorAll('.arch-edge').forEach(g => {
    const id = g.id.replace('aedge-','');
    const lit = edgeIds.includes(id);
    g.classList.toggle('arch-edge-lit', lit);
    g.classList.toggle('arch-edge-dim', !lit);
    g.querySelectorAll('.arch-elabel').forEach(el => el.setAttribute('opacity', lit ? '1' : '0'));
  });
}
// Per-step edge label: a shared edge (e.g. TE→Vault) carries different traffic in different flows,
// so a step may set `edgeLabel` to relabel its packet edge; otherwise the neutral default is shown.
function setEdgeLabel(edgeId, text) {
  const g = document.getElementById(`aedge-${edgeId}`);
  if (!g) return;
  const t = g.querySelector('.arch-elabel-text');
  const p = g.querySelector('.arch-elabel-pill');
  if (!t || !p) return;
  const s = (text == null) ? t.getAttribute('data-def') : (text.length > 34 ? text.slice(0, 33) + '…' : text);
  t.textContent = s;
  const w = s.length * 5.2 + 10;
  p.setAttribute('width', String(w));
  p.setAttribute('x', String(parseFloat(p.getAttribute('data-mx')) - w / 2));
}
function resetEdgeLabels() {
  document.querySelectorAll('.arch-edge').forEach(g => setEdgeLabel(g.id.replace('aedge-', ''), null));
}
function clearArchHighlight() {
  resetEdgeLabels();
  document.querySelectorAll('.arch-node').forEach(g => { g.classList.remove('arch-lit','arch-dim'); });
  document.querySelectorAll('.arch-edge').forEach(g => {
    g.classList.remove('arch-edge-lit','arch-edge-dim');
    g.querySelectorAll('.arch-elabel').forEach(el => el.setAttribute('opacity','0'));
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Packet animation (architecture top panel)
// ─────────────────────────────────────────────────────────────────────────────

// pulseNode — expanding ring animation on a node box, used for note (in-process) steps
function pulseNode(nodeId) {
  const node = nodeMap[nodeId];
  if (!node || !packetGroup) return;
  if (REDUCED) return;  // respect reduced-motion

  const RINGS = 2;
  for (let r = 0; r < RINGS; r++) {
    const delay = r * 320;
    const ring = svgEl('circle', {
      cx: String(node.x), cy: String(node.y),
      r: String(node.w / 2 + 4),
      fill: 'none',
      stroke: '#FFD814',
      'stroke-width': '2',
      opacity: '0.9',
      'aria-hidden': 'true',
    });
    packetGroup.appendChild(ring);
    let startTime = null;
    const DUR = 900;  // ms for one ring to fully expand + fade
    const R0  = node.w / 2 + 4;
    const R1  = node.w / 2 + 28;
    let timer;
    function animRing(ts) {
      if (!startTime) startTime = ts + delay;
      const elapsed = ts - startTime;
      if (elapsed < 0) { timer = requestAnimationFrame(animRing); return; }
      const frac = Math.min(elapsed / DUR, 1);
      const r_now = R0 + (R1 - R0) * frac;
      const op    = 0.85 * (1 - frac);
      ring.setAttribute('r', r_now.toFixed(1));
      ring.setAttribute('opacity', op.toFixed(3));
      if (frac < 1) {
        timer = requestAnimationFrame(animRing);
      } else {
        if (ring.parentNode) ring.parentNode.removeChild(ring);
      }
    }
    timer = requestAnimationFrame(animRing);
    packetHandles.push(() => {
      cancelAnimationFrame(timer);
      if (ring.parentNode) ring.parentNode.removeChild(ring);
    });
  }
}

function cancelPackets() {
  for (const h of packetHandles) { try { h(); } catch(_){} }
  packetHandles = [];
  while (packetGroup && packetGroup.firstChild) packetGroup.removeChild(packetGroup.firstChild);
}

function firePacket(edgeId, kind, reverse) {
  const edge = edgeMap[edgeId];
  if (!edge) return;

  // Use the actual drawn <path> so the packet follows the curve exactly.
  const edgeG  = svgRoot && svgRoot.querySelector(`#aedge-${edgeId}`);
  const pathEl = edgeG && edgeG.querySelector('path');
  if (!pathEl) return;

  const totalLen = pathEl.getTotalLength();
  if (totalLen < 1) return;

  const isDenied = kind === 'denied';
  const color    = KIND_COLOR[kind] || '#aaa';

  // All packet shapes point RIGHT (along +x) at rest.
  // The tick() function rotates them to align with the path tangent.
  const g = svgEl('g', {'aria-hidden':'true'});
  if (isDenied) {
    // X mark — no direction needed
    const s2 = 7;
    g.appendChild(svgEl('line',{x1:-s2,y1:-s2,x2:s2,y2:s2,stroke:color,'stroke-width':'2.5','stroke-linecap':'round'}));
    g.appendChild(svgEl('line',{x1:s2,y1:-s2,x2:-s2,y2:s2,stroke:color,'stroke-width':'2.5','stroke-linecap':'round'}));
  } else {
    // Chevron arrow: points right → rotated each frame to match travel direction
    // ▶  shape centred at origin, pointing along +x
    g.appendChild(svgEl('polygon',{points:'-7,-5 5,0 -7,5 -4,0',fill:color}));
  }
  packetGroup.appendChild(g);

  if (REDUCED) {
    const mid = pathEl.getPointAtLength(totalLen * 0.5);
    g.setAttribute('transform', `translate(${mid.x.toFixed(1)},${mid.y.toFixed(1)})`);
    return;
  }

  const endFrac = isDenied ? 0.55 : 1.0;
  const FRAMES  = 40;
  const dur     = 1600;
  let frame = 0, timer;

  function tick() {
    const frac   = (frame / FRAMES) * endFrac;
    // reverse: travel end→start; normal: start→end
    const len    = reverse
      ? totalLen * (1 - frac)
      : totalLen * frac;
    const lenClamped = Math.max(0, Math.min(totalLen, len));

    // Tangent: sample a point slightly AHEAD in the direction of travel.
    // forward: next = lenClamped + DELTA (ahead toward end)
    // reverse: next = lenClamped - DELTA (ahead toward start)
    const DELTA = 2;
    const lenNext = reverse
      ? Math.max(0,        lenClamped - DELTA)
      : Math.min(totalLen, lenClamped + DELTA);
    const ptCur  = pathEl.getPointAtLength(lenClamped);
    const ptNext = pathEl.getPointAtLength(lenNext);
    // angle: from current toward next (always points in travel direction)
    const dx = ptNext.x - ptCur.x;
    const dy = ptNext.y - ptCur.y;
    const angle = Math.atan2(dy, dx) * 180 / Math.PI;

    g.setAttribute('transform',
      `translate(${ptCur.x.toFixed(1)},${ptCur.y.toFixed(1)}) rotate(${angle.toFixed(1)})`);

    if (frame < FRAMES) {
      frame++;
      timer = setTimeout(tick, dur / FRAMES);
    } else {
      g.style.transition = 'opacity 0.35s';
      g.style.opacity    = '0';
      setTimeout(() => { if (g.parentNode) g.parentNode.removeChild(g); }, 400);
    }
  }
  timer = setTimeout(tick, 0);
  packetHandles.push(() => { clearTimeout(timer); if (g.parentNode) g.parentNode.removeChild(g); });
}

// ─────────────────────────────────────────────────────────────────────────────
// Sequence diagram (bottom panel)
// Uses the same 1600px-wide viewBox as the arch SVG so fonts render at the
// same apparent scale when both SVGs fill the full pane width.
// ─────────────────────────────────────────────────────────────────────────────
let seqSvg = null;
const SEQ_VB_W   = 1600; // fixed viewBox width — matches SCENE_W so font scale is identical
const SEQ_PAD    = 60;   // left/right padding inside the viewBox
const SEQ_HEAD_H = 72;   // participant header height (viewBox units)
const SEQ_ROW_H  = 70;   // height per message row (viewBox units)

function buildSequence(container) {
  container.innerHTML = '';
  seqSvg = null;

  const flow = FLOWS[activeFlowIdx];
  const parts = flow.participants;
  const nCols = parts.length;
  const nRows = flow.subSteps.length;

  // Distribute participants evenly across the fixed viewBox width
  const usableW = SEQ_VB_W - SEQ_PAD * 2;
  const colW    = usableW / nCols;
  const colX    = parts.map((_,i) => SEQ_PAD + i * colW + colW / 2);
  const headerH = colW * 0.40 | 0;  // box height proportional to column width, min 48
  const HEAD_H  = Math.max(48, Math.min(headerH, SEQ_HEAD_H));

  const svgH = HEAD_H + nRows * SEQ_ROW_H + 30;

  seqSvg = svgEl('svg', {
    viewBox:`0 0 ${SEQ_VB_W} ${svgH}`,
    class:'seq-svg',
    width:'100%',
    height:'auto',
    'aria-label':`Sequence diagram for ${flow.title}`,
    role:'img',
  });

  seqSvg.appendChild(svgEl('rect',{x:0,y:0,width:SEQ_VB_W,height:svgH,fill:'#0d1117'}));

  // Pre-build all marker defs so they exist before any row references them
  const allDefs = svgEl('defs');
  flow.subSteps.forEach((ss, si) => {
    const fromIdx = parts.indexOf(ss.from);
    const toIdx   = parts.indexOf(ss.to);
    if (ss.arrow === 'note' || fromIdx === toIdx || fromIdx < 0 || toIdx < 0) return;
    const isDashed = ss.arrow === 'dashed';
    const isDenied = !!ss.denied;
    const color = isDenied ? '#F85149' : (isDashed ? '#2dd4bf' : '#e6edf3');
    const mk = svgEl('marker',{id:`arrarr-${si}`,markerWidth:'9',markerHeight:'7',refX:'8',refY:'3.5',orient:'auto'});
    mk.appendChild(svgEl('polygon',{points:'0 0,9 3.5,0 7',fill:color}));
    allDefs.appendChild(mk);
  });
  seqSvg.appendChild(allDefs);

  // header boxes + lifelines
  parts.forEach((pKey, i) => {
    const pDef = PARTICIPANTS[pKey] || { label: pKey, color: '#888' };
    const cx = colX[i];
    const hw = colW * 0.44 | 0;
    const g = svgEl('g',{class:'seq-part',id:`seqpart-${pKey}`});
    g.appendChild(svgEl('rect',{x:cx-hw,y:6,width:hw*2,height:HEAD_H-10,rx:'7',ry:'7',
      fill:'#161b22',stroke:pDef.color,'stroke-width':'2'}));
    const lines = pDef.label.split('\n');
    const lh = 15, sy = HEAD_H/2 - ((lines.length-1)*lh)/2;
    lines.forEach((ln,j) => {
      const t = svgEl('text',{x:String(cx),y:String(sy + j*lh),
        'text-anchor':'middle','dominant-baseline':'middle',
        'font-size':'12','font-weight':'700','font-family':'-apple-system,sans-serif',fill:pDef.color});
      t.textContent = ln;
      g.appendChild(t);
    });
    seqSvg.appendChild(g);
    seqSvg.appendChild(svgEl('line',{
      x1:String(cx),y1:String(HEAD_H),x2:String(cx),y2:String(svgH-10),
      stroke:pDef.color,'stroke-width':'1.5','stroke-dasharray':'5,5',opacity:'0.25',
    }));
  });

  // Message rows
  flow.subSteps.forEach((ss, si) => {
    const rowY = HEAD_H + si * SEQ_ROW_H + SEQ_ROW_H / 2;
    const fromIdx = parts.indexOf(ss.from);
    const toIdx   = parts.indexOf(ss.to);
    const g = svgEl('g',{id:`seqrow-${si}`,class:'seq-row',opacity:'0'});

    if (ss.arrow === 'note' || fromIdx === toIdx) {
      const cx = fromIdx >= 0 ? colX[fromIdx] : SEQ_VB_W/2;
      const noteW = Math.min(colW * 0.95, SEQ_VB_W - cx - 20);
      const boxX = cx + 6;
      const boxY = rowY - SEQ_ROW_H / 2 + 5;
      const boxH = SEQ_ROW_H - 10;
      g.appendChild(svgEl('rect',{x:String(boxX),y:String(boxY),
        width:String(noteW),height:String(boxH),rx:'5',ry:'5',
        fill:'#1c1c0e',stroke:'#FFD814','stroke-width':'1.5',opacity:'0.9'}));

      // Checkbox: small rounded square + ✓ tick on the left of the note box
      const cbSize = 14, cbX = boxX + 8, cbY = boxY + (boxH - cbSize) / 2;
      g.appendChild(svgEl('rect',{x:String(cbX),y:String(cbY),
        width:String(cbSize),height:String(cbSize),rx:'3',ry:'3',
        fill:'#FFD814',opacity:'0.9'}));
      const tick = svgEl('text',{x:String(cbX + cbSize/2),y:String(cbY + cbSize/2 + 1),
        'text-anchor':'middle','dominant-baseline':'middle',
        'font-size':'10','font-weight':'700',
        'font-family':'-apple-system,sans-serif',fill:'#0d1117'});
      tick.textContent = '✓';
      g.appendChild(tick);

      const lns = wrapText(ss.label, Math.max(38, Math.min(56, Math.floor((noteW - 40) / 6.2))));
      lns.slice(0,2).forEach((ln,j) => {
        const t = svgEl('text',{x:String(cx+30),y:String(rowY-(lns.length>1?8:0)+j*17),
          'font-size':'11','font-family':'-apple-system,sans-serif',fill:'#ffe566'});
        t.textContent = ln;
        g.appendChild(t);
      });
    } else if (fromIdx >= 0 && toIdx >= 0) {
      const x1 = colX[fromIdx], x2 = colX[toIdx];
      const isDashed = ss.arrow === 'dashed';
      const isDenied = !!ss.denied;
      const color = isDenied ? '#F85149' : (isDashed ? '#2dd4bf' : '#e6edf3');
      const dash  = isDashed ? '6,4' : 'none';
      const arrowId = `arrarr-${si}`;
      g.appendChild(svgEl('line',{
        x1:String(x1),y1:String(rowY),x2:String(x2),y2:String(rowY),
        stroke:color,'stroke-width':'2','stroke-dasharray':dash,
        'marker-end':`url(#${arrowId})`,
      }));
      const midX = (x1+x2)/2;
      const lns = wrapText(ss.label, Math.max(40, Math.min(64, Math.floor(Math.abs(x2 - x1) / 6.2))));
      lns.slice(0,2).forEach((ln,j) => {
        const t = svgEl('text',{x:String(midX),y:String(rowY - SEQ_ROW_H/2 + 8 + j*15),
          'text-anchor':'middle','font-size':'11','font-family':'-apple-system,sans-serif',fill:color});
        t.textContent = ln;
        g.appendChild(t);
      });
    }

    seqSvg.appendChild(g);
  });

  container.appendChild(seqSvg);
}

function wrapText(str, maxChars) {
  if (str.length <= maxChars) return [str];
  const words = str.split(' ');
  const lines = [];
  let cur = '';
  for (const w of words) {
    if ((cur + ' ' + w).trim().length > maxChars) {
      if (cur) lines.push(cur);
      cur = w;
    } else {
      cur = (cur + ' ' + w).trim();
    }
  }
  if (cur) lines.push(cur);
  return lines;
}

function revealSubStepRows(upToIdx) {
  // Show rows 0..upToIdx, hide the rest
  if (!seqSvg) return;
  FLOWS[activeFlowIdx].subSteps.forEach((_, si) => {
    const row = seqSvg.querySelector(`#seqrow-${si}`);
    if (!row) return;
    if (si <= upToIdx) {
      row.setAttribute('opacity','1');
      row.classList.add('seq-row-visible');
    } else {
      row.setAttribute('opacity','0');
      row.classList.remove('seq-row-visible');
    }
    // highlight the current row
    row.classList.toggle('seq-row-active', si === upToIdx);
  });

  // No scroll container — the sequence SVG overflows the page naturally.
  // The browser's own scroll handles visibility.
}

// ─────────────────────────────────────────────────────────────────────────────
// Narration panel
// ─────────────────────────────────────────────────────────────────────────────
let narTitle, narBody;

function buildNarration(host) {
  const panel = h('div',{class:'arch-narration','aria-live':'polite'},
    h('div',{class:'arch-narration-header'},
      narTitle   = h('span',{class:'arch-narration-title'},''),
    ),
    narBody      = h('p',  {class:'arch-narration-body'},''),
  );
  host.appendChild(panel);
}

function updateNarration(flow, ss) {
  const fi = FLOWS.indexOf(flow);
  if (ss) {
    const si = flow.subSteps.indexOf(ss);
    narTitle.textContent = `${flow.shortTitle.replace(/^\d+\.\s*/,'')} — step ${si+1} of ${flow.subSteps.length}`;
  } else {
    narTitle.textContent = flow.title;
  }
  if (ss) {
    narBody.textContent = ss.narration;
  } else if (flow.description) {
    narBody.innerHTML = '';
    const intro = document.createElement('span');
    intro.textContent = 'Use Next or Play to step through this flow.';
    intro.style.cssText = 'display:block;margin-bottom:6px;opacity:0.6;font-style:italic';
    const desc = document.createElement('span');
    desc.textContent = flow.description;
    narBody.appendChild(intro);
    narBody.appendChild(desc);
  } else {
    narBody.textContent = 'Use Next or Play to step through this flow.';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Flow tabs
// ─────────────────────────────────────────────────────────────────────────────
let flowTabBar;

function buildFlowTabs(host, seqContainer) {
  flowTabBar = h('div',{class:'seq-flow-tabs',role:'tablist','aria-label':'Credential flows'});
  FLOWS.forEach((flow, fi) => {
    const btn = h('button',{class:'seq-flow-tab',role:'tab',
      id:`ftab-${fi}`,'aria-controls':'seq-diagram-area',
      'aria-selected': fi === 0 ? 'true' : 'false',
    }, flow.shortTitle);
    if (fi === activeFlowIdx) btn.classList.add('seq-flow-tab-active');
    btn.addEventListener('click', () => {
      stopPlay();
      selectFlow(fi, seqContainer);
    });
    flowTabBar.appendChild(btn);
  });
  host.appendChild(flowTabBar);
}

function selectFlow(fi, seqContainer) {
  activeFlowIdx = fi;
  activeSubStep = -1;

  // Update tab buttons
  flowTabBar.querySelectorAll('.seq-flow-tab').forEach((btn, i) => {
    btn.classList.toggle('seq-flow-tab-active', i === fi);
    btn.setAttribute('aria-selected', i === fi ? 'true' : 'false');
  });

  // Rebuild sequence SVG for this flow
  buildSequence(seqContainer);

  // Reset architecture to overview state (highlights applied per-step during playback)
  clearArchHighlight();
  cancelPackets();

  // Show narration for flow overview
  const flow = FLOWS[fi];
  updateNarration(flow, null);
  updateControls();
}

// ─────────────────────────────────────────────────────────────────────────────
// Controls
// ─────────────────────────────────────────────────────────────────────────────
let btnPlay, btnBack, btnNext, scrubber, speedSel, stepLabel;

function buildControls(host) {
  const bar = h('div',{class:'arch-controls',role:'toolbar','aria-label':'Playback controls'},
    btnBack  = h('button',{class:'arch-ctrl-btn','aria-label':'Previous step (←)'},'◀ Back'),
    btnPlay  = h('button',{class:'arch-ctrl-btn arch-ctrl-play','aria-label':'Play (Space)'},'▶ Play'),
    btnNext  = h('button',{class:'arch-ctrl-btn','aria-label':'Next step (→)'},'Next ▶'),
    h('div',{class:'arch-scrubber-wrap'},
      scrubber  = h('input',{type:'range',class:'arch-scrubber',min:'0',max:'0',value:'0','aria-label':'Sub-step'}),
      stepLabel = h('span',{class:'arch-step-label'},'0 / 0'),
    ),
    h('label',{class:'arch-speed-label'},'Speed ',
      speedSel = h('select',{class:'arch-speed-sel','aria-label':'Speed'},
        h('option',{value:'0.5'},'0.5×'),
        h('option',{value:'1',selected:''},'1×'),
        h('option',{value:'2'},'2×'),
      ),
    ),
  );
  host.appendChild(bar);

  btnPlay.addEventListener('click', togglePlay);
  btnBack.addEventListener('click', () => { stopPlay(); goSubStep(activeSubStep - 1); });
  btnNext.addEventListener('click', () => { stopPlay(); goSubStep(activeSubStep + 1); });
  scrubber.addEventListener('input', () => { stopPlay(); goSubStep(parseInt(scrubber.value,10)); });
  speedSel.addEventListener('change', () => { playSpeed = parseFloat(speedSel.value); });
}

function updateControls() {
  const flow = FLOWS[activeFlowIdx];
  const n    = flow.subSteps.length;
  if (scrubber) { scrubber.max = String(n-1); scrubber.value = String(Math.max(0,activeSubStep)); }
  if (stepLabel) stepLabel.textContent = activeSubStep < 0 ? `0 / ${n}` : `${activeSubStep+1} / ${n}`;
  if (btnBack) btnBack.disabled = activeSubStep <= 0;
  if (btnNext) btnNext.disabled = activeSubStep >= n - 1;
}

function togglePlay() {
  if (isPlaying) stopPlay(); else startPlay();
}
function startPlay() {
  const flow = FLOWS[activeFlowIdx];
  if (activeSubStep >= flow.subSteps.length - 1) activeSubStep = -1;
  isPlaying = true;
  btnPlay.textContent = '⏸ Pause';
  btnPlay.setAttribute('aria-label','Pause (Space)');
  schedNext();
}
function stopPlay() {
  isPlaying = false;
  if (playTimer) { clearTimeout(playTimer); playTimer = null; }
  if (btnPlay) { btnPlay.textContent = '▶ Play'; btnPlay.setAttribute('aria-label','Play (Space)'); }
}
function schedNext() {
  if (!isPlaying) return;
  playTimer = setTimeout(() => {
    if (!isPlaying) return;
    const flow = FLOWS[activeFlowIdx];
    if (activeSubStep < flow.subSteps.length - 1) {
      goSubStep(activeSubStep + 1);
      schedNext();
    } else {
      stopPlay();
    }
  }, STEP_MS / playSpeed);
}

function goSubStep(idx) {
  const flow = FLOWS[activeFlowIdx];
  if (idx < 0) idx = 0;
  if (idx >= flow.subSteps.length) idx = flow.subSteps.length - 1;
  activeSubStep = idx;

  const ss = flow.subSteps[idx];

  // Arch highlight
  cancelPackets();
  applyArchHighlight(ss.archNodes || [], ss.archEdges || [], !!ss.packetReverse);
  resetEdgeLabels();
  if (ss.edgeLabel) setEdgeLabel(ss.packetEdge || (ss.archEdges && ss.archEdges[0]), ss.edgeLabel);

  // Fire ONE packet — use packetEdge if specified, else first archEdge.
  // For note (in-process) steps, pulse the node instead.
  // For denied steps, override the edge kind to 'denied' so the X marker fires.
  const packetEid = ss.packetEdge || (ss.archEdges && ss.archEdges[0]);
  if (ss.arrow === 'note' && !ss.packetEdge) {
    pulseNode(ss.from);
  } else if (!REDUCED && packetEid) {
    const edge = edgeMap[packetEid];
    if (edge) firePacket(packetEid, ss.denied ? 'denied' : edge.kind, !!ss.packetReverse);
  }

  // Reveal sequence rows up to this index
  revealSubStepRows(idx);

  // Narration
  updateNarration(flow, ss);
  updateControls();
}

// ─────────────────────────────────────────────────────────────────────────────
// Keyboard
// ─────────────────────────────────────────────────────────────────────────────
function setupKeyboard() {
  document.addEventListener('keydown', e => {
    const pane = document.getElementById('tab-architecture');
    if (!pane || !pane.classList.contains('tab-active')) return;
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT') return;
    if (e.code === 'ArrowRight') { stopPlay(); goSubStep(activeSubStep + 1); e.preventDefault(); }
    else if (e.code === 'ArrowLeft') { stopPlay(); goSubStep(activeSubStep - 1); e.preventDefault(); }
    else if (e.code === 'Space') { togglePlay(); e.preventDefault(); }
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Main init
// ─────────────────────────────────────────────────────────────────────────────
function init() {
  const pane = document.getElementById('tab-architecture');
  if (!pane) return;
  pane.innerHTML = '';

  const wrapper = h('div',{class:'arch-wrapper'});
  pane.appendChild(wrapper);

  // ── 1. Flow tab bar (above SVG — always visible, never scrolls away) ─────
  const seqContainer = h('div',{class:'seq-diagram-area',id:'seq-diagram-area','aria-live':'polite'});
  const tabBarArea = h('div',{class:'arch-flow-tabs-area'});
  buildFlowTabs(tabBarArea, seqContainer);
  wrapper.appendChild(tabBarArea);

  // ── 2. SVG architecture overview ─────────────────────────────────────────
  const svgContainer = h('div',{class:'arch-svg-container'});
  wrapper.appendChild(svgContainer);
  buildSVG(svgContainer);
  buildTip(svgContainer);

  // ── 3. Controls (fixed strip directly below arch SVG — never moves) ──────
  const ctrlStrip = h('div',{class:'arch-controls-strip'});
  wrapper.appendChild(ctrlStrip);
  buildControls(ctrlStrip);

  // ── 4. Narration (below controls — grows downward, does not move buttons) ─
  const narrationArea = h('div',{class:'arch-narration-area'});
  wrapper.appendChild(narrationArea);
  buildNarration(narrationArea);

  // ── 5. Sequence diagram (no scroll box — free overflow) ──────────────────
  const seqPanel = h('div',{class:'seq-panel'});
  wrapper.appendChild(seqPanel);
  seqPanel.appendChild(seqContainer);

  // Keyboard
  setupKeyboard();

  // Build first flow's sequence diagram
  buildSequence(seqContainer);

  // Start on the flow overview — user presses Next or Play to begin
  updateNarration(FLOWS[0], null);
  updateControls();
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', init);
} else {
  init();
}

})();
