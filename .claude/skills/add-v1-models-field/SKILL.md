---
name: add-v1-models-field
description: Add a field to /v1/models and /api/models/details responses that mirrors another existing field.
---

# Add /v1/models Mirror Field

Add a new JSON field to the `/v1/models` (and `/api/models/details`) response that carries the exact same value as an existing field. The patterns used here avoid plumbing the field through the entire provider/model-catalog stack — it's set by pointer-copy at serialization time.

## When to Use

- User asks to add a field (e.g. `context_window`, `max_input_tokens`) to model list endpoints where the value should match an existing field (e.g. `context_length`)
- Don't use: when the field needs its own distinct value from the provider datasheet, pricing engine, or DB — that requires full end-to-end plumbing

## Key Files

| Endpoint | Response struct | Sync location |
|---|---|---|
| `/v1/models` (OpenAI-compat) | `core/schemas/models.go` → `Model` | `transports/bifrost-http/handlers/inference.go` → `enrichListModelsResponse()` |
| `/api/models/details` (management) | `transports/bifrost-http/handlers/providers.go` → `ModelDetailsResponse` | Same file, `listModelDetails()` handler |

## Procedure

### Step 1: Add field to `Model` struct

In `core/schemas/models.go`, add the new field adjacent to the source field:

```go
// Before:
ContextLength       *int               `json:"context_length,omitempty"`
MaxInputTokens      *int               `json:"max_input_tokens,omitempty"`

// After:
ContextLength       *int               `json:"context_length,omitempty"`
ContextWindow       *int               `json:"context_window,omitempty"`
MaxInputTokens      *int               `json:"max_input_tokens,omitempty"`
```

Tag pattern: `json:"<field_name>,omitempty"` — type must be `*int` or whatever the source field type is.

### Step 2: Sync in `enrichListModelsResponse`

In `transports/bifrost-http/handlers/inference.go`, after the client-level context window override block and before `resp.Data[i] = modelEntry`, add the sync:

```go
// Sync <new_field> with <source_field> so both carry the same value.
modelEntry.<NewField> = modelEntry.<SourceField>
```

This runs after `ApplyModelInfo` and the client-config override, so the value reflects all final transformations.

### Step 3 (if needed): Add field to `ModelDetailsResponse`

In `transports/bifrost-http/handlers/providers.go`, add the same field to `ModelDetailsResponse`:

```go
ContextLength        *int                  `json:"context_length,omitempty"`
ContextWindow        *int                  `json:"context_window,omitempty"`
MaxInputTokens       *int                  `json:"max_input_tokens,omitempty"`
```

Then in `listModelDetails()`, set it from the same source:

```go
details.ContextLength = capabilities.ContextLength
details.ContextWindow = capabilities.ContextLength  // mirror
details.MaxInputTokens = capabilities.ContextLength // mirror
```

### Step 4: Verify

```bash
cd transports/bifrost-http && go build -o /dev/null .
```

## Pitfalls

- **Don't plumb through providers.** The mirror pattern is explicitly a post-hoc copy. If the field needs its own distinct per-provider value, follow the full provider integration checklist instead.
- **Order matters.** The sync must happen after `ApplyModelInfo` and the client-config override in `enrichListModelsResponse`, or the value will be overwritten.
- **`omitempty` will hide zero-values.** An `*int` pointer that is `nil` serializes to nothing. If the source field is always populated this is fine — if it can be nil, the mirror will also be absent.