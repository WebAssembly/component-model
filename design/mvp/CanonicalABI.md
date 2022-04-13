# Canonical ABI Explainer

This explainer walks through the Canonical ABI used by [function definitions]
to convert between high-level interface-typed values and low-level Core
WebAssembly values.

* [Supporting definitions](#supporting-definitions)
  * [Despecialization](#Despecialization)
  * [Alignment](#alignment)
  * [Size](#size)
  * [Loading](#loading)
  * [Storing](#storing)
  * [Flattening](#flattening)
  * [Flat Lifting](#flat-lifting)
  * [Flat Lowering](#flat-lowering)
  * [Lifting and Lowering](#lifting-and-lowering)
* [Canonical ABI built-ins](#canonical-abi-built-ins)
  * [`canon.lift`](#canonlift)
  * [`canon.lower`](#canonlower)


## Supporting definitions

The Canonical ABI specifies, for each interface-typed function signature, a
corresponding core function signature and the process for reading
interface-typed values into and out of linear memory. While a full formal
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
OOM handling for all interface types, allowing a toolchain to intentionally
propagate OOM into the appropriate explicit return value of the function's
declared return type.


### Despecialization

[In the explainer][Type Definitions], interface types are classified as either *fundamental* or
*specialized*, where the specialized interface types are defined by expansion
into fundamental interface types. In most cases, the canonical ABI of a
specialized interface type is the same as its expansion so, to avoid
repetition, the other definitions below use the following `despecialize`
function to replace specialized interface types with their expansion:
```python
def despecialize(t):
  match t:
    case Tuple(ts)           : return Record([ Field(str(i), t) for i,t in enumerate(ts) ])
    case Unit()              : return Record([])
    case Union(ts)           : return Variant([ Case(str(i), t) for i,t in enumerate(ts) ])
    case Enum(labels)        : return Variant([ Case(l, Unit()) for l in labels ])
    case Option(t)           : return Variant([ Case("none", Unit()), Case("some", t) ])
    case Expected(ok, error) : return Variant([ Case("ok", ok), Case("error", error) ])
    case _                   : return t
```
The specialized interface types `string` and `flags` are missing from this list
because they are given specialized canonical ABI representations distinct from
their respective expansions.


### Alignment

Each interface type is assigned an [alignment] which is used by subsequent
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
    case Record(fields)     : return max_alignment(types_of(fields))
    case Variant(cases)     : return max_alignment(types_of(cases) + [discriminant_type(cases)])
    case Flags(labels)      : return alignment_flags(labels)

def types_of(fields_or_cases):
  return [x.t for x in fields_or_cases]

def max_alignment(ts):
  a = 1
  for t in ts:
    a = max(a, alignment(t))
  return a
```

As an optimization, `variant` discriminants are represented by the smallest integer
covering the number of cases in the variant. Depending on the payload type,
this can allow more compact representations of variants in memory. This smallest
integer type is selected by the following function, used above and below:
```python
def discriminant_type(cases):
  n = len(cases)
  assert(0 < n < (1 << 32))
  match math.ceil(math.log2(n)/8):
    case 0: return U8()
    case 1: return U8()
    case 2: return U16()
    case 3: return U32()
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

Each interface type is assigned two slightly-different measures of "size":
* its "byte size", which is the smallest number of bytes covering all its
  fields when stored at an aligned address in linear memory; and
* its "element size", which is the size of the type when stored as an element
  of a list, which may include additional padding at the end to ensure the
  alignment of the next element.

These two measures are defined by the following functions, which build on
the preceding alignment functions:
```python
def elem_size(t):
  return align_to(byte_size(t), alignment(t))

def align_to(ptr, alignment):
  return math.ceil(ptr / alignment) * alignment

def byte_size(t):
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
    case Record(fields)     : return byte_size_record(fields)
    case Variant(cases)     : return byte_size_variant(cases)
    case Flags(labels)      : return byte_size_flags(labels)

def byte_size_record(fields):
  s = 0
  for f in fields:
    s = align_to(s, alignment(f.t))
    s += byte_size(f.t)
  return s

def byte_size_variant(cases):
  s = byte_size(discriminant_type(cases))
  s = align_to(s, max_alignment(types_of(cases)))
  cs = 0
  for c in cases:
    cs = max(cs, byte_size(c.t))
  return s + cs

def byte_size_flags(labels):
  n = len(labels)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4 * num_i32_flags(labels)

def num_i32_flags(labels):
  return math.ceil(len(labels) / 32)
```


### Loading

The `load` function defines how to read a value of a given interface type `t`
out of linear memory starting at offset `ptr`, returning a interface-typed
value (here, as a Python value). The `Opts`/`opts` class/parameter contains the
[`canonopt`] immediates supplied as part of `canon.lift`/`canon.lower`.
Presenting the definition of `load` piecewise, we start with the top-level case
analysis:
```python
class Opts:
  string_encoding: str
  memory: bytearray
  realloc: types.FunctionType
  post_return: types.FunctionType

def load(opts, ptr, t):
  assert(ptr == align_to(ptr, alignment(t)))
  match despecialize(t):
    case Bool()         : return bool(load_int(opts, ptr, 1))
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
according to the signedness of the type:
```python
def load_int(opts, ptr, nbytes, signed = False):
  trap_if(ptr + nbytes > len(opts.memory))
  return int.from_bytes(opts.memory[ptr : ptr+nbytes], 'little', signed=signed)
```

Floats are loaded from memory and then "canonicalized", mapping all
Not-a-Number values to a single canonical `nan` bit-pattern:
```python
def reinterpret_i32_as_float(i):
  return struct.unpack('!f', struct.pack('!I', i))[0]

def reinterpret_i64_as_float(i):
  return struct.unpack('!d', struct.pack('!Q', i))[0]

def canonicalize32(f):
  if math.isnan(f):
    return reinterpret_i32_as_float(0x7fc00000)
  return f

def canonicalize64(f):
  if math.isnan(f):
    return reinterpret_i64_as_float(0x7ff8000000000000)
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

Strings can be decoded in one of three ways, according to the `string-encoding`
option in [`canonopt`]. String interface values include their original encoding
and byte length as a "hint" that enables `store_string` (defined below) to make
better up-front allocation size choices in many cases. Thus, the interface
value produced by `load_string` isn't simply a Python `str`, but a *tuple*
containing a `str`, the original encoding and the original byte length. Lastly,
the custom `latin1+utf16` encoding represents a dynamic choice between `latin1`
(when all code points fit the one-byte Latin-1 encoding) and `utf16`
(otherwise). This dynamic choice is encoded in the high bit of the `i32`
containing the string's byte length.
```python
def load_string(opts, ptr):
  begin = load_int(opts, ptr, 4)
  packed_byte_length = load_int(opts, ptr + 4, 4)
  return load_string_from_range(opts, begin, packed_byte_length)

UTF16_BIT = 1 << 31

def load_string_from_range(opts, ptr, packed_byte_length):
  match opts.string_encoding:
    case 'utf8':
      byte_length = packed_byte_length
      encoding = 'utf-8'
    case 'utf16':
      byte_length = packed_byte_length
      encoding = 'utf-16-le'
    case 'latin1+utf16':
      if bool(packed_byte_length & UTF16_BIT):
        byte_length = packed_byte_length ^ UTF16_BIT
        encoding = 'utf-16-le'
      else:
        byte_length = packed_byte_length
        encoding = 'latin-1'

  trap_if(ptr + byte_length > len(opts.memory))
  try:
    s = opts.memory[ptr : ptr+byte_length].decode(encoding)
  except UnicodeError:
    trap()

  return (s, opts.string_encoding, packed_byte_length)
```

Lists and records are loaded by recursively loading their elements/fields.
Note that lists use `elem_size` while records use `byte_size`.
```python
def load_list(opts, ptr, elem_type):
  begin = load_int(opts, ptr, 4)
  length = load_int(opts, ptr + 4, 4)
  return load_list_from_range(opts, begin, length, elem_type)

def load_list_from_range(opts, ptr, length, elem_type):
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + length * elem_size(elem_type) > len(opts.memory))
  a = []
  for i in range(length):
    a.append(load(opts, ptr + i * elem_size(elem_type), elem_type))
  return a

def load_record(opts, ptr, fields):
  record = {}
  for field in fields:
    ptr = align_to(ptr, alignment(field.t))
    record[field.label] = load(opts, ptr, field.t)
    ptr += byte_size(field.t)
  return record
```
As a technical detail: the `align_to` in the loop in `load_record` is
guaranteed to be a no-op on the first iteration because the record as
a whole starts out aligned (as asserted at the top of `load`).

Variants are loaded using the order of the cases in the type to determine the
case index. To support the subtyping allowed by `defaults-to`, a lifted variant
value semantically includes a full ordered list of its `defaults-to` case
labels so that the lowering code (defined below) can search this list to find a
case label it knows about. While the code below appears to perform case-label
lookup at runtime, a normal implementation can build the appropriate index
tables at compile-time so that variant-passing is always O(1) and not involving
string operations.
```python
def load_variant(opts, ptr, cases):
  disc_size = byte_size(discriminant_type(cases))
  disc = load_int(opts, ptr, disc_size)
  ptr += disc_size
  trap_if(disc >= len(cases))
  case = cases[disc]
  ptr = align_to(ptr, max_alignment(types_of(cases)))
  return { case_label_with_defaults(case, cases): load(opts, ptr, case.t) }

def case_label_with_defaults(case, cases):
  label = case.label
  while case.defaults_to is not None:
    case = cases[find_case(case.defaults_to, cases)]
    label += '|' + case.label
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
  i = load_int(opts, ptr, byte_size_flags(labels))
  return unpack_flags_from_int(i, labels)

def unpack_flags_from_int(i, labels):
  record = {}
  for l in labels:
    record[l] = bool(i & 1)
    i >>= 1
  trap_if(i)
  return record
```

### Storing

The `store` function defines how to write a value `v` of a given interface type
`t` into linear memory starting at offset `ptr`. Presenting the definition of
`store` piecewise, we start with the top-level case analysis:
```python
def store(opts, v, t, ptr):
  assert(ptr == align_to(ptr, alignment(t)))
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
    case Float32()      : store_int(opts, reinterpret_float_as_i32(v), ptr, 4)
    case Float64()      : store_int(opts, reinterpret_float_as_i64(v), ptr, 8)
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

Floats are stored directly into memory. Because the input domain is exactly the
set of interface values which includes only a single `nan` value (which we
assume is the canonical one), no additional runtime canonicalization is
necessary.
```python
def reinterpret_float_as_i32(f):
  return struct.unpack('!I', struct.pack('!f', f))[0]

def reinterpret_float_as_i64(f):
  return struct.unpack('!Q', struct.pack('!d', f))[0]
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
in `load_string` above, interface-typed strings come with two useful hints:
their original encoding and byte length. From this hint data, `store_string` can
do a much better job minimizing the number of reallocations.

We start with a case analysis to enumerate all the meaningful encoding
combinations, subdividing the `latin1+utf16` encoding into either `latin1` or
`utf16` based on the `UTF16_BIT` flag set by `load_string`:
```python
def store_string(opts, v, ptr):
  begin, packed_byte_length = store_string_into_range(opts, v)
  store_int(opts, begin, ptr, 4)
  store_int(opts, packed_byte_length, ptr + 4, 4)

def store_string_into_range(opts, v):
  src, src_encoding, src_packed_byte_length = v

  if src_encoding == 'latin1+utf16':
    if bool(src_packed_byte_length & UTF16_BIT):
      src_byte_length = src_packed_byte_length ^ UTF16_BIT
      src_unpacked_encoding = 'utf16'
    else:
      src_byte_length = src_packed_byte_length
      src_unpacked_encoding = 'latin1'
  else:
    src_byte_length = src_packed_byte_length
    src_unpacked_encoding = src_encoding

  match opts.string_encoding:
    case 'utf8':
      match src_unpacked_encoding:
        case 'utf8'         : return store_string_copy(opts, src, src_byte_length, 'utf-8')
        case 'utf16'        : return store_utf16_to_utf8(opts, src, src_byte_length)
        case 'latin1'       : return store_latin1_to_utf8(opts, src, src_byte_length)
    case 'utf16':
      match src_unpacked_encoding:
        case 'utf8'         : return store_utf8_to_utf16(opts, src, src_byte_length)
        case 'utf16'        : return store_string_copy(opts, src, src_byte_length, 'utf-16-le')
        case 'latin1'       : return store_string_copy(opts, src, src_byte_length, 'utf-16-le', inflation = 2)
    case 'latin1+utf16':
      match src_encoding:
        case 'utf8'         : return store_utf8_to_latin1_or_utf16(opts, src, src_byte_length)
        case 'utf16'        : return store_utf16_to_latin1_or_utf16(opts, src, src_byte_length)
        case 'latin1+utf16' :
          match src_unpacked_encoding:
            case 'latin1'   : return store_string_copy(opts, src, src_byte_length, 'latin-1')
            case 'utf16'    : return store_probably_utf16_to_latin1_or_utf16(opts, src, src_byte_length)
```

The simplest 4 cases above can compute the exact destination size and then copy
with a simply loop (that possibly inflates Latin-1 to UTF-16 by injecting a 0
byte after every Latin-1 byte).
```python
MAX_STRING_BYTE_LENGTH = (1 << 31) - 1

def store_string_copy(opts, src, src_byte_length, dst_encoding, inflation = 1):
  byte_length = src_byte_length * inflation
  trap_if(byte_length > MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 1, byte_length)
  encoded = src.encode(dst_encoding)
  assert(byte_length == len(encoded))
  opts.memory[ptr : ptr+len(encoded)] = encoded
  return (ptr, byte_length)
```
The choice of `MAX_STRING_BYTE_LENGTH` constant ensures that the high bit of a
string's byte length is never set, keeping it clear for `UTF16_BIT`.

The next 3 cases can all be mapped down to a generic transcoding algorithm that
makes an initial optimistic size allocation that falls back to a second worst-case
size reallocation that is "fixed up" at the end with a third (hopefully O(1))
shrinking reallocation.
```python
def store_utf16_to_utf8(opts, src, src_byte_length):
  optimistic_size = int(src_byte_length / 2)
  worst_case_size = optimistic_size * 3
  return store_string_transcode(opts, src, 'utf-8', optimistic_size, worst_case_size)

def store_latin1_to_utf8(opts, src, src_byte_length):
  optimistic_size = src_byte_length
  worst_case_size = optimistic_size * 2
  return store_string_transcode(opts, src, 'utf-8', optimistic_size, worst_case_size)

def store_utf8_to_utf16(opts, src, src_byte_length):
  optimistic_size = src_byte_length * 2
  worst_case_size = optimistic_size
  return store_string_transcode(opts, src, 'utf-16-le', optimistic_size, worst_case_size)

def store_string_transcode(opts, src, dst_encoding, optimistic_size, worst_case_size):
  trap_if(optimistic_size > MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 1, optimistic_size)
  encoded = src.encode(dst_encoding)
  bytes_copied = min(len(encoded), optimistic_size)
  opts.memory[ptr : ptr+bytes_copied] = encoded[0 : bytes_copied]
  if bytes_copied < optimistic_size:
    ptr = opts.realloc(ptr, optimistic_size, 1, bytes_copied)
  elif bytes_copied < len(encoded):
    trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
    ptr = opts.realloc(ptr, optimistic_size, 1, worst_case_size)
    opts.memory[ptr+bytes_copied : ptr+len(encoded)] = encoded[bytes_copied : ]
    if worst_case_size > len(encoded):
      ptr = opts.realloc(ptr, worst_case_size, 1, len(encoded))
  return (ptr, len(encoded))
```

The remaining cases handle the `latin1+utf16` encoding, where there general
goal is to fit the incoming string into Latin-1 if possible based on the code
points of the incoming string. The UTF-8 and UTF-16 cases are similar to the
preceding transcoding algorithm in that they make a best-effort optimistic
allocation, speculating that all code points *do* fit into Latin-1, before
falling back to a worst-case allocation size when a code point is found outside
Latin-1. In this fallback case, the previously-stored Latin-1 bytes are
inflated *in place*, inserting a 0 byte after every Latin-1 byte (iterating
in reverse to avoid clobbering later bytes):
```python
def store_utf8_to_latin1_or_utf16(opts, src, src_byte_length):
  optimistic_size = src_byte_length
  worst_case_size = 2 * src_byte_length
  return store_string_to_latin1_or_utf16(opts, src, optimistic_size, worst_case_size)

def store_utf16_to_latin1_or_utf16(opts, src, src_byte_length):
  optimistic_size = int(src_byte_length / 2)
  worst_case_size = src_byte_length
  return store_string_to_latin1_or_utf16(opts, src, optimistic_size, worst_case_size)

def store_string_to_latin1_or_utf16(opts, src, optimistic_size, worst_case_size):
  trap_if(optimistic_size > MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 1, optimistic_size)
  dst_byte_length = 0
  for usv in src:
    if ord(usv) < (1 << 8):
      opts.memory[ptr + dst_byte_length] = ord(usv)
      dst_byte_length += 1
    else:
      trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
      ptr = opts.realloc(ptr, optimistic_size, 1, worst_case_size)
      for j in range(dst_byte_length-1, -1, -1):
        opts.memory[ptr + 2*j] = opts.memory[ptr + j]
        opts.memory[ptr + 2*j + 1] = 0
      encoded = src.encode('utf-16-le')
      opts.memory[ptr+2*dst_byte_length : ptr+len(encoded)] = encoded[2*dst_byte_length : ]
      if worst_case_size > len(encoded):
        ptr = opts.realloc(ptr, worst_case_size, 1, len(encoded))
      return (ptr, len(encoded) | UTF16_BIT)
  if dst_byte_length < optimistic_size:
    ptr = opts.realloc(ptr, optimistic_size, 1, dst_byte_length)
  return (ptr, dst_byte_length)
```

The final string transcoding case takes advantage of the extra heuristic
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
def store_probably_utf16_to_latin1_or_utf16(opts, src, src_byte_length):
  trap_if(src_byte_length > MAX_STRING_BYTE_LENGTH)
  ptr = opts.realloc(0, 0, 1, src_byte_length)
  encoded = src.encode('utf-16-le')
  opts.memory[ptr : ptr+len(encoded)] = encoded
  if any(ord(c) >= (1 << 8) for c in src):
    return (ptr, len(encoded) | UTF16_BIT)
  latin1_size = int(len(encoded) / 2)
  for i in range(latin1_size):
    opts.memory[ptr + i] = opts.memory[ptr + 2*i]
  ptr = opts.realloc(ptr, src_byte_length, 1, latin1_size)
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
  byte_length = len(v) * elem_size(elem_type)
  trap_if(byte_length >= (1 << 32))
  ptr = opts.realloc(0, 0, alignment(elem_type), byte_length)
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + byte_length > len(opts.memory))
  for i,e in enumerate(v):
    store(opts, e, elem_type, ptr + i * elem_size(elem_type))
  return (ptr, len(v))

def store_record(opts, v, ptr, fields):
  for f in fields:
    ptr = align_to(ptr, alignment(f.t))
    store(opts, v[f.label], f.t, ptr)
    ptr += byte_size(f.t)
```

Variants are stored using the `|`-separated list of `defaults-to` cases built
by `case_label_with_default` (above) to iteratively find a matching case (which
validation guarantees will succeed). While this code appears to do O(n) string
matching, a normal implemention can statically fuse `store_variant` with its
matching `load_variant` to ultimately build a dense array that maps producer's
case indices to the consumer's case indices.
```python
def store_variant(opts, v, ptr, cases):
  case_index, case_value = match_case(v, cases)
  disc_size = byte_size(discriminant_type(cases))
  store_int(opts, case_index, ptr, disc_size)
  ptr += disc_size
  ptr = align_to(ptr, max_alignment(types_of(cases)))
  store(opts, case_value, cases[case_index].t, ptr)

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
  store_int(opts, i, ptr, byte_size_flags(labels))

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
optimization, the Canonical ABI defines `flatten` to map interface function
types to core function types by attempting to decompose all the
non-dynamically-sized interface types into core parameters and results.

For a variety of [practical][Implementation Limits] reasons, we need to limit
the total number of flattened parameters and results, falling back to storing
everything in linear memory. The number of flattened results is currently
limited to 1 due to various parts of the toolchain (notably LLVM) not yet fully
supporting [multi-value]. Hopefully this limitation is temporary and can be
lifted before the Component Model is fully standardized.

When there are too many flat values, in general, a single `i32` pointer can be
passed instead (pointing to a tuple in linear memory). When lowering *into*
linear memory, this requires the Canonical ABI to call `realloc` (in `lower`
below) to allocate space to put the tuple. As an optimization, when lowering
the return value of an imported function (lowered by `canon.lower`), the caller
can have already allocated space for the return value (e.g., efficiently on the
stack), passing in an `i32` pointer as an parameter instead of returning an
`i32` as a return value.

Given all this, the top-level definition of `flatten` is:
```python
MAX_FLAT_PARAMS = 16
MAX_FLAT_RESULTS = 1

def flatten(functype, context):
  flat_params = flatten_types(functype.params)
  if len(flat_params) > MAX_FLAT_PARAMS:
    flat_params = ['i32']

  flat_results = flatten_type(functype.result)
  if len(flat_results) > MAX_FLAT_RESULTS:
    match context:
      case 'canon.lift':
        flat_results = ['i32']
      case 'canon.lower':
        flat_params += ['i32']
        flat_results = []

  return { 'params': flat_params, 'results': flat_results }

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
    case Record(fields)       : return flatten_types(types_of(fields))
    case Variant(cases)       : return flatten_variant(cases)
    case Flags(labels)        : return ['i32'] * num_i32_flags(labels)
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
single high-level value of interface type `t`. The values are given by a value
iterator that iterates over a complete parameter or result list and asserts
that the expected and actual types line up. Presenting the definition of
`lift_flat` piecewise, we start with the top-level case analysis:
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
    case Bool()         : return bool(vi.next('i32'))
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
interface type to interpret the high-order bit. When the interface type is
narrower than an `i32`, the Canonical ABI specifies a dynamic range check in
order to catch bugs. The conversion logic here assumes that `i32` values are
always represented as unsigned Python `int`s and thus lifting to a signed type
performs a manual 2s complement conversion in the Python (which would be a
no-op in hardware).
```python
def lift_flat_unsigned(vi, core_width, t_width):
  i = vi.next('i' + str(core_width))
  assert(0 <= i < (1 << core_width))
  trap_if(i >= (1 << t_width))
  return i

def lift_flat_signed(vi, core_width, t_width):
  i = vi.next('i' + str(core_width))
  assert(0 <= i < (1 << core_width))
  if i >= (1 << (t_width - 1)):
    i -= (1 << core_width)
    trap_if(i < -(1 << (t_width - 1)))
    return i
  trap_if(i >= (1 << (t_width - 1)))
  return i
```

The contents of strings and lists are always stored in memory so lifting these
types is essentially the same as loading them from memory; the only difference
is that the pointer and length come from `i32` values instead of from linear
memory:
```python
def lift_flat_string(opts, vi):
  ptr = vi.next('i32')
  packed_byte_length = vi.next('i32')
  return load_string_from_range(opts, ptr, packed_byte_length)

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
  disc = vi.next('i32')
  trap_if(disc >= len(cases))
  case = cases[disc]
  class CoerceValueIter:
    def next(self, want):
      have = flat_types.pop(0)
      x = vi.next(have)
      match (have, want):
        case ('i32', 'f32') : return reinterpret_i32_as_float(x)
        case ('i64', 'i32') : return narrow_i64_to_i32(x)
        case ('i64', 'f32') : return reinterpret_i32_as_float(narrow_i64_to_i32(x))
        case ('i64', 'f64') : return reinterpret_i64_as_float(x)
        case _              : return x
  v = lift_flat(opts, CoerceValueIter(), case.t)
  for have in flat_types:
    _ = vi.next(have)
  return { case_label_with_defaults(case, cases): v }

def narrow_i64_to_i32(i):
  trap_if(i >= (1 << 32))
  return i
```

Finally, flags are lifted by OR-ing together all the flattened `i32` values
and then lifting to a record the same way as when loading flags from linear
memory. The dynamic checks in `unpack_flags_from_int` will trap if any
bits are set in an `i32` that don't correspond to a flag.
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

The `lower_flat` function defines how to convert a value `v` of a given
interface type `t` into zero or more core values. Presenting the definition of
`lower_flat` piecewise, we start with the top-level case analysis:
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
    case Float32()      : return [Value('f32', v)]
    case Float64()      : return [Value('f64', v)]
    case Char()         : return [Value('i32', char_to_i32(v))]
    case String()       : return lower_flat_string(opts, v)
    case List(t)        : return lower_flat_list(opts, v, t)
    case Record(fields) : return lower_flat_record(opts, v, fields)
    case Variant(cases) : return lower_flat_variant(opts, v, cases)
    case Flags(labels)  : return lower_flat_flags(v, labels)
```

Since interface-typed values are assumed to in-range and, as previously stated,
core `i32` values are always internally represented as unsigned `int`s,
unsigned interface values need no extra conversion. Signed interface values are
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
  ptr, packed_byte_length = store_string_into_range(opts, v)
  return [Value('i32', ptr), Value('i32', packed_byte_length)]

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
  payload = lower_flat(opts, case_value, cases[case_index].t)
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

### Lifting and Lowering

The `lift` function defines how to lift a list of at most `max_flat` core
parameters or results given by the `ValueIter` `vi` into a tuple of interface
values with types `ts`:
```python
def lift(opts, max_flat, vi, ts):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    ptr = vi.next('i32')
    tuple_type = Tuple(ts)
    trap_if(ptr != align_to(ptr, alignment(tuple_type)))
    return list(load(opts, ptr, tuple_type).values())
  else:
    return [ lift_flat(opts, vi, t) for t in ts ]
```

The `lower` function defines how to lower a list of interface values `vs` of
types `ts` into a list of at most `max_flat` core values. As already described
for [`flatten`](#flattening) above, lowering handles the
greater-than-`max_flat` case by either allocating storage with `realloc` or
accepting a caller-allocated buffer as an out-param:
```python
def lower(opts, max_flat, vs, ts, out_param = None):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    tuple_type = Tuple(functype.params)
    tuple_value = {str(i): v for i,v in enumerate(vs)}
    if out_param is None:
      ptr = opts.realloc(0, 0, alignment(tuple_type), byte_size(tuple_type))
    else:
      ptr = out_param.next('i32')
    trap_if(ptr != align_to(ptr, alignment(tuple_type)))
    store(opts, tuple_value, tuple_type, ptr)
    return [ Value('i32', ptr) ]
  else:
    flat_vals = []
    for i in range(len(vs)):
      flat_vals += lower_flat(opts, vs[i], ts[i])
    return flat_vals
```

## Canonical ABI built-ins

Using the above supporting definitions, we can describe the static and dynamic
semantics of [`func`], whose AST is defined in the main explainer as:
```
func     ::= (func <id>? <funcbody>)
funcbody ::= (canon.lift <functype> <canonopt>* <funcidx>)
           | (canon.lower <canonopt>* <funcidx>)
```
The following subsections define the static and dynamic semantics of each
case of `funcbody`.


### `canon.lift`

For a function:
```
(func $f (canon.lift $ft:<functype> $opts:<canonopt>* $callee:<funcidx>))
```
validation specifies:
 * `$callee` must have type `flatten($ft, 'canon.lift')`
 * `$f` is given type `$ft`

When instantiating component instance `$inst`:
* Define `$f` to be the closure `lambda args: canon_lift($opts, $inst, $callee, $ft, args)`

Thus, `$f` captures `$opts`, `$inst`, `$callee` and `$ft` in a closure which can be
subsequently exported or passed into a child instance (via `with`). If `$f`
ends up being called by the host, the host is responsible for, in a
host-defined manner, conjuring up interface values suitable for passing into
`lower` and, conversely, consuming the interface values produced by `lift`. For
example, if the host is a native JS runtime, the [JavaScript embedding] would
specify how native JavaScript values are converted to and from interface
values. Alternatively, if the host is a Unix CLI that invokes component exports
directly from the command line, the CLI could choose to automatically parse
`argv` into interface values according to the declared interface types of the
export. In any case, `canon.lift` specifies how these variously-produced
interface values are consumed as parameters (and produced as results) by a
*single host-agnostic component*.

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
def canon_lift(callee_opts, callee_instance, callee, functype, args):
  trap_if(not callee_instance.may_enter)

  assert(callee_instance.may_leave)
  callee_instance.may_leave = False
  flat_args = lower(callee_opts, MAX_FLAT_PARAMS, args, functype.params)
  callee_instance.may_leave = True

  try:
    flat_results = callee(flat_args)
  except CoreWebAssemblyException:
    trap()

  callee_instance.may_enter = False
  [result] = lift(callee_opts, MAX_FLAT_RESULTS, ValueIter(flat_results), [functype.result])
  def post_return():
    callee_instance.may_enter = True
    callee_opts.post_return()

  return (result, post_return)
```
There are a number of things to note about this definition:

Uncaught Core WebAssembly [exceptions] result in a trap at component
boundaries. Thus, if a component wishes to signal signal an error, it must
use some sort of explicit interface type such as `expected` (whose `error` case
particular language bindings may choose to map to and from exceptions).

The contract assumed by `canon_lift` (and ensured by `canon_lower` below) is
that the caller of `canon_lift` *must* call `post_return` right after lowering
`result`. This ordering ensures that the engine can reliably copy directly from
the callee's linear memory (read by `lift`) into the caller's linear memory
(written by `lower`). If `post_return` were called earlier (e.g., before
`canon_lift` returned), the callee's linear memory would have already been
freed and so the engine would need to eagerly make an intermediate copy in
`lift`.

Even assuming this `post_return` contract, if the callee could be re-entered
by the caller in the middle of the caller's `lower` (e.g., via `realloc`), then
either the engine has to make an eager intermediate copy in `lift` *or* the
Canonical ABI would have to specify a precise interleaving of side effects
which is more complicated and would inhibit some optimizations. Instead, the
`may_enter` guard set before `lift` and cleared in `post_return` prevents this
re-entrance. Thus, it is the combination of `post_return` and the re-entrance
guard that ensures `lift` does not need to make an eager copy.

The `may_leave` guard wrapping the lowering of parameters conservatively
ensures that `realloc` calls during lowering do not accidentally call imports
that accidentally re-enter the instance that lifted the same parameters.
While the `may_enter` guards of *those* component instances would also prevent
this re-entrance, it would be an error that only manifested in certain
component linking configurations, hence the eager error helps ensure
compositionality.


### `canon.lower`

For a function:
```
(func $f (canon.lower $opts:<canonopt>* $callee:<funcidx>))
```
where `$callee` has type `$ft`, validation specifies:
* `$f` is given type `flatten($ft, 'canon.lower')`

When instantiating component instance `$inst`:
* Define `$f` to be the closure: `lambda args: canon_lower($opts, $inst, $callee, $ft, args)`

Thus, from the perspective of Core WebAssembly, `$f` is a [function instance]
containing a `hostfunc` that closes over `$opts`, `$inst`, `$callee` and `$ft`
and, when called from Core WebAssembly code, calls `canon_lower`, which is defined as:
```python
def canon_lower(caller_opts, caller_instance, callee, functype, flat_args):
  trap_if(not caller_instance.may_leave)

  assert(caller_instance.may_enter)
  caller_instance.may_enter = False

  flat_args = ValueIter(flat_args)
  args = lift(caller_opts, MAX_FLAT_PARAMS, flat_args, functype.params)

  result, post_return = callee(args)

  caller_instance.may_leave = False
  flat_results = lower(caller_opts, MAX_FLAT_RESULTS, [result], [functype.result], flat_args)
  caller_instance.may_leave = True

  post_return()

  caller_instance.may_enter = True
  return flat_results
```
The definitions of `canon_lift` and `canon_lower` are mostly symmetric (swapping
lifting and lowering), with a few exceptions:
* The calling instance cannot be re-entered over the course of the entire call,
  not just while lifting the parameters. This ensures not just the needs of the
  Canonical ABI, but the general non-re-entrance expectations outlined in the
  [component invariants].
* The caller does not need a `post-return` function since the Core WebAssembly
  caller simply regains control when `canon_lower` returns, allowing it to free
  (or not) any memory passed as `flat_args`.
* When handling the too-many-flat-values case, instead of relying on `realloc`,
  the caller passs in a pointer to caller-allocated memory as a final
  `i32` parameter.

A useful consequence of the above rules for `may_enter` and `may_leave` is that
attempting to `canon.lower` to a `callee` in the same instance is a guaranteed,
immediate trap which a link-time compiler can eagerly compile to an
`unreachable`. This avoids what would otherwise be a surprising form of memory
aliasing that could introduce obscure bugs.

The net effect here is that any cross-component call necessarily
transits through a composed `canon_lower`/`canon_lift` pair, allowing a link-time
compiler to fuse the lifting/lowering steps of these two definitions into a
single, efficient trampoline. This fusion model allows efficient compilation of
the permissive [subtyping](Subtyping.md) allowed between components (including
the elimination of string operations on the labels of records and variants) as
well as post-MVP [adapter functions].


[Function Definitions]: Explainer.md#function-definitions
[`canonopt`]: Explainer.md#function-definitions
[`func`]: Explainer.md#function-definitions
[Type Definitions]: Explainer.md#type-definitions
[Component Invariants]: Explainer.md#component-invariants
[JavaScript Embedding]: Explainer.md#JavaScript-embedding
[Adapter Functions]: FutureFeatures.md#custom-abis-via-adapter-functions

[Administrative Instructions]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-instr-admin
[Implementation Limits]: https://webassembly.github.io/spec/core/appendix/implementation.html
[Function Instance]: https://webassembly.github.io/spec/core/exec/runtime.html#function-instances

[Multi-value]: https://github.com/WebAssembly/multi-value/blob/master/proposals/multi-value/Overview.md
[Exceptions]: https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md

[Alignment]: https://en.wikipedia.org/wiki/Data_structure_alignment
[Unicode Scalar Value]: https://unicode.org/glossary/#unicode_scalar_value
[Unicode Code Point]: https://unicode.org/glossary/#code_point
[Surrogate]: https://unicode.org/faq/utf_bom.html#utf16-2
