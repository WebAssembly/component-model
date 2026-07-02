# Flat-calling-convention treatment of fixed-length and bounded lists

## Background

The canonical ABI flattens component-level values into Wasm core function
parameters.  A `MAX_FLAT` cap (currently 16 in the spec, 4 used here for
illustration) limits how many flat slots a call may use before everything is
redirected through a *param-area* (a caller-allocated memory block whose
pointer is passed in r0).

The current implementation flattens fixed-length lists element-by-element
(`list<T, N>` → N flat slots) and bounded lists with a leading length register
(`list<T, ..N>` → 1 + N flat slots). This is wasteful in several ways.

A key property of fixed and bounded lists is that they can be passed without
additional allocations beyond the param area itself: because the maximum byte
count is statically known from the type, the caller can reserve space inline
rather than performing a separate heap allocation.

## Why the current strategy is problematic

### Semantic mismatch

List element access is indexed by a **runtime value**.  Even if all elements
arrive in registers, the callee must immediately spill them to memory before it
can iterate or index, because registers are not addressable.  Tuples do not
have this problem — each field is a compile-time-known register slot.

Passing list elements in registers therefore adds round-trip spill cost with no
benefit.

### Budget poisoning

When the flat slots for a list exceed `MAX_FLAT`, the ABI falls back to the
classic all-params-to-param-area strategy: **all** arguments, including simple
scalars that would fit comfortably in registers, are bundled into the param
area and only a single pointer is passed.  The list causes unrelated arguments
to pay an indirection penalty.

Example: `f(list<s32, 4>, s32)` needs 5 slots (4 elements + 1 scalar).  With
`MAX_FLAT=4` the scalar ends up in memory alongside the list — even though
there was a free register waiting for it.

## Proposal

Allow list elements to occupy the **param area** without consuming flat-register slots.

- Fixed list: **0** flat slots; list elements are stored in the param area
  (if no param area is required by other arguments, one is created and the
  elements occupy it starting at offset 0).
- Bounded list: **0** flat slots; a varint length prefix followed by the list
  elements are stored in the param area (if no param area is required by other
  arguments, one is created, with the varint prefix at offset 0 followed by the
  elements).
- After processing all typed arguments, if a param area is needed, one
  additional flat slot (`PAP_ptr`) is appended to the flat list.
- If the total flat slots now exceed `MAX_FLAT`, fall back to the classic
  all-params-to-param-area strategy (r0 = `PAP_ptr`, everything in the param
  area) for backward compatibility.

Benefits: scalar arguments that fit within `MAX_FLAT` stay in registers even
when a list is present.  Both fixed and bounded lists use the same in-memory
layout (`elements` for fixed, `varint | elements` for bounded) whether they
appear as top-level flat arguments or as elements of an outer fixed/bounded
list — the representation composes uniformly.  
Cost: the extra `PAP_ptr` slot can tip the budget when many scalar arguments
accompany a list, at which point the classic fallback fires.

### Scope and resolved edge cases

The bullets above describe top-level list arguments; the following rules pin
down the remaining cases. An argument (or result) is routed to the param area
iff its type *transitively contains* a fixed- or bounded-length list, where
"transitively contains" is evaluated by the `is_forced_to_mem` predicate.

- **Aggregates are passed by memory as a whole.** A `record`, `variant`, or
  `tuple` that contains a fixed/bounded list anywhere in its (transitive)
  structure is itself placed in the param area in its entirety, using its
  ordinary canonical in-memory layout — its non-list fields are *not* split off
  into flat registers. This keeps placement a per-top-level-argument decision
  and avoids threading param-area bookkeeping through aggregate flattening.

- **The `is_forced_to_mem` test stops at `string` and unbounded-`list`
  boundaries.** Those types are already passed indirectly (a pointer into a
  separate allocation), so a sized list nested *behind* one of them does not
  inflate the flat signature and does not force the enclosing value into the
  param area. For example, `f(record { x: list<list<s32, 3>> })` stays flat:
  the outer unbounded list is passed as its usual `(pointer, length)` pair, and
  the inner fixed lists live in that list's heap allocation.

