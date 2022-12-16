# Subtyping

TODO: write this up in more detail.

But roughly speaking:

| Type                      | Subtyping |
| ------------------------- | --------- |
| `bool`                    | |
| `s8`, `s16`, `s32`, `s64`, `u8`, `u16`, `u32`, `u64` | lossless coercions are allowed |
| `float32`, `float64`      | `float32 <: float64` |
| `char`                    | |
| `record`                  | fields can be reordered; covariant field payload subtyping; superfluous fields can be ignored in the subtype; `option` fields can be ignored in the supertype |
| `variant`                 | cases can be reordered; covariant case payload subtyping; superfluous cases can be ignored in the supertype; `refines` cases can be ignored in the subtype |
| `list`                    | covariant element subtyping |
| `tuple`                   | `(tuple T ...) <: T` |
| `option`                  | `T <: (option T)` |
| `expected`                | `T <: (expected T _)` |
| `union`                   | `T <: (union ... T ...)` |
| `own`, `borrow`           | none (although resource subtyping may be introduced in the future which would imply handle subtyping) |
| `func`                    | parameter names must match in order; contravariant parameter subtyping; superfluous parameters can be ignored in the subtype; `option` parameters can be ignored in the supertype; covariant result subtyping |
| `component`               | all imports in the subtype must be present in the supertype with matching types; all exports in the supertype must be present in the subtype; the `URL` is treated as the complete name, when present, ignoring the `name` field |

The remaining specialized value types inherit their subtyping from their
fundamental value types.
