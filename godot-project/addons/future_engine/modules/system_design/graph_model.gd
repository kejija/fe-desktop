@tool
class_name FEGraphModel
extends RefCounted

const MINOR_GRID := 28.0
const REGISTRATION_GRID := 140.0
const NODE_WIDTH := 280.0
const MIN_ZOOM := 0.3
const MAX_ZOOM := 1.8
const BODY_INTERFACE := "@body"
const STATUS_SEVERITY := {"compatible": 0, "unverified": 1, "warning": 2, "incompatible": 3}

static func build(design: Dictionary, presentation: Dictionary, active_assembly_id: String) -> Dictionary:
	var assemblies := _by_id(design.get("assemblies", []), "assembly_id")
	var components := _by_id(design.get("component_instances", []), "instance_id")
	var presented := _by_id(presentation.get("instances", []), "instance_id")
	var active_id := active_assembly_id
	if active_id.is_empty() or not assemblies.has(active_id):
		active_id = _root_assembly_id(assemblies)
	var nodes := {}
	var visible_instance_nodes := {}
	var hidden_generated := PackedStringArray()
	var layout: Dictionary = design.get("extensions", {}).get("node_design_layout", {})
	var order := 0

	for component_id in components:
		var component: Dictionary = components[component_id]
		if _is_generated(component):
			hidden_generated.append(component_id)
			continue
		if str(component.get("parent_assembly_id", "")) == active_id:
			var node_id := component_key(component_id)
			nodes[node_id] = _component_node(node_id, component, presented.get(component_id, {}), layout, order)
			visible_instance_nodes[component_id] = node_id
			order += 1

	for assembly_id in assemblies:
		var assembly: Dictionary = assemblies[assembly_id]
		if str(assembly.get("parent_assembly_id", "")) == active_id:
			var node_id := assembly_key(assembly_id)
			nodes[node_id] = _assembly_node(node_id, assembly, layout, order, false)
			for instance_id in components:
				if _is_descendant_assembly(str(components[instance_id].get("parent_assembly_id", "")), assembly_id, assemblies):
					visible_instance_nodes[instance_id] = node_id
			order += 1

	var projected := []
	for value in presentation.get("relationships", []):
		if not value is Dictionary:
			continue
		var relationship: Dictionary = value
		var source: Dictionary = relationship.get("source", {})
		var target: Dictionary = relationship.get("target", {})
		var source_instance := str(source.get("instance_id", ""))
		var target_instance := str(target.get("instance_id", ""))
		if hidden_generated.has(source_instance) or hidden_generated.has(target_instance):
			continue
		var source_node := str(visible_instance_nodes.get(source_instance, ""))
		var target_node := str(visible_instance_nodes.get(target_instance, ""))
		if source_node.is_empty():
			source_node = _ensure_external_proxy(nodes, components.get(source_instance, {}), assemblies, layout, order)
			if not source_node.is_empty():
				order += 1
		if target_node.is_empty():
			target_node = _ensure_external_proxy(nodes, components.get(target_instance, {}), assemblies, layout, order)
			if not target_node.is_empty():
				order += 1
		if source_node.is_empty() or target_node.is_empty() or source_node == target_node:
			continue
		var source_handle := _endpoint_handle(source_node, source, relationship)
		var target_handle := _endpoint_handle(target_node, target, relationship)
		_add_proxy_port(nodes[source_node], source_handle, source, presented, relationship)
		_add_proxy_port(nodes[target_node], target_handle, target, presented, relationship)
		projected.append({
			"relationship_id": str(relationship.get("relationship_id", "")),
			"kind": str(relationship.get("kind", "connection")),
			"source_node": source_node,
			"source_handle": source_handle,
			"target_node": target_node,
			"target_handle": target_handle,
			"domain": str(relationship.get("connection_type", "mechanical")),
			"label": str(relationship.get("label", "Relationship")),
			"description": str(relationship.get("description", "")),
			"status": str(relationship.get("status", "unverified")),
			"resolver_status": str(relationship.get("resolver_status", "unresolved")),
			"source": source.duplicate(true),
			"target": target.duplicate(true),
			"raw": relationship.duplicate(true)
		})

	return {
		"active_assembly_id": active_id,
		"breadcrumbs": _breadcrumbs(active_id, assemblies),
		"nodes": nodes.values(),
		"edges": _bundle_edges(projected),
		"hidden_generated": hidden_generated
	}

static func component_key(instance_id: String) -> String:
	return "component:%s" % instance_id

static func assembly_key(assembly_id: String) -> String:
	return "assembly:%s" % assembly_id

