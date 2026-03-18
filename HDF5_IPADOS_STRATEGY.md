# HDF5 iPadOS Strategy

Date: March 17, 2026

## Purpose

This document compares the practical options for making `sleap-io.swift`
usable inside downstream iPadOS apps such as `sleap.swift`.

Scope note:

- this document assumes we are still pursuing HDF5-backed I/O as the core path
- it compares packaging and deployment strategies for that path
- it does not replace broader product alternatives such as a portable non-HDF5
  bundle format or a pure-Swift reader

Those broader alternatives are tracked separately in
`IMPLEMENTATION_PLAN.md` under `iPad Compatibility Requirements`.

Status update for `v0.3.0`:

- the package now defaults to a vendored `CHDF5.xcframework`
- the release question is no longer "should we package HDF5 at all?"
- the release question is whether the current packaged path is validated enough
  to claim official downstream iPad `.slp` support

The question is not whether HDF5 works in Swift. It already does on macOS.
The question is how to package it so an iPad app can actually ship it.

## Current State

Today the package looks like this:

- `SleapIO`, `SleapVideo`, and `SleapRendering` are normal Swift targets
- `SleapHDF5` depends on `CHDF5`
- `CHDF5` defaults to a vendored Apple XCFramework, with a system-library path
  retained only as an explicit macOS development fallback

That is acceptable for:

- macOS development
- local benchmarking
- CLI work on a developer machine

The remaining release risk is:

- proving a real downstream iPad app target with release-candidate bits
- documenting the supported integration path clearly
- making that validation part of the release gate

## Decision Criteria

Any viable option should satisfy most or all of these:

1. `sleap.swift` can ship on iPad without requiring end users to install HDF5.
2. CI and local builds are reproducible.
3. The packaging story is understandable for downstream app teams.
4. The maintenance burden is reasonable for a small team.
5. The approach works for the HDF5-backed formats already implemented in phase 4.

## Options

### Option A: Vendor libhdf5 as an Apple XCFramework / binary artifact

Ship a prebuilt Apple-platform HDF5 artifact and make `SleapHDF5` depend on
that packaged binary rather than on a system-installed library.

What this means in practice:

- build libhdf5 for the Apple targets we care about
- package headers + binary slices as an XCFramework or equivalent binary artifact
- point SwiftPM at that artifact instead of `pkg-config`

Pros:

- best downstream app experience once it exists
- clear version pinning for HDF5
- no Homebrew requirement for consumers
- closest to a normal dependency story for `sleap.swift`
- keeps HDF5 support available on both macOS and iPadOS behind one integration path

Cons:

- requires build/release infrastructure for the binary artifact
- increases repo and release complexity
- every HDF5 upgrade becomes a packaging event, not just a code change
- debugging packaging mistakes across Apple targets is non-trivial

Risks:

- architecture and SDK slice mistakes
- header/module-map maintenance
- possible extra dependency handling if the HDF5 build is not self-contained

Assessment:

- best long-term product answer
- not the lowest-effort answer

### Option B: Vendor a statically linked HDF5 build for Apple mobile targets

Build HDF5 ourselves for Apple targets and link it statically into the package
or downstream app products.

Pros:

- can produce a self-contained deployment story
- avoids relying on a user-installed system library
- may reduce runtime integration surprises compared with dynamic packaging

Cons:

- more build-system work than it sounds like
- cross-compiling and maintaining static builds is still specialized packaging work
- the burden shifts to custom scripts/tooling rather than disappearing
- awkward if multiple downstream targets need slightly different packaging

Risks:

- brittle custom build scripts
- larger build times and more contributor friction
- unclear payoff relative to just doing Option A well

Assessment:

- technically viable
- usually worse than Option A unless we have a strong reason to avoid binary artifacts

### Option C: Split the package and keep `SleapHDF5` effectively macOS-only for now

Treat the package as two deployment tiers:

- iPad-ready pure Swift / Apple-framework modules:
  - `SleapIO`
  - `SleapVideo`
  - `SleapRendering`
- HDF5-backed I/O:
  - `SleapHDF5`
  - explicitly macOS-validated until portable HDF5 packaging exists

Pros:

- lowest immediate cost
- honest about current deployment reality
- lets downstream apps use non-HDF5 parts of the library on iPad now
- reduces the risk of overpromising platform support

Cons:

- does not solve iPad HDF5 support
- forces downstream app teams to own a temporary split in capability
- some formats remain unavailable on iPad until later work lands

Risks:

- product confusion if docs are not explicit
- downstream teams may build against APIs that are not uniformly deployable

Assessment:

- best short-term truth
- not a complete solution

## Comparison

| Option | Short-term effort | Long-term maintainability | iPad app usability | Downstream DX | Recommendation |
|---|---:|---:|---:|---:|---|
| A. XCFramework / binary artifact | Medium-High | Good | Good | Good | `v0.3.0` release vehicle |
| B. Static HDF5 build | High | Medium-Low | Good | Medium | Only if A is blocked |
| C. Split package / macOS-only HDF5 for now | Low | Good short-term | Low for HDF5, good for core modules | Medium | Fallback only if `v0.3.0` slips |

## Recommendation

Use a one-release strategy for `v0.3.0`.

### Release decision

Adopt Option A as the official release posture:

- package libhdf5 as an Apple binary artifact
- make `SleapHDF5` consume that artifact
- validate the real app integration story in `sleap.swift` before tagging

Reason:

- it gives the cleanest downstream experience
- it keeps one HDF5 implementation across macOS and iPadOS
- it is easier to explain and support than a one-off static-link pipeline

### Release rule

If downstream iPad validation fails, slip `v0.3.0`.

Do not:

- relabel iPad support as "experimental" for the same release
- switch to a new portable-format scope mid-release
- treat package-only compilation as sufficient signoff

### Non-recommendation

Do not choose Option B first unless Option A is blocked by a concrete
constraint.

Examples of valid reasons to prefer B:

- SwiftPM binary artifacts prove unworkable for the required layout
- app distribution policy forbids the intended artifact flow
- we need custom HDF5 compilation flags that are easier to own in a static build

Without that kind of constraint, Option B is mostly extra packaging work with a
weaker long-term developer experience.

## What This Means For `sleap.swift`

For `v0.3.0`, `sleap.swift` is the downstream proof point:

- it should validate the released-package integration path, not a local-only
  source checkout shortcut
- it should add a minimal iPad target or host app if needed for smoke
  validation
- it should treat open/edit/save/reopen on a real external-video `.slp` as the
  release gate
- it should also validate temporary vs permanent relocation behavior end to end

## Proposed Execution Plan

### Phase 1: Lock the release contract

- treat the vendored XCFramework path as the chosen deployment model
- align root docs with the official iPad support posture
- lock the persisted-relocation API in the release plan and API design docs

### Phase 2: Validate downstream behavior

- prove that `SleapHDF5` links in a real downstream iPad target
- verify one real external-video `.slp` open/edit/save/reopen path
- verify temporary vs permanent relocation behavior in the downstream app flow

### Phase 3: Tag only on passing proof

- keep the downstream validation step in the release gate
- document the supported integration path for downstream teams
- tag only when the smoke scenario is green

## Acceptance Criteria For Closing This Risk

This issue is only closed for `v0.3.0` when all of the following are true:

1. `sleap.swift` can build for iPad without a developer-installed HDF5 toolchain.
2. A real external-video `.slp` is opened, edited, saved, and reopened in an
   iPad app target using release-candidate bits.
3. Temporary vs permanent relocation behavior is validated end to end.
4. The dependency story is documented for downstream teams.
5. The release checklist treats this validation as a hard gate.
