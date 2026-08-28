import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const fixtures = resolve(root, 'contracts/fixtures');
const sha256 = /^sha256:[a-f0-9]{64}$/;

function tuple(value, length, name) {
  assert.ok(Array.isArray(value), `${name} must be an array`);
  assert.equal(value.length, length, `${name} must have ${length} values`);
  for (const number of value) assert.equal(typeof number, 'number', `${name} values must be numbers`);
}

function validatePresentation(value) {
  assert.equal(value.schema_version, 'future-engine.system-design-presentation.v1');
  assert.equal(typeof value.design_id, 'string');
  assert.ok(Number.isSafeInteger(value.draft_revision_number) && value.draft_revision_number > 0);
  assert.equal(typeof value.profile_id, 'string');
  assert.match(value.design_hash, sha256);
  assert.deepEqual(value.coordinate_system, { handedness: 'right', up_axis: 'z', length_unit: 'm', angle_unit: 'rad', quaternion_order: 'wxyz' });
  assert.ok(Array.isArray(value.instances));
  const ids = new Set();
  for (const instance of value.instances) {
    assert.ok(!ids.has(instance.instance_id), `duplicate instance ${instance.instance_id}`);
    ids.add(instance.instance_id);
    tuple(instance.world_transform.translation_m, 3, `${instance.instance_id}.translation_m`);
    tuple(instance.world_transform.rotation_wxyz, 4, `${instance.instance_id}.rotation_wxyz`);
    assert.ok(['component', 'assembly'].includes(instance.release.kind));
    assert.equal(typeof instance.release.category, 'string');
    assert.equal(typeof instance.release.description, 'string');
    assert.ok(['ready', 'warning', 'blocked'].includes(instance.release.readiness_status));
    assert.match(instance.release.package_digest, sha256);
    assert.ok(['anchor', 'joint_derived', 'generated', 'assembly_locked', 'live_controlled'].includes(instance.editability.reason));
    assert.equal(instance.editability.editable, instance.editability.reason === 'anchor');
    if (instance.model) {
      assert.match(instance.model.sha256, sha256);
      assert.ok(instance.model.asset_path.startsWith('/'));
      assert.ok(instance.model.size_bytes >= 0);
      assert.ok(instance.model.scale_to_m > 0);
      tuple(instance.model.model_scale, 3, `${instance.instance_id}.model_scale`);
      tuple(instance.model.inner_rotation_wxyz, 4, `${instance.instance_id}.inner_rotation_wxyz`);
    }
    assert.ok(Array.isArray(instance.interfaces));
    const interfaceIds = new Set();
    for (const port of instance.interfaces) {
      assert.ok(!interfaceIds.has(port.interface_id), `duplicate interface ${instance.instance_id}:${port.interface_id}`);
      interfaceIds.add(port.interface_id);
      assert.ok(['mount', 'port'].includes(port.type));
      assert.ok(['mechanical', 'electrical', 'signal', 'fluid', 'thermal', 'optical'].includes(port.domain));
      assert.ok(['input', 'output', 'bidirectional'].includes(port.direction));
      assert.equal(typeof port.compatibility_key, 'string');
      assert.ok(Number.isSafeInteger(port.capacity.used));
      assert.ok(port.capacity.maximum === 'unbounded' || Number.isSafeInteger(port.capacity.maximum));
      assert.ok(['reviewed', 'draft', 'incomplete'].includes(port.readiness.status));
      assert.ok(Array.isArray(port.readiness.diagnostics));
      assert.equal(typeof port.connectable, 'boolean');
      assert.ok(['available', 'selected', 'compatible', 'incompatible', 'connected', 'capacity_reached', 'definition_incomplete'].includes(port.state));
      assert.equal(typeof port.state_message, 'string');
    }
    assert.ok(Array.isArray(instance.resolved_configuration.parameters));
  }
  assert.ok(Array.isArray(value.relationships));
  for (const relationship of value.relationships) {
    assert.ok(['connection', 'joint'].includes(relationship.kind));
    assert.ok(ids.has(relationship.source.instance_id));
    assert.ok(ids.has(relationship.target.instance_id));
    assert.ok(['compatible', 'warning', 'incompatible', 'unverified'].includes(relationship.status));
    assert.ok(['resolved', 'blocked', 'stale', 'not_applicable', 'unresolved'].includes(relationship.resolver_status));
  }
  assert.ok(Array.isArray(value.bom));
  assert.ok(['ready', 'warning', 'blocked'].includes(value.readiness.status));
  assert.ok(Array.isArray(value.diagnostics));
  for (const item of value.diagnostics) {
    assert.ok(['info', 'warning', 'error'].includes(item.severity));
    assert.equal(typeof item.code, 'string');
    assert.equal(typeof item.message, 'string');
  }
}

const schema = JSON.parse(await readFile(resolve(root, 'contracts/presentation.schema.json'), 'utf8'));
assert.equal(schema.$schema, 'https://json-schema.org/draft/2020-12/schema');
assert.equal(schema.properties.schema_version.const, 'future-engine.system-design-presentation.v1');

const presentation = JSON.parse(await readFile(resolve(fixtures, 'presentation.success.json'), 'utf8'));
validatePresentation(presentation);

const document = JSON.parse(await readFile(resolve(fixtures, 'design-document.json'), 'utf8'));
assert.equal(document.draft.design.schema_version, 'future-engine.system-design.v2');
assert.equal(document.summary.draft_revision_number, document.draft.revision_number);
assert.equal(document.summary.design_id, document.draft.design.design_id);
assert.ok(document.draft.design.component_instances.length > 0);
assert.ok(document.draft.design.component_instances.every((instance) => Object.hasOwn(instance, 'parent_assembly_id')));
assert.ok(document.draft.design.profiles.some((profile) => profile.profile_id === presentation.profile_id));

for (const file of ['validation-error.json', 'revision-conflict.json', 'missing-asset.json']) {
  const payload = JSON.parse(await readFile(resolve(fixtures, file), 'utf8'));
  assert.equal(typeof payload.error.code, 'string');
  assert.equal(typeof payload.error.message, 'string');
  assert.equal(typeof payload.error.retryable, 'boolean');
}

const names = await readdir(fixtures);
process.stdout.write(`CONTRACTS_OK ${names.length} fixtures\n`);