- **No special case for length-1 lists.** A `list<T, 1>` is passed via the
  param area like any other sized list, even though it happens to flatten to a
  single slot. The placement rule is based purely on the type constructor, not
  on the flattened slot count.

- **Results are treated symmetrically.** A result whose type transitively
  contains a fixed/bounded list is returned via memory (a return-value
  pointer), regardless of its flattened size. Because the flattened-results
  budget is only one slot, the only sized list that could otherwise have been
  returned in a register would be a length-1 fixed list — which, per the
  previous point, is not special-cased and so also goes through memory. There
  is therefore no "hybrid" arrangement for results (a single result is either
  entirely flat or entirely in memory).

- **Async pointer ordering.** For an `async`-lowered call, the trailing
  pointers appear in the order `[flat params…, PAP_ptr, result-out-ptr]`: the
  param-area pointer precedes the return-value pointer.

## Comparison table (MAX_FLAT = 4)

PAP = param-area pointer.  List elements are stored in the param area (created
if not yet needed, with elements starting at offset 0; bounded lists prepend a
varint length prefix).  
⚡ = classic fallback triggered; r0 = PAP_ptr, all args stored in the param area
using canonical memory layout (bounded list: varint prefix + elements).

| # | Function | Cur r0 | r1 | r2 | r3 | Cur PAP | New r0 | r1 | r2 | r3 | New PAP |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `f(list<s32,3>)` | lst[0] | lst[1] | lst[2] | — | — | PAP | — | — | — | [lst[0..2]] |
| 2 | `f(list<s32,3>, s32)` | lst[0] | lst[1] | lst[2] | arg | — | arg | PAP | — | — | [lst[0..2]] |
| 3 | `f(list<s32,3>, s32, s32)` ⚡ | PAP | — | — | — | [lst[0..2],arg0,arg1] | arg0 | arg1 | PAP | — | [lst[0..2]] |
| 4 | `f(list<s32,4>)` | lst[0] | lst[1] | lst[2] | lst[3] | — | PAP | — | — | — | [lst[0..3]] |
| 5 | `f(list<s32,4>, s32)` ⚡ | PAP | — | — | — | [lst[0..3],arg] | arg | PAP | — | — | [lst[0..3]] |
| 6 | `f(list<s32,5>)` ⚡ | PAP | — | — | — | [lst[0..4]] | PAP | — | — | — | [lst[0..4]] |
| 7 | `f(list<s32,..3>)` | len | lst[0] | lst[1] | lst[2] | — | PAP | — | — | — | [varint,lst[0..2]] |
| 8 | `f(list<s32,..3>, s32)` ⚡ | PAP | — | — | — | [varint,lst[0..2],arg] | arg | PAP | — | — | [varint,lst[0..2]] |
| 9 | `f(list<s32,..4>)` ⚡ | PAP | — | — | — | [varint,lst[0..3]] | PAP | — | — | — | [varint,lst[0..3]] |
| 10 | `f(list<s32,..3>, s32, s32, s32)` ⚡ | PAP | — | — | — | [varint,lst[0..2],s32×3] | s32 | s32 | s32 | PAP | [varint,lst[0..2]] |
| 11 | `f(list<s32,..3>, s32, s32, s32, s32)` ⚡ | PAP | — | — | — | [varint,lst[0..2],s32×4] | ⚡PAP | — | — | — | [varint,lst[0..2],s32×4] |

Row 10 shows a key improvement: with bounded lists carrying 0 flat slots,
`3×s32 + PAP_ptr = 4` fits exactly within `MAX_FLAT`, so the scalars stay in
registers with no fallback needed.  Row 11 shows where the cap is hit:
`4×s32 + PAP_ptr = 5 > 4` triggers the fallback, and the layout collapses to
the classic all-in-PAP strategy.

## Open questions

1. Can the PAP_ptr overhead (one extra slot whenever any list is present) still
   cause frequent fallback with real signatures that have many scalar arguments
   alongside a list?
2. Should a maximum value for `maxlen` be specified in the binary format?
   The current grammar already excludes 0 via `(if maxlen > 0)` and the
   unsigned `<u32>` encoding, but no upper bound is set.
