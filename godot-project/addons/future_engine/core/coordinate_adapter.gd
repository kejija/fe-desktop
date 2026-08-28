@tool
class_name FECoordinateAdapter
extends RefCounted

# Columns map FE +X/+Y/+Z into Godot +X/-Z/+Y.
const FE_TO_GODOT := Basis(
	Vector3(1.0, 0.0, 0.0),
	Vector3(0.0, 0.0, -1.0),
	Vector3(0.0, 1.0, 0.0)
)

static func fe_position_to_godot(value: Array) -> Vector3:
	if value.size() != 3:
		return Vector3.ZERO
	return Vector3(float(value[0]), float(value[2]), -float(value[1]))

static func godot_position_to_fe(value: Vector3) -> Array[float]:
	return [value.x, -value.z, value.y]

static func fe_quaternion_to_godot(value: Array) -> Quaternion:
	if value.size() != 4:
		return Quaternion.IDENTITY
	var fe_rotation := Basis(Quaternion(float(value[1]), float(value[2]), float(value[3]), float(value[0])))
	return (FE_TO_GODOT * fe_rotation * FE_TO_GODOT.inverse()).get_rotation_quaternion().normalized()

static func godot_quaternion_to_fe(value: Quaternion) -> Array[float]:
	var fe_rotation := FE_TO_GODOT.inverse() * Basis(value.normalized()) * FE_TO_GODOT
	var quaternion := fe_rotation.get_rotation_quaternion().normalized()
	return [quaternion.w, quaternion.x, quaternion.y, quaternion.z]

static func fe_transform_to_godot(value: Dictionary) -> Transform3D:
	var position: Array = value.get("translation_m", [0.0, 0.0, 0.0])
	var rotation: Array = value.get("rotation_wxyz", [1.0, 0.0, 0.0, 0.0])
	return Transform3D(Basis(fe_quaternion_to_godot(rotation)), fe_position_to_godot(position))

static func godot_transform_to_fe(value: Transform3D) -> Dictionary:
	return {
		"translation_m": godot_position_to_fe(value.origin),
		"rotation_wxyz": godot_quaternion_to_fe(value.basis.get_rotation_quaternion())
	}

static func model_scale_to_godot(model: Dictionary) -> Vector3:
	var values: Array = model.get("model_scale", [1.0, 1.0, 1.0])
	var scale_to_m := float(model.get("scale_to_m", 1.0))
	if values.size() != 3:
		return Vector3.ONE * scale_to_m
	return Vector3(float(values[0]), float(values[2]), float(values[1])) * scale_to_m

# These formulas intentionally match apps/node-design-frontend/src/transform.ts at
# the parity baseline. They operate in FE coordinates before any Godot basis change.
static func quaternion_to_euler_degrees(value: Array) -> Array[float]:
	if value.size() != 4:
		return [0.0, 0.0, 0.0]
	var w := float(value[0])
	var x := float(value[1])
	var y := float(value[2])
	var z := float(value[3])
	var roll := atan2(2.0 * (w * x + y * z), 1.0 - 2.0 * (x * x + y * y))
	var pitch := asin(clampf(2.0 * (w * y - z * x), -1.0, 1.0))
	var yaw := atan2(2.0 * (w * z + x * y), 1.0 - 2.0 * (y * y + z * z))
	return [_display_degrees(roll), _display_degrees(pitch), _display_degrees(yaw)]

static func euler_degrees_to_quaternion(value: Array) -> Array[float]:
	if value.size() != 3:
		return [1.0, 0.0, 0.0, 0.0]
	var roll := deg_to_rad(float(value[0])) * 0.5
	var pitch := deg_to_rad(float(value[1])) * 0.5
	var yaw := deg_to_rad(float(value[2])) * 0.5
	var cr := cos(roll)
	var sr := sin(roll)
	var cp := cos(pitch)
	var sp := sin(pitch)
	var cy := cos(yaw)
	var sy := sin(yaw)
	var quaternion: Array[float] = [
		cr * cp * cy + sr * sp * sy,
		sr * cp * cy - cr * sp * sy,
		cr * sp * cy + sr * cp * sy,
		cr * cp * sy - sr * sp * cy
	]
	var magnitude := sqrt(quaternion[0] * quaternion[0] + quaternion[1] * quaternion[1] + quaternion[2] * quaternion[2] + quaternion[3] * quaternion[3])
	if magnitude <= 0.0:
		return [1.0, 0.0, 0.0, 0.0]
	for index in quaternion.size():
		quaternion[index] /= magnitude
	return quaternion

static func _display_degrees(radians: float) -> float:
	var rounded: float = round(rad_to_deg(radians) * 1000000.0) / 1000000.0
	return 0.0 if is_zero_approx(rounded) else rounded
