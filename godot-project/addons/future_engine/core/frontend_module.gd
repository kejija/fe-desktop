@tool
class_name FEFrontendModule
extends RefCounted

var id: StringName = &""
var display_name := ""
var required_services: PackedStringArray = []

func register_ui(_host: EditorPlugin) -> void:
	pass

func open_context(_context: Dictionary) -> void:
	pass

func activate() -> void:
	pass

func deactivate() -> void:
	pass

func backend_configuration_changed(_configuration: Dictionary) -> void:
	pass

func shutdown() -> void:
	pass
