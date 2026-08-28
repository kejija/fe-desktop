# Coordinate contract

Future Engine presentation payloads are right-handed, Z-up, meters, radians, with quaternions ordered `wxyz`. Godot is treated as right-handed, Y-up with forward along negative Z.

The only allowed boundary conversion is:

```text
FE position (x, y, z) -> Godot position (x, z, -y)
Godot position (x, y, z) -> FE position (x, -z, y)
```

Rotations are converted by basis conjugation, not by permuting quaternion fields:

```text
R_godot = C * R_fe * inverse(C)
R_fe = inverse(C) * R_godot * C
```

where `C` maps the FE X/Y/Z basis vectors to Godot `+X/-Z/+Y`. Model-package unit scale is applied below the component pose so authored mesh units do not contaminate engineering transforms.
