# Backend handoff: System Design Presentation V1

No backend code is changed by this repository. This document is the compatibility gate that a later `kejija/fe` change must satisfy before Future Engine Desktop enables authoritative upstream editing.

## Required endpoint

Implement `GET /v1/designs/:designId/presentation?profile_id=:profileId` in Node Design. Require `If-Match` with the client's loaded draft revision and return `ETag` with the resolved revision.

The service must use its canonical formula evaluator, forward kinematics, component-release resolver, configuration resolver, material resolver, and diagnostics/BOM/readiness sources. Presentation rules currently owned by a React-only helper must move to shared backend/SDK code; they must not be translated to GDScript.

The response must validate against `presentation.schema.json`. Asset paths are component-service-relative paths that the desktop gateway resolves under `/components`. Every asset must include the immutable file SHA-256 and byte size from the pinned release.

## Failure behavior

- Missing or malformed `If-Match`: `428 draft_precondition_required`.
- Revision mismatch: `409 draft_revision_conflict`, including the current revision.
- Invalid formula/kinematics/configuration: `422 presentation_invalid` with diagnostics.
- Missing pinned release: `422 component_release_unavailable`.
- Temporarily unavailable asset/catalog dependency: `503`, marked retryable.

## Acceptance

1. Run every fixture in `fixtures/` through the backend contract suite.
2. Compare resolved poses, scales, rotations, editability, BOM, and diagnostics with the existing React System Design output.
3. Point this repository's gateway at the candidate service and run the upstream integration suite.
4. Only then mark `presentation_v1` qualified and enable authoritative editing.
