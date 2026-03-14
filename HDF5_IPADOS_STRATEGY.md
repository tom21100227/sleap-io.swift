# HDF5 iPadOS Strategy

Date: March 14, 2026

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

The immediate problem is simple:

- `SleapHDF5` currently depends on `CHDF5`
- `CHDF5` is a system-library target with a macOS/Homebrew development story
- that is not a complete deployment story for iPadOS app builds

The question is not whether HDF5 works in Swift. It already does on macOS.
The question is how to package it so an iPad app can actually ship it.

## Current State

Today the package looks like this:

- `SleapIO`, `SleapVideo`, and `SleapRendering` are normal Swift targets
- `SleapHDF5` depends on `CHDF5`
- `CHDF5` assumes a system-installed libhdf5 discovered via `pkg-config`

That is acceptable for:

- macOS development
- local benchmarking
- CLI work on a developer machine

That is not sufficient for:

- App Store iPad builds
- reproducible mobile CI
- downstream app integration without custom local toolchain setup

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
| A. XCFramework / binary artifact | Medium-High | Good | Good | Good | Target state |
| B. Static HDF5 build | High | Medium-Low | Good | Medium | Only if A is blocked |
| C. Split package / macOS-only HDF5 for now | Low | Good short-term | Low for HDF5, good for core modules | Medium | Immediate posture |

## Recommendation

Use a two-step strategy.

### Immediate decision

Adopt Option C as the official current posture:

- be explicit that `SleapHDF5` is currently macOS-validated
- stop implying that HDF5-backed I/O is already deployable on iPad
- let downstream teams use the non-HDF5 modules on iPad without confusion

Reason:

- it matches reality
- it unblocks planning immediately
- it avoids spending product credibility on an incomplete packaging story

### Target implementation path

Pursue Option A as the intended production solution:

- package libhdf5 as an Apple binary artifact
- make `SleapHDF5` consume that artifact
- validate the real app integration story in `sleap.swift`

Reason:

- it gives the cleanest downstream experience
- it keeps one HDF5 implementation across macOS and iPadOS
- it is easier to explain and support than a one-off static-link pipeline

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

Until portable HDF5 packaging exists:

- `sleap.swift` should not assume HDF5-backed formats are iPad-deployable
- product planning should treat HDF5 I/O on iPad as a dependency that still
  needs packaging work
- any iPad feature that depends on `.slp`, analysis HDF5, JABS, or DLC through
  `SleapHDF5` should be considered at risk until the packaging strategy is done

In other words: this is a real integration blocker, not just a cleanup item.

## Proposed Execution Plan

### Phase 1: Truth in packaging and docs

- mark HDF5-backed iPad deployment as unresolved
- keep platform language precise in public docs
- avoid release claims that imply end-to-end iPad HDF5 support

### Phase 2: XCFramework spike

- build a minimal Apple HDF5 artifact for the required targets
- prove that `SleapHDF5` can link against it in a sample iPad app
- verify one real `.slp` load path inside an app target, not just in package tests

### Phase 3: Productize

- choose artifact hosting/versioning
- wire CI around the packaged HDF5 dependency
- add at least one iPad deployment validation step before release

## Acceptance Criteria For Closing This Risk

This issue is only closed when all of the following are true:

1. `sleap.swift` can build for iPad without a developer-installed HDF5 toolchain.
2. A real HDF5-backed format is load-tested in an iPad app target.
3. The dependency story is documented for downstream teams.
4. CI can reproduce the setup.

Until then, `SleapHDF5` should be treated as macOS-validated rather than fully
iPad-ready.
