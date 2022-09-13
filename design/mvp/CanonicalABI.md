# Canonical ABI Explainer

This document defines the Canonical ABI used to convert between the values and
functions of components in the Component Model and the values and functions
of modules in Core WebAssembly.

* [Supporting definitions](#supporting-definitions)
  * [Despecialization](#Despecialization)
  * [Alignment](#alignment)
  * [Size](#size)
  * [Loading](#loading)
  * [Storing](#storing)
  * [Flattening](#flattening)
  * [Flat Lifting](#flat-lifting)
  * [Flat Lowering](#flat-lowering)
  * [Lifting and Lowering Values](#lifting-and-lowering-values)
  * [Lifting and Lowering Functions](#lifting-and-lowering-functions)
* [Canonical definitions](#canonical-definitions)
  * [`canon lift`](#canon-lift)
  * [`canon lower`](#canon-lower)
* [Canonical ABI](#canonical-abi)
  * [Canonical Module Type](#canonical-module-type)
  * [Lifting Canonical Modules](#lifting-canonical-modules)


## Supporting definitions

The Canonical ABI specifies, for each component function signature, a
corresponding core function signature and the process for reading
component-level values into and out of linear memory. While a full formal
specification would specify the Canonical ABI in terms of macro-expansion into
Core WebAssembly instructions augmented with a new set of (spec-internal)
[administrative instructions], the informal presentation here instead specifies
the process in terms of Python code that would be logically executed at
validation- and run-time by a component model implementation. The Python code
is presented by interleaving definitions with descriptions and eliding some
boilerplate. For a complete listing of all Python definitions in a single
executable file with a small unit test suite, see the
[`canonical-abi`](canonical-abi/) directory.

The convention followed by the Python code below is that all traps are raised
by explicit `trap()`/`trap_if()` calls; Python `assert()` statements should
never fire and are only included as hints to the reader. Similarly, there
should be no uncaught Python exceptions.

While the Python code appears to perform a copy as part of lifting
the contents of linear memory into high-level Python values, a normal
implementation should never need to make this extra intermediate copy.
This claim is expanded upon [below](#calling-into-a-component).

Lastly, independently of Python, the Canonical ABI defined below assumes that
out-of-memory conditions (such as `memory.grow` returning `-1` from within
`realloc`) will trap (via `unreachable`). This significantly simplifies the
Canonical ABI by avoiding the need to support the complicated protocols
necessary to support recovery in the middle of nested allocations. In the MVP,
for large allocations that can OOM, [streams](Explainer.md#TODO) would usually
be the appropriate type to use and streams will be able to explicitly express
failure in their type. Post-MVP, [adapter functions] would allow fully custom
OOM handling for all component-level types, allowing a toolchain to
intentionally propagate OOM into the appropriate explicit return value of the
function's declared return type.


### Despecialization

[In the explainer][Type Definitions], component value types are classified as
either *fundamental* or *specialized*, where the specialized value types are
defined by expansion into fundamental value types. In most cases, the canonical
ABI of a specialized value type is the same as its expansion so, to avoid
repetition, the other definitions below use the following `despecialize`
function to replace specialized value types with their expansion:
```python
def despecialize(t):
  match t:
    case Tuple(ts)         : return Record([ Field(str(i), t) for i,t in enumerate(ts) ])
    case Union(ts)         : return Variant([ Case(str(i), t) for i,t in enumerate(ts) ])
    case Enum(labels)      : return Variant([ Case(l, None) for l in labels ])
    case Option(t)         : return Variant([ Case("none", None), Case("some", t) ])
    case Result(ok, error) : return Variant([ Case("ok", ok), Case("error", error) ])
    case _                 : return t
```
The specialized value types `string` and `flags` are missing from this list
because they are given specialized canonical ABI representations distinct from
their respective expansions.


### Alignment

Each value type is assigned an [alignment] which is used by subsequent
Canonical ABI definitions. Presenting the definition of `alignment` piecewise,
we start with the top-level case analysis:
```python
def alignment(t):
  match despecialize(t):
    case Bool()             : return 1
    case S8() | U8()        : return 1
    case S16() | U16()      : return 2
    case S32() | U32()      : return 4
    case S64() | U64()      : return 8
    case Float32()          : return 4
    case Float64()          : return 8
    case Char()             : return 4
    case String() | List(_) : return 4
    case Record(fields)     : return alignment_record(fields)
    case Variant(cases)     : return alignment_variant(cases)
    case Flags(labels)      : return alignment_flags(labels)
```

Record alignment is tuple alignment, with the definitions split for reuse below:
```python
def alignment_record(fields):
  a = 1
  for f in fields:
    a = max(a, alignment(f.t))
  return a
```

As an optimization, `variant` discriminants are represented by the smallest integer
covering the number of cases in the variant. Depending on the payload type,
this can allow more compact representations of variants in memory. This smallest
integer type is selected by the following function, used above and below:
```python
def alignment_variant(cases):
  return max(alignment(discriminant_type(cases)), max_case_alignment(cases))

def discriminant_type(cases):
  n = len(cases)
  assert(0 < n < (1 << 32))
  match math.ceil(math.log2(n)/8):
    case 0: return U8()
    case 1: return U8()
    case 2: return U16()
    case 3: return U32()

def max_case_alignment(cases):
  a = 1
  for c in cases:
    if c.t is not None:
      a = max(a, alignment(c.t))
  return a
```

As an optimization, `flags` are represented as packed bit-vectors. Like variant
discriminants, `flags` use the smallest integer that fits all the bits, falling
back to sequences of `i32`s when there are more than 32 flags.
```python
def alignment_flags(labels):
  n = len(labels)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4
```


### Size

Each value type is also assigned a `size`, measured in bytes, which corresponds
the `sizeof` operator in C:
```python
def size(t):
  match despecialize(t):
    case Bool()             : return 1
    case S8() | U8()        : return 1
    case S16() | U16()      : return 2
    case S32() | U32()      : return 4
    case S64() | U64()      : return 8
    case Float32()          : return 4
    case Float64()          : return 8
    case Char()             : return 4
    case String() | List(_) : return 8
    case Record(fields)     : return size_record(fields)
    case Variant(cases)     : return size_variant(cases)
    case Flags(labels)      : return size_flags(labels)

def size_record(fields):
  s = 0
  for f in fields:
    s = align_to(s, alignment(f.t))
    s += size(f.t)
  return align_to(s, alignment_record(fields))

def align_to(ptr, alignment):
  return math.ceil(ptr / alignment) * alignment

def size_variant(cases):
  s = size(discriminant_type(cases))
  s = align_to(s, max_case_alignment(cases))
  cs = 0
  for c in cases:
    if c.t is not None:
      cs = max(cs, size(c.t))
  s += cs
  return align_to(s, alignment_variant(cases))

def size_flags(labels):
  n = len(labels)
  if n == 0: return 0
  if n <= 8: return 1
  if n <= 16: return 2
  return 4 * num_i32_flags(labels)

def num_i32_flags(labels):
  return math.ceil(len(labels) / 32)
```


### Loading

The `load` function defines how to read a value of a given value type `t`
out of linear memory starting at offset `ptr`, returning the value represented
as a Python value. The `Opts`/`opts` class/parameter contains the
[`canonopt`] immediates supplied as part of `canon lift`/`canon lower`.
Presenting the definition of `load` piecewise, we start with the top-level case
analysis:
```python
class Opts:
  string_encoding: str
  memory: bytearray
  realloc: Callable[[int,int,int,int],int]
  post_return: Callable[[],None]

def load(opts, ptr, t):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + size(t) <= len(opts.memory))
  match despecialize(t):
    case Bool()         : return convert_int_to_bool(load_int(opts, ptr, 1))
    case U8()           : return load_int(opts, ptr, 1)
    case U16()          : return load_int(opts, ptr, 2)
    case U32()          : return load_int(opts, ptr, 4)
    case U64()          : return load_int(opts, ptr, 8)
    case S8()           : return load_int(opts, ptr, 1, signed=True)
    case S16()          : return load_int(opts, ptr, 2, signed=True)
    case S32()          : return load_int(opts, ptr, 4, signed=True)
    case S64()          : return load_int(opts, ptr, 8, signed=True)
    case Float32()      : return canonicalize32(reinterpret_i32_as_float(load_int(opts, ptr, 4)))
    case Float64()      : return canonicalize64(reinterpret_i64_as_float(load_int(opts, ptr, 8)))
    case Char()         : return i32_to_char(opts, load_int(opts, ptr, 4))
    case String()       : return load_string(opts, ptr)
    case List(t)        : return load_list(opts, ptr, t)
    case Record(fields) : return load_record(opts, ptr, fields)
    case Variant(cases) : return load_variant(opts, ptr, cases)
    case Flags(labels)  : return load_flags(opts, ptr, labels)
```

Integers are loaded directly from memory, with their high-order bit interpreted
according to the signedness of the type.
```python
def load_int(opts, ptr, nbytes, signed = False):
  trap_if(ptr + nbytes > len(opts.memory))
  return int.from_bytes(opts.memory[ptr : ptr+nbytes], 'little', signed=signed)
```

Integer-to-boolean conversions treats `0` as `false` and all other bit-patterns
as `true`:
```python
def convert_int_to_bool(i):
  assert(i >= 0)
  return bool(i)
```

For reasons [given](Explainer.md#type-definitions) in the explainer, floats are
loaded from memory and then "canonicalized", mapping all Not-a-Number bit
patterns to a single canonical `nan` value.
```python
def reinterpret_i32_as_float(i):
  return struct.unpack('!f', struct.pack('!I', i))[0] # f32.reinterpret_i32

def reinterpret_i64_as_float(i):
  return struct.unpack('!d', struct.pack('!Q', i))[0] # f64.reinterpret_i64

CANONICAL_FLOAT32_NAN = 0x7fc00000
CANONICAL_FLOAT64_NAN = 0x7ff8000000000000

def canonicalize32(f):
  if math.isnan(f):
    return reinterpret_i32_as_float(CANONICAL_FLOAT32_NAN)
  return f

def canonicalize64(f):
  if math.isnan(f):
    return reinterpret_i64_as_float(CANONICAL_FLOAT64_NAN)
  return f
```

An `i32` is converted to a `char` (a [Unicode Scalar Value]) by dynamically
testing that its unsigned integral value is in the valid [Unicode Code Point]
range and not a [Surrogate]:
```python
def i32_to_char(opts, i):
  trap_if(i >= 0x110000)
  trap_if(0xD800 <= i <= 0xDFFF)
  return chr(i)
```

Strings are loaded from two `i32` values: a pointer (offset in linear memory)
and a number of bytes. There are three supported string encodings in [`canonopt`]:
[UTF-8], [UTF-16] and `latin1+utf16`. This last options allows a *dynamic*
choice between [Latin-1] and UTF-16, indicated by the high bit of the second
`i32`. String values include their original encoding and byte length as a
"hint" that enables `store_string` (defined below) to make better up-front
allocation size choices in many cases. Thus, the value produced by
`load_string` isn't simply a Python `str`, but a *tuple* containing a `str`,
the original encoding and the original byte length.
```python
def load_string(opts, ptr):
  begin = load_int(opts, ptr, 4)
  tagged_code_units = load_int(opts, ptr + 4, 4)
  return load_string_from_range(opts, begin, tagged_code_units)

UTF16_TAG = 1 << 31

def load_string_from_range(opts, ptr, tagged_code_units):
  match opts.string_encoding:
    case 'utf8':
      alignment = 1
      byte_length = tagged_code_units
      encoding = 'utf-8'
    case 'utf16':
      alignment = 2
      byte_length = 2 * tagged_code_units
      encoding = 'utf-16-le'
    case 'latin1+utf16':
      alignment = 2
      if bool(tagged_code_units & UTF16_TAG):
        byte_length = 2 * (tagged_code_units ^ UTF16_TAG)
        encoding = 'utf-16-le'
      else:
        byte_length = tagged_code_units
        encoding = 'latin-1'

  trap_if(ptr != align_to(ptr, alignment))
  trap_if(ptr + byte_length > len(opts.memory))
  try:
    s = opts.memory[ptr : ptr+byte_length].decode(encoding)
  except UnicodeError:
    trap()

  return (s, opts.string_encoding, tagged_code_units)
```

Lists and records are loaded by recursively loading their elements/fields:
```python
def load_list(opts, ptr, elem_type):
  begin = load_int(opts, ptr, 4)
  length = load_int(opts, ptr + 4, 4)
  return load_list_from_range(opts, begin, length, elem_type)

def load_list_from_range(opts, ptr, length, elem_type):
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + length * size(elem_type) > len(opts.memory))
  a = []
  for i in range(length):
    a.append(load(opts, ptr + i * size(elem_type), elem_type))
  return a

def load_record(opts, ptr, fields):
  record = {}
  for field in fields:
    ptr = align_to(ptr, alignment(field.t))
    record[field.label] = load(opts, ptr, field.t)
    ptr += size(field.t)
  return record
```
As a technical detail: the `align_to` in the loop in `load_record` is
guaranteed to be a no-op on the first iteration because the record as
a whole starts out aligned (as asserted at the top of `load`).

Variants are loaded using the order of the cases in the type to determine the
case index. To support the subtyping allowed by `refines`, a lifted variant
value semantically includes a full ordered list of its `refines` case
labels so that the lowering code (defined below) can search this list to find a
case label it knows about. While the code below appears to perform case-label
lookup at runtime, a normal implementation can build the appropriate index
tables at compile-time so that variant-passing is always O(1) and not involving
string operations.
```python
def load_variant(opts, ptr, cases):
  disc_size = size(discriminant_type(cases))
  case_index = load_int(opts, ptr, disc_size)
  ptr += disc_size
  trap_if(case_index >= len(cases))
  c = cases[case_index]
  ptr = align_to(ptr, max_case_alignment(cases))
  case_label = case_label_with_refinements(c, cases)
  if c.t is None:
    return { case_label: None }
  return { case_label: load(opts, ptr, c.t) }

def case_label_with_refinements(c, cases):
  label = c.label
  while c.refines is not None:
    c = cases[find_case(c.refines, cases)]
    label += '|' + c.label
  return label

def find_case(label, cases):
  matches = [i for i,c in enumerate(cases) if c.label == label]
  assert(len(matches) <= 1)
  if len(matches) == 1:
    return matches[0]
  return -1
```

Finally, flags are converted from a bit-vector to a dictionary whose keys are
derived from the ordered labels of the `flags` type. The code here takes
advantage of Python's support for integers of arbitrary width.
```python
def load_flags(opts, ptr, labels):
  i = load_int(opts, ptr, size_flags(labels))
  return unpack_flags_from_int(i, labels)

def unpack_flags_from_int(i, labels):
  record = {}
  for l in labels:
    record[l] = bool(i & 1)
    i >>= 1
  return record
```

### Storing

The `store` function defines how to write a value `v` of a given value type
`t` into linear memory starting at offset `ptr`. Presenting the definition of
`store` piecewise, we start with the top-level case analysis:
```python
def store(opts, v, t, ptr):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + size(t) <= len(opts.memory))
  match despecialize(t):
    case Bool()         : store_int(opts, int(bool(v)), ptr, 1)
    case U8()           : store_int(opts, v, ptr, 1)
    case U16()          : store_int(opts, v, ptr, 2)
    case U32()          : store_int(opts, v, ptr, 4)
    case U64()          : store_int(opts, v, ptr, 8)
    case S8()           : store_int(opts, v, ptr, 1, signed=True)
    case S16()          : store_int(opts, v, ptr, 2, signed=True)
    case S32()          : store_int(opts, v, ptr, 4, signed=True)
    case S64()          : store_int(opts, v, ptr, 8, signed=True)
    case Float32()      : store_int(opts, reinterpret_float_as_i32(canonicalize32(v)), ptr, 4)
    case Float64()      : store_int(opts, reinterpret_float_as_i64(canonicalize64(v)), ptr, 8)
    case Char()         : store_int(opts, char_to_i32(v), ptr, 4)
    case String()       : store_string(opts, v, ptr)
    case List(t)        : store_list(opts, v, ptr, t)
    case Record(fields) : store_record(opts, v, ptr, fields)
    case Variant(cases) : store_variant(opts, v, ptr, cases)
    case Flags(labels)  : store_flags(opts, v, ptr, labels)
```

Integers are stored directly into memory. Because the input domain is exactly
the integers in range for the given type, no extra range checks are necessary;
the `signed` parameter is only present to ensure that the internal range checks
of `int.to_bytes` are satisfied.
```python
def store_int(opts, v, ptr, nbytes, signed = False):
  trap_if(ptr + nbytes > len(opts.memory))
  opts.memory[ptr : ptr+nbytes] = int.to_bytes(v, nbytes, 'little', signed=signed)
```

Floats are stored directly into memory (in the case of NaNs, using the
32-/64-bit canonical NaN bit pattern selected by
`canonicalize32`/`canonicalize64`):
```python
def reinterpret_float_as_i32(f):
  return struct.unpack('!I', struct.pack('!f', f))[0] # i32.reinterpret_f32

def reinterpret_float_as_i64(f):
  return struct.unpack('!Q', struct.pack('!d', f))[0] # i64.reinterpret_f64
```

The integral value of a `char` (a [Unicode Scalar Value]) is a valid unsigned
`i32` and thus no runtime conversion or checking is necessary:
```python
def char_to_i32(c):
  i = ord(c)
  assert(0 <= i <= 0xD7FF or 0xD800 <= i <= 0x10FFFF)
  return i
```

Storing strings is complicated by the goal of attempting to optimize the
different transcoding cases. In particular, one challenge is choosing the
linear memory allocation size *before* examining the contents of the string.
The reason for this constraint is that, in some settings where single-pass
iterators are involved (host calls and post-MVP [adapter functions]), examining
the contents of a string more than once would require making an engine-internal
temporary copy of the whole string, which the component model specifically aims
not to do. To avoid multiple passes, the canonical ABI instead uses a `realloc`
approach to update the allocation size during the single copy. A blind
`realloc` approach would normally suffer from multiple reallocations per string
(e.g., using the standard doubling-growth strategy). However, as already shown
in `load_string` above, string values come with two useful hints: their
original encoding and byte length. From this hint data, `store_string` can do a
much better job minimizing the number of reallocations.

We start with a case analysis to enumerate all the meaningful encoding
combinations, subdividing the `latin1+utf16` encoding into either `latin1` or
`utf16` based on the `UTF16_BIT` flag set by `load_string`:
```python
def store_string(opts, v, ptr):
  begin, tagged_code_units = store_string_into_range(opts, v)
  store_int(opts, begin, ptr, 4)
  store_int(opts, tagged_code_units, ptr + 4, 4)

def store_string_into_range(opts, v):
  src, src_encoding, src_tagged_code_units = v

  if src_encoding == 'latin1+utf16':
    if bool(src_tagged_code_units & UTF16_TAG):
      src_simple_encoding = 'utf16'
      src_code_units = src_tagged_code_units ^ UTF16_TAG
    else:
      src_simple_encoding = 'latin1'
      src_code_units = src_tagged_code_units
  else:
    src_simple_encoding = src_encoding
    src_code_units = src_tagged_code_units

  match opts.string_encoding:
    case 'utf8':
      match src_simple_encoding:
        case 'utf8'         : return store_string_copy(opts, src, src_code_units, 1, 1, 'utf-8')
        case 'utf16'        : return store_utf16_to_utf8(opts, src, src_code_units)
        case 'latin1'       : return store_latin1_to_utf8(opts, src, src_code_units)
    case 'utf16':
      match src_simple_encoding:
        case 'utf8'         : return store_utf8_to_utf16(opts, src, src_code_units)
        case 'utf16'        : return store_string_copy(opts, src, src_code_units, 2, 2, 'utf-16-le')
        case 'latin1'       : return store_string_copy(opts, src, src_code_units, 2, 2, 'utf-16-le')
    case 'latin1+utf16':
      match src_encoding:
        case 'utf8'         : return store_string_to_latin1_or_utf16(opts, src, src_code_units)
        case 'utf16'        : return store_string_to_latin1_or_utf16(opts, src, src_code_units)
        case 'latin1+utf16' :
          match src_simple_encoding:
            case 'latin1'   : return store_string_copy(opts, src, src_code_units, 1, 2, 'latin-1')
            case 'utf16'    : return store_probably_utf16_to_latin1_or_utf16(opts, src, src_code_units)
```

The simplest 4 cases above can compute the exact destination size and then copy
with a simply loop (that possibly inflates Latin-1 to UTF-16 by injecting a 0
byte after every Latin-1 byte).
```python
MAX_STRING_BYTE_LENGTH = (1 << 31) - 1

def store_string_copy(opts, src, src_code_units, dst_code_unit_size, dst_alignment, dst_encoding):
  dst_byte_length = dst_code_unit_size * src_code_units
  trap_if(dst_byte_length > MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, dst_alignment, dst_byte_length)
  trap_if(ptr != align_to(ptr, dst_alignment))
  trap_if(ptr + dst_byte_length > len(opts.memory))
  encoded = src.encode(dst_encoding)
  assert(dst_byte_length == len(encoded))
  opts.memory[ptr : ptr+len(encoded)] = encoded
  return (ptr, src_code_units)
```
The choice of `MAX_STRING_BYTE_LENGTH` constant ensures that the high bit of a
string's byte length is never set, keeping it clear for `UTF16_BIT`.

The 2 cases of transcoding into UTF-8 share an algorithm that starts by
optimistically assuming that each code unit of the source string fits in a
single UTF-8 byte and then, failing that, reallocates to a worst-case size,
finishes the copy, and then finishes with a shrinking reallocation.
```python
def store_utf16_to_utf8(opts, src, src_code_units):
  worst_case_size = src_code_units * 3
  return store_string_to_utf8(opts, src, src_code_units, worst_case_size)

def store_latin1_to_utf8(opts, src, src_code_units):
  worst_case_size = src_code_units * 2
  return store_string_to_utf8(opts, src, src_code_units, worst_case_size)

def store_string_to_utf8(opts, src, src_code_units, worst_case_size):
  assert(src_code_units <= MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 1, src_code_units)
  trap_if(ptr + src_code_units > len(opts.memory))
  encoded = src.encode('utf-8')
  assert(src_code_units <= len(encoded))
  opts.memory[ptr : ptr+src_code_units] = encoded[0 : src_code_units]
  if src_code_units < len(encoded):
    trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
    ptr = opts.realloc(ptr, src_code_units, 1, worst_case_size)
    trap_if(ptr + worst_case_size > len(opts.memory))
    opts.memory[ptr+src_code_units : ptr+len(encoded)] = encoded[src_code_units : ]
    if worst_case_size > len(encoded):
      ptr = opts.realloc(ptr, worst_case_size, 1, len(encoded))
      trap_if(ptr + len(encoded) > len(opts.memory))
  return (ptr, len(encoded))
```

Converting from UTF-8 to UTF-16 performs an initial worst-case size allocation
(assuming each UTF-8 byte encodes a whole code point that inflates into a
two-byte UTF-16 code unit) and then does a shrinking reallocation at the end
if multiple UTF-8 bytes were collapsed into a single 2-byte UTF-16 code unit:
```python
def store_utf8_to_utf16(opts, src, src_code_units):
  worst_case_size = 2 * src_code_units
  trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 2, worst_case_size)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + worst_case_size > len(opts.memory))
  encoded = src.encode('utf-16-le')
  opts.memory[ptr : ptr+len(encoded)] = encoded
  if len(encoded) < worst_case_size:
    ptr = opts.realloc(ptr, worst_case_size, 2, len(encoded))
    trap_if(ptr != align_to(ptr, 2))
    trap_if(ptr + len(encoded) > len(opts.memory))
  code_units = int(len(encoded) / 2)
  return (ptr, code_units)
```

The next transcoding case handles `latin1+utf16` encoding, where there general
goal is to fit the incoming string into Latin-1 if possible based on the code
points of the incoming string. The algorithm speculates that all code points
*do* fit into Latin-1 and then falls back to a worst-case allocation size when
a code point is found outside Latin-1. In this fallback case, the
previously-copied Latin-1 bytes are inflated *in place*, inserting a 0 byte
after every Latin-1 byte (iterating in reverse to avoid clobbering later
bytes):
```python
def store_string_to_latin1_or_utf16(opts, src, src_code_units):
  assert(src_code_units <= MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 2, src_code_units)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + src_code_units > len(opts.memory))
  dst_byte_length = 0
  for usv in src:
    if ord(usv) < (1 << 8):
      opts.memory[ptr + dst_byte_length] = ord(usv)
      dst_byte_length += 1
    else:
      worst_case_size = 2 * src_code_units
      trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
      ptr = opts.realloc(ptr, src_code_units, 2, worst_case_size)
      trap_if(ptr != align_to(ptr, 2))
      trap_if(ptr + worst_case_size > len(opts.memory))
      for j in range(dst_byte_length-1, -1, -1):
        opts.memory[ptr + 2*j] = opts.memory[ptr + j]
        opts.memory[ptr + 2*j + 1] = 0
      encoded = src.encode('utf-16-le')
      opts.memory[ptr+2*dst_byte_length : ptr+len(encoded)] = encoded[2*dst_byte_length : ]
      if worst_case_size > len(encoded):
        ptr = opts.realloc(ptr, worst_case_size, 2, len(encoded))
        trap_if(ptr != align_to(ptr, 2))
        trap_if(ptr + len(encoded) > len(opts.memory))
      tagged_code_units = int(len(encoded) / 2) | UTF16_TAG
      return (ptr, tagged_code_units)
  if dst_byte_length < src_code_units:
    ptr = opts.realloc(ptr, src_code_units, 2, dst_byte_length)
    trap_if(ptr != align_to(ptr, 2))
    trap_if(ptr + dst_byte_length > len(opts.memory))
  return (ptr, dst_byte_length)
```

The final transcoding case takes advantage of the extra heuristic
information that the incoming UTF-16 bytes were intentionally chosen over
Latin-1 by the producer, indicating that they *probably* contain code points
outside Latin-1 and thus *probably* require inflation. Based on this
information, the transcoding algorithm pessimistically allocates storage for
UTF-16, deflating at the end if indeed no non-Latin-1 code points were
encountered. This Latin-1 deflation ensures that if a group of components
are all using `latin1+utf16` and *one* component over-uses UTF-16, other
components can recover the Latin-1 compression. (The Latin-1 check can be
inexpensively fused with the UTF-16 validate+copy loop.)
```python
def store_probably_utf16_to_latin1_or_utf16(opts, src, src_code_units):
  src_byte_length = 2 * src_code_units
  trap_if(src_byte_length > MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 2, src_byte_length)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + src_byte_length > len(opts.memory))
  encoded = src.encode('utf-16-le')
  opts.memory[ptr : ptr+len(encoded)] = encoded
  if any(ord(c) >= (1 << 8) for c in src):
    tagged_code_units = int(len(encoded) / 2) | UTF16_TAG
    return (ptr, tagged_code_units)
  latin1_size = int(len(encoded) / 2)
  for i in range(latin1_size):
    opts.memory[ptr + i] = opts.memory[ptr + 2*i]
  ptr = opts.realloc(ptr, src_byte_length, 1, latin1_size)
  trap_if(ptr + latin1_size > len(opts.memory))
  return (ptr, latin1_size)
```

Lists and records are stored by recursively storing their elements and
are symmetric to the loading functions. Unlike strings, lists can
simply allocate based on the up-front knowledge of length and static
element size.
```python
def store_list(opts, v, ptr, elem_type):
  begin, length = store_list_into_range(opts, v, elem_type)
  store_int(opts, begin, ptr, 4)
  store_int(opts, length, ptr + 4, 4)

def store_list_into_range(opts, v, elem_type):
  byte_length = len(v) * size(elem_type)
  trap_if(byte_length >= (1 << 32))
  ptr = opts.realloc(0, 0, alignment(elem_type), byte_length)
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + byte_length > len(opts.memory))
  for i,e in enumerate(v):
    store(opts, e, elem_type, ptr + i * size(elem_type))
  return (ptr, len(v))

def store_record(opts, v, ptr, fields):
  for f in fields:
    ptr = align_to(ptr, alignment(f.t))
    store(opts, v[f.label], f.t, ptr)
    ptr += size(f.t)
```

Variants are stored using the `|`-separated list of `refines` cases built
by `case_label_with_refinements` (above) to iteratively find a matching case (which
validation guarantees will succeed). While this code appears to do O(n) string
matching, a normal implementation can statically fuse `store_variant` with its
matching `load_variant` to ultimately build a dense array that maps producer's
case indices to the consumer's case indices.
```python
def store_variant(opts, v, ptr, cases):
  case_index, case_value = match_case(v, cases)
  disc_size = size(discriminant_type(cases))
  store_int(opts, case_index, ptr, disc_size)
  ptr += disc_size
  ptr = align_to(ptr, max_case_alignment(cases))
  c = cases[case_index]
  if c.t is not None:
    store(opts, case_value, c.t, ptr)

def match_case(v, cases):
  assert(len(v.keys()) == 1)
  key = list(v.keys())[0]
  value = list(v.values())[0]
  for label in key.split('|'):
    case_index = find_case(label, cases)
    if case_index != -1:
      return (case_index, value)
```

Finally, flags are converted from a dictionary to a bit-vector by iterating
through the case-labels of the variant in the order they were listed in the
type definition and OR-ing all the bits together. Flag lifting/lowering can be
statically fused into array/integer operations (with a simple byte copy when
the case lists are the same) to avoid any string operations in a similar manner
to variants.
```python
def store_flags(opts, v, ptr, labels):
  i = pack_flags_into_int(v, labels)
  store_int(opts, i, ptr, size_flags(labels))

def pack_flags_into_int(v, labels):
  i = 0
  shift = 0
  for l in labels:
    i |= (int(bool(v[l])) << shift)
    shift += 1
  return i
```

### Flattening

With only the definitions above, the Canonical ABI would be forced to place all
parameters and results in linear memory. While this is necessary in the general
case, in many cases performance can be improved by passing small-enough values
in registers by using core function parameters and results. To support this
optimization, the Canonical ABI defines `flatten` to map component function
types to core function types by attempting to decompose all the
non-dynamically-sized component value types into core value types.

For a variety of [practical][Implementation Limits] reasons, we need to limit
the total number of flattened parameters and results, falling back to storing
everything in linear memory. The number of flattened results is currently
limited to 1 due to various parts of the toolchain (notably the C ABI) not yet
being able to express [multi-value] returns. Hopefully this limitation is
temporary and can be lifted before the Component Model is fully standardized.

When there are too many flat values, in general, a single `i32` pointer can be
passed instead (pointing to a tuple in linear memory). When lowering *into*
linear memory, this requires the Canonical ABI to call `realloc` (in `lower`
below) to allocate space to put the tuple. As an optimization, when lowering
the return value of an imported function (via `canon lower`), the caller can
have already allocated space for the return value (e.g., efficiently on the
stack), passing in an `i32` pointer as an parameter instead of returning an
`i32` as a return value.

Given all this, the top-level definition of `flatten` is:
```python
MAX_FLAT_PARAMS = 16
MAX_FLAT_RESULTS = 1

def flatten_functype(ft, context):
  flat_params = flatten_types(ft.param_types())
  if len(flat_params) > MAX_FLAT_PARAMS:
    flat_params = ['i32']

  flat_results = flatten_types(ft.result_types())
  if len(flat_results) > MAX_FLAT_RESULTS:
    match context:
      case 'lift':
        flat_results = ['i32']
      case 'lower':
        flat_params += ['i32']
        flat_results = []

  return CoreFuncType(flat_params, flat_results)

def flatten_types(ts):
  return [ft for t in ts for ft in flatten_type(t)]
```

Presenting the definition of `flatten_type` piecewise, we start with the
top-level case analysis:
```python
def flatten_type(t):
  match despecialize(t):
    case Bool()               : return ['i32']
    case U8() | U16() | U32() : return ['i32']
    case S8() | S16() | S32() : return ['i32']
    case S64() | U64()        : return ['i64']
    case Float32()            : return ['f32']
    case Float64()            : return ['f64']
    case Char()               : return ['i32']
    case String() | List(_)   : return ['i32', 'i32']
    case Record(fields)       : return flatten_record(fields)
    case Variant(cases)       : return flatten_variant(cases)
    case Flags(labels)        : return ['i32'] * num_i32_flags(labels)
```

Record flattening simply flattens each field in sequence.
```python
def flatten_record(fields):
  flat = []
  for f in fields:
    flat += flatten_type(f.t)
  return flat
```

Variant flattening is more involved due to the fact that each case payload can
have a totally different flattening. Rather than giving up when there is a type
mismatch, the Canonical ABI relies on the fact that the 4 core value types can
be easily bit-cast between each other and defines a `join` operator to pick the
tightest approximation. What this means is that, regardless of the dynamic
case, all flattened variants are passed with the same static set of core types,
which may involve, e.g., reinterpreting an `f32` as an `i32` or zero-extending
an `i32` into an `i64`.
```python
def flatten_variant(cases):
  flat = []
  for c in cases:
    if c.t is not None:
      for i,ft in enumerate(flatten_type(c.t)):
        if i < len(flat):
          flat[i] = join(flat[i], ft)
        else:
          flat.append(ft)
  return flatten_type(discriminant_type(cases)) + flat

def join(a, b):
  if a == b: return a
  if (a == 'i32' and b == 'f32') or (a == 'f32' and b == 'i32'): return 'i32'
  return 'i64'
```

### Flat Lifting

The `lift_flat` function defines how to convert zero or more core values into a
single high-level value of type `t`. The values are given by a value iterator
that iterates over a complete parameter or result list and asserts that the
expected and actual types line up. Presenting the definition of `lift_flat`
piecewise, we start with the top-level case analysis:
```python
@dataclass
class Value:
  t: str # 'i32'|'i64'|'f32'|'f64'
  v: int|float

@dataclass
class ValueIter:
  values: [Value]
  i = 0
  def next(self, t):
    v = self.values[self.i]
    self.i += 1
    assert(v.t == t)
    return v.v

def lift_flat(opts, vi, t):
  match despecialize(t):
    case Bool()         : return convert_int_to_bool(vi.next('i32'))
    case U8()           : return lift_flat_unsigned(vi, 32, 8)
    case U16()          : return lift_flat_unsigned(vi, 32, 16)
    case U32()          : return lift_flat_unsigned(vi, 32, 32)
    case U64()          : return lift_flat_unsigned(vi, 64, 64)
    case S8()           : return lift_flat_signed(vi, 32, 8)
    case S16()          : return lift_flat_signed(vi, 32, 16)
    case S32()          : return lift_flat_signed(vi, 32, 32)
    case S64()          : return lift_flat_signed(vi, 64, 64)
    case Float32()      : return canonicalize32(vi.next('f32'))
    case Float64()      : return canonicalize64(vi.next('f64'))
    case Char()         : return i32_to_char(opts, vi.next('i32'))
    case String()       : return lift_flat_string(opts, vi)
    case List(t)        : return lift_flat_list(opts, vi, t)
    case Record(fields) : return lift_flat_record(opts, vi, fields)
    case Variant(cases) : return lift_flat_variant(opts, vi, cases)
    case Flags(labels)  : return lift_flat_flags(vi, labels)
```

Integers are lifted from core `i32` or `i64` values using the signedness of the
target type to interpret the high-order bit. When the target type is narrower
than an `i32`, the Canonical ABI ignores the unused high bits (like `load_int`).
The conversion logic here assumes that `i32` values are always represented as
unsigned Python `int`s and thus lifting to a signed type performs a manual 2s
complement conversion in the Python (which would be a no-op in hardware).
```python
def lift_flat_unsigned(vi, core_width, t_width):
  i = vi.next('i' + str(core_width))
  assert(0 <= i < (1 << core_width))
  return i % (1 << t_width)

def lift_flat_signed(vi, core_width, t_width):
  i = vi.next('i' + str(core_width))
  assert(0 <= i < (1 << core_width))
  i %= (1 << t_width)
  if i >= (1 << (t_width - 1)):
    return i - (1 << t_width)
  return i
```

The contents of strings and lists are always stored in memory so lifting these
types is essentially the same as loading them from memory; the only difference
is that the pointer and length come from `i32` values instead of from linear
memory:
```python
def lift_flat_string(opts, vi):
  ptr = vi.next('i32')
  packed_length = vi.next('i32')
  return load_string_from_range(opts, ptr, packed_length)

def lift_flat_list(opts, vi, elem_type):
  ptr = vi.next('i32')
  length = vi.next('i32')
  return load_list_from_range(opts, ptr, length, elem_type)
```

Records are lifted by recursively lifting their fields:
```python
def lift_flat_record(opts, vi, fields):
  record = {}
  for f in fields:
    record[f.label] = lift_flat(opts, vi, f.t)
  return record
```

Variants are also lifted recursively. Lifting a variant must carefully follow
the definition of `flatten_variant` above, consuming the exact same core types
regardless of the dynamic case payload being lifted. Because of the `join`
performed by `flatten_variant`, we need a more-permissive value iterator that
reinterprets between the different types appropriately and also traps if the
high bits of an `i64` are set for a 32-bit type:
```python
def lift_flat_variant(opts, vi, cases):
  flat_types = flatten_variant(cases)
  assert(flat_types.pop(0) == 'i32')
  case_index = vi.next('i32')
  trap_if(case_index >= len(cases))
  class CoerceValueIter:
    def next(self, want):
      have = flat_types.pop(0)
      x = vi.next(have)
      match (have, want):
        case ('i32', 'f32') : return reinterpret_i32_as_float(x)
        case ('i64', 'i32') : return wrap_i64_to_i32(x)
        case ('i64', 'f32') : return reinterpret_i32_as_float(wrap_i64_to_i32(x))
        case ('i64', 'f64') : return reinterpret_i64_as_float(x)
        case _              : return x
  c = cases[case_index]
  if c.t is None:
    v = None
  else:
    v = lift_flat(opts, CoerceValueIter(), c.t)
  for have in flat_types:
    _ = vi.next(have)
  return { case_label_with_refinements(c, cases): v }

def wrap_i64_to_i32(i):
  assert(0 <= i < (1 << 64))
  return i % (1 << 32)
```

Finally, flags are lifted by OR-ing together all the flattened `i32` values
and then lifting to a record the same way as when loading flags from linear
memory.
```python
def lift_flat_flags(vi, labels):
  i = 0
  shift = 0
  for _ in range(num_i32_flags(labels)):
    i |= (vi.next('i32') << shift)
    shift += 32
  return unpack_flags_from_int(i, labels)
```

### Flat Lowering

The `lower_flat` function defines how to convert a value `v` of a given type
`t` into zero or more core values. Presenting the definition of `lower_flat`
piecewise, we start with the top-level case analysis:
```python
def lower_flat(opts, v, t):
  match despecialize(t):
    case Bool()         : return [Value('i32', int(v))]
    case U8()           : return [Value('i32', v)]
    case U16()          : return [Value('i32', v)]
    case U32()          : return [Value('i32', v)]
    case U64()          : return [Value('i64', v)]
    case S8()           : return lower_flat_signed(v, 32)
    case S16()          : return lower_flat_signed(v, 32)
    case S32()          : return lower_flat_signed(v, 32)
    case S64()          : return lower_flat_signed(v, 64)
    case Float32()      : return [Value('f32', canonicalize32(v))]
    case Float64()      : return [Value('f64', canonicalize64(v))]
    case Char()         : return [Value('i32', char_to_i32(v))]
    case String()       : return lower_flat_string(opts, v)
    case List(t)        : return lower_flat_list(opts, v, t)
    case Record(fields) : return lower_flat_record(opts, v, fields)
    case Variant(cases) : return lower_flat_variant(opts, v, cases)
    case Flags(labels)  : return lower_flat_flags(v, labels)
```

Since component-level values are assumed in-range and, as previously stated,
core `i32` values are always internally represented as unsigned `int`s,
unsigned integer values need no extra conversion. Signed integer values are
converted to unsigned core `i32`s by 2s complement arithmetic (which again
would be a no-op in hardware):
```python
def lower_flat_signed(i, core_bits):
  if i < 0:
    i += (1 << core_bits)
  return [Value('i' + str(core_bits), i)]
```

Since strings and lists are stored in linear memory, lifting can reuse the
previous definitions; only the resulting pointers are returned differently
(as `i32` values instead of as a pair in linear memory):
```python
def lower_flat_string(opts, v):
  ptr, packed_length = store_string_into_range(opts, v)
  return [Value('i32', ptr), Value('i32', packed_length)]

def lower_flat_list(opts, v, elem_type):
  (ptr, length) = store_list_into_range(opts, v, elem_type)
  return [Value('i32', ptr), Value('i32', length)]
```

Records are lowered by recursively lowering their fields:
```python
def lower_flat_record(opts, v, fields):
  flat = []
  for f in fields:
    flat += lower_flat(opts, v[f.label], f.t)
  return flat
```

Variants are also lowered recursively. Symmetric to `lift_flat_variant` above,
`lower_flat_variant` must consume all flattened types of `flatten_variant`,
manually coercing the otherwise-incompatible type pairings allowed by `join`:
```python
def lower_flat_variant(opts, v, cases):
  case_index, case_value = match_case(v, cases)
  flat_types = flatten_variant(cases)
  assert(flat_types.pop(0) == 'i32')
  c = cases[case_index]
  if c.t is None:
    payload = []
  else:
    payload = lower_flat(opts, case_value, c.t)
  for i,have in enumerate(payload):
    want = flat_types.pop(0)
    match (have.t, want):
      case ('f32', 'i32') : payload[i] = Value('i32', reinterpret_float_as_i32(have.v))
      case ('i32', 'i64') : payload[i] = Value('i64', have.v)
      case ('f32', 'i64') : payload[i] = Value('i64', reinterpret_float_as_i32(have.v))
      case ('f64', 'i64') : payload[i] = Value('i64', reinterpret_float_as_i64(have.v))
      case _              : pass
  for want in flat_types:
    payload.append(Value(want, 0))
  return [Value('i32', case_index)] + payload
```

Finally, flags are lowered by slicing the bit vector into `i32` chunks:
```python
def lower_flat_flags(v, labels):
  i = pack_flags_into_int(v, labels)
  flat = []
  for _ in range(num_i32_flags(labels)):
    flat.append(Value('i32', i & 0xffffffff))
    i >>= 32
  assert(i == 0)
  return flat
```

### Lifting and Lowering Values

The `lift_values` function defines how to lift a list of at most `max_flat`
core parameters or results given by the `ValueIter` `vi` into a tuple of values
with types `ts`:
```python
def lift_values(opts, max_flat, vi, ts):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    ptr = vi.next('i32')
    tuple_type = Tuple(ts)
    trap_if(ptr != align_to(ptr, alignment(tuple_type)))
    trap_if(ptr + size(tuple_type) > len(opts.memory))
    return list(load(opts, ptr, tuple_type).values())
  else:
    return [ lift_flat(opts, vi, t) for t in ts ]
```

The `lower_values` function defines how to lower a list of component-level
values `vs` of types `ts` into a list of at most `max_flat` core values. As
already described for [`flatten`](#flattening) above, lowering handles the
greater-than-`max_flat` case by either allocating storage with `realloc` or
accepting a caller-allocated buffer as an out-param:
```python
def lower_values(opts, max_flat, vs, ts, out_param = None):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    tuple_type = Tuple(ts)
    tuple_value = {str(i): v for i,v in enumerate(vs)}
    if out_param is None:
      ptr = opts.realloc(0, 0, alignment(tuple_type), size(tuple_type))
    else:
      ptr = out_param.next('i32')
    trap_if(ptr != align_to(ptr, alignment(tuple_type)))
    trap_if(ptr + size(tuple_type) > len(opts.memory))
    store(opts, tuple_value, tuple_type, ptr)
    return [ Value('i32', ptr) ]
  else:
    flat_vals = []
    for i in range(len(vs)):
      flat_vals += lower_flat(opts, vs[i], ts[i])
    return flat_vals
```

## Canonical Definitions

Using the above supporting definitions, we can describe the static and dynamic
semantics of component-level [`canon`] definitions, which have the following
AST (copied from the [explainer][Canonical Definitions]):
```
canon     ::= (canon lift <functype> <canonopt>* <core:funcidx> (func <id>?))
            | (canon lower <canonopt>* <funcidx> (core func <id>?))
```
The following subsections cover each of these cases (which will soon be
extended to include [async](https://docs.google.com/presentation/d/1MNVOZ8hdofO3tI0szg_i-Yoy0N2QPU2C--LzVuoGSlE/edit#slide=id.g13600a23b7f_16_0)
and [resource/handle](https://github.com/alexcrichton/interface-types/blob/40f157ad429772c2b6a8b66ce7b4df01e83ae76d/proposals/interface-types/CanonicalABI.md#handle-intrinsics)
built-ins).


### `canon lift`

For a function:
```
(canon lift $ft:<functype> $opts:<canonopt>* $callee:<funcidx> (func $f))
```
validation specifies:
 * `$callee` must have type `flatten($ft, 'lift')`
 * `$f` is given type `$ft`
 * a `memory` is present if required by lifting and is a subtype of `(memory 1)`
 * a `realloc` is present if required by lifting and has type `(func (param i32 i32 i32 i32) (result i32))`
 * if a `post-return` is present, it has type `(func (param flatten($ft)['results']))`

When instantiating component instance `$inst`:
* Define `$f` to be the closure `lambda args: canon_lift($opts, $inst, $callee, $ft, args)`

Thus, `$f` captures `$opts`, `$inst`, `$callee` and `$ft` in a closure which
can be subsequently exported or passed into a child instance (via `with`). If
`$f` ends up being called by the host, the host is responsible for, in a
host-defined manner, conjuring up component values suitable for passing into
`lower` and, conversely, consuming the component values produced by `lift`. For
example, if the host is a native JS runtime, the [JavaScript embedding] would
specify how native JavaScript values are converted to and from component
values. Alternatively, if the host is a Unix CLI that invokes component exports
directly from the command line, the CLI could choose to automatically parse
`argv` into component-level values according to the declared types of the
export. In any case, `canon lift` specifies how these variously-produced values
are consumed as parameters (and produced as results) by a *single host-agnostic
component*.

The `$inst` captured above is assumed to have at least the following two fields,
which are used to implement the [component invariants]:
```python
class Instance:
  may_leave = True
  may_enter = True
  # ...
```
The `may_leave` state indicates whether the instance may call out to an import
and the `may_enter` state indicates whether the instance may be called from
the outside world through an export.

Given the above closure arguments, `canon_lift` is defined:
```python
def canon_lift(callee_opts, callee_instance, callee, ft, args, called_as_export):
  if called_as_export:
    trap_if(not callee_instance.may_enter)
    callee_instance.may_enter = False
  else:
    assert(not callee_instance.may_enter)

  assert(callee_instance.may_leave)
  callee_instance.may_leave = False
  flat_args = lower_values(callee_opts, MAX_FLAT_PARAMS, args, ft.param_types())
  callee_instance.may_leave = True

  try:
    flat_results = callee(flat_args)
  except CoreWebAssemblyException:
    trap()

  results = lift_values(callee_opts, MAX_FLAT_RESULTS, ValueIter(flat_results), ft.result_types())
  def post_return():
    if callee_opts.post_return is not None:
      callee_opts.post_return(flat_results)
    if called_as_export:
      callee_instance.may_enter = True

  return (results, post_return)
```
There are a number of things to note about this definition:

Uncaught Core WebAssembly [exceptions] result in a trap at component
boundaries. Thus, if a component wishes to signal an error, it must use some
sort of explicit type such as `result` (whose `error` case particular language
bindings may choose to map to and from exceptions).

The `called_as_export` parameter indicates whether `canon_lift` is being called
as part of a component export or whether this `canon_lift` is being called
internally (for example, by a child component instance). By clearing
`may_enter` for the duration of `canon_lift` when called as an export, the
dynamic traps ensure that components cannot be reentered, which is a [component
invariant]. Furthermore, because `may_enter` is not cleared on the exceptional
exit path taken by `trap()`, if there is a trap during Core WebAssembly
execution or lifting/lowering, the component is left permanently un-enterable,
ensuring the lockdown-after-trap [component invariant].

The contract assumed by `canon_lift` (and ensured by `canon_lower` below) is
that the caller of `canon_lift` *must* call `post_return` right after lowering
`result`. This ensures that `post_return` can be used to perform cleanup
actions after the lowering is complete.


### `canon lower`

For a function:
```
(canon lower $opts:<canonopt>* $callee:<funcidx> (core func $f))
```
where `$callee` has type `$ft`, validation specifies:
* `$f` is given type `flatten($ft, 'lower')`
 * a `memory` is present if required by lifting and is a subtype of `(memory 1)`
 * a `realloc` is present if required by lifting and has type `(func (param i32 i32 i32 i32) (result i32))`
 * there is no `post-return` in `$opts`

When instantiating component instance `$inst`:
* Define `$f` to be the closure: `lambda args: canon_lower($opts, $inst, $callee, $ft, args)`

Thus, from the perspective of Core WebAssembly, `$f` is a [function instance]
containing a `hostfunc` that closes over `$opts`, `$inst`, `$callee` and `$ft`
and, when called from Core WebAssembly code, calls `canon_lower`, which is defined as:
```python
def canon_lower(caller_opts, caller_instance, callee, ft, flat_args):
  trap_if(not caller_instance.may_leave)

  flat_args = ValueIter(flat_args)
  args = lift_values(caller_opts, MAX_FLAT_PARAMS, flat_args, ft.param_types())

  results, post_return = callee(args)

  caller_instance.may_leave = False
  flat_results = lower_values(caller_opts, MAX_FLAT_RESULTS, results, ft.result_types(), flat_args)
  caller_instance.may_leave = True

  post_return()

  return flat_results
```
The definitions of `canon_lift` and `canon_lower` are mostly symmetric (swapping
lifting and lowering), with a few exceptions:
* The caller does not need a `post-return` function since the Core WebAssembly
  caller simply regains control when `canon_lower` returns, allowing it to free
  (or not) any memory passed as `flat_args`.
* When handling the too-many-flat-values case, instead of relying on `realloc`,
  the caller pass in a pointer to caller-allocated memory as a final
  `i32` parameter.

Since any cross-component call necessarily transits through a statically-known
`canon_lower`+`canon_lift` call pair, an AOT compiler can fuse `canon_lift` and
`canon_lower` into a single, efficient trampoline. This allows efficient
compilation of the permissive [subtyping](Subtyping.md) allowed between
components (including the elimination of string operations on the labels of
records and variants) as well as post-MVP [adapter functions].

The `may_leave` flag set during lowering in `canon_lift` and `canon_lower`
ensures that the relative ordering of the side effects of `lift` and `lower`
cannot be observed via import calls and thus an implementation may reliably
interleave `lift` and `lower` whenever making a cross-component call to avoid
the intermediate copy performed by `lift`. This unobservability of interleaving
depends on the shared-nothing property of components which guarantees that all
the low-level state touched by `lift` and `lower` are disjoint. Though it
should be rare, same-component-instance `canon_lift`+`canon_lower` call pairs
are technically allowed by the above rules (and may arise unintentionally in
component reexport scenarios). Such cases can be statically distinguished by
the AOT compiler as requiring an intermediate copy to implement the above
`lift`-then-`lower` semantics.


## Canonical ABI

The above `canon` definitions are parameterized, giving each component a small
space of ABI options for interfacing with its contained core modules. Moreover,
each component can choose its ABI options independently of each other component,
with compiled adapter trampolines handling any conversions at cross-component
call boundaries. However, in some contexts, it is useful to fix a **single**,
"**canonical**" ABI that is fully determined by a given component type (which
itself is fully determined by a set of [`wit`](WIT.md) files). For example,
this allows existing Core WebAssembly toolchains to continue targeting [WASI]
by importing and exporting fixed Core Module functions signatures, without
having to add any new component-model concepts.

To support these use cases, the following section defines two new mappings:
1. `canonical-module-type : componenttype -> core:moduletype`
2. `lift-canonical-module : core:module -> component`

The `canonical-module-type` mapping defines the collection of core function
signatures that a core module must import and export to implement the given
component type via the Canonical ABI.

The `lift-canonical-module` mapping defines the runtime behavior of a core
module that has successfully implemented `canonical-module-type` by fixing
a canonical set of ABI options that are passed to the above-defined `canon`
definitions.

Together, these definitions are intended to satisfy the invariant:
```
for all m : core:module and ct : componenttype:
  module-type(m) = canonical-module-type(ct) implies ct = type-of(lift-canonical-module(m))
```
One consequence of this is that the canonical `core:moduletype` must encode
enough high-level type information for `lift-canonical-module` to be able to
reconstruct a working component. This is achieved using [name mangling]. Unlike
traditional C-family name mangling, which have a limited character set imposed
by linkers and aim to be space-efficient enough to support millions of
*internal* names, the Canonical ABI can use any valid UTF-8 string and only
needs to mangle *external* names, of which there will only be a handful.
Therefore, squeezing out every byte is a lower concern and so, for simplicity
and readability, type information is mangled using a subset of the
[`wit`](WIT.md) syntax.

One final point of note is that `lift-canonical-module` is only able to produce
a *subset* of all possible components (e.g., not covering nesting and
virtualization scenarios); to express the full variety of components, a
toolchain needs to emit proper components directly. Thus, the Canonical ABI
serves as an incremental adoption path to the full component model, allowing
existing Core WebAssembly toolchains to produce simple components simply by
emitting module imports and exports with the appropriate mangled names (e.g.,
in LLVM using the [`import_name`] and [`export_name`] attributes).


### Canonical Module Type

For the same reason that core module and component [binaries](Binary.md)
include a version number (that is intended to never change after it reaches
1.0), the Canonical ABI defines its own version that is explicitly declared by
a core module. Before reaching stable 1.0, the Canonical ABI is explicitly
allowed to make breaking changes, so this version also serves the purpose of
coordinating breaking changes in pre-1.0 tools and runtimes.
```python
CABI_VERSION = '0.1'
```
Working top-down, a canonical module type is defined by the following mapping:
```python
def canonical_module_type(ct: ComponentType) -> ModuleType:
  start_params, import_funcs = mangle_instances(ct.imports)
  start_results, export_funcs = mangle_instances(ct.exports)

  imports = []
  for name,ft in import_funcs:
    flat_ft = flatten_functype(ft, 'lower')
    imports.append(CoreImportDecl('', mangle_funcname(name, ft), flat_ft))

  exports = []
  exports.append(CoreExportDecl('cabi_memory', CoreMemoryType(initial=0, maximum=None)))
  exports.append(CoreExportDecl('cabi_realloc', CoreFuncType(['i32','i32','i32','i32'], ['i32'])))

  start_ft = FuncType(start_params, start_results)
  start_name = mangle_funcname('cabi_start{cabi=' + CABI_VERSION + '}', start_ft)
  exports.append(CoreExportDecl(start_name, flatten_functype(start_ft, 'lift')))

  for name,ft in export_funcs:
    flat_ft = flatten_functype(ft, 'lift')
    exports.append(CoreExportDecl(mangle_funcname(name, ft), flat_ft))
    if any(contains_dynamic_allocation(t) for t in ft.results):
      exports.append(CoreExportDecl('cabi_post_' + name, CoreFuncType(flat_ft.results, [])))

  return ModuleType(imports, exports)

def contains_dynamic_allocation(t):
  match despecialize(t):
    case String()       : return True
    case List(t)        : return True
    case Record(fields) : return any(contains_dynamic_allocation(f.t) for f in fields)
    case Variant(cases) : return any(contains_dynamic_allocation(c.t) for c in cases)
    case _              : return False
```
This definition starts by mangling all nested instances into the names of the
leaf fields, so that instances can be subsequently ignored. Next, each
component-level function import/export is mapped to corresponding core function
import/export with the function type mangled into the name. Additionally, each
export whose return type implies possible dynamic allocation is given a
`post-return` function so that it can deallocate after the caller reads the
return value. Lastly, all value imports and exports are concatenated into a
synthetic `cabi_start` function that is called immediately after instantiation.

For imports (which in Core WebAssembly are [two-level]), the first-level name
is set to be a zero-length string so that the entire rest of the first-level
string space is available for [shared-everything linking].

For imports and exports, the Canonical ABI assumes that `_` is not a valid
character in a component-level import/export (as is currently the case in `wit`
[identifiers](WIT.md#identifiers)) and thus can safely be used to prefix
auxiliary Canonical ABI-induced imports/exports.

#### Instance type mangling

Instance-type mangling recursively builds a dotted path string (of instance names)
that is included in the mangled core import/export name:
```python
def mangle_instances(xs, path = ''):
  values = []
  funcs = []
  for x in xs:
    name = path + x.name
    match x.t:
      case ValueType(t):
        values.append( (name, t) )
      case FuncType(params,results):
        funcs.append( (name, x.t) )
      case InstanceType(exports):
        vs,fs = mangle_instances(exports, name + '.')
        values += vs
        funcs += fs
      case TypeType(bounds):
        assert(False) # TODO: resource types
      case ComponentType(imports, exports):
        assert(False) # TODO: `canon instantiate`
      case ModuleType(imports, exports):
        assert(False) # TODO: canonical shared-everything linking
  return (values, funcs)
```
The three `TODO` cases are intended to be filled in by future PRs extending
the Canonical ABI.

#### Function type mangling

Function types are mangled into
[`wit`](WIT.md)-compatible syntax:
```python
def mangle_funcname(name, ft):
  return '{name}: func{params} -> {results}'.format(
           name = name,
           params = mangle_funcvec(ft.params, pre_space = False),
           results = mangle_funcvec(ft.results, pre_space = True))

def mangle_funcvec(es, pre_space):
  if len(es) == 1 and isinstance(es[0], ValType):
    return (' ' if not pre_space else '') + mangle_valtype(es[0])
  assert(all(type(e) == tuple and len(e) == 2 for e in es))
  mangled_elems = (e[0] + ': ' + mangle_valtype(e[1]) for e in es)
  return '(' + ', '.join(mangled_elems) + ')'

#### Value type mangling

Value types are similarly mangled into [`wit`](WIT.md)-compatible syntax,
recursively:

def mangle_valtype(t):
  match t:
    case Bool()           : return 'bool'
    case S8()             : return 's8'
    case U8()             : return 'u8'
    case S16()            : return 's16'
    case U16()            : return 'u16'
    case S32()            : return 's32'
    case U32()            : return 'u32'
    case S64()            : return 's64'
    case U64()            : return 'u64'
    case Float32()        : return 'float32'
    case Float64()        : return 'float64'
    case Char()           : return 'char'
    case String()         : return 'string'
    case List(t)          : return 'list<' + mangle_valtype(t) + '>'
    case Record(fields)   : return mangle_recordtype(fields)
    case Tuple(ts)        : return mangle_tupletype(ts)
    case Flags(labels)    : return mangle_flags(labels)
    case Variant(cases)   : return mangle_varianttype(cases)
    case Enum(labels)     : return mangle_enumtype(labels)
    case Union(ts)        : return mangle_uniontype(ts)
    case Option(t)        : return mangle_optiontype(t)
    case Result(ok,error) : return mangle_resulttype(ok,error)

def mangle_recordtype(fields):
  mangled_fields = (f.label + ': ' + mangle_valtype(f.t) for f in fields)
  return 'record { ' + ', '.join(mangled_fields) + ' }'

def mangle_tupletype(ts):
  return 'tuple<' + ', '.join(mangle_valtype(t) for t in ts) + '>'

def mangle_flags(labels):
  return 'flags { ' + ', '.join(labels) + ' }'

def mangle_varianttype(cases):
  mangled_cases = ('{label}{payload}'.format(
                     label = c.label,
                     payload = '' if c.t is None else '(' + mangle_valtype(c.t) + ')')
                   for c in cases)
  return 'variant { ' + ', '.join(mangled_cases) + ' }'

def mangle_enumtype(labels):
  return 'enum { ' + ', '.join(labels) + ' }'

def mangle_uniontype(ts):
  return 'union { ' + ', '.join(mangle_valtype(t) for t in ts) + ' }'

def mangle_optiontype(t):
  return 'option<' + mangle_valtype(t) + '>'

def mangle_resulttype(ok, error):
  match (ok, error):
    case (None, None) : return 'result'
    case (None, _)    : return 'result<_, ' + mangle_valtype(error) + '>'
    case (_, None)    : return 'result<' + mangle_valtype(ok) + '>'
    case (_, _)       : return 'result<' + mangle_valtype(ok) + ', ' + mangle_valtype(error) + '>'
```
As an example, given a component type:
```wasm
(component
  (import "foo" (func))
  (import "a" (instance
    (export "bar" (func (param "x" u32) (param "y" u32) (result u32)))
  ))
  (import "v1" (value string))
  (export "baz" (func (param string) (result string)))
  (export "v2" (value list<list<string>>))
)
```
the `canonical_module_type` would be:
```wasm
(module
  (import "" "foo: func() -> ()" (func))
  (import "" "a.bar: func(x: u32, y: u32) -> u32" (func param i32 i32) (result i32))
  (export "cabi_memory" (memory 0))
  (export "cabi_realloc" (func (param i32 i32 i32 i32) (result i32)))
  (export "cabi_start{cabi=0.1}: func(v1: string) -> (v2: list<list<string>>)" (func (param i32 i32) (result i32)))
  (export "baz: func string -> string" (func (param i32 i32) (result i32)))
  (export "cabi_post_baz" (func (param i32)))
)
```

### Lifting Canonical Modules

TODO

```python
class Module:
  t: ModuleType
  instantiate: Callable[typing.List[typing.Tuple[str,str,Value]], typing.List[typing.Tuple[str,Value]]]

class Component:
  t: ComponentType
  instantiate: Callable[typing.List[typing.Tuple[str,any]], typing.List[typing.Tuple[str,any]]]

def lift_canonical_module(module: Module) -> Component:
  # TODO: define component.instantiate by:
  #  1. creating canonical import adapters
  #  2. creating a core module instance that imports (1)
  #  3. creating canonical export adapters from the exports of (2)
  pass
```



[Canonical Definitions]: Explainer.md#canonical-definitions
[`canonopt`]: Explainer.md#canonical-definitions
[`canon`]: Explainer.md#canonical-definitions
[Type Definitions]: Explainer.md#type-definitions
[Component Invariants]: Explainer.md#component-invariants
[JavaScript Embedding]: Explainer.md#JavaScript-embedding
[Adapter Functions]: FutureFeatures.md#custom-abis-via-adapter-functions
[Shared-Everything Linking]: examples/SharedEverythingLinking.md

[Administrative Instructions]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-instr-admin
[Implementation Limits]: https://webassembly.github.io/spec/core/appendix/implementation.html
[Function Instance]: https://webassembly.github.io/spec/core/exec/runtime.html#function-instances
[Two-level]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-import

[Multi-value]: https://github.com/WebAssembly/multi-value/blob/master/proposals/multi-value/Overview.md
[Exceptions]: https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md
[WASI]: https://github.com/webassembly/wasi

[Alignment]: https://en.wikipedia.org/wiki/Data_structure_alignment
[UTF-8]: https://en.wikipedia.org/wiki/UTF-8
[UTF-16]: https://en.wikipedia.org/wiki/UTF-16
[Latin-1]: https://en.wikipedia.org/wiki/ISO/IEC_8859-1
[Unicode Scalar Value]: https://unicode.org/glossary/#unicode_scalar_value
[Unicode Code Point]: https://unicode.org/glossary/#code_point
[Surrogate]: https://unicode.org/faq/utf_bom.html#utf16-2
[Name Mangling]: https://en.wikipedia.org/wiki/Name_mangling

[`import_name`]: https://clang.llvm.org/docs/AttributeReference.html#import-name
[`export_name`]: https://clang.llvm.org/docs/AttributeReference.html#export-name
