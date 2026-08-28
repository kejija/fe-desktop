import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { repositoryRoot } from './config.mjs';

const fixturesRoot = resolve(repositoryRoot, 'contracts/fixtures');

async function fixture(name) {
  return JSON.parse(await readFile(resolve(fixturesRoot, name), 'utf8'));
}

function makeEmptyGlb() {
  const jsonText = JSON.stringify({ asset: { version: '2.0', generator: 'Future Engine Desktop mock' }, scene: 0, scenes: [{ nodes: [] }], nodes: [] });
  const padding = (4 - (Buffer.byteLength(jsonText) % 4)) % 4;
  const json = Buffer.from(jsonText + ' '.repeat(padding));
  const output = Buffer.alloc(20 + json.length);
  output.writeUInt32LE(0x46546c67, 0);
  output.writeUInt32LE(2, 4);
  output.writeUInt32LE(output.length, 8);
  output.writeUInt32LE(json.length, 12);
  output.writeUInt32LE(0x4e4f534a, 16);
  json.copy(output, 20);
  return output;
}

const emptyGlb = makeEmptyGlb();
const emptyGlbDigest = `sha256:${createHash('sha256').update(emptyGlb).digest('hex')}`;

function json(reply, status, body, headers = {}) {
  const bytes = Buffer.from(JSON.stringify(body));
  reply.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': bytes.length, ...headers });
  reply.end(bytes);
}