static func encode_proxy_handle(instance_id: String, interface_id: Variant) -> String:
	return "proxy:%s:%s" % [instance_id.uri_encode(), str(interface_id if interface_id != null else BODY_INTERFACE).uri_encode()]

static func decode_proxy_handle(handle: String) -> Dictionary:
	if not handle.begins_with("proxy:"):
		return {}
	var values := handle.trim_prefix("proxy:").split(":", false, 1)
	if values.size() != 2:
		return {}
	var interface_id := values[1].uri_decode()
	return {"instance_id": values[0].uri_decode(), "interface_id": null if interface_id == BODY_INTERFACE else interface_id}

static func snap_position(position: Vector2) -> Vector2:
	return Vector2(round(position.x / REGISTRATION_GRID) * REGISTRATION_GRID, round(position.y / REGISTRATION_GRID) * REGISTRATION_GRID)

static func layout_position(design: Dictionary, node_id: String, fallback: Vector2) -> Dictionary:
	var layout: Dictionary = design.get("extensions", {}).get("node_design_layout", {})
	if layout.has(node_id):
		return {"position": _vector2(layout[node_id], fallback), "legacy": false}
	if node_id.begins_with("component:"):
		var legacy_key := node_id.trim_prefix("component:")
		if layout.has(legacy_key):
			return {"position": _vector2(layout[legacy_key], fallback), "legacy": true}
	return {"position": fallback, "legacy": false}

static func write_layout(design: Dictionary, node_id: String, position: Vector2) -> void:
	var extensions: Dictionary = design.get("extensions", {})
	var layout: Dictionary = extensions.get("node_design_layout", {})
	layout[node_id] = [position.x, position.y]
	if node_id.begins_with("component:"):
		layout.erase(node_id.trim_prefix("component:"))
	extensions["node_design_layout"] = layout
	design["extensions"] = extensions

static func aggregate_status(members: Array) -> String:
	var result := "compatible"
	var severity := -1
	for member in members:
		var status := str(member.get("status", "unverified"))
		var candidate := int(STATUS_SEVERITY.get(status, 1))
		if candidate > severity:
			severity = candidate
			result = status if STATUS_SEVERITY.has(status) else "unverified"
	return result

static func _component_node(node_id: String, component: Dictionary, presentation: Dictionary, layout: Dictionary, order: int) -> Dictionary:
	var fallback := _default_position(order)
	var positioned := layout_position({"extensions": {"node_design_layout": layout}}, node_id, fallback)
	return {
		"id": node_id,
		"kind": "component",
		"instance_id": str(component.get("instance_id", "")),
		"title": str(presentation.get("name", component.get("name", "Component"))),
		"component": component.duplicate(true),
		"presentation": presentation.duplicate(true),
		"ports": presentation.get("interfaces", []).duplicate(true),
		"position": positioned.position,
		"legacy_layout": positioned.legacy,
		"external": false
	}

static func _assembly_node(node_id: String, assembly: Dictionary, layout: Dictionary, order: int, external: bool) -> Dictionary:
	var fallback := Vector2(910.0, 490.0) if external else _default_position(order)
	var positioned := layout_position({"extensions": {"node_design_layout": layout}}, node_id, fallback)
	return {
		"id": node_id,
		"kind": "assembly",
		"assembly_id": str(assembly.get("assembly_id", "")),
		"title": ("External · " if external else "") + str(assembly.get("name", "Assembly")),
		"ports": [],
		"position": positioned.position,
		"legacy_layout": false,
		"external": external
	}

static func _add_proxy_port(node: Dictionary, handle: String, endpoint: Dictionary, presented: Dictionary, relationship: Dictionary) -> void:
	if node.get("kind") == "component" and endpoint.get("interface_id") != null:
		return
	for existing in node.get("ports", []):
		if existing.get("interface_id") == handle:
			return
	var original_interface: Variant = null
	var instance: Dictionary = presented.get(str(endpoint.get("instance_id", "")), {})
	for value in instance.get("interfaces", []):
		if value is Dictionary and value.get("interface_id") == endpoint.get("interface_id"):
			original_interface = value
			break
	var port := {
		"interface_id": handle,
		"name": str(original_interface.get("name", relationship.get("label", "Body anchor"))) if original_interface is Dictionary else "%s body" % instance.get("name", endpoint.get("instance_id", "Instance")),
		"description": str(original_interface.get("description", "Collapsed relationship endpoint")) if original_interface is Dictionary else "Non-connectable body-authored joint anchor",
		"type": str(original_interface.get("type", "mount")) if original_interface is Dictionary else "mount",
		"domain": str(relationship.get("connection_type", original_interface.get("domain", "mechanical") if original_interface is Dictionary else "mechanical")),
		"direction": str(original_interface.get("direction", "bidirectional")) if original_interface is Dictionary else "bidirectional",
		"compatibility_key": str(original_interface.get("compatibility_key", "")) if original_interface is Dictionary else "",
		"capacity": original_interface.get("capacity", {"used": 1, "maximum": 1}) if original_interface is Dictionary else {"used": 1, "maximum": 1},
		"readiness": original_interface.get("readiness", {"status": "reviewed", "diagnostics": []}) if original_interface is Dictionary else {"status": "reviewed", "diagnostics": []},
		"connectable": bool(original_interface.get("connectable", false)) if original_interface is Dictionary and endpoint.get("interface_id") != null else false,
		"state": str(original_interface.get("state", "connected")) if original_interface is Dictionary else "connected",
		"state_message": str(original_interface.get("state_message", "Collapsed endpoint")) if original_interface is Dictionary else "Body joint anchors are display-only",
		"original_endpoint": endpoint.duplicate(true),
		"proxy": true,
		"body_anchor": endpoint.get("interface_id") == null
	}
	node.ports.append(port)

