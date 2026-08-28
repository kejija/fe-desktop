@tool
class_name FEContractValidator
extends RefCounted

const PRESENTATION_SCHEMA := "future-engine.system-design-presentation.v1"
const DESIGN_SCHEMA := "future-engine.system-design.v2"
const EDITABILITY_REASONS := [&"anchor", &"joint_derived", &"generated", &"assembly_locked", &"live_controlled"]

static func validate_design_document(value: Variant) -> PackedStringArray:
	var errors := PackedStringArray()
	if not value is Dictionary:
		errors.append("Design document must be an object.")
		return errors
	var document: Dictionary = value
	var summary: Variant = document.get("summary")
	if not summary is Dictionary:
		errors.append("summary is required.")
		return errors
	if str(summary.get("design_id", "")).is_empty():
		errors.append("summary.design_id is required.")
	if int(summary.get("draft_revision_number", 0)) < 1:
		errors.append("summary.draft_revision_number must be positive.")
	var draft: Variant = document.get("draft")
	if not draft is Dictionary or not draft.get("design") is Dictionary:
		errors.append("draft.design is required.")
		return errors
	var design: Dictionary = draft.get("design")
	if design.get("schema_version") != DESIGN_SCHEMA:
		errors.append("Unsupported design schema: %s" % design.get("schema_version", "missing"))
	if str(design.get("design_id", "")) != str(summary.get("design_id", "")):
		errors.append("summary and draft design IDs must match.")
	if int(draft.get("revision_number", 0)) != int(summary.get("draft_revision_number", 0)):
		errors.append("summary and draft revision numbers must match.")
	for instance in design.get("component_instances", []):
		if not instance is Dictionary or not instance.has("parent_assembly_id"):
			errors.append("Every component instance requires parent_assembly_id.")
	return errors

static func validate_presentation(value: Variant, expected_design_id := "", expected_revision := 0) -> PackedStringArray:
	var errors := PackedStringArray()
	if not value is Dictionary:
		errors.append("Presentation must be an object.")
		return errors
	var presentation: Dictionary = value
	if presentation.get("schema_version") != PRESENTATION_SCHEMA:
		errors.append("The backend does not provide %s." % PRESENTATION_SCHEMA)
	if expected_design_id and presentation.get("design_id") != expected_design_id:
		errors.append("Presentation design_id does not match the open design.")
	if expected_revision > 0 and int(presentation.get("draft_revision_number", 0)) != expected_revision:
		errors.append("Presentation revision is stale.")
	if not _sha256(presentation.get("design_hash", "")):
		errors.append("design_hash must be a sha256 digest.")
	var coordinates: Variant = presentation.get("coordinate_system")
	if not coordinates is Dictionary:
		errors.append("coordinate_system is required.")
	else:
		var expected := {"handedness": "right", "up_axis": "z", "length_unit": "m", "angle_unit": "rad", "quaternion_order": "wxyz"}
		for key in expected:
			if coordinates.get(key) != expected[key]:
				errors.append("Unsupported coordinate convention for %s." % key)
	var instances: Variant = presentation.get("instances")
	if not instances is Array:
		errors.append("instances must be an array.")
		return errors
	var ids := {}
	for value_instance in instances:
		if not value_instance is Dictionary:
			errors.append("Every instance must be an object.")
			continue
		var instance: Dictionary = value_instance
		var instance_id := str(instance.get("instance_id", ""))
		if instance_id.is_empty() or ids.has(instance_id):
			errors.append("Instance IDs must be non-empty and unique.")
		ids[instance_id] = true
		_validate_transform(instance.get("world_transform"), instance_id, errors)
		var editability: Variant = instance.get("editability")
		if not editability is Dictionary or StringName(editability.get("reason", "")) not in EDITABILITY_REASONS:
			errors.append("%s has invalid editability." % instance_id)
		elif bool(editability.get("editable", false)) != (editability.get("reason") == "anchor"):
			errors.append("%s editability conflicts with its reason." % instance_id)
		var model: Variant = instance.get("model")
		if model != null and model is Dictionary:
			if not _sha256(model.get("sha256", "")):
				errors.append("%s model digest is invalid." % instance_id)
			if float(model.get("scale_to_m", 0.0)) <= 0.0:
				errors.append("%s model scale_to_m must be positive." % instance_id)
		var release: Variant = instance.get("release")
		if not release is Dictionary or str(release.get("category", "")).is_empty() or not release.has("description"):
			errors.append("%s release graph metadata is required." % instance_id)
		var interfaces: Variant = instance.get("interfaces")
		if not interfaces is Array:
			errors.append("%s interfaces must be an array." % instance_id)
		else:
			var interface_ids := {}
			for interface in interfaces:
				if not interface is Dictionary:
					errors.append("%s contains an invalid interface." % instance_id)
					continue
				var interface_id := str(interface.get("interface_id", ""))
				if interface_id.is_empty() or interface_ids.has(interface_id):
					errors.append("%s interface IDs must be non-empty and unique." % instance_id)
				interface_ids[interface_id] = true
				for required_key in ["compatibility_key", "capacity", "readiness", "connectable", "state", "state_message"]:
					if not interface.has(required_key):
						errors.append("%s:%s is missing %s." % [instance_id, interface_id, required_key])
	var relationships: Variant = presentation.get("relationships")
	if not relationships is Array:
		errors.append("Presentation graph required: relationships must be an array.")
	else:
		var relationship_ids := {}
		for value_relationship in relationships:
			if not value_relationship is Dictionary:
				errors.append("Every relationship must be an object.")
				continue
			var relationship_id := str(value_relationship.get("relationship_id", ""))
			if relationship_id.is_empty() or relationship_ids.has(relationship_id):
				errors.append("Relationship IDs must be non-empty and unique.")
			relationship_ids[relationship_id] = true
			for endpoint_name in ["source", "target"]:
				var endpoint: Variant = value_relationship.get(endpoint_name)
				if not endpoint is Dictionary or not ids.has(str(endpoint.get("instance_id", ""))):
					errors.append("%s has an invalid %s endpoint." % [relationship_id, endpoint_name])
	return errors

static func _validate_transform(value: Variant, label: String, errors: PackedStringArray) -> void:
	if not value is Dictionary:
		errors.append("%s world_transform is required." % label)
		return
	if not value.get("translation_m") is Array or value.get("translation_m").size() != 3:
		errors.append("%s translation_m must contain three numbers." % label)
	if not value.get("rotation_wxyz") is Array or value.get("rotation_wxyz").size() != 4:
		errors.append("%s rotation_wxyz must contain four numbers." % label)

static func _sha256(value: Variant) -> bool:
	var text := str(value)
	if not text.begins_with("sha256:") or text.length() != 71:
		return false
	return text.trim_prefix("sha256:").is_valid_hex_number(false)