async function body(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function revisionFrom(value) {
  const normalized = String(value ?? '').replaceAll('"', '').trim();
  if (!normalized) return null;
  const parsed = Number(normalized);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

function currentRevision(state) {
  return state.document.draft.revision_number;
}

function updateRevision(state, revision) {
  state.document.draft.revision_number = revision;
  state.document.summary.draft_revision_number = revision;
  state.document.summary.updated_at = '2026-08-27T12:00:00.000Z';
  state.presentation.draft_revision_number = revision;
}

function presentationInterface(state, endpoint) {
  const instance = state.presentation.instances.find((value) => value.instance_id === endpoint?.instance_id);
  return instance?.interfaces.find((value) => value.interface_id === endpoint?.interface_id) ?? null;
}

function previewHash(revision, endpointA, endpointB) {
  const canonical = JSON.stringify({ revision, endpoint_a: endpointA, endpoint_b: endpointB });
  return `sha256:${createHash('sha256').update(canonical).digest('hex')}`;
}

export async function createMockState() {
  const document = await fixture('design-document.json');
  const presentation = await fixture('presentation.success.json');
  for (const instance of presentation.instances) {
    if (instance.model) {
      instance.model.sha256 = emptyGlbDigest;
      instance.model.size_bytes = emptyGlb.length;
    }
  }
  return {
    document,
    presentation,
    designs: await fixture('design-list.json'),
    conflict: await fixture('revision-conflict.json'),
    validationError: await fixture('validation-error.json'),
    missingAsset: await fixture('missing-asset.json'),
    sessions: new Map(),
    nextSession: 1,
    nextDesign: 1,
    nextCheckpoint: 1,
    nextHydrated: 1,
    nextConnection: 1,
    previews: new Map(),
    emptyGlb,
    emptyGlbDigest
  };
}

function syncPresentation(state) {
  const components = state.document.draft.design.component_instances ?? [];
  const existing = new Map(state.presentation.instances.map((instance) => [instance.instance_id, instance]));
  state.presentation.instances = components.map((component) => {
    const prior = existing.get(component.instance_id);
    if (prior) {
      prior.name = component.name;
      prior.world_transform = structuredClone(component.transform ?? prior.world_transform);
      return prior;
    }
    return {
      instance_id: component.instance_id,
      name: component.name,
      parent_instance_id: null,
      world_transform: structuredClone(component.transform ?? { translation_m: [0, 0, 0], rotation_wxyz: [1, 0, 0, 0] }),
      release: {
        release_id: component.release.release_id,
        item_key: component.release.item_key,
        kind: component.release.kind ?? 'component',
        version: component.release.version,
        package_digest: component.release.package_digest,
        category: 'Catalog component',
        description: 'Deterministically hydrated mock component.',
        readiness_status: 'ready'
      },
      model: {
        asset_path: '/v1/blobs/mock-empty.glb', sha256: state.emptyGlbDigest, size_bytes: state.emptyGlb.length,
        scale_to_m: 1, model_scale: [1, 1, 1], inner_rotation_wxyz: [1, 0, 0, 0], materials: []
      },
      editability: { editable: true, reason: 'anchor' },
      interfaces: [{
        interface_id: 'mount', name: 'Mount', description: 'General mechanical mount', type: 'mount', domain: 'mechanical', direction: 'bidirectional',
        compatibility_key: 'shaft-12mm', capacity: { used: 0, maximum: 1 }, readiness: { status: 'reviewed', diagnostics: [] },
        connectable: true, state: 'available', state_message: 'Available for connection'
      }],
      resolved_configuration: { preset: component.configuration?.preset ?? 'default', parameters: [] }
    };
  });
  const relationshipIds = new Set([
    ...(state.document.draft.design.connections ?? []).map((value) => value.connection_id),
    ...(state.document.draft.design.joints ?? []).map((value) => value.joint_id)
  ]);
  state.presentation.relationships = state.presentation.relationships.filter((value) => relationshipIds.has(value.relationship_id));
  state.presentation.design_hash = `sha256:${createHash('sha256').update(JSON.stringify(state.document.draft.design)).digest('hex')}`;
}

export async function handleMock(request, reply, state) {
  const url = new URL(request.url, 'http://mock.local');
  const path = url.pathname;

  if (path === '/node-design/healthz' || path === '/node-design/readyz' || path === '/components/healthz' || path === '/simulation/healthz') {
    json(reply, 200, { status: path.endsWith('readyz') ? 'ready' : 'ok', version: 'mock-1' });
    return true;
  }
  if (request.method === 'GET' && path === '/node-design/v1/designs') {
    json(reply, 200, state.designs);
    return true;
  }
  if (request.method === 'POST' && path === '/node-design/v1/designs') {
    const input = await body(request);
    const created = structuredClone(state.document);
    const designId = `mock-design-${state.nextDesign++}`;
    created.summary.design_id = designId;
    created.summary.name = String(input.name || 'Untitled design');
    created.summary.draft_revision_number = 1;
    created.draft.revision_number = 1;
    created.draft.design.design_id = designId;
    created.draft.design.name = created.summary.name;
    created.checkpoints = [];
    json(reply, 201, created, { etag: '"1"' });
    return true;
  }
  if (request.method === 'GET' && path === '/node-design/v1/design-templates') {
    json(reply, 200, { object: 'list', data: [{ template_id: 'mock-drive', name: 'Mock drive', description: 'Deterministic two-component drive' }] });
    return true;
  }
  if (request.method === 'GET' && path === '/node-design/v1/designs/demo-drive') {
    json(reply, 200, state.document, { etag: `"${currentRevision(state)}"` });
    return true;
  }
  if (request.method === 'GET' && path === '/node-design/v1/designs/demo-drive/presentation') {
    const expected = revisionFrom(request.headers['if-match']);
    if (expected === null) {
      json(reply, 428, { error: { code: 'draft_precondition_required', message: 'If-Match is required.', request_id: 'mock-precondition', retryable: false } });
    } else if (expected !== currentRevision(state)) {
      const conflict = structuredClone(state.conflict);
      conflict.error.details.current_revision = currentRevision(state);
      json(reply, 409, conflict);
    } else {
      state.presentation.draft_revision_number = currentRevision(state);
      state.presentation.profile_id = url.searchParams.get('profile_id') || 'default';
      json(reply, 200, state.presentation, { etag: `"${currentRevision(state)}"` });
    }
    return true;
  }
  if (request.method === 'PUT' && path === '/node-design/v1/designs/demo-drive/draft') {
    const expected = revisionFrom(request.headers['if-match']);
    if (expected !== currentRevision(state)) {
      const conflict = structuredClone(state.conflict);
      conflict.error.details.current_revision = currentRevision(state);
      json(reply, 409, conflict);
      return true;
    }
    const input = await body(request);
    const design = input.design ?? input;
    updateRevision(state, currentRevision(state) + 1);
    state.document.draft.design = design;
    syncPresentation(state);
    json(reply, 200, { draft: structuredClone(state.document.draft) }, { etag: `"${currentRevision(state)}"` });
    return true;
  }
  if (request.method === 'POST' && path === '/node-design/v1/designs/demo-drive/checkpoints') {
    const input = await body(request);
    const checkpoint = { checkpoint_id: `checkpoint-${state.nextCheckpoint++}`, revision_number: currentRevision(state), label: String(input.label || 'Manual checkpoint'), created_at: '2026-08-27T12:00:00.000Z' };
    state.document.checkpoints.push(checkpoint);
    json(reply, 201, { checkpoint });
    return true;
  }
  if (request.method === 'POST' && path === '/node-design/v1/designs/demo-drive/compile') {
    json(reply, 201, { package_digest: 'sha256:4444444444444444444444444444444444444444444444444444444444444444', profile_id: 'default', revision_number: currentRevision(state), diagnostics: [] });
    return true;
  }
  if (request.method === 'POST' && path.endsWith('/connections/preview')) {
    const expected = revisionFrom(request.headers['if-match']);
    if (expected !== currentRevision(state)) {
      const conflict = structuredClone(state.conflict);
      conflict.error.details.current_revision = currentRevision(state);
      json(reply, 409, conflict);
      return true;
    }
    const input = await body(request);
    const endpointA = input.endpoint_a;
    const endpointB = input.endpoint_b;
    const portA = presentationInterface(state, endpointA);
    const portB = presentationInterface(state, endpointB);
    const blockers = [];
    if (!portA || !portB) blockers.push({ code: 'interface_not_found', message: 'Both endpoints must name an exact released interface.' });
    if (endpointA?.instance_id === endpointB?.instance_id) blockers.push({ code: 'same_instance', message: 'A connection requires two different instances.' });
    if (portA && portB && portA.domain !== portB.domain) blockers.push({ code: 'domain_mismatch', message: `Domain mismatch: ${portA.domain} cannot connect to ${portB.domain}.` });
    if (portA && !portA.connectable) blockers.push({ code: 'source_unavailable', message: `${portA.name}: ${portA.state_message}` });
    if (portB && !portB.connectable) blockers.push({ code: 'target_unavailable', message: `${portB.name}: ${portB.state_message}` });
    const directions = new Set([portA?.direction, portB?.direction]);
    if (portA && portB && !directions.has('bidirectional') && directions.size === 1) blockers.push({ code: 'direction_mismatch', message: 'Interface directions are incompatible.' });
    const domain = portA?.domain ?? portB?.domain ?? 'mechanical';
    const inferredKind = domain === 'mechanical' ? (portA?.type === 'mount' || portB?.type === 'mount' ? 'mount' : 'mechanical') : 'port';
    const inputHash = previewHash(currentRevision(state), endpointA, endpointB);
    const preview = {
      input_hash: inputHash,
      inferred_kind: inferredKind,
      compatibility: blockers.length === 0 ? (inferredKind === 'mount' ? 'review' : 'exact') : 'incompatible',
      endpoint_a: endpointA,
      endpoint_b: endpointB,
      moved_subtree: blockers.length === 0 ? [endpointB.instance_id] : [],
      proposed_transforms: blockers.length === 0 ? [{ instance_id: endpointB.instance_id, transform: { translation_m: [0.12, 0.04, 0.16], rotation_wxyz: [1, 0, 0, 0] } }] : [],
      feature_matches: blockers.length === 0 ? [{ source_feature: portA.interface_id, target_feature: portB.interface_id, status: 'matched' }] : [],
      hardware: inferredKind === 'mount' && blockers.length === 0 ? [{ role: 'fastener', item_key: 'component/fastener-m4', quantity: 4 }] : [],
      warnings: blockers.length === 0 && inferredKind === 'mount' ? [{ code: 'default_mount_policy', message: 'Mock resolver selected the default concentric mount policy.' }] : [],
      blockers,
      policy_overrides: input.policy_overrides ?? {},
      joint_type: inferredKind === 'mount' || inferredKind === 'mechanical' ? (input.joint_type === 'automatic' || !input.joint_type ? 'fixed' : input.joint_type) : null
    };
    state.previews.set(inputHash, structuredClone(preview));
    json(reply, 200, preview);
    return true;
  }
  if (request.method === 'POST' && path === '/node-design/v1/catalog/hydrate') {
    const input = await body(request);
    const slug = String(input.slug || 'mock-component');
    const instanceId = `${slug}-${state.nextHydrated++}`;
    json(reply, 200, {
      assemblies: [], connections: [], joints: [], extensions: {},
      component_instances: [{
        instance_id: instanceId,
        name: slug.split('-').map((part) => part.slice(0, 1).toUpperCase() + part.slice(1)).join(' '),
        parent_assembly_id: input.parent_assembly_id || 'root',
        component_ref: { id: `component-${slug}` },
        release: {
          release_id: `release-${slug}-${input.version || '1.0.0'}`,
          item_key: `${input.kind || 'component'}/${slug}`,
          kind: input.kind || 'component',
          version: input.version || '1.0.0',
          package_digest: 'sha256:6666666666666666666666666666666666666666666666666666666666666666'
        },
        transform: { translation_m: [0.15, 0, 0], rotation_wxyz: [1, 0, 0, 0] },
        configuration: { preset: 'default', parameter_overrides: [], parameter_formulas: [] }
      }]
    });
    return true;
  }
  if (request.method === 'POST' && path.endsWith('/connections/apply')) {
    const expected = revisionFrom(request.headers['if-match']);
    const input = await body(request);
    if (expected !== currentRevision(state)) {
      const conflict = structuredClone(state.conflict);
      conflict.error.details.current_revision = currentRevision(state);
      json(reply, 409, conflict);
      return true;
    }
    const preview = state.previews.get(input.input_hash);
    if (!preview || preview.blockers.length > 0 || preview.endpoint_a.instance_id !== input.endpoint_a?.instance_id || preview.endpoint_a.interface_id !== input.endpoint_a?.interface_id || preview.endpoint_b.instance_id !== input.endpoint_b?.instance_id || preview.endpoint_b.interface_id !== input.endpoint_b?.interface_id) {
      json(reply, 422, { error: { code: 'connection_preview_stale', message: 'Connection preview hash is invalid.', request_id: 'mock-connection', retryable: false } });
      return true;
    }
    const connectionId = `connection-${state.nextConnection++}`;
    const appliedDomain = presentationInterface(state, preview.endpoint_a)?.domain ?? 'mechanical';
    state.document.draft.design.connections.push({ connection_id: connectionId, kind: preview.inferred_kind, endpoint_a: preview.endpoint_a, endpoint_b: preview.endpoint_b, ...(input.policy_overrides ? { policy_overrides: input.policy_overrides } : {}) });
    state.presentation.relationships.push({ relationship_id: connectionId, kind: 'connection', source: preview.endpoint_a, target: preview.endpoint_b, connection_type: appliedDomain, label: `${appliedDomain} connection`, description: 'Applied from deterministic mock preview', status: preview.compatibility === 'review' ? 'warning' : 'compatible', resolver_status: preview.inferred_kind === 'mount' || preview.inferred_kind === 'mechanical' ? 'resolved' : 'not_applicable' });
    updateRevision(state, currentRevision(state) + 1);
    syncPresentation(state);
    state.previews.delete(input.input_hash);
    json(reply, 200, { draft: structuredClone(state.document.draft), connection_id: connectionId }, { etag: `"${currentRevision(state)}"` });
    return true;
  }
  if (request.method === 'GET' && path === '/components/v1/blobs/mock-empty.glb') {
    reply.writeHead(200, { 'content-type': 'model/gltf-binary', 'content-length': state.emptyGlb.length, etag: state.emptyGlbDigest });
    reply.end(state.emptyGlb);
    return true;
  }
  if (request.method === 'GET' && path === '/components/v1/items') {
    json(reply, 200, { object: 'list', data: state.presentation.instances.map((instance) => ({ id: instance.release.release_id, item_key: instance.release.item_key, kind: 'component', slug: instance.release.item_key.split('/').at(-1), version: instance.release.version, name: instance.name, package_digest: instance.release.package_digest })) });
    return true;
  }
  if (request.method === 'POST' && path === '/simulation/v1/sessions') {
    const sessionId = `mock-session-${state.nextSession++}`;
    const session = { session_id: sessionId, status: 'paused', sequence: 0, realtime_factor: 1, lag_s: 0 };
    state.sessions.set(sessionId, session);
    json(reply, 201, session);
    return true;
  }
  const sessionMatch = path.match(/^\/simulation\/v1\/sessions\/([^/]+)(?:\/(state|control))?$/);
  if (sessionMatch) {
    const session = state.sessions.get(sessionMatch[1]);
    if (!session) {
      json(reply, 404, { error: { code: 'session_not_found', message: 'Session not found.', request_id: 'mock-session', retryable: false } });
      return true;
    }
    if (request.method === 'DELETE') {
      state.sessions.delete(session.session_id);
      reply.writeHead(204); reply.end(); return true;
    }
    if (request.method === 'POST' && sessionMatch[2] === 'control') {
      const input = await body(request);
      session.status = input.command === 'run' ? 'running' : 'paused';
    }
    session.sequence += 1;
    json(reply, 200, { ...session, poses: [{ instance_id: 'shaft', translation_m: [0, 0, 0.08], rotation_wxyz: [1, 0, 0, 0] }], actuators: [], sensors: [] });
    return true;
  }
  return false;
}

export function acceptMockWebSocket(request, socket, state) {
  const match = new URL(request.url, 'http://mock.local').pathname.match(/^\/simulation\/v1\/sessions\/([^/]+)\/stream$/);
  if (!match || !state.sessions.has(match[1])) return false;
  const key = request.headers['sec-websocket-key'];
  if (!key) return false;
  const accept = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
  socket.write([
    'HTTP/1.1 101 Switching Protocols',
    'Upgrade: websocket',
    'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${accept}`,
    '', ''
  ].join('\r\n'));
  const session = state.sessions.get(match[1]);
  const send = () => {
    if (socket.destroyed) return;
    session.sequence += 1;
    const payload = Buffer.from(JSON.stringify({ type: 'state', ...session, poses: [{ instance_id: 'shaft', translation_m: [0, 0, 0.08], rotation_wxyz: [1, 0, 0, 0] }], actuators: [], sensors: [] }));
    const header = payload.length < 126 ? Buffer.from([0x81, payload.length]) : Buffer.from([0x81, 126, payload.length >> 8, payload.length & 0xff]);
    socket.write(Buffer.concat([header, payload]));
  };
  send();
  const interval = setInterval(send, 250);
  const close = () => clearInterval(interval);
  socket.on('close', close); socket.on('error', close); socket.on('end', close);
  return true;
}