static func _endpoint_handle(node_id: String, endpoint: Dictionary, relationship: Dictionary) -> String:
	if node_id.begins_with("component:"):
		var interface_id: Variant = endpoint.get("interface_id")
		return str(interface_id) if interface_id != null else "body:%s:%s" % [relationship.get("relationship_id", "joint"), endpoint.get("instance_id", "instance")]
	return encode_proxy_handle(str(endpoint.get("instance_id", "")), endpoint.get("interface_id"))

static func _bundle_edges(edges: Array) -> Array:
	var grouped := {}
	var order := []
	for edge in edges:
		var key := "relationship:%s" % edge.relationship_id
		if edge.domain == "mechanical":
			var pair := [str(edge.source_node), str(edge.target_node)]
			pair.sort()
			key = "mechanical:%s|%s" % pair
		if not grouped.has(key):
			grouped[key] = []
			order.append(key)
		grouped[key].append(edge)
	var result := []
	for key in order:
		var members: Array = grouped[key]
		var first: Dictionary = members[0]
		result.append({
			"id": key,
			"source_node": first.source_node,
			"source_handle": first.source_handle,
			"target_node": first.target_node,
			"target_handle": first.target_handle,
			"domain": first.domain,
			"status": aggregate_status(members),
			"label": "%s ×%s" % [first.label, members.size()] if members.size() > 1 else first.label,
			"members": members,
			"bundled": members.size() > 1
		})
	return result

static func _ensure_external_proxy(nodes: Dictionary, component: Dictionary, assemblies: Dictionary, layout: Dictionary, order: int) -> String:
	if component.is_empty():
		return ""
	var assembly_id := str(component.get("parent_assembly_id", ""))
	if assembly_id.is_empty() or not assemblies.has(assembly_id):
		return ""
	var node_id := "external:%s" % assembly_id
	if not nodes.has(node_id):
		nodes[node_id] = _assembly_node(node_id, assemblies[assembly_id], layout, order, true)
	return node_id

static func _is_descendant_assembly(candidate: String, ancestor: String, assemblies: Dictionary) -> bool:
	var current := candidate
	var visited := {}
	while not current.is_empty() and not visited.has(current):
		if current == ancestor:
			return true
		visited[current] = true
		current = str(assemblies.get(current, {}).get("parent_assembly_id", ""))
	return false

static func _breadcrumbs(active_id: String, assemblies: Dictionary) -> Array:
	var values := []
	var current := active_id
	var visited := {}
	while not current.is_empty() and assemblies.has(current) and not visited.has(current):
		visited[current] = true
		var assembly: Dictionary = assemblies[current]
		values.push_front({"assembly_id": current, "name": str(assembly.get("name", current))})
		current = str(assembly.get("parent_assembly_id", ""))
	return values

static func _root_assembly_id(assemblies: Dictionary) -> String:
	for assembly_id in assemblies:
		if assemblies[assembly_id].get("parent_assembly_id") == null or str(assemblies[assembly_id].get("parent_assembly_id", "")).is_empty():
			return str(assembly_id)
	return str(assemblies.keys()[0]) if not assemblies.is_empty() else ""

static func _by_id(values: Array, key: String) -> Dictionary:
	var result := {}
	for value in values:
		if value is Dictionary and not str(value.get(key, "")).is_empty():
			result[str(value[key])] = value
	return result

static func _is_generated(component: Dictionary) -> bool:
	return component.get("generated") is Dictionary

static func _default_position(order: int) -> Vector2:
	return Vector2(70.0 + float(order % 3) * 420.0, 140.0 + float(order / 3) * 350.0)

static func _vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Array and value.size() == 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback
