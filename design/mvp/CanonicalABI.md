# Canonical ABI Explainer

This document defines the Canonical ABI used to convert between the values and
functions of components in the Component Model and the values and functions
of modules in Core WebAssembly. See the [AST explainer](Explainer.md) for a
walkthrough of the static structure of a component and the
[async explainer](Async.md) for a high-level description of the async model
being specified here.

* [Supporting definitions](#supporting-definitions)
  * [Despecialization](#despecialization)
  * [Alignment](#alignment)
  * [Element Size](#element-size)
  * [Call Context](#call-context)
  * [Canonical ABI Options](#canonical-abi-options)
  * [Runtime State](#runtime-state)
  * [Loading](#loading)
  * [Storing](#storing)
  * [Flattening](#flattening)
  * [Flat Lifting](#flat-lifting)
  * [Flat Lowering](#flat-lowering)
  * [Lifting and Lowering Values](#lifting-and-lowering-values)
* [Canonical definitions](#canonical-definitions)
  * [`canon lift`](#canon-lift)
  * [`canon lower`](#canon-lower)
  * [`canon resource.new`](#canon-resourcenew)
  * [`canon resource.drop`](#canon-resourcedrop)
  * [`canon resource.rep`](#canon-resourcerep)
  * [`canon task.backpressure`](#-canon-taskbackpressure) 🔀
  * [`canon task.start`](#-canon-taskstart) 🔀
  * [`canon task.return`](#-canon-taskreturn) 🔀
  * [`canon task.wait`](#-canon-taskwait) 🔀
  * [`canon task.poll`](#-canon-taskpoll) 🔀
  * [`canon task.yield`](#-canon-taskyield) 🔀


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
for large allocations that can OOM, [streams](Async.md#todo) would usually
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
    case F32()              : return 4
    case F64()              : return 8
    case Char()             : return 4
    case String() | List(_) : return 4
    case Record(fields)     : return alignment_record(fields)
    case Variant(cases)     : return alignment_variant(cases)
    case Flags(labels)      : return alignment_flags(labels)
    case Own(_) | Borrow(_) : return 4
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
covering the number of cases in the variant (with cases numbered in order from
`0` to `len(cases)-1`). Depending on the payload type, this can allow more
compact representations of variants in memory. This smallest integer type is
selected by the following function, used above and below:
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

Handle types are passed as `i32` indices into the `Table[HandleElem]`
introduced below.


### Element Size

Each value type is also assigned an `elem_size` which is the number of bytes
used when values of the type are stored as elements of a `list`. Having this
byte size be a static property of the type instead of attempting to use a
variable-length element-encoding scheme both simplifies the implementation and
maps well to languages which represent `list`s as random-access arrays. Empty
types, such as records with no fields, are not permitted, to avoid
complications in source languages.
```python
def elem_size(t):
  match despecialize(t):
    case Bool()             : return 1
    case S8() | U8()        : return 1
    case S16() | U16()      : return 2
    case S32() | U32()      : return 4
    case S64() | U64()      : return 8
    case F32()              : return 4
    case F64()              : return 8
    case Char()             : return 4
    case String() | List(_) : return 8
    case Record(fields)     : return elem_size_record(fields)
    case Variant(cases)     : return elem_size_variant(cases)
    case Flags(labels)      : return elem_size_flags(labels)
    case Own(_) | Borrow(_) : return 4

def elem_size_record(fields):
  s = 0
  for f in fields:
    s = align_to(s, alignment(f.t))
    s += elem_size(f.t)
  assert(s > 0)
  return align_to(s, alignment_record(fields))

def align_to(ptr, alignment):
  return math.ceil(ptr / alignment) * alignment

def elem_size_variant(cases):
  s = elem_size(discriminant_type(cases))
  s = align_to(s, max_case_alignment(cases))
  cs = 0
  for c in cases:
    if c.t is not None:
      cs = max(cs, elem_size(c.t))
  s += cs
  return align_to(s, alignment_variant(cases))

def elem_size_flags(labels):
  n = len(labels)
  assert(n > 0)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4 * num_i32_flags(labels)

def num_i32_flags(labels):
  return math.ceil(len(labels) / 32)
```

### Call Context

The subsequent definitions of loading and storing a value from linear memory
require additional configuration and state, which is threaded through most
subsequent definitions via the `cx` parameter of type `CallContext`:
```python
@dataclass
class CallContext:
  opts: CanonicalOptions
  inst: ComponentInstance
```
Note that the `Task` and `Subtask` classes defined below derive `CallContext`,
adding additional state only used for export and import calls, resp.

### Canonical ABI Options

The `opts` field of `CallContext` contains all the possible `canonopt`
immediates that can be passed to the `canon` definition being implemented.
```python
@dataclass
class CanonicalOptions:
  memory: Optional[bytearray] = None
  string_encoding: Optional[str] = None
  realloc: Optional[Callable] = None
  post_return: Optional[Callable] = None
  sync: bool = True # = !canonopt.async
  callback: Optional[Callable] = None
```
(Note that the `async` `canonopt` is inverted to `sync` here for the practical
reason that `async` is a keyword and most branches below want to start with the
`sync = True` case.)

### Runtime State

The `inst` field of `CallContext` points to the component instance which the
`canon`-generated function is closed over. Component instances contain all the
core wasm instance as well as some extra state that is used exclusively by the
Canonical ABI:
```python
class ComponentInstance:
  # core module instance state
  may_leave: bool
  handles: HandleTables
  num_tasks: int
  backpressure: bool
  calling_sync_import: bool
  pending_tasks: list[asyncio.Future]
  active_sync_task: bool
  pending_sync_tasks: list[asyncio.Future]
  async_subtasks: Table[AsyncSubtask]

  def __init__(self):
    self.may_leave = True
    self.handles = HandleTables()
    self.num_tasks = 0
    self.backpressure = False
    self.calling_sync_import = False
    self.pending_tasks = []
    self.active_sync_task = False
    self.pending_sync_tasks = []
    self.async_subtasks = Table[AsyncSubtask]()
```
The `may_leave` field is used below to track whether the instance may call a
lowered import to prevent optimization-breaking cases of reentrance during
lowering.

The `handles` field contains a mapping from `ResourceType` to `Table`s of
`HandleElem`s (defined next), establishing a separate `i32`-indexed array per
resource type.

The `backpressure` and `pending_tasks` fields are used below to implement
backpressure that is applied when new export calls create new `Task`s in this
`ComponentInstance`. The `num_tasks` field tracks the number of live `Task`s in
this `ComponentInstance` and is primarily used to guard that a component
doesn't enter an invalid state where `backpressure` enabled but there are no
live tasks to disable it.

The `calling_sync_import` flag also triggers backpressure when a component is
in the middle of a synchronous import call and does not expect to be reentered.

The `active_sync_task` and `pending_sync_tasks` fields are similarly used to
serialize synchronously-lifted calls into this component instance.

The `async_subtasks` field is used below to track and assign an `i32` index to
each active async-lowered call in progress that has been made by this
`ComponentInstance`.

One `HandleTables` object is stored per `ComponentInstance` and is defined as:
```python
class HandleTables:
  rt_to_table: MutableMapping[ResourceType, Table[HandleElem]]

  def __init__(self):
    self.rt_to_table = dict()

  def table(self, rt):
    if rt not in self.rt_to_table:
      self.rt_to_table[rt] = Table[HandleElem]()
    return self.rt_to_table[rt]

  def get(self, rt, i):
    return self.table(rt).get(i)
  def add(self, rt, h):
    return self.table(rt).add(h)
  def remove(self, rt, i):
    return self.table(rt).remove(i)
```
While this Python code performs a dynamic hash-table lookup on each handle
table access, as we'll see below, the `rt` parameter is always statically known
such that a normal implementation can statically enumerate all `Table` objects
at compile time and then route the calls to `get`, `add` and `remove` to the
correct `Table` at the callsite. The net result is that each component instance
will contain one handle table per resource type used by the component, with
each compiled adapter function accessing the correct handle table as-if it were
a global variable.

The `ResourceType` class represents a concrete resource type that has been
created by the component instance `impl`. `ResourceType` objects are used as
keys by `HandleTables` above and thus we assume that Python object identity
corresponds to resource type equality, as defined by [type checking] rules.
```python
class ResourceType(Type):
  impl: ComponentInstance
  dtor: Optional[Callable]
  dtor_sync: bool
  dtor_callback: Optional[Callable]

  def __init__(self, impl, dtor = None, dtor_sync = True, dtor_callback = None):
    self.impl = impl
    self.dtor = dtor
    self.dtor_sync = dtor_sync
    self.dtor_callback = dtor_callback
```
The `Table` class, used by `HandleTables` above, encapsulates a single
mutable, growable array of generic elements, indexed by Core WebAssembly
`i32`s.
```python
ElemT = TypeVar('ElemT')
class Table(Generic[ElemT]):
  array: list[Optional[ElemT]]
  free: list[int]

  def __init__(self):
    self.array = [None]
    self.free = []

  def get(self, i):
    trap_if(i >= len(self.array))
    trap_if(self.array[i] is None)
    return self.array[i]

  def add(self, e):
    if self.free:
      i = self.free.pop()
      assert(self.array[i] is None)
      self.array[i] = e
    else:
      i = len(self.array)
      trap_if(i >= 2**30)
      self.array.append(e)
    return i

  def remove(self, i):
    e = self.get(i)
    self.array[i] = None
    self.free.append(i)
    return e
```
`Table` maintains a dense array of elements that can contain holes created by
the `remove` method (defined below). When table elements are accessed (e.g., by
`canon_lift` and `resource.rep`, below), there are thus both a bounds check and
hole check necessary. Upon initialization, table element `0` is allocated and
set to `None`, effectively reserving index `0` which is both useful for
catching null/uninitialized accesses and allowing `0` to serve as a sentinel
value.

The `add` and `remove` methods work together to maintain a free list of holes
that are used in preference to growing the table. The free list is represented
as a Python list here, but an optimizing implementation could instead store the
free list in the free elements of `array`.

The limit of `2**30` ensures that the high 2 bits of table indices are unset
and available for other use in guest code (e.g., for tagging, packed words or
sentinel values).

The `HandleElem` class defines the elements of the per-resource-type `Table`s
stored in `HandleTables`:
```python
class HandleElem:
  rep: int
  own: bool
  scope: Optional[Task]
  lend_count: int

  def __init__(self, rep, own, scope = None):
    self.rep = rep
    self.own = own
    self.scope = scope
    self.lend_count = 0
```
The `rep` field of `HandleElem` stores the resource representation (currently
fixed to be an `i32`) passed to `resource.new`.

The `own` field indicates whether this element was created from an `own` type
(or, if false, a `borrow` type).

The `scope` field stores the `Task` that created the borrowed handle. When a
component only uses sync-lifted exports, due to lack of reentrance, there is at
most one `Task` alive in a component instance at any time and thus an
optimizing implementation doesn't need to store the `Task` per `HandleElem`.

The `lend_count` field maintains a conservative approximation of the number of
live handles that were lent from this `own` handle (by calls to `borrow`-taking
functions). This count is maintained by the `ImportCall` bookkeeping functions
(above) and is ensured to be zero when an `own` handle is dropped.

An optimizing implementation can enumerate the canonical definitions present
in a component to statically determine that a given resource type's handle
table only contains `own` or `borrow` handles and then, based on this,
statically eliminate the `own` and the `lend_count` xor `scope` fields,
and guards thereof.

Additional runtime state is required to implement the canonical built-ins and
check that callers and callees uphold their respective parts of the call
contract. This additional call state derives from `CallContext`, adding extra
mutable fields. There are two subclasses of `CallContext`: `Task`, which is
created by `canon_lift` and `Subtask`, which is created by `canon_lower`.
Additional sync-/async-specialized mutable state is added by the `SyncTask`,
`AsyncTask` and `AsyncSubtask` subclasses.

The `Task` class and its subclasses depend on the following two enums:
```python
class AsyncCallState(IntEnum):
  STARTING = 0
  STARTED = 1
  RETURNED = 2
  DONE = 3

class EventCode(IntEnum):
  CALL_STARTING = AsyncCallState.STARTING
  CALL_STARTED = AsyncCallState.STARTED
  CALL_RETURNED = AsyncCallState.RETURNED
  CALL_DONE = AsyncCallState.DONE
  YIELDED = 4
```
The `AsyncCallState` enum describes the linear sequence of states that an async
call necessarily transitions through: [`STARTING`](Async.md#starting),
`STARTED`, [`RETURNING`](Async.md#returning) and `DONE`. The `EventCode` enum
shares common code values with `AsyncCallState` to define the set of integer
event codes that are delivered to [waiting](Async.md#waiting) or polling tasks.

The `current_Task` global holds an `asyncio.Lock` that is used to prevent the
Python runtime from arbitrarily switching between Python coroutines (`async
def` functions). Instead, switching between execution can only happen at
specific points where the `current_task` lock is released and reacquired (viz.,
`Task.suspend` and `Task.exit` below). Without this lock, Python's normal async
scheduler would be able to switch between concurrent `Task`s at *every*
spec-internal `await`, which would end up looking like preemptive
multi-threading to guest code. Alternatively, if Python had standard-library
[fibers], fibers could be used instead of `asyncio`, obviating the need for
this lock.
```python
current_task = asyncio.Lock()
```

A `Task` object is created for each call to `canon_lift` and is implicitly
threaded through all core function calls. This implicit `Task` parameter
specifies a concept of [the current task](Async.md#current-task) and inherently
scopes execution of all core wasm (including `canon`-defined core functions) to
a `Task`.
```python
class Task(CallContext):
  caller: Optional[Task]
  on_block: Optional[Callable]
  borrow_count: int
  events: asyncio.Queue[AsyncSubtask]
  num_async_subtasks: int

  def __init__(self, opts, inst, caller, on_block):
    super().__init__(opts, inst)
    assert(on_block is not None)
    self.caller = caller
    self.on_block = on_block
    self.borrow_count = 0
    self.events = asyncio.Queue[AsyncSubtask]()
    self.num_async_subtasks = 0
```
The fields of `Task` are only accessed by the methods of `Task` and are
introduced in groups of related `Task`-methods next. Using a conservative
syntactic analysis of the component-level definitions of a linked component
DAG, an optimizing implementation can statically eliminate these fields when
the particular feature (`borrow` handles, `async` imports) is not used.

The `enter()` method is called immediately after constructing the `Task` and is
responsible for preventing reentrance and implementing backpressure:
```python
  async def enter(self):
    assert(current_task.locked())
    self.trap_if_on_the_stack(self.inst)
    self.inst.num_tasks += 1
    if not self.may_enter() or self.inst.pending_tasks:
      f = asyncio.Future()
      self.inst.pending_tasks.append(f)
      await self.suspend(f)
      assert(self.may_enter())
```

The `caller` field is immutable and is either `None`, when a `Task` is created
for a component export called directly by the host, or else the current task
when the calling component called into this component. The `trap_if_on_the_stack`
method (called by `enter` above) uses `caller` to prevent a component from
being reentered (enforcing the [component invariant]) in a way that is
well-defined even in the presence of async calls. Having a `caller` depends on
having an async call tree which in turn depends on maintaining
[structured concurrency].
```python
  def trap_if_on_the_stack(self, inst):
    c = self.caller
    while c is not None:
      trap_if(c.inst is inst)
      c = c.caller
```
By analyzing a linked component DAG, an optimized implementation can avoid the
O(n) loop in `trap_if_on_the_stack`:
* Reentrance by a child component can (often) be statically ruled out when the
  parent component doesn't both lift and lower the child's imports and exports
  (i.e., "donut wrapping").
* Reentrance of the root component by the host can either be asserted not to
  happen or be tracked in a per-root-component-instance flag.
* When a potentially-reenterable child component only lifts and lowers
  synchronously, reentrance can be tracked in a per-component-instance flag.
* For the remaining cases, the live instances on the stack can be maintained in
  a packed bit-vector (assigning each potentially-reenterable async component
  instance a static bit position) that is passed by copy from caller to callee.

The definition of `may_enter` (used to trigger backpressure in `enter`) is a
combination of two boolean flags: whether backpressure was explicitly requested
by guest code (via `task.backpressure`) or implied by a synchronous import call
in-progress:
```python
  def may_enter(self):
    return not self.inst.backpressure and not self.inst.calling_sync_import
```

The key method of `Task`, used by `enter`, `wait` and `yield_`, is `suspend`.
`Task.suspend` takes an `asyncio.Future` and waits on it, while allowing other
tasks make progress. When suspending, there are two cases to consider:
* This is the first time the current `Task` has blocked and thus there may be
  an `async`-lowered caller waiting to find out that its call blocked (which we
  signal by calling the `on_block` handler that the caller passed to
  `canon_lift`).
* This task has already blocked in the past (signaled by `on_block` being
  `None`) and thus there is no `async`-lowered caller to switch to and so we
  let Python's `asyncio` scheduler non-deterministically pick some other task
  that is ready to go, waiting to `acquire` the `current_task` lock.

In either case, once the given future is resolved, this `Task` has to
re`acquire` the `current_stack` lock to run again.
```python
  async def suspend(self, future):
    assert(current_task.locked())
    self.maybe_start_pending_task()
    if self.on_block:
      self.on_block()
      self.on_block = None
    else:
      current_task.release()
    r = await future
    await current_task.acquire()
    return r
```
As a side note: the `suspend` method is so named because it could be
reimplemented using the [`suspend`] instruction of the [typed continuations]
proposal, removing the need for `on_block` and the subtle calling contract
between `Task.suspend` and `canon_lift`.

The `pending_tasks` queue (appended to by `enter` above) is emptied (by
`suspend` above and `exit` below) one at a time when backpressure is disabled,
ensuring that each popped tasks gets a chance to start and possibly re-enable
backpressure before the next pending task is started:
```python
  def maybe_start_pending_task(self):
    if self.inst.pending_tasks and self.may_enter():
      self.inst.pending_tasks.pop(0).set_result(None)
```

The `borrow_count` field is used by the following methods to track the number
of borrowed handles that were passed as parameters to the export that have not
yet been dropped (and thus might dangle if the caller destroys the resource
after this export call finishes):
```python
  def create_borrow(self):
    self.borrow_count += 1

  def drop_borrow(self):
    assert(self.borrow_count > 0)
    self.borrow_count -= 1
```
The `exit` defined below traps if `borrow_count` is not zero when the lifted
call completes.

All `Task`s (whether lifted `async` or not) are allowed to call `async`-lowered
imports. Calling an `async`-lowered import creates an `AsyncSubtask` (defined
below) which is stored in the current component instance's `async_subtasks`
table and tracked by the current task's `num_async_subtasks` counter, which is
guarded to be `0` in `Task.exit` (below) to ensure [structured concurrency].
```python
  def add_async_subtask(self, subtask):
    assert(subtask.supertask is None and subtask.index is None)
    subtask.supertask = self
    subtask.index = self.inst.async_subtasks.add(subtask)
    self.num_async_subtasks += 1
    return subtask.index

  def async_subtask_made_progress(self, subtask):
    assert(subtask.supertask is self)
    if subtask.enqueued:
      return
    subtask.enqueued = True
    self.events.put_nowait(subtask)

  async def wait(self):
    subtask = await self.suspend(self.events.get())
    return self.process_event(subtask)

  def process_event(self, subtask):
    assert(subtask.supertask is self)
    subtask.enqueued = False
    if subtask.state == AsyncCallState.DONE:
      self.inst.async_subtasks.remove(subtask.index)
      self.num_async_subtasks -= 1
    return (EventCode(subtask.state), subtask.index)
```
While a task is running, it may call `wait` (via `canon task.wait` or, when a
`callback` is present, by returning to the event loop) to block until there is
progress on one of the task's async subtasks. Although the Python code above
uses an `asyncio.Queue` to coordinate async events, an optimized implementation
should not have to create an actual queue; instead it should be possible to
embed a "next ready" linked list in the elements of the `async_subtasks` table
(noting the `enqueued` guard above ensures that a subtask can be enqueued at
most once).

Alternatively, the current task can call `poll` (via `canon task.poll`, defined
below), which does not block and does not allow the runtime to switch to
another task:
```python
  def poll(self):
    if self.events.empty():
      return None
    return self.process_event(self.events.get_nowait())
```

A task may also cooperatively yield the current thread, explicitly allowing
the runtime to switch to another ready task, but without blocking on I/O (as
emulated in the Python code here by awaiting a `sleep(0)`).
```python
  async def yield_(self):
    await self.suspend(asyncio.sleep(0))
```

Lastly, when a task exits, the runtime enforces the guard conditions mentioned
above and allows other tasks to start or make progress.
```python
  def exit(self):
    assert(current_task.locked())
    assert(self.events.empty())
    assert(self.inst.num_tasks >= 1)
    trap_if(self.inst.backpressure and self.inst.num_tasks == 1)
    trap_if(self.borrow_count != 0)
    trap_if(self.num_async_subtasks != 0)
    self.inst.num_tasks -= 1
    self.maybe_start_pending_task()
    if not self.on_block:
      current_task.release()
```
If this `Task` has not yet blocked, there is an active `async`-lowered caller
on the stack, so we don't release the `current_task` lock; instead we just let
the `Task`'s Python coroutine return directly to the `await`ing caller without
a non-deterministic task switch.

While `canon_lift` creates `Task`s, `canon_lower` creates `Subtask` objects:
```python
class Subtask(CallContext):
  lenders: list[HandleElem]

  def __init__(self, opts, inst):
    super().__init__(opts, inst)
    self.lenders = []

  def track_owning_lend(self, lending_handle):
    assert(lending_handle.own)
    lending_handle.lend_count += 1
    self.lenders.append(lending_handle)

  def finish(self):
    for h in self.lenders:
      h.lend_count -= 1
```
A `Subtask` tracks the owned handles that have been lent for the duration of
the call, ensuring that the caller doesn't drop them during the call (which
might create a dangling borrowed handle in the callee). Note, the `lenders`
list usually has a fixed size (in all cases except when a function signature
has `borrow`s in `list`s) and thus can be stored inline in the native stack
frame.

The following `SyncTask`/`AsyncTask`/`AsyncSubtask` classes extend the
preceding `Task`/`Subtask` classes with additional state and methods that apply
only to the sync or async case.

The `SyncTask` classes overrides the `enter` and `exit` methods to additionally
enforce the rule that there only ever at most one synchronous task running in a
given component instance at a given time.
```python
class SyncTask(Task):
  async def enter(self):
    await super().enter()
    if self.inst.active_sync_task:
      f = asyncio.Future()
      self.inst.pending_sync_tasks.append(f)
      await self.suspend(f)
      assert(not self.inst.active_sync_task)
    self.inst.active_sync_task = True

  def exit(self):
    assert(self.inst.active_sync_task)
    self.inst.active_sync_task = False
    if self.inst.pending_sync_tasks:
      self.inst.pending_sync_tasks.pop(0).set_result(None)
    super().exit()
```
Thus, after one sync task starts running, any subsequent attempts to call into
the same component instance before the first sync task finishes will wait in a
LIFO queue until the sync task ahead of them in line completes. An optimized
implementation should be able to avoid separately allocating
`pending_sync_tasks` by instead embedding a "next pending" linked list in the
`Subtask` table element of the caller.

The first 3 fields of `AsyncTask` are simply immutable copies of
arguments/immediates passed to `canon_lift` and are used by the `task.start`
and `task.return` built-ins below. The last field is used to check the
above-mentioned state machine transitions from methods that are called by
`task.start`, `task.return` and `canon_lift` below.
```python
class AsyncTask(Task):
  ft: FuncType
  on_start: Callable
  on_return: Callable
  state: AsyncCallState

  def __init__(self, opts, inst, caller, on_block, ft, on_start, on_return):
    super().__init__(opts, inst, caller, on_block)
    self.ft = ft
    self.on_start = on_start
    self.on_return = on_return
    self.state = AsyncCallState.STARTING

  def start(self):
    trap_if(self.state != AsyncCallState.STARTING)
    self.state = AsyncCallState.STARTED

  def return_(self):
    trap_if(self.state != AsyncCallState.STARTED)
    self.state = AsyncCallState.RETURNED

  def exit(self):
    trap_if(self.state != AsyncCallState.RETURNED)
    self.state = AsyncCallState.DONE
    super().exit()
```

Finally, the `AsyncSubtask` class extends `Subtask` with fields that are used
by the methods of `Task`, as shown above. `AsyncSubtask`s have the same linear
state machine as `AsyncTask`s, except that the state transitions are guaranteed
by the Canonical ABI to happen in the right order. Each time an async subtask
advances a state, it notifies its "supertask", which was the current task when
the async-lowered function was first called.
```python
class AsyncSubtask(Subtask):
  state: AsyncCallState
  supertask: Optional[Task]
  index: Optional[int]
  enqueued: bool

  def __init__(self, opts, inst):
    super().__init__(opts, inst)
    self.state = AsyncCallState.STARTING
    self.supertask = None
    self.index = None
    self.enqueued = False

  def start(self):
    assert(self.state == AsyncCallState.STARTING)
    self.state = AsyncCallState.STARTED
    if self.supertask is not None:
      self.supertask.async_subtask_made_progress(self)

  def return_(self):
    assert(self.state == AsyncCallState.STARTED)
    self.state = AsyncCallState.RETURNED
    if self.supertask is not None:
      self.supertask.async_subtask_made_progress(self)

  def finish(self):
    super().finish()
    assert(self.state == AsyncCallState.RETURNED)
    self.state = AsyncCallState.DONE
    if self.supertask is not None:
      self.supertask.async_subtask_made_progress(self)
```
The `supertask` and `index` fields will be `None` when a subtask first starts
executing, before it blocks and gets added to the `async_subtasks` table (by
`canon_lower`, below). If a subtask advances all the way to the `DONE` state
before blocking, the `async`-lowered call will indicate to the caller that the
callee completed synchronously, avoiding the overhead of adding an
`AsyncSubtask` altogether. Thus, progress events don't need to be delivered
until the subtask has passed this "possibly synchronous early return" phase.

### Loading

The `load` function defines how to read a value of a given value type `t`
out of linear memory starting at offset `ptr`, returning the value represented
as a Python value. Presenting the definition of `load` piecewise, we start with
the top-level case analysis:
```python
def load(cx, ptr, t):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + elem_size(t) <= len(cx.opts.memory))
  match despecialize(t):
    case Bool()         : return convert_int_to_bool(load_int(cx, ptr, 1))
    case U8()           : return load_int(cx, ptr, 1)
    case U16()          : return load_int(cx, ptr, 2)
    case U32()          : return load_int(cx, ptr, 4)
    case U64()          : return load_int(cx, ptr, 8)
    case S8()           : return load_int(cx, ptr, 1, signed=True)
    case S16()          : return load_int(cx, ptr, 2, signed=True)
    case S32()          : return load_int(cx, ptr, 4, signed=True)
    case S64()          : return load_int(cx, ptr, 8, signed=True)
    case F32()          : return decode_i32_as_float(load_int(cx, ptr, 4))
    case F64()          : return decode_i64_as_float(load_int(cx, ptr, 8))
    case Char()         : return convert_i32_to_char(cx, load_int(cx, ptr, 4))
    case String()       : return load_string(cx, ptr)
    case List(t)        : return load_list(cx, ptr, t)
    case Record(fields) : return load_record(cx, ptr, fields)
    case Variant(cases) : return load_variant(cx, ptr, cases)
    case Flags(labels)  : return load_flags(cx, ptr, labels)
    case Own()          : return lift_own(cx, load_int(cx, ptr, 4), t)
    case Borrow()       : return lift_borrow(cx, load_int(cx, ptr, 4), t)
```

Integers are loaded directly from memory, with their high-order bit interpreted
according to the signedness of the type.
```python
def load_int(cx, ptr, nbytes, signed = False):
  return int.from_bytes(cx.opts.memory[ptr : ptr+nbytes], 'little', signed=signed)
```

Integer-to-boolean conversions treats `0` as `false` and all other bit-patterns
as `true`:
```python
def convert_int_to_bool(i):
  assert(i >= 0)
  return bool(i)
```

Floats are loaded directly from memory, with the sign and payload information
of NaN values discarded. Consequently, there is only one unique NaN value per
floating-point type. This reflects the practical reality that some languages
and protocols do not preserve these bits. In the Python code below, this is
expressed as canonicalizing NaNs to a particular bit pattern.

See the comments about lowering of float values for a discussion of possible
optimizations.
```python
DETERMINISTIC_PROFILE = False # or True
CANONICAL_FLOAT32_NAN = 0x7fc00000
CANONICAL_FLOAT64_NAN = 0x7ff8000000000000

def canonicalize_nan32(f):
  if math.isnan(f):
    f = core_f32_reinterpret_i32(CANONICAL_FLOAT32_NAN)
    assert(math.isnan(f))
  return f

def canonicalize_nan64(f):
  if math.isnan(f):
    f = core_f64_reinterpret_i64(CANONICAL_FLOAT64_NAN)
    assert(math.isnan(f))
  return f

def decode_i32_as_float(i):
  return canonicalize_nan32(core_f32_reinterpret_i32(i))

def decode_i64_as_float(i):
  return canonicalize_nan64(core_f64_reinterpret_i64(i))

def core_f32_reinterpret_i32(i):
  return struct.unpack('<f', struct.pack('<I', i))[0] # f32.reinterpret_i32

def core_f64_reinterpret_i64(i):
  return struct.unpack('<d', struct.pack('<Q', i))[0] # f64.reinterpret_i64
```

An `i32` is converted to a `char` (a [Unicode Scalar Value]) by dynamically
testing that its unsigned integral value is in the valid [Unicode Code Point]
range and not a [Surrogate]:
```python
def convert_i32_to_char(cx, i):
  assert(i >= 0)
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
def load_string(cx, ptr):
  begin = load_int(cx, ptr, 4)
  tagged_code_units = load_int(cx, ptr + 4, 4)
  return load_string_from_range(cx, begin, tagged_code_units)

UTF16_TAG = 1 << 31

def load_string_from_range(cx, ptr, tagged_code_units):
  match cx.opts.string_encoding:
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
  trap_if(ptr + byte_length > len(cx.opts.memory))
  try:
    s = cx.opts.memory[ptr : ptr+byte_length].decode(encoding)
  except UnicodeError:
    trap()

  return (s, cx.opts.string_encoding, tagged_code_units)
```

Lists and records are loaded by recursively loading their elements/fields:
```python
def load_list(cx, ptr, elem_type):
  begin = load_int(cx, ptr, 4)
  length = load_int(cx, ptr + 4, 4)
  return load_list_from_range(cx, begin, length, elem_type)

def load_list_from_range(cx, ptr, length, elem_type):
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + length * elem_size(elem_type) > len(cx.opts.memory))
  a = []
  for i in range(length):
    a.append(load(cx, ptr + i * elem_size(elem_type), elem_type))
  return a

def load_record(cx, ptr, fields):
  record = {}
  for field in fields:
    ptr = align_to(ptr, alignment(field.t))
    record[field.label] = load(cx, ptr, field.t)
    ptr += elem_size(field.t)
  return record
```
As a technical detail: the `align_to` in the loop in `load_record` is
guaranteed to be a no-op on the first iteration because the record as
a whole starts out aligned (as asserted at the top of `load`).

Variants are loaded using the order of the cases in the type to determine the
case index, assigning `0` to the first case, `1` to the next case, etc. To
support the subtyping allowed by `refines`, a lifted variant value semantically
includes a full ordered list of its `refines` case labels so that the lowering
code (defined below) can search this list to find a case label it knows about.
While the code below appears to perform case-label lookup at runtime, a normal
implementation can build the appropriate index tables at compile-time so that
variant-passing is always O(1) and not involving string operations.
```python
def load_variant(cx, ptr, cases):
  disc_size = elem_size(discriminant_type(cases))
  case_index = load_int(cx, ptr, disc_size)
  ptr += disc_size
  trap_if(case_index >= len(cases))
  c = cases[case_index]
  ptr = align_to(ptr, max_case_alignment(cases))
  case_label = case_label_with_refinements(c, cases)
  if c.t is None:
    return { case_label: None }
  return { case_label: load(cx, ptr, c.t) }

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

Flags are converted from a bit-vector to a dictionary whose keys are
derived from the ordered labels of the `flags` type. The code here takes
advantage of Python's support for integers of arbitrary width.
```python
def load_flags(cx, ptr, labels):
  i = load_int(cx, ptr, elem_size_flags(labels))
  return unpack_flags_from_int(i, labels)

def unpack_flags_from_int(i, labels):
  record = {}
  for l in labels:
    record[l] = bool(i & 1)
    i >>= 1
  return record
```

`own` handles are lifted by removing the handle from the current component
instance's handle table, so that ownership is *transferred* to the lowering
component. The lifting operation fails if unique ownership of the handle isn't
possible, for example if the index was actually a `borrow` or if the `own`
handle is currently being lent out as borrows.
```python
def lift_own(cx, i, t):
  h = cx.inst.handles.remove(t.rt, i)
  trap_if(h.lend_count != 0)
  trap_if(not h.own)
  return h.rep
```
The abstract lifted value for handle types is currently just the internal
resource representation `i32`, which is kept opaque from the receiving
component (it's stored in the handle table and only accessed indirectly via
index). (This assumes that resource representations are immutable. If
representations were to become mutable, the address of the mutable cell would
be passed as the lifted value instead.)

In contrast to `own`, `borrow` handles are lifted by reading the representation
from the source handle, leaving the source handle intact in the current
component instance's handle table:
```python
def lift_borrow(cx, i, t):
  assert(isinstance(cx, Subtask))
  h = cx.inst.handles.get(t.rt, i)
  if h.own:
    cx.track_owning_lend(h)
  return h.rep
```
The `track_owning_lend` call to `CallContext` participates in the enforcement
of the dynamic borrow rules, which keep the source `own` handle alive until the
end of the call (as an intentionally-conservative upper bound on how long the
`borrow` handle can be held). This tracking is only required when `h` is an
`own` handle because, when `h` is a `borrow` handle, this tracking has already
happened (when the originating `own` handle was lifted) for a strictly longer
call scope than the current call.


### Storing

The `store` function defines how to write a value `v` of a given value type
`t` into linear memory starting at offset `ptr`. Presenting the definition of
`store` piecewise, we start with the top-level case analysis:
```python
def store(cx, v, t, ptr):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + elem_size(t) <= len(cx.opts.memory))
  match despecialize(t):
    case Bool()         : store_int(cx, int(bool(v)), ptr, 1)
    case U8()           : store_int(cx, v, ptr, 1)
    case U16()          : store_int(cx, v, ptr, 2)
    case U32()          : store_int(cx, v, ptr, 4)
    case U64()          : store_int(cx, v, ptr, 8)
    case S8()           : store_int(cx, v, ptr, 1, signed=True)
    case S16()          : store_int(cx, v, ptr, 2, signed=True)
    case S32()          : store_int(cx, v, ptr, 4, signed=True)
    case S64()          : store_int(cx, v, ptr, 8, signed=True)
    case F32()          : store_int(cx, encode_float_as_i32(v), ptr, 4)
    case F64()          : store_int(cx, encode_float_as_i64(v), ptr, 8)
    case Char()         : store_int(cx, char_to_i32(v), ptr, 4)
    case String()       : store_string(cx, v, ptr)
    case List(t)        : store_list(cx, v, ptr, t)
    case Record(fields) : store_record(cx, v, ptr, fields)
    case Variant(cases) : store_variant(cx, v, ptr, cases)
    case Flags(labels)  : store_flags(cx, v, ptr, labels)
    case Own()          : store_int(cx, lower_own(cx.opts, v, t), ptr, 4)
    case Borrow()       : store_int(cx, lower_borrow(cx.opts, v, t), ptr, 4)
```

Integers are stored directly into memory. Because the input domain is exactly
the integers in range for the given type, no extra range checks are necessary;
the `signed` parameter is only present to ensure that the internal range checks
of `int.to_bytes` are satisfied.
```python
def store_int(cx, v, ptr, nbytes, signed = False):
  cx.opts.memory[ptr : ptr+nbytes] = int.to_bytes(v, nbytes, 'little', signed=signed)
```

Floats are stored directly into memory, with the sign and payload bits of NaN
values modified non-deterministically. This reflects the practical reality that
different languages, protocols and CPUs have different effects on NaNs.

Although this non-determinism is expressed in the Python code below as
generating a "random" NaN bit-pattern, native implementations do not need to
use the same "random" algorithm, or even any random algorithm at all. Hosts
may instead chose to canonicalize to an arbitrary fixed NaN value, or even to
the original value of the NaN before lifting, allowing them to optimize away
both the canonicalization of lifting and the randomization of lowering.

When a host implements the [deterministic profile], NaNs are canonicalized to
a particular NaN bit-pattern.
```python
def maybe_scramble_nan32(f):
  if math.isnan(f):
    if DETERMINISTIC_PROFILE:
      f = core_f32_reinterpret_i32(CANONICAL_FLOAT32_NAN)
    else:
      f = core_f32_reinterpret_i32(random_nan_bits(32, 8))
    assert(math.isnan(f))
  return f

def maybe_scramble_nan64(f):
  if math.isnan(f):
    if DETERMINISTIC_PROFILE:
      f = core_f64_reinterpret_i64(CANONICAL_FLOAT64_NAN)
    else:
      f = core_f64_reinterpret_i64(random_nan_bits(64, 11))
    assert(math.isnan(f))
  return f

def random_nan_bits(total_bits, exponent_bits):
  fraction_bits = total_bits - exponent_bits - 1
  bits = random.getrandbits(total_bits)
  bits |= ((1 << exponent_bits) - 1) << fraction_bits
  bits |= 1 << random.randrange(fraction_bits - 1)
  return bits

def encode_float_as_i32(f):
  return core_i32_reinterpret_f32(maybe_scramble_nan32(f))

def encode_float_as_i64(f):
  return core_i64_reinterpret_f64(maybe_scramble_nan64(f))

def core_i32_reinterpret_f32(f):
  return struct.unpack('<I', struct.pack('<f', f))[0] # i32.reinterpret_f32

def core_i64_reinterpret_f64(f):
  return struct.unpack('<Q', struct.pack('<d', f))[0] # i64.reinterpret_f64
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
def store_string(cx, v, ptr):
  begin, tagged_code_units = store_string_into_range(cx, v)
  store_int(cx, begin, ptr, 4)
  store_int(cx, tagged_code_units, ptr + 4, 4)

def store_string_into_range(cx, v):
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

  match cx.opts.string_encoding:
    case 'utf8':
      match src_simple_encoding:
        case 'utf8'         : return store_string_copy(cx, src, src_code_units, 1, 1, 'utf-8')
        case 'utf16'        : return store_utf16_to_utf8(cx, src, src_code_units)
        case 'latin1'       : return store_latin1_to_utf8(cx, src, src_code_units)
    case 'utf16':
      match src_simple_encoding:
        case 'utf8'         : return store_utf8_to_utf16(cx, src, src_code_units)
        case 'utf16'        : return store_string_copy(cx, src, src_code_units, 2, 2, 'utf-16-le')
        case 'latin1'       : return store_string_copy(cx, src, src_code_units, 2, 2, 'utf-16-le')
    case 'latin1+utf16':
      match src_encoding:
        case 'utf8'         : return store_string_to_latin1_or_utf16(cx, src, src_code_units)
        case 'utf16'        : return store_string_to_latin1_or_utf16(cx, src, src_code_units)
        case 'latin1+utf16' :
          match src_simple_encoding:
            case 'latin1'   : return store_string_copy(cx, src, src_code_units, 1, 2, 'latin-1')
            case 'utf16'    : return store_probably_utf16_to_latin1_or_utf16(cx, src, src_code_units)
```

The simplest 4 cases above can compute the exact destination size and then copy
with a simply loop (that possibly inflates Latin-1 to UTF-16 by injecting a 0
byte after every Latin-1 byte).
```python
MAX_STRING_BYTE_LENGTH = (1 << 31) - 1

def store_string_copy(cx, src, src_code_units, dst_code_unit_size, dst_alignment, dst_encoding):
  dst_byte_length = dst_code_unit_size * src_code_units
  trap_if(dst_byte_length > MAX_STRING_BYTE_LENGTH)
  ptr = cx.opts.realloc(0, 0, dst_alignment, dst_byte_length)
  trap_if(ptr != align_to(ptr, dst_alignment))
  trap_if(ptr + dst_byte_length > len(cx.opts.memory))
  encoded = src.encode(dst_encoding)
  assert(dst_byte_length == len(encoded))
  cx.opts.memory[ptr : ptr+len(encoded)] = encoded
  return (ptr, src_code_units)
```
The choice of `MAX_STRING_BYTE_LENGTH` constant ensures that the high bit of a
string's byte length is never set, keeping it clear for `UTF16_BIT`.

The 2 cases of transcoding into UTF-8 share an algorithm that starts by
optimistically assuming that each code unit of the source string fits in a
single UTF-8 byte and then, failing that, reallocates to a worst-case size,
finishes the copy, and then finishes with a shrinking reallocation.
```python
def store_utf16_to_utf8(cx, src, src_code_units):
  worst_case_size = src_code_units * 3
  return store_string_to_utf8(cx, src, src_code_units, worst_case_size)

def store_latin1_to_utf8(cx, src, src_code_units):
  worst_case_size = src_code_units * 2
  return store_string_to_utf8(cx, src, src_code_units, worst_case_size)

def store_string_to_utf8(cx, src, src_code_units, worst_case_size):
  assert(src_code_units <= MAX_STRING_BYTE_LENGTH)
  ptr = cx.opts.realloc(0, 0, 1, src_code_units)
  trap_if(ptr + src_code_units > len(cx.opts.memory))
  for i,code_point in enumerate(src):
    if ord(code_point) < 2**7:
      cx.opts.memory[ptr + i] = ord(code_point)
    else:
      trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
      ptr = cx.opts.realloc(ptr, src_code_units, 1, worst_case_size)
      trap_if(ptr + worst_case_size > len(cx.opts.memory))
      encoded = src.encode('utf-8')
      cx.opts.memory[ptr+i : ptr+len(encoded)] = encoded[i : ]
      if worst_case_size > len(encoded):
        ptr = cx.opts.realloc(ptr, worst_case_size, 1, len(encoded))
        trap_if(ptr + len(encoded) > len(cx.opts.memory))
      return (ptr, len(encoded))
  return (ptr, src_code_units)
```

Converting from UTF-8 to UTF-16 performs an initial worst-case size allocation
(assuming each UTF-8 byte encodes a whole code point that inflates into a
two-byte UTF-16 code unit) and then does a shrinking reallocation at the end
if multiple UTF-8 bytes were collapsed into a single 2-byte UTF-16 code unit:
```python
def store_utf8_to_utf16(cx, src, src_code_units):
  worst_case_size = 2 * src_code_units
  trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
  ptr = cx.opts.realloc(0, 0, 2, worst_case_size)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + worst_case_size > len(cx.opts.memory))
  encoded = src.encode('utf-16-le')
  cx.opts.memory[ptr : ptr+len(encoded)] = encoded
  if len(encoded) < worst_case_size:
    ptr = cx.opts.realloc(ptr, worst_case_size, 2, len(encoded))
    trap_if(ptr != align_to(ptr, 2))
    trap_if(ptr + len(encoded) > len(cx.opts.memory))
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
def store_string_to_latin1_or_utf16(cx, src, src_code_units):
  assert(src_code_units <= MAX_STRING_BYTE_LENGTH)
  ptr = cx.opts.realloc(0, 0, 2, src_code_units)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + src_code_units > len(cx.opts.memory))
  dst_byte_length = 0
  for usv in src:
    if ord(usv) < (1 << 8):
      cx.opts.memory[ptr + dst_byte_length] = ord(usv)
      dst_byte_length += 1
    else:
      worst_case_size = 2 * src_code_units
      trap_if(worst_case_size > MAX_STRING_BYTE_LENGTH)
      ptr = cx.opts.realloc(ptr, src_code_units, 2, worst_case_size)
      trap_if(ptr != align_to(ptr, 2))
      trap_if(ptr + worst_case_size > len(cx.opts.memory))
      for j in range(dst_byte_length-1, -1, -1):
        cx.opts.memory[ptr + 2*j] = cx.opts.memory[ptr + j]
        cx.opts.memory[ptr + 2*j + 1] = 0
      encoded = src.encode('utf-16-le')
      cx.opts.memory[ptr+2*dst_byte_length : ptr+len(encoded)] = encoded[2*dst_byte_length : ]
      if worst_case_size > len(encoded):
        ptr = cx.opts.realloc(ptr, worst_case_size, 2, len(encoded))
        trap_if(ptr != align_to(ptr, 2))
        trap_if(ptr + len(encoded) > len(cx.opts.memory))
      tagged_code_units = int(len(encoded) / 2) | UTF16_TAG
      return (ptr, tagged_code_units)
  if dst_byte_length < src_code_units:
    ptr = cx.opts.realloc(ptr, src_code_units, 2, dst_byte_length)
    trap_if(ptr != align_to(ptr, 2))
    trap_if(ptr + dst_byte_length > len(cx.opts.memory))
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
def store_probably_utf16_to_latin1_or_utf16(cx, src, src_code_units):
  src_byte_length = 2 * src_code_units
  trap_if(src_byte_length > MAX_STRING_BYTE_LENGTH)
  ptr = cx.opts.realloc(0, 0, 2, src_byte_length)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + src_byte_length > len(cx.opts.memory))
  encoded = src.encode('utf-16-le')
  cx.opts.memory[ptr : ptr+len(encoded)] = encoded
  if any(ord(c) >= (1 << 8) for c in src):
    tagged_code_units = int(len(encoded) / 2) | UTF16_TAG
    return (ptr, tagged_code_units)
  latin1_size = int(len(encoded) / 2)
  for i in range(latin1_size):
    cx.opts.memory[ptr + i] = cx.opts.memory[ptr + 2*i]
  ptr = cx.opts.realloc(ptr, src_byte_length, 1, latin1_size)
  trap_if(ptr + latin1_size > len(cx.opts.memory))
  return (ptr, latin1_size)
```

Lists and records are stored by recursively storing their elements and
are symmetric to the loading functions. Unlike strings, lists can
simply allocate based on the up-front knowledge of length and static
element size.
```python
def store_list(cx, v, ptr, elem_type):
  begin, length = store_list_into_range(cx, v, elem_type)
  store_int(cx, begin, ptr, 4)
  store_int(cx, length, ptr + 4, 4)

def store_list_into_range(cx, v, elem_type):
  byte_length = len(v) * elem_size(elem_type)
  trap_if(byte_length >= (1 << 32))
  ptr = cx.opts.realloc(0, 0, alignment(elem_type), byte_length)
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + byte_length > len(cx.opts.memory))
  for i,e in enumerate(v):
    store(cx, e, elem_type, ptr + i * elem_size(elem_type))
  return (ptr, len(v))

def store_record(cx, v, ptr, fields):
  for f in fields:
    ptr = align_to(ptr, alignment(f.t))
    store(cx, v[f.label], f.t, ptr)
    ptr += elem_size(f.t)
```

Variants are stored using the `|`-separated list of `refines` cases built
by `case_label_with_refinements` (above) to iteratively find a matching case (which
validation guarantees will succeed). While this code appears to do O(n) string
matching, a normal implementation can statically fuse `store_variant` with its
matching `load_variant` to ultimately build a dense array that maps producer's
case indices to the consumer's case indices.
```python
def store_variant(cx, v, ptr, cases):
  case_index, case_value = match_case(v, cases)
  disc_size = elem_size(discriminant_type(cases))
  store_int(cx, case_index, ptr, disc_size)
  ptr += disc_size
  ptr = align_to(ptr, max_case_alignment(cases))
  c = cases[case_index]
  if c.t is not None:
    store(cx, case_value, c.t, ptr)

def match_case(v, cases):
  assert(len(v.keys()) == 1)
  key = list(v.keys())[0]
  value = list(v.values())[0]
  for label in key.split('|'):
    case_index = find_case(label, cases)
    if case_index != -1:
      return (case_index, value)
```

Flags are converted from a dictionary to a bit-vector by iterating
through the case-labels of the variant in the order they were listed in the
type definition and OR-ing all the bits together. Flag lifting/lowering can be
statically fused into array/integer operations (with a simple byte copy when
the case lists are the same) to avoid any string operations in a similar manner
to variants.
```python
def store_flags(cx, v, ptr, labels):
  i = pack_flags_into_int(v, labels)
  store_int(cx, i, ptr, elem_size_flags(labels))

def pack_flags_into_int(v, labels):
  i = 0
  shift = 0
  for l in labels:
    i |= (int(bool(v[l])) << shift)
    shift += 1
  return i
```

Finally, `own` and `borrow` handles are lowered by initializing new handle
elements in the current component instance's handle table:
```python
def lower_own(cx, rep, t):
  h = HandleElem(rep, own=True)
  return cx.inst.handles.add(t.rt, h)

def lower_borrow(cx, rep, t):
  assert(isinstance(cx, Task))
  if cx.inst is t.rt.impl:
    return rep
  h = HandleElem(rep, own=False, scope=cx)
  cx.create_borrow()
  return cx.inst.handles.add(t.rt, h)
```
The special case in `lower_borrow` is an optimization, recognizing that, when
a borrowed handle is passed to the component that implemented the resource
type, the only thing the borrowed handle is good for is calling
`resource.rep`, so lowering might as well avoid the overhead of creating an
intermediate borrow handle.

### Flattening

With only the definitions above, the Canonical ABI would be forced to place all
parameters and results in linear memory. While this is necessary in the general
case, in many cases performance can be improved by passing small-enough values
in registers by using core function parameters and results. To support this
optimization, the Canonical ABI defines `flatten_functype` to map component
function types to core function types by attempting to decompose all the
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

Given all this, the top-level definition of `flatten_functype` is:
```python
MAX_FLAT_PARAMS = 16
MAX_FLAT_RESULTS = 1

class Needs:
  memory: bool = False
  realloc: bool = False

def reverse_context(context):
  match context:
    case 'lift'  : return 'lower'
    case 'lower' : return 'lift'

def flatten_functype(opts, ft, context, needs):
  flat_params = flatten_types(ft.param_types(), reverse_context(context), needs)
  flat_results = flatten_types(ft.result_types(), context, needs)
  if opts.sync:
    if len(flat_params) > MAX_FLAT_PARAMS:
      needs.memory = True
      if context == 'lift':
        needs.realloc = True
      flat_params = ['i32']
    if len(flat_results) > MAX_FLAT_RESULTS:
      needs.memory = True
      match context:
        case 'lift':
          flat_results = ['i32']
        case 'lower':
          flat_params += ['i32']
          flat_results = []
    return CoreFuncType(flat_params, flat_results)
  else:
    match context:
      case 'lift':
        flat_params = []
        flat_results = []
      case 'lower':
        if len(flat_params) > 1:
          needs.memory = True
          flat_params = ['i32']
        if len(flat_results) > 0:
          needs.memory = True
          flat_params += ['i32']
        flat_results = ['i32']
    return CoreFuncType(flat_params, flat_results)
```
The `Needs` object tracks whether a Canonical ABI call requires the
`memory` or `realloc` `canonopt`s to be set, as required by Component
Model validation.

As shown here, the core signatures `async` functions use a lower limit on the
maximum number of parameters (1) and results (0) passed as scalars before
falling back to passing through memory.

Presenting the definition of `flatten_type(s)` piecewise, we start with the
top-level case analysis:
```python
def flatten_types(ts, context, needs):
  return [ft for t in ts for ft in flatten_type(t, context, needs)]

def flatten_type(t, context, needs):
  match despecialize(t):
    case Bool()               : return ['i32']
    case U8() | U16() | U32() : return ['i32']
    case S8() | S16() | S32() : return ['i32']
    case S64() | U64()        : return ['i64']
    case F32()                : return ['f32']
    case F64()                : return ['f64']
    case Char()               : return ['i32']
    case Record(fields)       : return flatten_record(fields, context, needs)
    case Variant(cases)       : return flatten_variant(cases, context, needs)
    case Flags(labels)        : return ['i32'] * num_i32_flags(labels)
    case Own(_) | Borrow(_)   : return ['i32']
    case String() | List(_):
      needs.memory = True
      if context == 'lower':
        needs.realloc = True
      return ['i32', 'i32']
```
Note that `context` refers to whether the particular *value* is being lifted or
lowered, not whether this is part of a lifted or lowered call to a function. In
particular, `flatten_functype` above reverses the direction of parameters since
a lifted function call lowers its parameters. Thus, `needs.realloc` is only set
for the string/list parameters of lifted exports and results of lowered
imports.

Record flattening simply flattens each field in sequence.
```python
def flatten_record(fields, context, needs):
  flat = []
  for f in fields:
    flat += flatten_type(f.t, context, needs)
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
def flatten_variant(cases, context, needs):
  flat = []
  for c in cases:
    if c.t is not None:
      for i,ft in enumerate(flatten_type(c.t, context, needs)):
        if i < len(flat):
          flat[i] = join(flat[i], ft)
        else:
          flat.append(ft)
  return flatten_type(discriminant_type(cases), context, needs) + flat

def join(a, b):
  if a == b: return a
  if (a == 'i32' and b == 'f32') or (a == 'f32' and b == 'i32'): return 'i32'
  return 'i64'
```

### Flat Lifting

Values are lifted by iterating over a list of parameter or result Core
WebAssembly values:
```python
@dataclass
class CoreValueIter:
  values: list[int|float]
  i = 0
  def next(self, t):
    v = self.values[self.i]
    self.i += 1
    match t:
      case 'i32': assert(isinstance(v, int) and 0 <= v < 2**32)
      case 'i64': assert(isinstance(v, int) and 0 <= v < 2**64)
      case 'f32': assert(isinstance(v, (int,float)))
      case 'f64': assert(isinstance(v, (int,float)))
      case _    : assert(False)
    return v
```
The `match` is only used for spec-level assertions; no runtime typecase is
required.

The `lift_flat` function defines how to convert a list of core values into a
single high-level value of type `t`. Presenting the definition of `lift_flat`
piecewise, we start with the top-level case analysis:
```python
def lift_flat(cx, vi, t):
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
    case F32()          : return canonicalize_nan32(vi.next('f32'))
    case F64()          : return canonicalize_nan64(vi.next('f64'))
    case Char()         : return convert_i32_to_char(cx, vi.next('i32'))
    case String()       : return lift_flat_string(cx, vi)
    case List(t)        : return lift_flat_list(cx, vi, t)
    case Record(fields) : return lift_flat_record(cx, vi, fields)
    case Variant(cases) : return lift_flat_variant(cx, vi, cases)
    case Flags(labels)  : return lift_flat_flags(vi, labels)
    case Own()          : return lift_own(cx, vi.next('i32'), t)
    case Borrow()       : return lift_borrow(cx, vi.next('i32'), t)
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
def lift_flat_string(cx, vi):
  ptr = vi.next('i32')
  packed_length = vi.next('i32')
  return load_string_from_range(cx, ptr, packed_length)

def lift_flat_list(cx, vi, elem_type):
  ptr = vi.next('i32')
  length = vi.next('i32')
  return load_list_from_range(cx, ptr, length, elem_type)
```

Records are lifted by recursively lifting their fields:
```python
def lift_flat_record(cx, vi, fields):
  record = {}
  for f in fields:
    record[f.label] = lift_flat(cx, vi, f.t)
  return record
```

Variants are also lifted recursively. Lifting a variant must carefully follow
the definition of `flatten_variant` above, consuming the exact same core types
regardless of the dynamic case payload being lifted. Because of the `join`
performed by `flatten_variant`, we need a more-permissive value iterator that
reinterprets between the different types appropriately and also traps if the
high bits of an `i64` are set for a 32-bit type:
```python
def lift_flat_variant(cx, vi, cases):
  flat_types = flatten_variant(cases, 'lift', Needs())
  assert(flat_types.pop(0) == 'i32')
  case_index = vi.next('i32')
  trap_if(case_index >= len(cases))
  class CoerceValueIter:
    def next(self, want):
      have = flat_types.pop(0)
      x = vi.next(have)
      match (have, want):
        case ('i32', 'f32') : return decode_i32_as_float(x)
        case ('i64', 'i32') : return wrap_i64_to_i32(x)
        case ('i64', 'f32') : return decode_i32_as_float(wrap_i64_to_i32(x))
        case ('i64', 'f64') : return decode_i64_as_float(x)
        case _              : assert(have == want); return x
  c = cases[case_index]
  if c.t is None:
    v = None
  else:
    v = lift_flat(cx, CoerceValueIter(), c.t)
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
def lower_flat(cx, v, t):
  match despecialize(t):
    case Bool()         : return [int(v)]
    case U8()           : return [v]
    case U16()          : return [v]
    case U32()          : return [v]
    case U64()          : return [v]
    case S8()           : return lower_flat_signed(v, 32)
    case S16()          : return lower_flat_signed(v, 32)
    case S32()          : return lower_flat_signed(v, 32)
    case S64()          : return lower_flat_signed(v, 64)
    case F32()          : return [maybe_scramble_nan32(v)]
    case F64()          : return [maybe_scramble_nan64(v)]
    case Char()         : return [char_to_i32(v)]
    case String()       : return lower_flat_string(cx, v)
    case List(t)        : return lower_flat_list(cx, v, t)
    case Record(fields) : return lower_flat_record(cx, v, fields)
    case Variant(cases) : return lower_flat_variant(cx, v, cases)
    case Flags(labels)  : return lower_flat_flags(v, labels)
    case Own()          : return [lower_own(cx, v, t)]
    case Borrow()       : return [lower_borrow(cx, v, t)]
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
  return [i]
```

Since strings and lists are stored in linear memory, lifting can reuse the
previous definitions; only the resulting pointers are returned differently
(as `i32` values instead of as a pair in linear memory):
```python
def lower_flat_string(cx, v):
  ptr, packed_length = store_string_into_range(cx, v)
  return [ptr, packed_length]

def lower_flat_list(cx, v, elem_type):
  (ptr, length) = store_list_into_range(cx, v, elem_type)
  return [ptr, length]
```

Records are lowered by recursively lowering their fields:
```python
def lower_flat_record(cx, v, fields):
  flat = []
  for f in fields:
    flat += lower_flat(cx, v[f.label], f.t)
  return flat
```

Variants are also lowered recursively. Symmetric to `lift_flat_variant` above,
`lower_flat_variant` must consume all flattened types of `flatten_variant`,
manually coercing the otherwise-incompatible type pairings allowed by `join`:
```python
def lower_flat_variant(cx, v, cases):
  case_index, case_value = match_case(v, cases)
  flat_types = flatten_variant(cases, 'lower', Needs())
  assert(flat_types.pop(0) == 'i32')
  c = cases[case_index]
  if c.t is None:
    payload = []
  else:
    payload = lower_flat(cx, case_value, c.t)
    for i,(fv,have) in enumerate(zip(payload, flatten_type(c.t, 'lower', Needs()))):
      want = flat_types.pop(0)
      match (have, want):
        case ('f32', 'i32') : payload[i] = encode_float_as_i32(fv)
        case ('i32', 'i64') : payload[i] = fv
        case ('f32', 'i64') : payload[i] = encode_float_as_i32(fv)
        case ('f64', 'i64') : payload[i] = encode_float_as_i64(fv)
        case _              : assert(have == want)
  for _ in flat_types:
    payload.append(0)
  return [case_index] + payload
```

Finally, flags are lowered by slicing the bit vector into `i32` chunks:
```python
def lower_flat_flags(v, labels):
  i = pack_flags_into_int(v, labels)
  flat = []
  for _ in range(num_i32_flags(labels)):
    flat.append(i & 0xffffffff)
    i >>= 32
  assert(i == 0)
  return flat
```

### Lifting and Lowering Values

The `lift_flat_values` function defines how to lift a list of core
parameters or results (given by the `CoreValueIter` `vi`) into a tuple
of component-level values with types `ts`.
```python
def lift_flat_values(cx, max_flat, vi, ts):
  flat_types = flatten_types(ts, 'lift', Needs())
  if len(flat_types) > max_flat:
    return lift_heap_values(cx, vi, ts)
  else:
    return [ lift_flat(cx, vi, t) for t in ts ]

def lift_heap_values(cx, vi, ts):
  ptr = vi.next('i32')
  tuple_type = Tuple(ts)
  trap_if(ptr != align_to(ptr, alignment(tuple_type)))
  trap_if(ptr + elem_size(tuple_type) > len(cx.opts.memory))
  return list(load(cx, ptr, tuple_type).values())
```

Symmetrically, the `lower_flat_values` function defines how to lower a
list of component-level values `vs` of types `ts` into a list of core
values. As already described for [`flatten_functype`](#flattening) above,
lowering handles the greater-than-`max_flat` case by either allocating
storage with `realloc` or accepting a caller-allocated buffer as an
out-param:
```python
def lower_flat_values(cx, max_flat, vs, ts, out_param = None):
  assert(cx.inst.may_leave)
  cx.inst.may_leave = False
  flat_types = flatten_types(ts, 'lower', Needs())
  if len(flat_types) > max_flat:
    flat_vals = lower_heap_values(cx, vs, ts, out_param)
  else:
    flat_vals = []
    for i in range(len(vs)):
      flat_vals += lower_flat(cx, vs[i], ts[i])
  cx.inst.may_leave = True
  return flat_vals

def lower_heap_values(cx, vs, ts, out_param):
  tuple_type = Tuple(ts)
  tuple_value = {str(i): v for i,v in enumerate(vs)}
  if out_param is None:
    ptr = cx.opts.realloc(0, 0, alignment(tuple_type), elem_size(tuple_type))
    flat_vals = [ptr]
  else:
    ptr = out_param.next('i32')
    flat_vals = []
  trap_if(ptr != align_to(ptr, alignment(tuple_type)))
  trap_if(ptr + elem_size(tuple_type) > len(cx.opts.memory))
  store(cx, tuple_value, tuple_type, ptr)
  return flat_vals
```
The `may_leave` flag is guarded by `canon_lower` below to prevent a component
from calling out of the component while in the middle of lowering, ensuring
that the relative ordering of the side effects of lifting followed by lowering
cannot be observed and thus an implementation may reliably fuse lifting with
lowering when making a cross-component call to avoid the intermediate copy.

## Canonical Definitions

Using the above supporting definitions, we can describe the static and dynamic
semantics of component-level [`canon`] definitions. The following subsections
cover each of these `canon` cases.

### `canon lift`

For a canonical definition:
```wasm
(canon lift $callee:<funcidx> $opts:<canonopt>* (func $f (type $ft)))
```
validation specifies:
* `$callee` must have type `flatten_functype($opts, $ft, 'lift')`
* `$f` is given type `$ft`
* a `memory` is present if required by lifting and is a subtype of `(memory 1)`
* a `realloc` is present if required by lifting and has type `(func (param i32 i32 i32 i32) (result i32))`
* if a `post-return` is present, it has type `(func (param flatten_functype({}, $ft, 'lift').results))`

When instantiating component instance `$inst`:
* Define `$f` to be the partially-bound closure `canon_lift($opts, $inst, $callee, $ft)`

The resulting function `$f` takes 4 runtime arguments:
* `caller`: the caller's `Task` or, if this lifted function is being called by
  the host, `None`
* `on_block`: a nullary function that must be called at most once by the callee
  before blocking the first time
* `on_start`: a nullary function that must be called to return the caller's
  arguments as a list of component-level values
* `on_return`: a unary function that must be called after `on_start`,
  passing the list of component-level return values

The indirection of `on_start` and `on_return` are used to model the
interleaving of reading arguments out of the caller's stack and memory and
writing results back into the caller's stack and memory, which will vary in
async calls.

If `$f` ends up being called by the host, the host is responsible for, in a
host-defined manner, conjuring up component-level values suitable for passing
into `lower` and, conversely, consuming the component values produced by
`lift`. For example, if the host is a native JS runtime, the [JavaScript
embedding] would specify how native JavaScript values are converted to and from
component values. Alternatively, if the host is a Unix CLI that invokes
component exports directly from the command line, the CLI could choose to
automatically parse `argv` into component-level values according to the
declared types of the export. In any case, `canon lift` specifies how these
variously-produced values are consumed as parameters (and produced as results)
by a *single host-agnostic component*.

Based on this, `canon_lift` is defined:
```python
async def canon_lift(opts, inst, callee, ft, caller, on_block, on_start, on_return):
  if opts.sync:
    task = SyncTask(opts, inst, caller, on_block)
    await task.enter()

    flat_args = lower_flat_values(task, MAX_FLAT_PARAMS, on_start(), ft.param_types())
    flat_results = await call_and_trap_on_throw(callee, task, flat_args)
    on_return(lift_flat_values(task, MAX_FLAT_RESULTS, CoreValueIter(flat_results), ft.result_types()))

    if opts.post_return is not None:
      [] = await call_and_trap_on_throw(opts.post_return, task, flat_results)

    task.exit()
  else:
    task = AsyncTask(opts, inst, caller, on_block, ft, on_start, on_return)
    await task.enter()

    if not opts.callback:
      [] = await call_and_trap_on_throw(callee, task, [])
    else:
      [packed_ctx] = await call_and_trap_on_throw(callee, task, [])
      while packed_ctx != 0:
        is_yield = bool(packed_ctx & 1)
        ctx = packed_ctx & ~1
        if is_yield:
          await task.yield_()
          event, payload = (EventCode.YIELDED, 0)
        else:
          event, payload = await task.wait()
        [packed_ctx] = await call_and_trap_on_throw(opts.callback, task, [ctx, event, payload])

    assert(opts.post_return is None)
    task.exit()

async def call_and_trap_on_throw(callee, task, args):
  try:
    return await callee(task, args)
  except CoreWebAssemblyException:
    trap()
```
The only fundamental difference between sync and async lifting is whether
parameters/results are automatically lowered/lifted (with `canon_lift` calling
`on_start` and `on_return`) or whether the `callee` explicitly triggers
`on_start`/`on_return` via `task.start`/`task.return` (defined below).

In a sync call, after the results have been copied from the callee's memory
into the caller's memory, the callee's `post_return` function is called to
allow the callee to reclaim any memory. An async call doesn't need a
`post_return` function, since the callee can keep running after calling
`task.return`.

Within the async case, there are two sub-cases depending on whether the
`callback` `canonopt` was set. When `callback` is present, waiting happens in
an "event loop" inside `canon_lift` which also allows yielding (i.e., allowing
other tasks to run without blocking) by setting the LSB of the returned `i32`.
Otherwise, waiting must happen by calling `task.wait` (defined below), which
potentially requires the runtime implementation to use a fiber (aka. stackful
coroutine) to switch to another task. Thus, `callback` is an optimization for
avoiding fiber creation for async languages that don't need it (e.g., JS,
Python, C# and Rust).

Uncaught Core WebAssembly [exceptions] result in a trap at component
boundaries. Thus, if a component wishes to signal an error, it must use some
sort of explicit type such as `result` (whose `error` case particular language
bindings may choose to map to and from exceptions).

### `canon lower`

For a canonical definition:
```wasm
(canon lower $callee:<funcidx> $opts:<canonopt>* (core func $f))
```
where `$callee` has type `$ft`, validation specifies:
* `$f` is given type `flatten_functype($opts, $ft, 'lower')`
* a `memory` is present if required by lifting and is a subtype of `(memory 1)`
* a `realloc` is present if required by lifting and has type `(func (param i32 i32 i32 i32) (result i32))`
* there is no `post-return` in `$opts`

When instantiating component instance `$inst`:
* Define `$f` to be the partially-bound closure: `canon_lower($opts, $callee, $ft)`

The resulting function `$f` takes 2 runtime arguments:
* `task`: the `Task` that was created by `canon_lift` when entering the current
  component instance
* `flat_args`: the list of core values passed by the core function calller

Given this, `canon_lower` is defined:
```python
async def canon_lower(opts, callee, ft, task, flat_args):
  trap_if(not task.inst.may_leave)

  flat_args = CoreValueIter(flat_args)
  flat_results = None
  if opts.sync:
    subtask = Subtask(opts, task.inst)
    task.inst.calling_sync_import = True
    def on_block():
      if task.on_block:
        task.on_block()
        task.on_block = None
    def on_start():
      return lift_flat_values(subtask, MAX_FLAT_PARAMS, flat_args, ft.param_types())
    def on_return(results):
      nonlocal flat_results
      flat_results = lower_flat_values(subtask, MAX_FLAT_RESULTS, results, ft.result_types(), flat_args)
    await callee(task, on_block, on_start, on_return)
    task.inst.calling_sync_import = False
    subtask.finish()
  else:
    subtask = AsyncSubtask(opts, task.inst)
    eager_result = asyncio.Future()
    async def do_call():
      def on_block():
        eager_result.set_result('block')
      def on_start():
        subtask.start()
        return lift_flat_values(subtask, 1, flat_args, ft.param_types())
      def on_return(results):
        subtask.return_()
        lower_flat_values(subtask, 0, results, ft.result_types(), flat_args)
      await callee(task, on_block, on_start, on_return)
      subtask.finish()
      if not eager_result.done():
        eager_result.set_result('complete')
    asyncio.create_task(do_call())
    match await eager_result:
      case 'complete':
        flat_results = [0]
      case 'block':
        i = task.add_async_subtask(subtask)
        flat_results = [pack_async_result(i, subtask.state)]

  return flat_results
```
In the synchronous case, the import call is bracketed by setting
`calling_sync_import` to prevent reentrance into the current component instance
if the `callee` blocks and the caller gets control flow (via `on_block`). Like
`Task.suspend` above, `canon_lift` clears the `on_block` handler after calling
to signal that the current `Task` has already released any waiting
`async`-lowered callers.

In the asynchronous case, we finally see the whole point of `on_block` which is
to allow us to wait for one of two outcomes: the callee blocks or the callee
finishes without blocking. Whichever happens first resolves the `eager_result`
future. After calling `asyncio.create_task`, `canon_lift` immediately `await`s
`eager_result` so that there is no allowed interleaving between the caller and
callee's Python coroutines. This overall behavior resembles the [`resume`]
instruction of the [typed continuations] proposal (handling a `block` effect)
which could be used to more-directly implement the Python control flow here.

Whether or not the `callee` blocks, the `on_start` and `on_return` handlers
must be called before the `callee` completes (either by `canon_lift` in the
synchronous case or the `task.start`/`task.return` built-ins in the
asynchronous case). Note that, when `async`-lowering, lifting and lowering
can happen after `canon_lower` returns and thus the caller must `task.wait`
for `EventCode`s to know when the supplied linear memory pointers can be
reused.

If an `async`-lowered call blocks, the `AsyncSubtask` is added to the component
instance's `async_subtasks` table, and the index and state are returned to the
caller packed into a single `i32` as follows:
```python
def pack_async_result(i, state):
  assert(0 < i < 2**30)
  assert(0 <= int(state) < 2**2)
  return i | (int(state) << 30)
```

The above definitions of sync/async `canon_lift`/`canon_lower` ensure that a
sync-or-async `canon_lift` may call a sync-or-async `canon_lower`, with all
combinations working. This is why the `Task` base class (derived by `SyncTask`
and `AsyncTask`) contains the code for handling async-lowered subtasks. As
mentioned above, conservative syntactic analysis of all `canon` definitions in
a component can statically rule out combinations so that, e.g., a DAG of
all-sync components use a plain synchronous callstack and a DAG of all `async
callback` components use only an event loop without fibers. It's only when
`async` (without a `callback`) or various compositions of async and sync
components are used that fibers (or [Asyncify]) are required to implement the
above async rules.

Since any cross-component call necessarily transits through a statically-known
`canon_lower`+`canon_lift` call pair, an AOT compiler can fuse `canon_lift` and
`canon_lower` into a single, efficient trampoline. In the future this may allow
efficient compilation of permissive subtyping between components (including the
elimination of string operations on the labels of records and variants) as well
as post-MVP [adapter functions].

### `canon resource.new`

For a canonical definition:
```wasm
(canon resource.new $rt (core func $f))
```
validation specifies:
* `$rt` must refer to locally-defined (not imported) resource type
* `$f` is given type `(func (param $rt.rep) (result i32))`, where `$rt.rep` is
  currently fixed to be `i32`.

Calling `$f` invokes the following function, which adds an owning handle
containing the given resource representation in the current component
instance's handle table:
```python
async def canon_resource_new(rt, task, rep):
  h = HandleElem(rep, own=True)
  i = task.inst.handles.add(rt, h)
  return [i]
```

### `canon resource.drop`

For a canonical definition:
```wasm
(canon resource.drop $rt (core func $f))
```
validation specifies:
* `$rt` must refer to resource type
* `$f` is given type `(func (param i32))`

Calling `$f` invokes the following function, which removes the handle from the
current component instance's handle table and, if the handle was owning, calls
the resource's destructor.
```python
async def canon_resource_drop(rt, sync, task, i):
  inst = task.inst
  h = inst.handles.remove(rt, i)
  flat_results = [] if sync else [0]
  if h.own:
    assert(h.scope is None)
    trap_if(h.lend_count != 0)
    if inst is rt.impl:
      if rt.dtor:
        await rt.dtor(h.rep)
    else:
      if rt.dtor:
        caller_opts = CanonicalOptions(sync = sync)
        callee_opts = CanonicalOptions(sync = rt.dtor_sync, callback = rt.dtor_callback)
        ft = FuncType([U32()],[])
        callee = partial(canon_lift, callee_opts, rt.impl, rt.dtor, ft)
        flat_results = await canon_lower(caller_opts, callee, ft, task, [h.rep, 0])
      else:
        task.trap_if_on_the_stack(rt.impl)
  else:
    h.scope.drop_borrow()
  return flat_results
```
In general, the call to a resource's destructor is treated like a
cross-component call (as-if the destructor was exported by the component
defining the resource type). This means that cross-component destructor calls
follow the same concurrency rules as normal exports. However, since there are
valid reasons to call `resource.drop` in the same component instance that
defined the resource, which would otherwise trap at the reentrance guard of
`Task.enter`, an exception is made when the resource type's
implementation-instance is the same as the current instance (which is
statically known for any given `canon resource.drop`).

When a destructor isn't present, the rules still perform a reentrance check
since this is the caller's responsibility and the presence or absence of a
destructor is an encapsualted implementation detail of the resource type.

### `canon resource.rep`

For a canonical definition:
```wasm
(canon resource.rep $rt (core func $f))
```
validation specifies:
* `$rt` must refer to a locally-defined (not imported) resource type
* `$f` is given type `(func (param i32) (result $rt.rep))`, where `$rt.rep` is
  currently fixed to be `i32`.

Calling `$f` invokes the following function, which extracts the resource
representation from the handle.
```python
async def canon_resource_rep(rt, task, i):
  h = task.inst.handles.get(rt, i)
  return [h.rep]
```
Note that the "locally-defined" requirement above ensures that only the
component instance defining a resource can access its representation.

### 🔀 `canon task.backpressure`

For a canonical definition:
```wasm
(canon task.backpressure (core func $f))
```
validation specifies:
* `$f` is given type `[i32] -> []`

Calling `$f` invokes the following function, which sets the `backpressure`
flag on the current `ComponentInstance`:
```python
async def canon_task_backpressure(task, flat_args):
  trap_if(task.opts.sync)
  task.inst.backpressure = bool(flat_args[0])
  return []
```
The `backpressure` flag is read by `Task.enter` (defined above) to prevent new
tasks from entering the component instance and forcing the guest code to
consume resources.

### 🔀 `canon task.start`

For a canonical definition:
```wasm
(canon task.start $ft (core func $f))
```
validation specifies:
* `$f` is given type `$ft`, which validation requires to be a (core) function type

Calling `$f` invokes the following function which extracts the arguments from the
caller and lowers them into the current instance:
```python
async def canon_task_start(task, core_ft, flat_args):
  assert(len(core_ft.params) == len(flat_args))
  trap_if(task.opts.sync)
  trap_if(core_ft != flatten_functype(CanonicalOptions(), FuncType([], task.ft.params), 'lower', Needs()))
  task.start()
  args = task.on_start()
  flat_results = lower_flat_values(task, MAX_FLAT_RESULTS, args, task.ft.param_types(), CoreValueIter(flat_args))
  assert(len(core_ft.results) == len(flat_results))
  return flat_results
```
An expected implementation of `task.start` would generate a core wasm function
for each lowering of an `async`-lifted export that performs the fused copy of
the arguments into the caller, storing the index of this function in the `Task`
structure and using `call_indirect` to perform the function-type-equality check
required here. The call to `Task.start` (defined above) ensures that `canon
task.start` is called exactly once, before `canon task.return`, before an async
call finishes.

### 🔀 `canon task.return`

For a canonical definition:
```wasm
(canon task.return $ft (core func $f))
```
validation specifies:
* `$f` is given type `$ft`, which validation requires to be a (core) function type

Calling `$f` invokes the following function which lifts the results from the
current instance and passes them to the caller:
```python
async def canon_task_return(task, core_ft, flat_args):
  assert(len(core_ft.params) == len(flat_args))
  trap_if(task.opts.sync)
  trap_if(core_ft != flatten_functype(CanonicalOptions(), FuncType(task.ft.results, []), 'lower', Needs()))
  task.return_()
  results = lift_flat_values(task, MAX_FLAT_PARAMS, CoreValueIter(flat_args), task.ft.result_types())
  task.on_return(results)
  assert(len(core_ft.results) == 0)
  return []
```
An expected implementation of `task.return` would generate a core wasm function
for each lowering of an `async`-lifted export that performs the fused copy of
the results into the caller, storing the index of this function in the `Task`
structure and using `call_indirect` to perform the function-type-equality check
required here. The call to `Task.return_` (defined above) ensures that `canon
task.return` is called exactly once, after `canon task.start`, before an async
call finishes.

### 🔀 `canon task.wait`

For a canonical definition:
```wasm
(canon task.wait (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32) (result i32))`

Calling `$f` waits for progress to be made in a subtask of the current task,
returning the event (which is currently simply an `AsyncCallState` value)
and writing the subtask index as an outparam:
```python
async def canon_task_wait(task, ptr):
  trap_if(task.opts.callback is not None)
  event, payload = await task.wait()
  store(task, payload, U32(), ptr)
  return [event]
```
The `trap_if` ensures that, when a component uses a `callback` all events flow
through the event loop at the base of the stack.

Note that `task.wait` will `suspend` the current `Task`, allowing other tasks
to run. Note also that `task.wait` can be called from a synchronously-lifted
export so that even synchronous code can make concurrent import calls. In these
synchronous cases, though, the automatic backpressure (applied by
`SyncTask.enter`) will ensure there is only ever at most once
synchronously-lifted task executing in a component instance at a time.

### 🔀 `canon task.poll`

For a canonical definition:
```wasm
(canon task.poll (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32) (result i32))`

Calling `$f` does a non-blocking check for whether an event is already
available, returning whether or not there was such an event as a boolean and,
if there was an event, storing the `i32` event+payload pair as an outparam.
```python
async def canon_task_poll(task, ptr):
  ret = task.poll()
  if ret is None:
    return [0]
  store(task, ret, Tuple([U32(), U32()]), ptr)
  return [1]
```
Note that there is no `await` of `poll` and thus no possible task switching.

### 🔀 `canon task.yield`

For a canonical definition:
```wasm
(canon task.yield (core func $f))
```
validation specifies:
* `$f` is given type `(func)`

Calling `$f` calls `Task.yield_`, trapping if called when there is a `callback`.
(When there is a callback, yielding is achieved by returning with the LSB set.)
```python
async def canon_task_yield(task):
  trap_if(task.opts.callback is not None)
  await task.yield_()
  return []
```

### 🧵 `canon thread.spawn`

For a canonical definition:
```wasm
(canon thread.spawn (type $ft) (core func $st))
```
validation specifies:
* `$ft` must refer to a `shared` function type; initially, only the type `(func
  shared (param $c i32))` is allowed (see explanation below)
* `$st` is given type `(func (param $f (ref null $ft)) (param $c i32) (result $e
  i32))`.

> Note: ideally, a thread could be spawned with [arbitrary thread parameters].
> Currently, that would require additional work in the toolchain to support so,
> for simplicity, the current proposal simply fixes a single `i32` parameter type.
> However, `thread.spawn` could be extended to allow arbitrary thread parameters
> in the future, once it's concretely beneficial to the toolchain.
> The inclusion of `$ft` ensures backwards compatibility for when arbitrary
> parameters are allowed.

Calling `$st` checks that the reference `$f` is not null. Then, it spawns a
thread which:
  - invokes `$f` with `$c`
  - executes `$f` until completion or trap in a `shared` context as described by
    the [shared-everything threads] proposal.

In pseudocode, `$st` looks like:

```python
def canon_thread_spawn(f, c):
  trap_if(f is None)
  if DETERMINISTIC_PROFILE:
    return [-1]

  def thread_start():
    try:
      f(c)
    except CoreWebAssemblyException:
      trap()

  if spawn(thread_start):
    return [0]
  else:
    return [-1]
```

### 🧵 `canon thread.hw_concurrency`

For a canonical definition:
```wasm
(canon thread.hw_concurrency (core func $f))
```
validation specifies:
* `$f` is given type `(func shared (result i32))`.

Calling `$f` returns the number of threads the underlying hardware can be
expected to execute concurrently. This value can be artificially limited by
engine configuration and is not allowed to change over the lifetime of a
component instance.

```python
def canon_thread_hw_concurrency():
  if DETERMINISTIC_PROFILE:
    return [1]
  else:
    return [NUM_ALLOWED_THREADS]
```

[Canonical Definitions]: Explainer.md#canonical-definitions
[`canonopt`]: Explainer.md#canonical-definitions
[`canon`]: Explainer.md#canonical-definitions
[Type Definitions]: Explainer.md#type-definitions
[Component Invariant]: Explainer.md#component-invariants
[Component Invariants]: Explainer.md#component-invariants
[JavaScript Embedding]: Explainer.md#JavaScript-embedding
[Adapter Functions]: FutureFeatures.md#custom-abis-via-adapter-functions
[Shared-Everything Dynamic Linking]: examples/SharedEverythingDynamicLinking.md
[Structured Concurrency]: Async.md#structured-concurrency

[Administrative Instructions]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-instr-admin
[Implementation Limits]: https://webassembly.github.io/spec/core/appendix/implementation.html
[Function Instance]: https://webassembly.github.io/spec/core/exec/runtime.html#function-instances
[Two-level]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-import

[Multi-value]: https://github.com/WebAssembly/multi-value/blob/master/proposals/multi-value/Overview.md
[Exceptions]: https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md
[WASI]: https://github.com/webassembly/wasi
[Deterministic Profile]: https://github.com/WebAssembly/profiles/blob/main/proposals/profiles/Overview.md
[Typed Continuations]: https://github.com/WebAssembly/stack-switching/blob/main/proposals/continuations/Explainer.md
[`suspend`]: https://github.com/WebAssembly/stack-switching/blob/main/proposals/continuations/Explainer.md#suspending-continuations
[`resume`]: https://github.com/WebAssembly/stack-switching/blob/main/proposals/continuations/Explainer.md#invoking-continuations

[Alignment]: https://en.wikipedia.org/wiki/Data_structure_alignment
[UTF-8]: https://en.wikipedia.org/wiki/UTF-8
[UTF-16]: https://en.wikipedia.org/wiki/UTF-16
[Latin-1]: https://en.wikipedia.org/wiki/ISO/IEC_8859-1
[Unicode Scalar Value]: https://unicode.org/glossary/#unicode_scalar_value
[Unicode Code Point]: https://unicode.org/glossary/#code_point
[Surrogate]: https://unicode.org/faq/utf_bom.html#utf16-2
[Name Mangling]: https://en.wikipedia.org/wiki/Name_mangling
[Fibers]: https://en.wikipedia.org/wiki/Fiber_(computer_science)
[Asyncify]: https://emscripten.org/docs/porting/asyncify.html

[`import_name`]: https://clang.llvm.org/docs/AttributeReference.html#import-name
[`export_name`]: https://clang.llvm.org/docs/AttributeReference.html#export-name

[Arbitrary Thread Parameters]: https://github.com/WebAssembly/shared-everything-threads/discussions/3
[wasi-libc Convention]: https://github.com/WebAssembly/wasi-libc/blob/925ad6d7/libc-top-half/musl/src/thread/pthread_create.c#L318
[Shared-Everything Threads]: https://github.com/WebAssembly/shared-everything-threads/blob/main/proposals/shared-everything-threads/Overview.md
