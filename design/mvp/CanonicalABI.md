# Canonical ABI Explainer

This document defines the Canonical ABI used to convert between the values and
functions of components in the Component Model and the values and functions
of modules in Core WebAssembly. See the [AST explainer](Explainer.md) for a
walkthrough of the static structure of a component and the
[async explainer](Async.md) for a high-level description of the async model
being specified here.

* [Supporting definitions](#supporting-definitions)
  * [Lifting and Lowering Context](#lifting-and-lowering-context)
  * [Canonical ABI Options](#canonical-abi-options)
  * [Runtime State](#runtime-state)
    * [Component Instance State](#component-instance-state)
    * [Table State](#table-state)
    * [Resource State](#resource-state)
    * [Buffer State](#buffer-state)
    * [Task State](#task-state)
    * [Waitable State](#waitable-state)
    * [Subtask State](#subtask-state)
    * [Stream State](#stream-state)
    * [Future State](#future-state)
  * [Despecialization](#despecialization)
  * [Type Predicates](#type-predicates)
  * [Alignment](#alignment)
  * [Element Size](#element-size)
  * [Loading](#loading)
  * [Storing](#storing)
  * [Flattening](#flattening)
  * [Flat Lifting](#flat-lifting)
  * [Flat Lowering](#flat-lowering)
  * [Lifting and Lowering Values](#lifting-and-lowering-values)
* [Canonical definitions](#canonical-definitions)
  * [`canonopt` Validation](#canonopt-validation)
  * [`canon lift`](#canon-lift)
  * [`canon lower`](#canon-lower)
  * [`canon resource.new`](#canon-resourcenew)
  * [`canon resource.drop`](#canon-resourcedrop)
  * [`canon resource.rep`](#canon-resourcerep)
  * [`canon context.get`](#-canon-contextget) 🔀
  * [`canon context.set`](#-canon-contextset) 🔀
  * [`canon backpressure.set`](#-canon-backpressureset) 🔀
  * [`canon task.return`](#-canon-taskreturn) 🔀
  * [`canon task.cancel`](#-canon-taskcancel) 🔀
  * [`canon yield`](#-canon-yield) 🔀
  * [`canon waitable-set.new`](#-canon-waitable-setnew) 🔀
  * [`canon waitable-set.wait`](#-canon-waitable-setwait) 🔀
  * [`canon waitable-set.poll`](#-canon-waitable-setpoll) 🔀
  * [`canon waitable-set.drop`](#-canon-waitable-setdrop) 🔀
  * [`canon waitable.join`](#-canon-waitablejoin) 🔀
  * [`canon subtask.cancel`](#-canon-subtaskcancel) 🔀
  * [`canon subtask.drop`](#-canon-subtaskdrop) 🔀
  * [`canon {stream,future}.new`](#-canon-streamfuturenew) 🔀
  * [`canon stream.{read,write}`](#-canon-streamreadwrite) 🔀
  * [`canon future.{read,write}`](#-canon-futurereadwrite) 🔀
  * [`canon {stream,future}.cancel-{read,write}`](#-canon-streamfuturecancel-readwrite) 🔀
  * [`canon {stream,future}.drop-{readable,writable}`](#-canon-streamfuturedrop-readablewritable) 🔀
  * [`canon error-context.new`](#-canon-error-contextnew) 📝
  * [`canon error-context.debug-message`](#-canon-error-contextdebug-message) 📝
  * [`canon error-context.drop`](#-canon-error-contextdrop) 📝
  * [`canon thread.spawn_ref`](#-canon-threadspawn_ref) 🧵
  * [`canon thread.spawn_indirect`](#-canon-threadspawn_indirect) 🧵
  * [`canon thread.available_parallelism`](#-canon-threadavailable_parallelism) 🧵

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

While the Python code for lifting and lowering values appears to create an
intermediate copy when lifting linear memory into high-level Python values, a
real implementation should be able to fuse lifting and lowering into a single
direct copy from the source linear memory into the destination linear memory.
Similarly, while the Python code specifies [async](Async.md) using Python's
[`asyncio`] library, a real implementation is expected to implement this
specified behavior using other lower-level concurrency primitives such as
fibers or Core WebAssembly [stack-switching].

Lastly, independently of Python, the Canonical ABI defined below assumes that
out-of-memory conditions (such as `memory.grow` returning `-1` from within
`realloc`) will trap (via `unreachable`). This significantly simplifies the
Canonical ABI by avoiding the need to support the complicated protocols
necessary to support recovery in the middle of nested allocations. (Note: by
nature of eliminating `realloc`, switching to [lazy lowering] would obviate
this issue, allowing guest wasm code to handle failure by eagerly returning
some value of the declared return type to indicate failure.


### Lifting and Lowering Context

Most Canonical ABI definitions depend on some ambient information which is
established by the `canon lift`- or `canon lower`-defined function that is
being called:
* the ABI options supplied via [`canonopt`]
* the containing component instance
* the `Task` or `Subtask` used to lower or lift, resp., `borrow` handles

These three pieces of ambient information are stored in an `LiftLowerContext`
object that is threaded through all the Python functions below as the `cx`
parameter/field.
```python
class LiftLowerContext:
  opts: LiftLowerOptions
  inst: ComponentInstance
  borrow_scope: Optional[Task|Subtask]

  def __init__(self, opts, inst, borrow_scope = None):
    self.opts = opts
    self.inst = inst
    self.borrow_scope = borrow_scope
```
The `borrow_scope` field may be `None` if the types being lifted/lowered are
known to not contain `borrow`. The `CanonicalOptions`, `ComponentInstance`,
`Task` and `Subtask` classes are defined next.


### Canonical ABI Options

The following classes list the various Canonical ABI options ([`canonopt`])
that can be set on various Canonical ABI definitions. The default values of
the Python fields are the default values when the associated `canonopt` is
not present in the binary or text format definition.

The `LiftOptions` class contains the subset of [`canonopt`] which are needed
when lifting individual parameters and results:
```python
@dataclass
class LiftOptions:
  string_encoding: str = 'utf8'
  memory: Optional[bytearray] = None

  def equal(lhs, rhs):
    return lhs.string_encoding == rhs.string_encoding and \
           lhs.memory is rhs.memory
```
The `equal` static method is used by `task.return` below to dynamically
compare equality of just this subset of `canonopt`.

The `LiftLowerOptions` class contains the subset of [`canonopt`] which are
needed when lifting *or* lowering individual parameters and results:
```python
@dataclass
class LiftLowerOptions(LiftOptions):
  realloc: Optional[Callable] = None
```

The `CanonicalOptions` class contains the rest of the [`canonopt`]
options that affect how an overall function is lifted/lowered:
```python
@dataclass
class CanonicalOptions(LiftLowerOptions):
  post_return: Optional[Callable] = None
  sync: bool = True # = !canonopt.async
  callback: Optional[Callable] = None
```
(Note that the `async` `canonopt` is inverted to `sync` here for the practical
reason that `async` is a keyword and most branches below want to start with the
`sync = True` case.)


### Runtime State

The following Python classes define spec-internal state and utility methods
that are used to define the externally-visible behavior of Canonical ABI's
lifting, lowering and built-in definitions below. These fields are chosen for
simplicity over performance and thus an optimizing implementation is expected
to use a more optimized representations as long as it preserves the same
externally-visible behavior. Some specific examples of expected optimizations
are noted below.

There is a global singleton `asyncio.Lock` `scheduler` which is used to emulate
fiber-like [stack-switching] using Python's standard `asyncio` machinery:
```python
scheduler = asyncio.Lock()
```
The idea is to create a Python [`asyncio.Task`] for each stack but only allow 1
`asyncio.Task` to make progress at a time by parking all other (non-active)
`asyncio.Task`s on either:
1. an `await` of an `asyncio.Future` that is to be resolved by an active
   `asyncio.Task` *right before* the active `asyncio.Task` parks itself
   (effecting a deterministic stack switch); or
2. an `await scheduler.acquire()` that is to unblocked by the active
   `asyncio.Task` performing `scheduler.release()` *right before* parking
   itself (effecting a non-deterministic stack switch that allows the host
   to take into account I/O readiness, priorities and other scheduling
   concerns).

Without this scheme, the `asyncio.Task`s representing stacks would be able to
switch at any internal `await` point according to normal `async`/`await` rules,
which would semantically look more like non-cooperative multi-threading.


#### Component Instance State

The `ComponentInstance` class contains all the relevant per-component-instance
state that the definitions below use to implement the Component Model's runtime
behavior and enforce invariants.
```python
class ComponentInstance:
  table: Table
  may_leave: bool
  no_backpressure: asyncio.Event
  exclusive: asyncio.Lock
  pending_tasks: int

  def __init__(self):
    self.table = Table()
    self.may_leave = True
    self.no_backpressure = asyncio.Event()
    self.no_backpressure.set()
    self.exclusive = asyncio.Lock()
    self.pending_tasks = 0
```
These fields will be described as they are used by the following definitions.


#### Table State

The `Table` class encapsulates a mutable, growable array of opaque elements
that are represented in Core WebAssembly as `i32` indices into the array. There
is one `Table` object per `ComponentInstance` object and  "the current
component instance's table" refers to this object.
```python
class Table:
  array: list[any]
  free: list[int]

  MAX_LENGTH = 2**28 - 1

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
      trap_if(i > Table.MAX_LENGTH)
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

The limit of `2**28` ensures that the high 2 bits of table indices are unset
and available for other use in guest code (e.g., for tagging, packed words or
sentinel values).


#### Resource State

The `ResourceHandle` class defines the elements of the component instance's
table used to represent handles to resources:
```python
class ResourceHandle:
  rt: ResourceType
  rep: int
  own: bool
  borrow_scope: Optional[Task]
  num_lends: int

  def __init__(self, rt, rep, own, borrow_scope = None):
    self.rt = rt
    self.rep = rep
    self.own = own
    self.borrow_scope = borrow_scope
    self.num_lends = 0
```
The `rt` and `rep` fields of `ResourceHandle` store the `rt` and `rep`
parameters passed to the `resource.new` call that created this handle. The
`rep` field is currently fixed to be an `i32`, but will be generalized in the
future to other types.

The `own` field indicates whether this element was created from an `own` type
(or, if false, a `borrow` type).

The `borrow_scope` field stores the `Task` that lowered the borrowed handle as a
parameter. When a component only uses sync-lifted exports, due to lack of
reentrance, there is at most one `Task` alive in a component instance at any
time and thus an optimizing implementation doesn't need to store the `Task`
per `ResourceHandle`.

The `num_lends` field maintains a conservative approximation of the number of
live handles that were lent from this `own` handle (by calls to `borrow`-taking
functions). This count is maintained by the `ImportCall` bookkeeping functions
(above) and is ensured to be zero when an `own` handle is dropped.

The `ResourceType` class represents a runtime instance of a resource type that
has been created either by the host or a component instance (where multiple
component instances of the same static component create multiple `ResourceType`
instances). `ResourceType` Python object identity is used by trapping guards on
the `rt` field of `ResourceHandle` (above) and thus resource type equality is
*not* defined structurally (on the contents of `ResourceType`).
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


#### Buffer State

A "buffer" is an abstract region of memory that can either be read-from or
written-to. This region of memory can either be owned by the host or by wasm.
Currently wasm memory is always 32-bit linear memory, but soon 64-bit and GC
memory will be added. Thus, buffers provide an abstraction over at least 4
different "kinds" of memory.

(Currently, buffers are only created implicitly as part of stream and future
built-ins such as `stream.read`. However, in the
[future](https://github.com/WebAssembly/component-model/issues/369#issuecomment-2248574765),
explicit component-level buffer types and canonical built-ins may be added to
allow explicitly creating buffers and passing them between components.)

A "readable buffer" allows reading `t` values *from* the buffer's memory. A
"writable buffer" allows writing `t` values *into* the buffer's memory. All
buffers have an associated component-level value type `t` and a `remain` method
that returns how many `t` values may still be read or written. Buffers mostly
hide their original/complete size. However, zero-length buffers need to be
treated specially (particularly when a zero-length read rendezvous with a
zero-length write), so there is a special query for detecting whether a buffer
is zero-length. Based on this, buffers are represented by the following 3
abstract Python classes:
```python
class Buffer:
  MAX_LENGTH = 2**28 - 1
  t: ValType
  remain: Callable[[], int]
  is_zero_length: Callable[[], bool]

class ReadableBuffer(Buffer):
  read: Callable[[int], list[any]]

class WritableBuffer(Buffer):
  write: Callable[[list[any]]]
```
As preconditions (internally ensured by the Canonical ABI code below):
* `read` may only be passed a positive number less than or equal to `remain`
* `write` may only be passed a non-empty list of length less than or equal to
  `remain` containing values of type `t`

Since `read` and `write` are synchronous Python functions, buffers inherently
guarantee synchronous access to a fixed-size backing memory and are thus
distinguished from streams (which provide *asynchronous* operations for reading
and writing an unbounded number of values to potentially-different regions of
memory over time).

The `ReadableBuffer` and `WritableBuffer` abstract classes may either be
implemented by the host or by another wasm component. In the latter case, these
abstract classes are implemented by the concrete `ReadableBufferGuestImpl` and
`WritableBufferGuestImpl` classes which eagerly check alignment and range
when the buffer is constructed so that `read` and `write` are infallible
operations (modulo traps):
```python
class BufferGuestImpl(Buffer):
  cx: LiftLowerContext
  t: ValType
  ptr: int
  progress: int
  length: int

  def __init__(self, t, cx, ptr, length):
    trap_if(length > Buffer.MAX_LENGTH)
    if t and length > 0:
      trap_if(ptr != align_to(ptr, alignment(t)))
      trap_if(ptr + length * elem_size(t) > len(cx.opts.memory))
    self.cx = cx
    self.t = t
    self.ptr = ptr
    self.progress = 0
    self.length = length

  def remain(self):
    return self.length - self.progress

  def is_zero_length(self):
    return self.length == 0

class ReadableBufferGuestImpl(BufferGuestImpl):
  def read(self, n):
    assert(n <= self.remain())
    if self.t:
      vs = load_list_from_valid_range(self.cx, self.ptr, n, self.t)
      self.ptr += n * elem_size(self.t)
    else:
      vs = n * [()]
    self.progress += n
    return vs

class WritableBufferGuestImpl(BufferGuestImpl, WritableBuffer):
  def write(self, vs):
    assert(len(vs) <= self.remain())
    if self.t:
      store_list_into_valid_range(self.cx, vs, self.ptr, self.t)
      self.ptr += len(vs) * elem_size(self.t)
    else:
      assert(all(v == () for v in vs))
    self.progress += len(vs)
```
When `t` is `None` (arising from `stream` and `future` with empty element
types), the core-wasm-supplied `ptr` is entirely ignored, while the `length`
and `progress` are still semantically meaningful. Source bindings may represent
this case with a generic stream/future of [unit] type or a distinct type that
conveys events without values.

The `load_list_from_valid_range` and `store_list_into_valid_range` functions
that do all the heavy lifting are shared with function parameter/result lifting
and lowering and defined below.


#### Context-Local Storage

The `ContextLocalStorage` class implements [context-local storage], with each
new `Task` getting a fresh, zero-initialized `ContextLocalStorage` that can be
accessed by core wasm code using `canon context.{get,set}`. (In the future,
when threads are integrated, each `thread.spawn`ed thread would also get a
fresh, zero-initialized `ContextLocalStorage`.)
```python
class ContextLocalStorage:
  LENGTH = 1
  array: list[int]

  def __init__(self):
    self.array = [0] * ContextLocalStorage.LENGTH

  def set(self, i, v):
    assert(types_match_values(['i32'], [v]))
    self.array[i] = v

  def get(self, i):
    return self.array[i]
```
`LENGTH` is currently set to `1`, but the plan is to increase it to `2` once
toolchains are ready to migrate the linear-memory-stack pointer from a
`global` to context-local storage as part of implementing threads.


#### Waitable State

A "waitable" is a concurrent activity that can be waited on by the built-ins
`waitable-set.wait` and `waitable-set.poll`. Currently, there are 5 different
kinds of waitables: [subtasks](Async.md#structured-concurrency)
and the 4 combinations of the [readable and writable ends of futures and
streams](Async.md#streams-and-futures).

Waitables deliver "events" which are values of the following `EventTuple` type.
The two `int` "payload" fields of `EventTuple` store core wasm `i32`s and are
to be interpreted based on the `EventCode`. The meaning of the different
`EventCode`s and their payloads will be introduced incrementally below by the
code that produces the events (specifically, in `subtask_event`, `stream_event`
or `future_event`).
```python
class EventCode(IntEnum):
  NONE = 0
  SUBTASK = 1
  STREAM_READ = 2
  STREAM_WRITE = 3
  FUTURE_READ = 4
  FUTURE_WRITE = 5
  TASK_CANCELLED = 6

EventTuple = tuple[EventCode, int, int]
```

The `Waitable` class factors out the state and behavior common to all 5 kinds
of waitables, which are each defined as subclasses of `Waitable` below. Every
`Waitable` can store at most one pending event in its `pending_event` field
which will be delivered to core wasm as soon as the core wasm code explicitly
waits on this `Waitable` (which may take an arbitrarily long time). A
`pending_event` is represented in the Python code below as a *closure* so that
the closure can specify behaviors that trigger *right before* events are
delivered to core wasm and so that the closure can compute the event based on
the state of the world at delivery time (as opposed to when `pending_event` was
first set). Currently, `pending_event` holds a closure of the `subtask_event`,
`stream_event` or `future_event` functions defined below. An optimizing
implementation would avoid closure allocation by inlining a union containing
the closure fields directly in the component instance table.

A waitable can belong to at most one "waitable set" (defined next) which is
referred to by the `maybe_waitable_set` field. A `Waitable`'s `pending_event`
is delivered when core wasm code waits on a task's waitable set (via
`task.wait` or, when using `callback`, by returning to the event loop). The
`maybe_has_pending_event` field of `WaitableSet` stores an [`asyncio.Event`]
boolean which is used to wait for *any* `Waitable` element to make progress. As
the name implies, `maybe_has_pending_event` is allowed to have false positives
(but not false negatives) and thus it's not `clear()`ed even when a
`Waitable`'s `pending_event` is cleared (because other `Waitable`s in the set
may still have a pending event).

In addition to being waited on as a member of a task, a `Waitable` can also be
waited on individually (e.g., as part of a synchronous `stream.cancel-read`).
This is enabled by the `has_pending_event_` field which stores an
[`asyncio.Event`] boolean that `is_set()` iff `pending_event` is set.

Based on all this, the `Waitable` class is defined as follows:
```python
class Waitable:
  pending_event: Optional[Callable[[], EventTuple]]
  has_pending_event_: asyncio.Event
  maybe_waitable_set: Optional[WaitableSet]

  def __init__(self):
    self.pending_event = None
    self.has_pending_event_ = asyncio.Event()
    self.maybe_waitable_set = None

  def set_event(self, pending_event):
    self.pending_event = pending_event
    self.has_pending_event_.set()
    if self.maybe_waitable_set:
      self.maybe_waitable_set.maybe_has_pending_event.set()

  def has_pending_event(self):
    assert(self.has_pending_event_.is_set() == bool(self.pending_event))
    return self.has_pending_event_.is_set()

  async def wait_for_pending_event(self):
    return await self.has_pending_event_.wait()

  def get_event(self) -> EventTuple:
    assert(self.has_pending_event())
    pending_event = self.pending_event
    self.pending_event = None
    self.has_pending_event_.clear()
    return pending_event()

  def join(self, maybe_waitable_set):
    if self.maybe_waitable_set:
      self.maybe_waitable_set.elems.remove(self)
    self.maybe_waitable_set = maybe_waitable_set
    if maybe_waitable_set:
      maybe_waitable_set.elems.append(self)
      if self.has_pending_event():
        maybe_waitable_set.maybe_has_pending_event.set()

  def drop(self):
    assert(not self.has_pending_event())
    self.join(None)
```

A "waitable set" contains a collection of waitables that can be waited on or
polled for *any* element to make progress. Although the `WaitableSet` class
below represents `elems` as a `list` and implements `poll` with an O(n) search,
because a waitable can be associated with at most one set and can contain at
most one pending event, a real implementation could instead store a list of
waitables-with-pending-events as a linked list embedded directly in the
component instance's table element to avoid the separate allocation while
providing O(1) polling.
```python
class WaitableSet:
  elems: list[Waitable]
  maybe_has_pending_event: asyncio.Event
  num_waiting: int

  def __init__(self):
    self.elems = []
    self.maybe_has_pending_event = asyncio.Event()
    self.num_waiting = 0

  def poll(self) -> Optional[EventTuple]:
    if not DETERMINISTIC_PROFILE:
      random.shuffle(self.elems)
    for w in self.elems:
      assert(self is w.maybe_waitable_set)
      if w.has_pending_event():
        assert(self.maybe_has_pending_event.is_set())
        return w.get_event()
    self.maybe_has_pending_event.clear()
    return None

  def drop(self):
    trap_if(len(self.elems) > 0)
    trap_if(self.num_waiting > 0)
```
The `WaitableSet.drop` method traps if dropped while it still contains elements
(whose `Waitable.waitable_set` field would become dangling) or if it is being
waited-upon by another `Task` (as indicated by the `num_waiting` field, which
is incremented/decremented by `Task.wait_for_event` below).

Note: the `random.shuffle` in `poll` is meant to give runtimes the semantic
freedom to schedule delivery of events non-deterministically (e.g., taking into
account priorities); runtimes do not have to literally randomize event
delivery.


#### Task State

A "task" is created for each call to a component export and is implicitly
threaded through all core function calls as the "[current task]".

Tasks are parameterized by the caller with 3 callbacks of the following types:
```python
class Cancelled(IntEnum):
  FALSE = 0
  TRUE = 1

OnStart = Callable[[], list[any]]
OnResolve = Callable[[Optional[list[any]]], None]
OnBlock = Callable[[Awaitable], Awaitable[Cancelled]]
```
and with the following meanings:
* The `OnStart` callback is called by the task when the task is ready to start
  running. `OnStart` returns the list of lifted argument values which the task
  must then lower into its core wasm state. `OnStart` must be called exactly
  once.
* The `OnResolve` callback is called by the task when the task is ready to
  report to its caller that it is either returning (0 or 1) values or has been
  successfully cancelled (by passing `None`). `OnResolve` must be called
  exactly once and only after `OnStart` and may only pass `None` if `OnBlock`
  has previously requested cancellation.
* The `OnBlock` callback is called by the task whenever the task needs to block
  on a Python [awaitable]. `OnBlock` allows a transitive (async) supertask to
  take control flow while its subtask is blocked. During a call to `OnBlock`,
  any other `asyncio.Task`s can be scheduled or new `asyncio.Task`s can be
  started in response to new export calls. `OnBlock` may return `Cancelled.TRUE`
  at most once before a task is resolved to signal that the caller is requesting
  cancellation; in this case, the given awaitable may not be resolved, and the
  cancelled task should call `OnResolve` ASAP (potentially passing `None`).

Tasks are represented by objects of the `Task` class which are created by the
`canon_lift` function (defined below). `Task` is introduced in chunks, starting
with fields and initialization:
```python
class Task:
  class State(Enum):
    INITIAL = 1
    PENDING_CANCEL = 2
    CANCEL_DELIVERED = 3
    RESOLVED = 4

  state: State
  opts: CanonicalOptions
  inst: ComponentInstance
  ft: FuncType
  supertask: Optional[Task]
  on_resolve: OnResolve
  on_block: OnBlock
  num_borrows: int
  context: ContextLocalStorage

  def __init__(self, opts, inst, ft, supertask, on_resolve, on_block):
    self.state = Task.State.INITIAL
    self.opts = opts
    self.inst = inst
    self.ft = ft
    self.supertask = supertask
    self.on_resolve = on_resolve
    self.on_block = on_block
    self.num_borrows = 0
    self.context = ContextLocalStorage()
```
Using a conservative syntactic analysis of a complete component, an optimizing
implementation can statically eliminate fields when a particular feature (such
as `borrow` or `async`) is not present in the component definition.

The `Task.trap_if_on_the_stack` method checks for unintended reentrance,
enforcing a [component invariant]. This guard uses the `supertask` field of
`Task` which points to the task's supertask in the async call tree defined by
[structured concurrency]. Structured concurrency is necessary to distinguish
between the deadlock-hazardous kind of reentrance (where the new task is a
transitive subtask of a task already running in the same component instance)
and the normal kind of async reentrance (where the new task is just a sibling
of any existing tasks running in the component instance). Note that, in the
[future](Async.md#TODO), there will be a way for a function to opt in (via
function type attribute) to the hazardous kind of reentrance, which will nuance
this test.
```python
  def trap_if_on_the_stack(self, inst):
    c = self.supertask
    while c is not None:
      trap_if(c.inst is inst)
      c = c.supertask
```
An optimizing implementation can avoid the O(n) loop in `trap_if_on_the_stack`
in several ways:
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

The `Task.needs_exclusive` predicate returns whether the Canonical ABI options
indicate that the core wasm being executed does not expect to be reentered
(e.g., because the code is using a single global linear memory shadow stack).
Concretely, this is assumed to be the case when core wasm is lifted
synchronously or with `async callback`. This predicate is used by the other
`Task` methods to determine whether to acquire/release the
component-instance-wide `exclusive` [`asyncio.Lock`].
```python
  def needs_exclusive(self):
    return self.opts.sync or self.opts.callback

```

The `Task.enter` method implements [backpressure] between when a caller makes a
call to an imported callee and when the callee's core wasm entry point is
executed. This interstitial placement allows an overloaded component instance
to avoid the need to otherwise-endlessly allocate guest memory for blocked
async calls until OOM. When backpressure is enabled, `enter` will block until
backpressure is disabled. There are three sources of backpressure:
 1. *Explicit backpressure* triggered by core wasm calling `backpressure.set`
    which, in `canon_backpressure_set` (defined below), clears the
    `no_backpressure` [`asyncio.Event`].
 2. *Residual backpressure* triggered by explicit backpressure having been
    disabled, but there still being greater than zero "pending" tasks that need
    to be given the chance to start without getting starved by new tasks.
 3. *Implicit backpressure* triggered when `Task.needs_exclusive()` is true and
    the `exclusive` lock is already held.

Introducing `Task.enter` in two cases, the first case is the fast path where
none of these three sources of backpressure apply and thus the new task can
start without "blocking" (which means control flow deterministically proceeds
to lowering arguments and calling the core wasm callee):
```python
  async def enter(self):
    if (self.inst.no_backpressure.is_set() and
        self.inst.pending_tasks == 0 and
        (not self.needs_exclusive() or not self.inst.exclusive.locked())):
      if self.needs_exclusive():
        await self.inst.exclusive.acquire()
      return True
```

The `else` branch handles the case where backpressure is needed and thus the
task must "block" (which means deterministically returning control flow to any
transitive `async` callers on the stack via the `OnBlock` callback). The code
below is careful to satisfy three requirements:
 1. The component-instance-wide `pending_tasks` counter tracks how many
    residual tasks are still waiting to start due to explicit backpressure.
 2. While blocked in `Task.enter`, caller cancellation (signalled by
    `OnBlock` returning `Cancelled.TRUE`) aborts execution immediately by
    calling `on_resolve(None)` without waiting for anything else first.
 3. Once backpressure is (re)enabled, no tasks start, even previous pending
    tasks (i.e., disabling backpressure doesn't unleash a thundering herd of
    unstoppable pending tasks).

To satisfy these requirements, `Task.enter` checks `no_backpressure` in a loop
after `OnBlock` returns. Residual backpressure is only checked once to trigger
this whole `else` branch; afterwards, `OnBlock` is allowed to
non-deterministically decide which tasks are scheduled, giving the host a
chance to non-deterministically start new or pending tasks (e.g., based on
prioritization heuristics):
```python
    else:
      while True:
        self.inst.pending_tasks += 1
        no_backpressure = asyncio.create_task(self.inst.no_backpressure.wait())
        cancelled = await self.on_block(no_backpressure)
        self.inst.pending_tasks -= 1
        if cancelled:
          self.on_resolve(None)
          return False
        if not self.inst.no_backpressure.is_set():
          continue
        if self.needs_exclusive():
          acquired = asyncio.create_task(self.inst.exclusive.acquire())
          if await self.on_block(acquired) == Cancelled.TRUE:
            if acquired.done():
              self.inst.exclusive.release()
            else:
              acquired.cancel()
            self.on_resolve(None)
            return False
          if not self.inst.no_backpressure.is_set():
            self.inst.exclusive.release()
            continue
        return True
```
While the above Python code loops and calls `OnBlock` multiple times, from a
semantic perspective, all that matters is that `OnBlock` is called at least
once (thereby returning control flow back to any `async` callers). A realistic
implementation could avoid the loop and multiple suspensions by having the
scheduler simultaneously check all the backpressure conditions before starting
a new `async` task.

The `Task.block_on` method defines what happens when a task needs to
potentially block until a given Python [awaitable] completes. This awaitable
can either represent external I/O or some event triggered by internal wasm
execution.
```python
  async def block_on(self, awaitable, cancellable = False, for_callback = False) -> Cancelled:
    f = asyncio.ensure_future(awaitable)
    if f.done() and not DETERMINISTIC_PROFILE and random.randint(0,1):
      return Cancelled.FALSE

    if for_callback:
      self.inst.exclusive.release()

    cancelled = await self.on_block(f)
    if cancelled and not cancellable:
      assert(await self.on_block(f) == Cancelled.FALSE)

    if for_callback:
      acquired = asyncio.create_task(self.inst.exclusive.acquire())
      if await self.on_block(acquired) == Cancelled.TRUE:
        assert(self.on_block(acquired) == Cancelled.FALSE)
        cancelled = Cancelled.TRUE

    if cancelled:
      assert(self.state == Task.State.INITIAL)
      if not cancellable:
        self.state = Task.State.PENDING_CANCEL
        return Cancelled.FALSE
      else:
        self.state = Task.State.CANCEL_DELIVERED
        return Cancelled.TRUE
    else:
      return Cancelled.FALSE
```
If the given `awaitable` is already `done()`, the Component Model allows the
runtime to non-deterministically avoid "blocking" the task.

If `block_on` is called with `cancellable` set, then the caller is ready to
handle a supertask's request for cancellation so `block_on` propagates
cancellation requests returned by the `OnBlock` callback. However, if
`cancellable` is *not* set, the caller does not expect cancellation and needs
to wait until the given awaitable is complete. To handle this case, `block_on`
records the supertask's cancellation request in `state` and calls the `OnBlock`
callback a second time (which, by contract, will not return `Cancelled.TRUE` a
second time). Future `cancellable` calls will see the `PENDING_CANCEL` in
`state` and deliver the cancellation request to the core wasm caller.

If `block_on` is called with `for_callback` set, then the `exclusive` lock
(which is used to serialize non-reentrant execution of synchronous and `async
callback` code) is `release()`ed before blocking and re-`acquire()`d after
unblocking. `for_callback` is set by the `async callback` event loop to allow
concurrent tasks to execute when the current task blocks at a reentrancy-safe
point.

The `Task.call_sync` method defines how a task makes a synchronous call to an
imported `callee`. `call_sync` works like `block_on` with `cancellable = False`
(recording the request for cancellation and calling `OnBlock` a second time)
except that `call_sync` only blocks if `callee` transitively blocks. This means
that N-deep synchronous callstacks avoid the overhead of async calls if none of
the calls in the stack actually block on external I/O.
```python
  async def call_sync(self, callee, on_start, on_return):
    async def sync_on_block(awaitable):
      if await self.on_block(awaitable) == Cancelled.TRUE:
        assert(self.state == Task.State.INITIAL)
        self.state = Task.State.PENDING_CANCEL
        assert(await self.on_block(awaitable) == Cancelled.FALSE)
      return Cancelled.FALSE

    await callee(self, on_start, on_return, sync_on_block)
```

The `Task.wait_for_event` method is called by `canon_waitable_set_wait` or,
when a `callback` is used, when the `callback` returns `WAIT` to the event
loop. `wait_for_event` waits until a `Waitable` in a given `WaitableSet` makes
progress:
```python
  async def wait_for_event(self, waitable_set, cancellable, for_callback) -> EventTuple:
    if cancellable and self.state == Task.State.PENDING_CANCEL:
      self.state = Task.State.CANCEL_DELIVERED
      return (EventCode.TASK_CANCELLED, 0, 0)
    else:
      waitable_set.num_waiting += 1
      e = None
      while not e:
        maybe_event = waitable_set.maybe_has_pending_event.wait()
        if await self.block_on(maybe_event, cancellable, for_callback) == Cancelled.TRUE:
          return (EventCode.TASK_CANCELLED, 0, 0)
        e = waitable_set.poll()
      waitable_set.num_waiting -= 1
    return e
```
As mentioned above with `WaitableSet`, `maybe_has_pending_event` is allowed to
have false positives and so a loop is required to `poll()` repeatedly until
there is actually an event. This looping as well as the number of iterations is
not semantically observable by the wasm code and so the host implementation can
loop or not using its own event delivery scheme.

If there is already a pending cancellation request (from a previous
non-cancellable `block_on` or a `call_sync`), the cancellation request is
delivered to core wasm via the `TASK_CANCELLED` event code and task's `state`
is transitioned to `CANCEL_DELIVERED` so that `canon_task_cancel` can be called
without trapping. If cancellation is requested *during* `wait_for_event`, there
is a direct transition to the `CANCEL_DELIVERED` state.

The `num_waiting` increment/decrement prevent the given waitable set from being
`waitable-set.drop`ed in the interim.

The `Task.yield_` method is called by `canon_yield` or, when a `callback` is
used, when the `callback` returns `YIELD` to the event loop. Yielding allows
the runtime to switch execution to another task without having to wait for any
external I/O. This is emulated in the Python code below by waiting on an
immediately-resolved future, which calls the `OnBlock` callback, which allows
control flow to switch to other `asyncio.Task`s.
```python
  async def yield_(self, cancellable, for_callback) -> EventTuple:
    if cancellable and self.state == Task.State.PENDING_CANCEL:
      self.state = Task.State.CANCEL_DELIVERED
      return (EventCode.TASK_CANCELLED, 0, 0)
    elif await self.block_on(asyncio.sleep(0), cancellable, for_callback) == Cancelled.TRUE:
      return (EventCode.TASK_CANCELLED, 0, 0)
    else:
      return (EventCode.NONE, 0, 0)
```
Handling of cancellation requests in `yield_` mirrors `wait_for_event` above,
handling both the cases of pending cancellation and cancellation while
yielding.

The `Task.poll_for_event` method is called by `canon_waitable_set_poll` or,
when a `callback` is used, when the `callback` returns `POLL` to the event
loop. Polling returns the `NONE` event code instead of blocking when there are
no pending events.
```python
  async def poll_for_event(self, waitable_set, cancellable, for_callback) -> Optional[EventTuple]:
    waitable_set.num_waiting += 1
    event_code,_,_ = e = await self.yield_(cancellable, for_callback)
    waitable_set.num_waiting -= 1
    if event_code == EventCode.TASK_CANCELLED:
      return e
    elif (e := waitable_set.poll()):
      return e
    else:
      return (EventCode.NONE, 0, 0)
```
The implicit `yield_` call in `poll_for_event` allows other tasks to be
scheduled, preventing starvation in various common polling use cases. The
`num_waiting` increment/decrement prevents the given waitable set from being
`waitable-set.drop`ed in the interim.

The `Task.return_` method is called by either `canon_task_return` or
`canon_lift` to return a list of `0` or `1` lifted values to the task's caller
via the `OnResolve` callback. There is a dynamic error if the callee has not
dropped all borrowed handles by the time `task.return` is called which means
that the caller can assume that all its lent handles have been returned to it
when it receives the `SUBTASK` `RETURNED` event.
```python
  def return_(self, result):
    trap_if(self.state == Task.State.RESOLVED)
    trap_if(self.num_borrows > 0)
    assert(result is not None)
    self.on_resolve(result)
    self.state = Task.State.RESOLVED
```

The `Task.cancel` method is called by `canon_task_cancel` and enforces the same
`num_borrows` condition as `return_`, ensuring that when the caller's
`OnResolve` callback is called, the caller knows all borrows have been returned.
```python
  def cancel(self):
    trap_if(self.state != Task.State.CANCEL_DELIVERED)
    trap_if(self.num_borrows > 0)
    self.on_resolve(None)
    self.state = Task.State.RESOLVED
```
As guarded here, the `task.cancel` built-in can only be called after the
`TASK_CANCELLED` event code has been delivered to core wasm.

Lastly, the `Task.exit` method is called when the task has finished executing
to check that the task has returned a value (or been cancelled) and to release
the `exclusive` lock that was `acquire()`d by `Task.enter()` to serialize
non-reentrant core wasm execution.
```python
  def exit(self):
    trap_if(self.state != Task.State.RESOLVED)
    assert(self.num_borrows == 0)
    if self.needs_exclusive():
      self.inst.exclusive.release()
```


#### Subtask State

While `canon_lift` creates `Task` objects, `canon_lower` creates `Subtask`
objects, using `Subtask` to contain all the state relevant to the caller. See
the [structured concurrency] section for a summary of how `Task` and `Subtask`
relate with respect to component- and host-defined callers and callees. This
section introduces `Subtask` incrementally, starting with its fields and
initialization:
```python
class Subtask(Waitable):
  class State(IntEnum):
    STARTING = 0
    STARTED = 1
    RETURNED = 2
    CANCELLED_BEFORE_STARTED = 3
    CANCELLED_BEFORE_RETURNED = 4

  state: State
  supertask: Optional[Task]
  lenders: Optional[list[ResourceHandle]]
  request_cancel_begin: asyncio.Future
  request_cancel_end: asyncio.Future

  def __init__(self, supertask):
    Waitable.__init__(self)
    self.state = Subtask.State.STARTING
    self.supertask = supertask
    self.lenders = []
    self.request_cancel_begin = asyncio.Future()
    self.request_cancel_end = asyncio.Future()
```
The `state` field of `Subtask` tracks the callee's progression from the initial
[`STARTING`](Async.md#backpressure) state along the [subtask state machine].
The `state` field is updated immediately when the callee calls the `OnStart`
and `OnResolve` callbacks (which are implemented by the
`{sync,async}_on_{start,resolve}` functions nested in the
`Subtask.call_{sync,async}` methods defined next.

The `Subtask.call_sync` method wraps the `Task.call_sync` method, intercepting
the `OnStart` and `OnResolve` calls from `callee` in order to track `state`
transitions:
```python
  async def call_sync(self, callee, on_start, on_resolve):
    def sync_on_start():
      assert(self.state == Subtask.State.STARTING)
      self.state = Subtask.State.STARTED
      return on_start()

    def sync_on_resolve(result):
      assert(result is not None)
      assert(self.state == Subtask.State.STARTED)
      self.state = Subtask.State.RETURNED
      on_resolve(result)

    await Task.call_sync(self.supertask, callee, sync_on_start, sync_on_resolve)
```

The following three methods are used to implement subtask cancellation in
conjunction with `call_async` (next). The Canonical ABI specifies that
`subtask.cancel` can only be called once for a given subtask before it has been
resolved. This is implemented by `canon_subtask_cancel` using the following
`Subtask.cancelled` and `Subtask.resolved` methods. After guarding,
`canon_subtask_cancel` will then call `Subtask.request_cancel` to actually
initiate the cancellation.
```python
  def cancelled(self):
    return self.request_cancel_begin.done()

  def resolved(self):
    match self.state:
      case (Subtask.State.STARTING |
            Subtask.State.STARTED):
        return False
      case (Subtask.State.RETURNED |
            Subtask.State.CANCELLED_BEFORE_STARTED |
            Subtask.State.CANCELLED_BEFORE_RETURNED):
        return True

  async def request_cancel(self):
    assert(not self.cancelled() and not self.resolved())
    self.request_cancel_begin.set_result(None)
    await self.request_cancel_end
```
As implemented here in conjunction with `call_async`, control flow is
transferred to the subtask by resolving `request_cancel_begin` and transferred
back by having the subtask resolve `request_cancel_end`.

The `Subtask.call_async` method calls `callee`, intercepting `OnBlock` in order
to prevent the caller from blocking if `callee` blocks and to request
cancellation:
```python
  async def call_async(self, callee, on_start, on_resolve):
    async def do_call():
      await callee(self.supertask, async_on_start, async_on_resolve, async_on_block)
      relinquish_control()

    def async_on_start():
      assert(self.state == Subtask.State.STARTING)
      self.state = Subtask.State.STARTED
      return on_start()

    def async_on_resolve(result):
      if result is None:
        if self.state == Subtask.State.STARTING:
          self.state = Subtask.State.CANCELLED_BEFORE_STARTED
        else:
          assert(self.state == Subtask.State.STARTED)
          self.state = Subtask.State.CANCELLED_BEFORE_RETURNED
      else:
        assert(self.state == Subtask.State.STARTED)
        self.state = Subtask.State.RETURNED
      on_resolve(result)

    async def async_on_block(awaitable):
      relinquish_control()
      if not self.request_cancel_end.done():
        await asyncio.wait([awaitable, self.request_cancel_begin],
                           return_when = asyncio.FIRST_COMPLETED)
        if self.request_cancel_begin.done():
          return Cancelled.TRUE
      else:
        await awaitable
      assert(awaitable.done())
      await scheduler.acquire()
      return Cancelled.FALSE

    def relinquish_control():
      if not ret.done():
        ret.set_result(None)
      elif self.request_cancel_begin.done() and not self.request_cancel_end.done():
        self.request_cancel_end.set_result(None)
      else:
        scheduler.release()

    ret = asyncio.Future()
    asyncio.create_task(do_call())
    await ret
```
Explaining what's going on here:
* `call_async` creates a new [`asyncio.Task`] to `await` the call to `callee`
  and then immediately `await`s a future `ret` that will be resolved by this
  new `asyncio.Task`. The net effect of this is a deterministic control flow
  transfer from `call_async` to `callee`.
* If `callee` returns without calling its `OnBlock` callback, `do_call`'s call
  to `relinquish_control` resolves `ret` and unblocks `call_async`. The net
  effect of this is a deterministic control flow transfer from `callee` back to
  `call_async`. Thus, if `callee` doesn't block, the entire call executes
  synchronously.
* If `callee` calls its `OnBlock` callback, then `async_on_block` will
  `relinquish_control` back to `call_async` and park the `callee`'s
  `asyncio.Task` on the `scheduler` lock. The net effect is that, when `callee`
  blocks, there is a deterministic control flow transfer back to `call_async`.
* Once an `asyncio.Task` has blocked the first time, it goes into a cycle of
  `scheduler.acquire()`, run, `scheduler.release()`. The net effect is that the
  asynchronous call now executes until completion like a cooperative thread
  with non-deterministic (implementation-defined) interleaving.
* To support cancellation, `async_on_block` waits on a race between the given
  `awaitable` and `request_cancel_begin`. If `request_cancel_begin` is resolved,
  `async_on_block` returns `True` to request cancellation (per `OnBlock` rules)
  without waiting on the `scheduler` lock so that control flow switches to the
  subtask (being careful to only do so once per subtask, per `OnBlock` rules).
  Once the subtask blocks or resolves, `relinquish_control` will then resolve
  `request_cancel_end` without releasing the `scheduler` lock so that control
  flow switches back to `request_cancel`. The net effect is that subtask
  cancellation works just like an asychronous import call: it runs
  synchronously up until the subtask blocks or resolves.

As a side note: this whole idiosyncratic use of `asyncio` is emulating
algebraic effects as realized by the Core WebAssembly [stack-switching]
proposal. If Python had the equivalent of [stack-switching]'s `suspend` and
`resume` instructions, `scheduler` and the `OnBlock` callbacks would disappear;
calls to `OnBlock` would `suspend` with a `block` effect and `call_async` would
`resume` with a `block` handler. Indeed, a runtime that has implemented
[stack-switching] could implement `async` by compiling down to Core WebAssembly
using `cont.new`/`suspend`/`resume`.

A combined effect of `Subtask.call_sync` and `Subtask.call_async` and how
`OnBlock` callbacks are created is that if a caller asynchronously calls a
callee that makes a nested synchronous call that blocks, the asynchronous
caller will deterministically regain control without blocking.

The `Subtask.add_lender` method is called by `lift_borrow` (below). This method
increments the `num_lends` counter on the handle being lifted, which is guarded
to be zero by `canon_resource_drop` (below). The `Subtask.deliver_resolve`
method is called right before the `SUBTASK` `RETURNED` event is delivered to
wasm, at which point all the borrowed handles are logically returned to the
caller by decrementing all the `num_lend` counts that were initially
incremented.
```python
  def add_lender(self, lending_handle):
    assert(not self.resolve_delivered() and not self.resolved())
    lending_handle.num_lends += 1
    self.lenders.append(lending_handle)

  def deliver_resolve(self):
    assert(not self.resolve_delivered() and self.resolved())
    for h in self.lenders:
      h.num_lends -= 1
    self.lenders = None

  def resolve_delivered(self):
    assert(self.lenders is not None or self.resolved())
    return self.lenders is None
```
Note, the `lenders` list usually has a fixed size (in all cases except when a
function signature has `borrow`s in `list`s or `stream`s) and thus can be
stored inline in the native stack frame.

The `Subtask.drop` method is only called for `Subtask`s that have been added to
the current component instance's table and checks that the callee has been
allowed to resolve and explicitly relinquish any borrowed handles.
```python
  def drop(self):
    trap_if(not self.resolve_delivered())
    Waitable.drop(self)
```


#### Stream State

Values of `stream` type are represented in the Canonical ABI as `i32` indices
into the current component instance's table referring to either the
[readable or writable end](Async.md#streams-and-futures) of a stream. Reading
from the readable end of a stream is achieved by calling `stream.read` and
supplying a `WritableBuffer`. Conversely, writing to the writable end of a
stream is achieved by calling `stream.write` and supplying a `ReadableBuffer`.
The runtime waits until both a readable and writable buffer have been supplied
and then performs a direct copy between the two buffers. This rendezvous-based
design avoids the need for an intermediate buffer and copy (unlike, e.g., a
Unix pipe; a Unix pipe would instead be implemented as a resource type owning
the buffer memory and *two* streams; on going in and one coming out).

The result of a `{stream,future}.{read,write}` is communicated to the wasm
guest via a `CopyResult` code:
```python
class CopyResult(IntEnum):
  COMPLETED = 0
  DROPPED = 1
  CANCELLED = 2
```
The `DROPPED` code indicates that the *other* end has since been dropped and
thus no more reads/writes are possible. The `CANCELLED` code is only possible
after *this* end has performed a `{stream,future}.{read,write}` followed by a
`{stream,future}.cancel-{read,write}`; `CANCELLED` notifies the wasm code
that the cancellation finished and so ownership of the memory buffer has been
returned to the wasm code. Lastly, `COMPLETED` indicates that at least one
value has been copied and neither `DROPPED` nor `CANCELLED` apply.

As with functions and buffers, native host code can be on either side of a
stream. Thus, streams are defined in terms of abstract interfaces that can be
implemented and consumed by wasm or host code (with all {wasm,host} pairings
being possible and well-defined). Since a `stream` in a function parameter or
result type always represents the transfer of the *readable* end of a stream,
only the `ReadableStream` interface can be implemented by either wasm or the
host; the `WritableStream` interface is always written to by wasm via a
writable stream end created by `stream.new`.
```python
ReclaimBuffer = Callable[[], None]
OnCopy = Callable[[ReclaimBuffer], None]
OnCopyDone = Callable[[CopyResult], None]

class ReadableStream:
  t: ValType
  read: Callable[[ComponentInstance, WritableBuffer, OnCopy, OnCopyDone], None]
  cancel: Callable[[], None]
  drop: Callable[[], None]

class WritableStream:
  t: ValType
  write: Callable[[ComponentInstance, ReadableBuffer, OnCopy, OnCopyDone], None]
  cancel: Callable[[], None]
  drop: Callable[[], None]
```
The key operations in these interfaces are `read` and `write` which work as
follows:
* `read` never blocks and returns its values by either synchronously or
  asynchronously writing to the given `WritableBuffer` and then calling the
  given `OnCopy*` callbacks to notify the caller of progress.
* Symmetrically, `write` never blocks and takes the value to be written
  from the given `ReadableBuffer`, calling the given `OnCopy*` callbacks to
  notify the caller of progress.
* `OnCopyDone` is called to indicate that the `read` or `write` is finished
  copying and that the caller has regained ownership of the buffer.
* `OnCopy` is called to indicate a copy has been made to or from the buffer.
  However, there may be further copies made in the future, so the caller has
  *not* regained ownership of the buffer.
* The `ReclaimBuffer` callback passed to `OnCopy` allows the caller of `read` or
  `write` to immediately regain ownership of the buffer once the first copy has
  completed.
* `cancel` is non-blocking, but does **not** guarantee that ownership of
  the buffer has been returned; `cancel` only lets the caller *request* that
  one of the `OnCopy*` callbacks be called ASAP (which may or may not happen
  during `cancel`).
* The client may not call `read`, `write` or `drop` while there is a previous
  `read` or `write` in progress.

The `OnCopy*` callbacks are a spec-internal detail used to specify the allowed
concurrent behaviors of `stream.{read,write}` and not exposed directly to core
wasm code. Specifically, the point of the `OnCopy*` callbacks is to specify that
*multiple* reads or writes are allowed into the same `Buffer` up until the point
where either the buffer is full or the calling core wasm code receives a
`STREAM_READ` or `STREAM_WRITE` progress event (in which case `ReclaimBuffer` is
called). This reduces the number of task-switches required by the spec,
particularly when streaming between two components.

The `SharedStreamImpl` class implements both `ReadableStream` and
`WritableStream` for streams created by wasm (via `stream.new`) and tracks the
common state shared by both the readable and writable ends of streams (defined
below). 

Introducing `SharedStreamImpl` in chunks, starting with the fields and initialization:
```python
class SharedStreamImpl(ReadableStream, WritableStream):
  dropped: bool
  pending_inst: Optional[ComponentInstance]
  pending_buffer: Optional[Buffer]
  pending_on_copy: Optional[OnCopy]
  pending_on_copy_done: Optional[OnCopyDone]

  def __init__(self, t):
    self.t = t
    self.dropped = False
    self.reset_pending()

  def reset_pending(self):
    self.set_pending(None, None, None, None)

  def set_pending(self, inst, buffer, on_copy, on_copy_done):
    self.pending_inst = inst
    self.pending_buffer = buffer
    self.pending_on_copy = on_copy
    self.pending_on_copy_done = on_copy_done
```
If set, the `pending_*` fields record the `Buffer` and `OnCopy*` callbacks of a
`read` or `write` that is waiting to rendezvous with a complementary `write` or
`read`. Dropping the readable or writable end of a stream or cancelling a
`read` or `write` notifies any pending `read` or `write` via its `OnCopyDone`
callback:
```python
  def reset_and_notify_pending(self, result):
    pending_on_copy_done = self.pending_on_copy_done
    self.reset_pending()
    pending_on_copy_done(result)

  def cancel(self):
    self.reset_and_notify_pending(CopyResult.CANCELLED)

  def drop(self):
    if not self.dropped:
      self.dropped = True
      if self.pending_buffer:
        self.reset_and_notify_pending(CopyResult.DROPPED)
```
While the abstract `ReadableStream` and `WritableStream` interfaces *allow*
`cancel` to return without having returned ownership of the buffer (which, in
general, is necessary for [various][OIO] [host][io_uring] APIs), when *wasm* is
implementing the stream, `cancel` always returns ownership of the buffer
immediately.

Note that `cancel` and `drop` notify in opposite directions:
* `cancel` *must* be called on a readable or writable end with an operation
  pending, and thus `cancel` notifies the same end that called it.
* `drop` *must not* be called on a readable or writable end with an operation
  pending, and thus `drop` notifies the opposite end.

The `read` method implements `ReadableStream.read` and is called by either
`stream.read` or the host, depending on who is passed the readable end of the
stream. If the reader is first to rendezvous, then all the parameters are
stored in the `pending_*` fields, requiring the reader to wait for the writer
to rendezvous. If the writer was first to rendezvous, then there is already a
pending `ReadableBuffer` to read from, and so the reader copies as much as it
can (which may be less than a full buffer's worth) and eagerly completes the
copy without blocking. In the final special case where both the reader and
pending writer have zero-length buffers, the writer is notified, but the reader
remains blocked:
```python
  def read(self, inst, dst_buffer, on_copy, on_copy_done):
    if self.dropped:
      on_copy_done(CopyResult.DROPPED)
    elif not self.pending_buffer:
      self.set_pending(inst, dst_buffer, on_copy, on_copy_done)
    else:
      assert(self.t == dst_buffer.t == self.pending_buffer.t)
      trap_if(inst is self.pending_inst and self.t is not None) # temporary
      if self.pending_buffer.remain() > 0:
        if dst_buffer.remain() > 0:
          n = min(dst_buffer.remain(), self.pending_buffer.remain())
          dst_buffer.write(self.pending_buffer.read(n))
          self.pending_on_copy(self.reset_pending)
        on_copy_done(CopyResult.COMPLETED)
      else:
        self.reset_and_notify_pending(CopyResult.COMPLETED)
        self.set_pending(inst, dst_buffer, on_copy, on_copy_done)
```
Currently, there is a trap when both the `read` and `write` come from the same
component instance and there is a non-empty element type. This trap will be
removed in a subsequent release; the reason for the trap is that when lifting
and lowering can alias the same memory, interleavings can be complex and must
be handled carefully. Future improvements to the Canonical ABI ([lazy lowering])
can greatly simplify this interleaving and be more practical to implement.

The `write` method implements `WritableStream.write` and is called by the
`stream.write` built-in (noting that the host cannot be passed the writable end
of a stream but may instead *implement* the `ReadableStream` interface and pass
the readable end into a component). The steps for `write` are the same as
`read` except for when a zero-length `write` rendezvous with a zero-length
`read`, in which case the `write` eagerly completes, leaving the `read`
pending:
```python
  def write(self, inst, src_buffer, on_copy, on_copy_done):
    if self.dropped:
      on_copy_done(CopyResult.DROPPED)
    elif not self.pending_buffer:
      self.set_pending(inst, src_buffer, on_copy, on_copy_done)
    else:
      assert(self.t == src_buffer.t == self.pending_buffer.t)
      trap_if(inst is self.pending_inst and self.t is not None) # temporary
      if self.pending_buffer.remain() > 0:
        if src_buffer.remain() > 0:
          n = min(src_buffer.remain(), self.pending_buffer.remain())
          self.pending_buffer.write(src_buffer.read(n))
          self.pending_on_copy(self.reset_pending)
        on_copy_done(CopyResult.COMPLETED)
      elif src_buffer.is_zero_length() and self.pending_buffer.is_zero_length():
        on_copy_done(CopyResult.COMPLETED)
      else:
        self.reset_and_notify_pending(CopyResult.COMPLETED)
        self.set_pending(inst, src_buffer, on_copy, on_copy_done)
```
Putting together the behavior of zero-length `read` and `write` above, we can
see that, when *both* the reader and writer are zero-length, regardless of who
was first, the zero-length `write` always completes, leaving the zero-length
`read` pending. To avoid livelock, the Canonical ABI requires that a writer
*must* (eventually) follow a completed zero-length `write` with a
non-zero-length `write` that is allowed to block. This will break the loop,
notifying the reader end and allowing it to rendezvous with a non-zero-length
`read` and make progress. Based on this rule, to implement a traditional
`O_NONBLOCK` `write()` or `sendmsg()` API, a writer can use a buffering scheme
in which, after `select()` (or a similar API) signals a file descriptor is
ready to write, the next `O_NONBLOCK` `write()`/`sendmsg()` on that file
descriptor copies to an internal buffer and suceeds, issuing an `async`
`stream.write` in the background and waiting for completion before signalling
readiness again. Note that buffering only occurs when streaming between two
components using non-blocking I/O; if either side is the host or a component
using blocking or completion-based I/O, no buffering is necessary. This
buffering is analogous to the buffering performed in kernel memory by a
`pipe()`.

Given the above, we can define the `{Readable,Writable}StreamEnd` classes that
are actually stored in the component instance table. The classes are almost
entirely symmetric, with the only difference being whether the polymorphic
`copy` method (used below) calls `read` or `write`:
```python
class StreamEnd(Waitable):
  shared: ReadableStream|WritableStream
  copying: bool
  done: bool

  def __init__(self, shared):
    Waitable.__init__(self)
    self.shared = shared
    self.copying = False
    self.done = False

  def drop(self):
    trap_if(self.copying)
    self.shared.drop()
    Waitable.drop(self)

class ReadableStreamEnd(StreamEnd):
  def copy(self, inst, dst, on_copy, on_copy_done):
    self.shared.read(inst, dst, on_copy, on_copy_done)

class WritableStreamEnd(StreamEnd):
  def copy(self, inst, src, on_copy, on_copy_done):
    self.shared.write(inst, src, on_copy, on_copy_done)
```
The `copying` field tracks whether there is an asynchronous read or write in
progress and is maintained by the definitions of `stream.{read,write}` below.
The `done` field tracks whether this end has been notified that the other end
was dropped (via `CopyResult.DROPPED`) and thus no further read/write
operations are allowed. Importantly, `copying` and `done` are per-*end*, not
per-*stream* (unlike the fields of `SharedStreamImpl` shown above, which are
per-stream and shared by both ends via their `shared` field).

Dropping a stream end while an asynchronous read or write is in progress traps
since the async read or write cannot be cancelled without blocking and `drop`
(called by `stream.drop-{readable,writable}`) is synchronous and non-blocking.
This means that client code must take care to wait for these operations to
finish before dropping.


#### Future State

Futures are similar to streams, except that instead of passing 0..N values,
exactly one value is passed from the writer end to the reader end unless the
reader end is explicitly dropped first.

Futures are defined in terms of abstract `ReadableFuture` and `WritableFuture`
interfaces:
```python
class ReadableFuture:
  t: ValType
  read: Callable[[ComponentInstance, WritableBuffer, OnCopyDone], None]
  cancel: Callable[[], None]
  drop: Callable[[], None]

class WritableFuture:
  t: ValType
  write: Callable[[ComponentInstance, ReadableBuffer, OnCopyDone], None]
  cancel: Callable[[], None]
  drop: Callable[[], None]
```
These interfaces work like `ReadableStream` and `WritableStream` except that
there is no `OnCopy` callback passed to `read` or `write` to report partial
progress (since at most 1 value is copied) and the given `Buffer` must have
`remain() == 1`.

Introducing `SharedFutureImpl` in chunks, the first part is exactly
symmetric to `SharedStreamImpl` in how initialization and cancellation work:
```python
class SharedFutureImpl(ReadableFuture, WritableFuture):
  dropped: bool
  pending_inst: Optional[ComponentInstance]
  pending_buffer: Optional[Buffer]
  pending_on_copy_done: Optional[OnCopyDone]

  def __init__(self, t):
    self.t = t
    self.dropped = False
    self.reset_pending()

  def reset_pending(self):
    self.set_pending(None, None, None)

  def set_pending(self, inst, buffer, on_copy_done):
    self.pending_inst = inst
    self.pending_buffer = buffer
    self.pending_on_copy_done = on_copy_done

  def reset_and_notify_pending(self, result):
    pending_on_copy_done = self.pending_on_copy_done
    self.reset_pending()
    pending_on_copy_done(result)

  def cancel(self):
    self.reset_pending_and_notify_pending(CopyResult.CANCELLED)
```
Dropping works almost the same in futures as streams, except that a future
writable end cannot be dropped without having written a value. This is guarded
by `WritableFutureEnd.drop` so it can be asserted here:
```python
  def drop(self):
    assert(not self.dropped)
    self.dropped = True
    if self.pending_buffer:
      assert(isinstance(self.pending_buffer, WritableBuffer))
      self.reset_and_notify_pending(CopyResult.DROPPED)
```
Lastly, `read` and `write` work mostly like streams, but simplified based on
the fact that we're copying at most 1 value. The only asymmetric difference is
that, as mentioned above, only the writable end can observe that the readable
end was dropped before receiving a value.
```python
  def read(self, inst, dst_buffer, on_copy_done):
    assert(not self.dropped and dst_buffer.remain() == 1)
    if not self.pending_buffer:
      self.set_pending(inst, dst_buffer, on_copy_done)
    else:
      trap_if(inst is self.pending_inst and self.t is not None) # temporary
      dst_buffer.write(self.pending_buffer.read(1))
      self.reset_and_notify_pending(CopyResult.COMPLETED)
      on_copy_done(CopyResult.COMPLETED)

  def write(self, inst, src_buffer, on_copy_done):
    assert(src_buffer.remain() == 1)
    if self.dropped:
      on_copy_done(CopyResult.DROPPED)
    elif not self.pending_buffer:
      self.set_pending(inst, src_buffer, on_copy_done)
    else:
      trap_if(inst is self.pending_inst and self.t is not None) # temporary
      self.pending_buffer.write(src_buffer.read(1))
      self.reset_and_notify_pending(CopyResult.COMPLETED)
      on_copy_done(CopyResult.COMPLETED)
```
As with streams, the `# temporary` limitation shown above is that a future
cannot be read and written from the same component instance when it has a
non-empty value type.

Lastly, the `{Readable,Writable}FutureEnd` classes are mostly symmetric with
`{Readable,Writable}StreamEnd`, with the only difference being that
`WritableFutureEnd.drop` traps if the writer hasn't successfully written a
value or been notified of the reader dropping their end:
```python
class FutureEnd(Waitable):
  shared: ReadableFuture|WritableFuture
  copying: bool
  done: bool

  def __init__(self, shared):
    Waitable.__init__(self)
    self.shared = shared
    self.copying = False
    self.done = False

  def drop(self):
    trap_if(self.copying)
    Waitable.drop(self)

class ReadableFutureEnd(FutureEnd):
  def copy(self, inst, src_buffer, on_copy_done):
    self.shared.read(inst, src_buffer, on_copy_done)

  def drop(self):
    self.shared.drop()
    FutureEnd.drop(self)

class WritableFutureEnd(FutureEnd):
  def copy(self, inst, dst_buffer, on_copy_done):
    self.shared.write(inst, dst_buffer, on_copy_done)

  def drop(self):
    trap_if(not self.done)
    FutureEnd.drop(self)
```
The `copying` and `done` fields are maintained by the `future` built-ins
defined below.


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
    case TupleType(ts)       : return RecordType([ FieldType(str(i), t) for i,t in enumerate(ts) ])
    case EnumType(labels)    : return VariantType([ CaseType(l, None) for l in labels ])
    case OptionType(t)       : return VariantType([ CaseType("none", None), CaseType("some", t) ])
    case ResultType(ok, err) : return VariantType([ CaseType("ok", ok), CaseType("error", err) ])
    case _                   : return t
```
The specialized value types `string` and `flags` are missing from this list
because they are given specialized canonical ABI representations distinct from
their respective expansions.


### Type Predicates

The `contains_borrow` and `contains_async_value` predicates return whether the
given type contains a `borrow` or `future/`stream`, respectively.
```python
def contains_borrow(t):
  return contains(t, lambda u: isinstance(u, BorrowType))

def contains_async_value(t):
  return contains(t, lambda u: isinstance(u, StreamType | FutureType))

def contains(t, p):
  t = despecialize(t)
  match t:
    case None:
      return False
    case PrimValType() | OwnType() | BorrowType():
      return p(t)
    case ListType(u) | StreamType(u) | FutureType(u):
      return p(t) or contains(u, p)
    case RecordType(fields):
      return p(t) or any(contains(f.t, p) for f in fields)
    case VariantType(cases):
      return p(t) or any(contains(c.t, p) for c in cases)
    case FuncType():
      return any(p(u) for u in t.param_types() + t.result_type())
    case _:
      assert(False)
```

### Alignment

Each value type is assigned an [alignment] which is used by subsequent
Canonical ABI definitions. Presenting the definition of `alignment` piecewise,
we start with the top-level case analysis:
```python
def alignment(t):
  match despecialize(t):
    case BoolType()                  : return 1
    case S8Type() | U8Type()         : return 1
    case S16Type() | U16Type()       : return 2
    case S32Type() | U32Type()       : return 4
    case S64Type() | U64Type()       : return 8
    case F32Type()                   : return 4
    case F64Type()                   : return 8
    case CharType()                  : return 4
    case StringType()                : return 4
    case ErrorContextType()          : return 4
    case ListType(t, l)              : return alignment_list(t, l)
    case RecordType(fields)          : return alignment_record(fields)
    case VariantType(cases)          : return alignment_variant(cases)
    case FlagsType(labels)           : return alignment_flags(labels)
    case OwnType() | BorrowType()    : return 4
    case StreamType() | FutureType() : return 4
```

List alignment is the same as tuple alignment when the length is fixed and
otherwise uses the alignment of pointers.
```python
def alignment_list(elem_type, maybe_length):
  if maybe_length is not None:
    return alignment(elem_type)
  return 4
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
    case 0: return U8Type()
    case 1: return U8Type()
    case 2: return U16Type()
    case 3: return U32Type()

def max_case_alignment(cases):
  a = 1
  for c in cases:
    if c.t is not None:
      a = max(a, alignment(c.t))
  return a
```

As an optimization, `flags` are represented as packed bit-vectors. Like variant
discriminants, `flags` use the smallest integer that fits all the bits.
```python
def alignment_flags(labels):
  n = len(labels)
  assert(0 < n <= 32)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4
```


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
    case BoolType()                  : return 1
    case S8Type() | U8Type()         : return 1
    case S16Type() | U16Type()       : return 2
    case S32Type() | U32Type()       : return 4
    case S64Type() | U64Type()       : return 8
    case F32Type()                   : return 4
    case F64Type()                   : return 8
    case CharType()                  : return 4
    case StringType()                : return 8
    case ErrorContextType()          : return 4
    case ListType(t, l)              : return elem_size_list(t, l)
    case RecordType(fields)          : return elem_size_record(fields)
    case VariantType(cases)          : return elem_size_variant(cases)
    case FlagsType(labels)           : return elem_size_flags(labels)
    case OwnType() | BorrowType()    : return 4
    case StreamType() | FutureType() : return 4

def elem_size_list(elem_type, maybe_length):
  if maybe_length is not None:
    return maybe_length * elem_size(elem_type)
  return 8

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
  assert(0 < n <= 32)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4
```

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
    case BoolType()         : return convert_int_to_bool(load_int(cx, ptr, 1))
    case U8Type()           : return load_int(cx, ptr, 1)
    case U16Type()          : return load_int(cx, ptr, 2)
    case U32Type()          : return load_int(cx, ptr, 4)
    case U64Type()          : return load_int(cx, ptr, 8)
    case S8Type()           : return load_int(cx, ptr, 1, signed = True)
    case S16Type()          : return load_int(cx, ptr, 2, signed = True)
    case S32Type()          : return load_int(cx, ptr, 4, signed = True)
    case S64Type()          : return load_int(cx, ptr, 8, signed = True)
    case F32Type()          : return decode_i32_as_float(load_int(cx, ptr, 4))
    case F64Type()          : return decode_i64_as_float(load_int(cx, ptr, 8))
    case CharType()         : return convert_i32_to_char(cx, load_int(cx, ptr, 4))
    case StringType()       : return load_string(cx, ptr)
    case ErrorContextType() : return lift_error_context(cx, load_int(cx, ptr, 4))
    case ListType(t, l)     : return load_list(cx, ptr, t, l)
    case RecordType(fields) : return load_record(cx, ptr, fields)
    case VariantType(cases) : return load_variant(cx, ptr, cases)
    case FlagsType(labels)  : return load_flags(cx, ptr, labels)
    case OwnType()          : return lift_own(cx, load_int(cx, ptr, 4), t)
    case BorrowType()       : return lift_borrow(cx, load_int(cx, ptr, 4), t)
    case StreamType(t)      : return lift_stream(cx, load_int(cx, ptr, 4), t)
    case FutureType(t)      : return lift_future(cx, load_int(cx, ptr, 4), t)
```

Integers are loaded directly from memory, with their high-order bit interpreted
according to the signedness of the type.
```python
def load_int(cx, ptr, nbytes, signed = False):
  return int.from_bytes(cx.opts.memory[ptr : ptr+nbytes], 'little', signed = signed)
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
and a number of [code units]. There are three supported string encodings in
[`canonopt`]: [UTF-8], [UTF-16] and `latin1+utf16`. This last options allows a
*dynamic* choice between [Latin-1] and UTF-16, indicated by the high bit of the
second `i32`. String values include their original encoding and length in
tagged code units as a "hint" that enables `store_string` (defined below) to
make better up-front allocation size choices in many cases. Thus, the value
produced by `load_string` isn't simply a Python `str`, but a *tuple* containing
a `str`, the original encoding and the number of source code units.
```python
String = tuple[str, str, int]

def load_string(cx, ptr) -> String:
  begin = load_int(cx, ptr, 4)
  tagged_code_units = load_int(cx, ptr + 4, 4)
  return load_string_from_range(cx, begin, tagged_code_units)

UTF16_TAG = 1 << 31

def load_string_from_range(cx, ptr, tagged_code_units) -> String:
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

Error context values are lifted directly from the current component instance's
table:
```python
def lift_error_context(cx, i):
  errctx = cx.inst.table.get(i)
  trap_if(not isinstance(errctx, ErrorContext))
  return errctx
```

Lists and records are loaded by recursively loading their elements/fields:
```python
def load_list(cx, ptr, elem_type, maybe_length):
  if maybe_length is not None:
    return load_list_from_valid_range(cx, ptr, maybe_length, elem_type)
  begin = load_int(cx, ptr, 4)
  length = load_int(cx, ptr + 4, 4)
  return load_list_from_range(cx, begin, length, elem_type)

def load_list_from_range(cx, ptr, length, elem_type):
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + length * elem_size(elem_type) > len(cx.opts.memory))
  return load_list_from_valid_range(cx, ptr, length, elem_type)

def load_list_from_valid_range(cx, ptr, length, elem_type):
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
case index, assigning `0` to the first case, `1` to the next case, etc.
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
  if c.t is None:
    return { c.label: None }
  return { c.label: load(cx, ptr, c.t) }
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
instance's table so that ownership is *transferred* to the lowering component.
The lifting operation fails if unique ownership of the handle isn't possible,
for example if the index was actually a `borrow` or if the `own` handle is
currently being lent out as borrows.
```python
def lift_own(cx, i, t):
  h = cx.inst.table.remove(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not t.rt)
  trap_if(h.num_lends != 0)
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
component instance's table:
```python
def lift_borrow(cx, i, t):
  assert(isinstance(cx.borrow_scope, Subtask))
  h = cx.inst.table.get(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not t.rt)
  cx.borrow_scope.add_lender(h)
  return h.rep
```
The `Subtask.add_lender` participates in the enforcement of the dynamic borrow
rules, which keep the source handle alive until the end of the call (as a
conservative upper bound on how long the `borrow` handle can be held). Note
that `add_lender` is called for borrowed source handles so that they must be
kept alive until the subtask completes, which in turn prevents the current task
from `task.return`ing while its non-returned subtask still holds a
transitively-borrowed handle.

Streams and futures are entirely symmetric, transferring ownership of the
readable end from the lifting component to the host or lowering component and
trapping if the readable end is in the middle of `copying` (which would create
a dangling-pointer situation) or is already `done` (in which case the only
valid operation is `{stream,future}.drop-{readable,writable}`).
```python
def lift_stream(cx, i, t):
  return lift_async_value(ReadableStreamEnd, cx, i, t)

def lift_future(cx, i, t):
  return lift_async_value(ReadableFutureEnd, cx, i, t)

def lift_async_value(ReadableEndT, cx, i, t):
  assert(not contains_borrow(t))
  e = cx.inst.table.remove(i)
  trap_if(not isinstance(e, ReadableEndT))
  trap_if(e.shared.t != t)
  trap_if(e.copying)
  trap_if(e.done)
  return e.shared
```


### Storing

The `store` function defines how to write a value `v` of a given value type
`t` into linear memory starting at offset `ptr`. Presenting the definition of
`store` piecewise, we start with the top-level case analysis:
```python
def store(cx, v, t, ptr):
  assert(ptr == align_to(ptr, alignment(t)))
  assert(ptr + elem_size(t) <= len(cx.opts.memory))
  match despecialize(t):
    case BoolType()         : store_int(cx, int(bool(v)), ptr, 1)
    case U8Type()           : store_int(cx, v, ptr, 1)
    case U16Type()          : store_int(cx, v, ptr, 2)
    case U32Type()          : store_int(cx, v, ptr, 4)
    case U64Type()          : store_int(cx, v, ptr, 8)
    case S8Type()           : store_int(cx, v, ptr, 1, signed = True)
    case S16Type()          : store_int(cx, v, ptr, 2, signed = True)
    case S32Type()          : store_int(cx, v, ptr, 4, signed = True)
    case S64Type()          : store_int(cx, v, ptr, 8, signed = True)
    case F32Type()          : store_int(cx, encode_float_as_i32(v), ptr, 4)
    case F64Type()          : store_int(cx, encode_float_as_i64(v), ptr, 8)
    case CharType()         : store_int(cx, char_to_i32(v), ptr, 4)
    case StringType()       : store_string(cx, v, ptr)
    case ErrorContextType() : store_int(cx, lower_error_context(cx, v), ptr, 4)
    case ListType(t, l)     : store_list(cx, v, ptr, t, l)
    case RecordType(fields) : store_record(cx, v, ptr, fields)
    case VariantType(cases) : store_variant(cx, v, ptr, cases)
    case FlagsType(labels)  : store_flags(cx, v, ptr, labels)
    case OwnType()          : store_int(cx, lower_own(cx, v, t), ptr, 4)
    case BorrowType()       : store_int(cx, lower_borrow(cx, v, t), ptr, 4)
    case StreamType(t)      : store_int(cx, lower_stream(cx, v, t), ptr, 4)
    case FutureType(t)      : store_int(cx, lower_future(cx, v, t), ptr, 4)
```

Integers are stored directly into memory. Because the input domain is exactly
the integers in range for the given type, no extra range checks are necessary;
the `signed` parameter is only present to ensure that the internal range checks
of `int.to_bytes` are satisfied.
```python
def store_int(cx, v, ptr, nbytes, signed = False):
  cx.opts.memory[ptr : ptr+nbytes] = int.to_bytes(v, nbytes, 'little', signed = signed)
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
original encoding and number of source [code units]. From this hint data,
`store_string` can do a much better job minimizing the number of reallocations.

We start with a case analysis to enumerate all the meaningful encoding
combinations, subdividing the `latin1+utf16` encoding into either `latin1` or
`utf16` based on the `UTF16_TAG` flag set by `load_string`:
```python
def store_string(cx, v: String, ptr):
  begin, tagged_code_units = store_string_into_range(cx, v)
  store_int(cx, begin, ptr, 4)
  store_int(cx, tagged_code_units, ptr + 4, 4)

def store_string_into_range(cx, v: String):
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
string's number of code units is never set, keeping it clear for `UTF16_TAG`.

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

Error context values are lowered by storing them directly into the current
component instance's table and passing the `i32` index to wasm:
```python
def lower_error_context(cx, v):
  return cx.inst.table.add(v)
```

Lists and records are stored by recursively storing their elements and
are symmetric to the loading functions. Unlike strings, lists can
simply allocate based on the up-front knowledge of length and static
element size.
```python
def store_list(cx, v, ptr, elem_type, maybe_length):
  if maybe_length is not None:
    assert(maybe_length == len(v))
    store_list_into_valid_range(cx, v, ptr, elem_type)
    return
  begin, length = store_list_into_range(cx, v, elem_type)
  store_int(cx, begin, ptr, 4)
  store_int(cx, length, ptr + 4, 4)

def store_list_into_range(cx, v, elem_type):
  byte_length = len(v) * elem_size(elem_type)
  trap_if(byte_length >= (1 << 32))
  ptr = cx.opts.realloc(0, 0, alignment(elem_type), byte_length)
  trap_if(ptr != align_to(ptr, alignment(elem_type)))
  trap_if(ptr + byte_length > len(cx.opts.memory))
  store_list_into_valid_range(cx, v, ptr, elem_type)
  return (ptr, len(v))

def store_list_into_valid_range(cx, v, ptr, elem_type):
  for i,e in enumerate(v):
    store(cx, e, elem_type, ptr + i * elem_size(elem_type))

def store_record(cx, v, ptr, fields):
  for f in fields:
    ptr = align_to(ptr, alignment(f.t))
    store(cx, v[f.label], f.t, ptr)
    ptr += elem_size(f.t)
```

Variant values are represented as Python dictionaries containing exactly one
entry whose key is the label of the lifted case and whose value is the
(optional) case payload. While this code appears to do an O(n) search of the
`variant` type for a matching case label, a normal implementation can
statically fuse `store_variant` with its matching `load_variant` to ultimately
build a dense array that maps producer's case indices to the consumer's case
indices.
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
  [label] = v.keys()
  [index] = [i for i,c in enumerate(cases) if c.label == label]
  [value] = v.values()
  return (index, value)
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
elements in the current component instance's table. The increment of
`num_borrows` is complemented by a decrement in `canon_resource_drop` and
ensures that all borrowed handles are dropped before the end of the task.
```python
def lower_own(cx, rep, t):
  h = ResourceHandle(t.rt, rep, own = True)
  return cx.inst.table.add(h)

def lower_borrow(cx, rep, t):
  assert(isinstance(cx.borrow_scope, Task))
  if cx.inst is t.rt.impl:
    return rep
  h = ResourceHandle(t.rt, rep, own = False, borrow_scope = cx.borrow_scope)
  h.borrow_scope.num_borrows += 1
  return cx.inst.table.add(h)
```
The special case in `lower_borrow` is an optimization, recognizing that, when
a borrowed handle is passed to the component that implemented the resource
type, the only thing the borrowed handle is good for is calling
`resource.rep`, so lowering might as well avoid the overhead of creating an
intermediate borrow handle.

Lowering a `stream` or `future` is entirely symmetric and simply adds a new
readable end to the current component instance's table, passing the index of
the new element to core wasm:
```python
def lower_stream(cx, v, t):
  assert(isinstance(v, ReadableStream))
  assert(not contains_borrow(t))
  return cx.inst.table.add(ReadableStreamEnd(v))

def lower_future(cx, v, t):
  assert(isinstance(v, ReadableFuture))
  assert(not contains_borrow(t))
  return cx.inst.table.add(ReadableFutureEnd(v))
```


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
MAX_FLAT_ASYNC_PARAMS = 4
MAX_FLAT_RESULTS = 1

def flatten_functype(opts, ft, context):
  flat_params = flatten_types(ft.param_types())
  flat_results = flatten_types(ft.result_type())
  if opts.sync:
    if len(flat_params) > MAX_FLAT_PARAMS:
      flat_params = ['i32']
    if len(flat_results) > MAX_FLAT_RESULTS:
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
        if len(flat_params) > MAX_FLAT_PARAMS:
          flat_params = ['i32']
        if opts.callback:
          flat_results = ['i32']
        else:
          flat_results = []
      case 'lower':
        if len(flat_params) > MAX_FLAT_ASYNC_PARAMS:
          flat_params = ['i32']
        if len(flat_results) > 0:
          flat_params += ['i32']
        flat_results = ['i32']
    return CoreFuncType(flat_params, flat_results)

def flatten_types(ts):
  return [ft for t in ts for ft in flatten_type(t)]
```
As shown here, the core signatures `async` functions use a lower limit on the
maximum number of parameters (1) and results (0) passed as scalars before
falling back to passing through memory.

Presenting the definition of `flatten_type` piecewise, we start with the
top-level case analysis:
```python
def flatten_type(t):
  match despecialize(t):
    case BoolType()                       : return ['i32']
    case U8Type() | U16Type() | U32Type() : return ['i32']
    case S8Type() | S16Type() | S32Type() : return ['i32']
    case S64Type() | U64Type()            : return ['i64']
    case F32Type()                        : return ['f32']
    case F64Type()                        : return ['f64']
    case CharType()                       : return ['i32']
    case StringType()                     : return ['i32', 'i32']
    case ErrorContextType()               : return ['i32']
    case ListType(t, l)                   : return flatten_list(t, l)
    case RecordType(fields)               : return flatten_record(fields)
    case VariantType(cases)               : return flatten_variant(cases)
    case FlagsType(labels)                : return ['i32']
    case OwnType() | BorrowType()         : return ['i32']
    case StreamType() | FutureType()      : return ['i32']
```

List flattening of a fixed-length list uses the same flattening as a tuple
(via `flatten_record` below).
```python
def flatten_list(elem_type, maybe_length):
  if maybe_length is not None:
    return flatten_type(elem_type) * maybe_length
  return ['i32', 'i32']
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

Values are lifted by iterating over a list of parameter or result Core
WebAssembly values:
```python
class CoreValueIter:
  values: list[int|float]
  i: int

  def __init__(self, vs):
    self.values = vs
    self.i = 0

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

  def done(self):
    return self.i == len(self.values)
```
The `match` is only used for spec-level assertions; no runtime typecase is
required.

The `lift_flat` function defines how to convert a list of core values into a
single high-level value of type `t`. Presenting the definition of `lift_flat`
piecewise, we start with the top-level case analysis:
```python
def lift_flat(cx, vi, t):
  match despecialize(t):
    case BoolType()         : return convert_int_to_bool(vi.next('i32'))
    case U8Type()           : return lift_flat_unsigned(vi, 32, 8)
    case U16Type()          : return lift_flat_unsigned(vi, 32, 16)
    case U32Type()          : return lift_flat_unsigned(vi, 32, 32)
    case U64Type()          : return lift_flat_unsigned(vi, 64, 64)
    case S8Type()           : return lift_flat_signed(vi, 32, 8)
    case S16Type()          : return lift_flat_signed(vi, 32, 16)
    case S32Type()          : return lift_flat_signed(vi, 32, 32)
    case S64Type()          : return lift_flat_signed(vi, 64, 64)
    case F32Type()          : return canonicalize_nan32(vi.next('f32'))
    case F64Type()          : return canonicalize_nan64(vi.next('f64'))
    case CharType()         : return convert_i32_to_char(cx, vi.next('i32'))
    case StringType()       : return lift_flat_string(cx, vi)
    case ErrorContextType() : return lift_error_context(cx, vi.next('i32'))
    case ListType(t, l)     : return lift_flat_list(cx, vi, t, l)
    case RecordType(fields) : return lift_flat_record(cx, vi, fields)
    case VariantType(cases) : return lift_flat_variant(cx, vi, cases)
    case FlagsType(labels)  : return lift_flat_flags(vi, labels)
    case OwnType()          : return lift_own(cx, vi.next('i32'), t)
    case BorrowType()       : return lift_borrow(cx, vi.next('i32'), t)
    case StreamType(t)      : return lift_stream(cx, vi.next('i32'), t)
    case FutureType(t)      : return lift_future(cx, vi.next('i32'), t)
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

The contents of strings and variable-length lists are stored in memory so
lifting these types is essentially the same as loading them from memory; the
only difference is that the pointer and length come from `i32` values instead
of from linear memory. Fixed-length lists are lifted the same way as a
tuple (via `lift_flat_record` below).
```python
def lift_flat_string(cx, vi):
  ptr = vi.next('i32')
  packed_length = vi.next('i32')
  return load_string_from_range(cx, ptr, packed_length)

def lift_flat_list(cx, vi, elem_type, maybe_length):
  if maybe_length is not None:
    a = []
    for i in range(maybe_length):
      a.append(lift_flat(cx, vi, elem_type))
    return a
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
  flat_types = flatten_variant(cases)
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
  return { c.label: v }

def wrap_i64_to_i32(i):
  assert(0 <= i < (1 << 64))
  return i % (1 << 32)
```

Finally, flags are lifted by lifting to a record the same way as when loading
flags from linear memory.
```python
def lift_flat_flags(vi, labels):
  assert(0 < len(labels) <= 32)
  i = vi.next('i32')
  return unpack_flags_from_int(i, labels)
```

### Flat Lowering

The `lower_flat` function defines how to convert a value `v` of a given type
`t` into zero or more core values. Presenting the definition of `lower_flat`
piecewise, we start with the top-level case analysis:
```python
def lower_flat(cx, v, t):
  match despecialize(t):
    case BoolType()         : return [int(v)]
    case U8Type()           : return [v]
    case U16Type()          : return [v]
    case U32Type()          : return [v]
    case U64Type()          : return [v]
    case S8Type()           : return lower_flat_signed(v, 32)
    case S16Type()          : return lower_flat_signed(v, 32)
    case S32Type()          : return lower_flat_signed(v, 32)
    case S64Type()          : return lower_flat_signed(v, 64)
    case F32Type()          : return [maybe_scramble_nan32(v)]
    case F64Type()          : return [maybe_scramble_nan64(v)]
    case CharType()         : return [char_to_i32(v)]
    case StringType()       : return lower_flat_string(cx, v)
    case ErrorContextType() : return lower_error_context(cx, v)
    case ListType(t, l)     : return lower_flat_list(cx, v, t, l)
    case RecordType(fields) : return lower_flat_record(cx, v, fields)
    case VariantType(cases) : return lower_flat_variant(cx, v, cases)
    case FlagsType(labels)  : return lower_flat_flags(v, labels)
    case OwnType()          : return [lower_own(cx, v, t)]
    case BorrowType()       : return [lower_borrow(cx, v, t)]
    case StreamType(t)      : return [lower_stream(cx, v, t)]
    case FutureType(t)      : return [lower_future(cx, v, t)]
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

Since strings and variable-length lists are stored in linear memory, lifting
can reuse the previous definitions; only the resulting pointers are returned
differently (as `i32` values instead of as a pair in linear memory).
Fixed-length lists are lowered the same way as tuples (via `lower_flat_record`
below).
```python
def lower_flat_string(cx, v):
  ptr, packed_length = store_string_into_range(cx, v)
  return [ptr, packed_length]

def lower_flat_list(cx, v, elem_type, maybe_length):
  if maybe_length is not None:
    assert(maybe_length == len(v))
    flat = []
    for e in v:
      flat += lower_flat(cx, e, elem_type)
    return flat
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
  flat_types = flatten_variant(cases)
  assert(flat_types.pop(0) == 'i32')
  c = cases[case_index]
  if c.t is None:
    payload = []
  else:
    payload = lower_flat(cx, case_value, c.t)
    for i,(fv,have) in enumerate(zip(payload, flatten_type(c.t))):
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

Finally, flags are lowered by packing the flags into an `i32` bitvector.
```python
def lower_flat_flags(v, labels):
  assert(0 < len(labels) <= 32)
  return [pack_flags_into_int(v, labels)]
```

### Lifting and Lowering Values

The `lift_flat_values` function defines how to lift a list of core
parameters or results (given by the `CoreValueIter` `vi`) into a tuple
of component-level values with types `ts`.
```python
def lift_flat_values(cx, max_flat, vi, ts):
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    ptr = vi.next('i32')
    tuple_type = TupleType(ts)
    trap_if(ptr != align_to(ptr, alignment(tuple_type)))
    trap_if(ptr + elem_size(tuple_type) > len(cx.opts.memory))
    return list(load(cx, ptr, tuple_type).values())
  else:
    return [ lift_flat(cx, vi, t) for t in ts ]
```

Symmetrically, the `lower_flat_values` function defines how to lower a
list of component-level values `vs` of types `ts` into a list of core
values. As already described for [`flatten_functype`](#flattening) above,
lowering handles the greater-than-`max_flat` case by either allocating
storage with `realloc` or accepting a caller-allocated buffer as an
out-param:
```python
def lower_flat_values(cx, max_flat, vs, ts, out_param = None):
  cx.inst.may_leave = False
  flat_types = flatten_types(ts)
  if len(flat_types) > max_flat:
    tuple_type = TupleType(ts)
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
  else:
    flat_vals = []
    for i in range(len(vs)):
      flat_vals += lower_flat(cx, vs[i], ts[i])
  cx.inst.may_leave = True
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

### `canonopt` Validation

Canonical options, often referred to as `$opts` in the definitions below,
can be specified at most once in any particular list of options. For example
specifying `string-encoding=utf8` twice is an error. Each individual option, if
present, is validated as such:

* `string-encoding=N` - can be passed at most once, regardless of `N`.
* `memory` - this is a subtype of `(memory 1)`
* `realloc` - the function has type `(func (param i32 i32 i32 i32) (result i32))`
* if `realloc` is present, then `memory` must be present
* `post-return` - only allowed on [`canon lift`](#canon-lift), which has rules
  for validation
* 🔀 `async` - cannot be present with `post-return`
* 🔀,not(🚟) `async` - `callback` must also be present. Note that with the 🚟
  feature (the "stackful" ABI), this restriction is lifted.
* 🔀 `callback` - the function has type `(func (param i32 i32 i32) (result i32))`
  and cannot be present without `async` and is only allowed with
  [`canon lift`](#canon-lift)

Additionally some options are required depending on lift/lower operations
performed for a component. These are defined as:

* `lower(T)`
  * requires `memory` if `T` contains a `list` or `string`

* `lift(T)`
  * requires `realloc` if `T` contains a `list` or `string`


### `canon lift`

For a canonical definition:
```wat
(canon lift $callee:<funcidx> $opts:<canonopt>* (func $f (type $ft)))
```

In addition to [general validation of `$opts`](#canonopt-validation) the additional
validation is performed:

* `$callee` must have type `flatten_functype($opts, $ft, 'lift')`
* `$f` is given type `$ft`
* if a `post-return` is present, it has type `(func (param flatten_functype({}, $ft, 'lift').results))`
* requires options based on [`lift(param)`](#canonopt-validation) for all parameters in `ft`
* requires options based on [`lower(result)`](#canonopt-validation) if `ft` has a result
* if `len(flatten_types(ft.param_types())) > MAX_FLAT_PARAMS`, `realloc` is required
* if `len(flatten_types(ft.result_type())) > MAX_FLAT_RESULTS`, `memory` is required

When instantiating component instance `$inst`:
* Define `$f` to be the partially-bound closure `canon_lift($opts, $inst, $ft, $callee)`

The resulting bound function `$f` takes 4 runtime arguments:
* `caller`, which is either the `Task` of the caller or, when the caller is the
  host, `None`
* the caller's `OnStart`, `OnResolve` and `OnBlock` callbacks, whose meaning is
  described [above](#task-state)

If `$f` is called by the host, the host is responsible for producing the lifted
values returned by the `OnStart` callback and consuming the lifted values passed
to the `OnResolve` callback. For example, if the host is a native JS runtime, the
[JavaScript embedding] would specify how native JavaScript values are mapped to
and from lifted values. Alternatively, if the host is a POSIX CLI that invokes
component exports directly from the command line, the host might parse `argv`
into lifted values according to the declared types of the export and render the
return value into text printed to `stdout`.

Based on this, `canon_lift` is defined in chunks as follows, starting with how
a `lift`ed function starts executing:
```python
async def canon_lift(opts, inst, ft, callee, caller, on_start, on_resolve, on_block):
  task = Task(opts, inst, ft, caller, on_resolve, on_block)
  task.trap_if_on_the_stack(inst)
  if not await task.enter():
    return

  cx = LiftLowerContext(opts, inst, task)
  args = on_start()
  flat_args = lower_flat_values(cx, MAX_FLAT_PARAMS, args, ft.param_types())
  flat_ft = flatten_functype(opts, ft, 'lift')
  assert(types_match_values(flat_ft.params, flat_args))
```
Each call starts by immediately checking for unexpected reentrance using
`Task.trap_if_on_the_stack`. Next, a `lift`ed function waits until there is no
backpressure, as defined by `Task.enter`. If the supertask cancels the call
while waiting for backpressure, the call is aborted before the arguments are
lowered (which means that owned-handle arguments are not transferred) without
ever executing the core wasm callee. Once the backpressure gate is cleared, the
arguments are lowered into core wasm values and memory according to the
`canonopt` immediates of `canon lift` (as defined by `lower_flat_values`
above).

If the `async` `canonopt` is *not* specified, a `lift`ed function then calls
the core wasm callee, passing the lowered arguments in core function parameters
and receiving the return value as core function results. Once the core results
are lifted according to `lift_flat_values` above, the optional `post-return`
function (specified as a `canonopt` immediate of `canon lift`) is called,
passing the same core wasm results as parameters so that the `post-return`
function can free any associated allocations. Since `Task.enter` acquired the
`exclusive` lock and the `Task.exit` call here releases the `exclusive` lock,
synchronous functions cannot overlap execution; attempts by callers to make
overlapping calls will result in backpressure in `Task.enter`.
```python
  if opts.sync:
    flat_results = await call_and_trap_on_throw(callee, task, flat_args)
    assert(types_match_values(flat_ft.results, flat_results))
    result = lift_flat_values(cx, MAX_FLAT_RESULTS, CoreValueIter(flat_results), ft.result_type())
    task.return_(result)
    if opts.post_return is not None:
      task.inst.may_leave = False
      [] = await call_and_trap_on_throw(opts.post_return, task, flat_results)
      task.inst.may_leave = True
    task.exit()
    return
```
By clearing `may_leave` for the duration of the `post-return` call, the
Canonical ABI ensures that synchronously-lowered calls to synchronously-lifted
functions can always be implemented by a plain synchronous function call
without the need for fibers which would otherwise be necessary if the
`post-return` function performed a blocking operation.

In both of the `async` cases below (with or without `callback`), the
`task.return` built-in must be called, providing the return value as core wasm
*parameters* to the `task.return` built-in (rather than as core function
results as in the synchronous case). If `task.return` is *not* called by the
time the `lift`ed function exits, `Task.exit` traps.

In the `async` non-`callback` ("stackful async") case, there is a single call
to the core wasm callee which must return empty core results. Waiting for async
I/O happens by the callee synchronously calling built-ins like
`waitable-set.wait`. When these built-ins need to block, they call
`Task.block_on` which allows other concurrent tasks to make progress. Note
that, since `Task.enter` does *not* acquire the `exclusive` lock for stackful
async functions, calls to `waitable-set.wait` made by a stackful async function
do not prevent other stackful async calls from starting or progressing in the
same component instance.
```python
  if not opts.callback:
    [] = await call_and_trap_on_throw(callee, task, flat_args)
    assert(types_match_values(flat_ft.results, []))
    task.exit()
    return
```

Lastly, in the `async callback` ("stackless async") case, waiting happens by
first calling the core wasm callee and then repeatedly calling the `callback`
function (specified as a `funcidx` immediate in `canon lift`) until the
`EXIT` code (`0`) is returned:
```python
  [packed] = await call_and_trap_on_throw(callee, task, flat_args)
  while True:
    code,si = unpack_callback_result(packed)
    match code:
      case CallbackCode.EXIT:
        task.exit()
        return
      case CallbackCode.YIELD:
        e = await task.yield_(cancellable = True, for_callback = True)
      case CallbackCode.WAIT:
        s = task.inst.table.get(si)
        trap_if(not isinstance(s, WaitableSet))
        e = await task.wait_for_event(s, cancellable = True, for_callback = True)
      case CallbackCode.POLL:
        s = task.inst.table.get(si)
        trap_if(not isinstance(s, WaitableSet))
        e = await task.poll_for_event(s, cancellable = True, for_callback = True)
    event_code, p1, p2 = e
    [packed] = await call_and_trap_on_throw(opts.callback, task, [event_code, p1, p2])
```
The `Task.yield_`, `wait_for_event` and `poll_for_event` methods called here
are the same methods called by the `canon yield`, `waitable-set.wait` and
`waitable-set.poll` built-ins. Thus, the main difference between stackful and
stackless async is whether these blocking operations are performed from an
empty or non-empty core wasm callstack. A key difference, though, is that the
`for_callback` flag is only set when calling these blocking operations from the
event loop, not the built-ins. `for_callback` tells these blocking operations
to release the `exclusive` lock taken by `Task.enter()` so that other `async
callback` functions can start or make progress in the interim. Since the
built-ins don't set `for_callback`, they do not drop the `exclusive` lock,
thereby ensuring the invariant that `async callback` code is never reentered
while other `async callback` core wasm code (or, because they share the same
`exclusive` lock, synchronous core wasm code) is on the stack.

The bit-packing scheme used for the `i32` `packed` return value is defined as
follows:
```python
class CallbackCode(IntEnum):
  EXIT = 0
  YIELD = 1
  WAIT = 2
  POLL = 3
  MAX = 3

def unpack_callback_result(packed):
  code = packed & 0xf
  trap_if(code > CallbackCode.MAX)
  assert(packed < 2**32)
  assert(Table.MAX_LENGTH < 2**28)
  waitable_set_index = packed >> 4
  return (CallbackCode(code), waitable_set_index)
```
The ability to asynchronously wait, poll, yield and exit is thus available to
both the `callback` and non-`callback` cases, making `callback` just an
optimization to avoid allocating stacks for async languages that have avoided
the need for [stack-switching] by design (e.g., `async`/`await` in JS, Python,
C# and Rust).

Uncaught Core WebAssembly [exceptions] result in a trap at component
boundaries. Thus, if a component wishes to signal an error, it must use some
sort of explicit type such as `result` (whose `error` case particular language
bindings may choose to map to and from exceptions):
```python
async def call_and_trap_on_throw(callee, task, args):
  try:
    return await callee(task, args)
  except CoreWebAssemblyException:
    trap()
```


### `canon lower`

For a canonical definition:
```wat
(canon lower $callee:<funcidx> $opts:<canonopt>* (core func $f))
```

In addition to [general validation of `$opts`](#canonopt-validation), additional
validation is performed where `$callee` has type `$ft`:

* `$f` is given type `flatten_functype($opts, $ft, 'lower')`
* requires options [based on `lower(param)`](#canonopt-validation) for all parameters in `ft`
* requires options [based on `lift(result)`](#canonopt-validation) if `ft` has a result
* if `len(flatten_types(ft.param_types())) > max_flat_params`, `memory` is required
* if `len(flatten_types(ft.result_type())) > max_flat_results`, `realloc` is required
* 🔀 if `async` is specified, `memory` must be present

When instantiating component instance `$inst`:
* Define `$f` to be the partially-bound closure: `canon_lower($opts, $ft, $callee)`

The resulting bound function `$f` takes 2 runtime arguments:
* `task`, which is the [current task]
* `flat_args`, which is a list of core wasm values passed by the caller

Based on this, `canon_lower` is defined in chunks as follows:
```python
async def canon_lower(opts, ft, callee, task, flat_args):
  trap_if(not task.inst.may_leave)
  subtask = Subtask(task)
  cx = LiftLowerContext(opts, task.inst, subtask)
  flat_ft = flatten_functype(opts, ft, 'lower')
  assert(types_match_values(flat_ft.params, flat_args))
  flat_args = CoreValueIter(flat_args)
```
Each call to `canon_lower` creates a new `Subtask`. However, this `Subtask` is
only added to the current component instance's table (below) if `async` is
specified *and* `callee` blocks. In any case, this `Subtask` is used as the
`borrow_scope` for `borrow` arguments, ensuring that owned handles are not
dropped before `Subtask.deliver_return` is called (below).

In the synchronous case, `Subtask.call_sync` ensures a fully-synchronous call to
`callee` (that prevents any interleaved execution until `callee` returns):
```python
  if opts.sync:
    def on_start():
      return lift_flat_values(cx, MAX_FLAT_PARAMS, flat_args, ft.param_types())

    flat_results = None
    def on_resolve(result):
      nonlocal flat_results
      flat_results = lower_flat_values(cx, MAX_FLAT_RESULTS, result, ft.result_type(), flat_args)

    await subtask.call_sync(callee, on_start, on_resolve)
    assert(types_match_values(flat_ft.results, flat_results))
    subtask.deliver_resolve()
    return flat_results
```

In the asynchronous case, `Subtask.call_async` ensures that the call to `callee`
always returns control flow back to the caller without blocking:
```python
  def on_start():
    on_progress()
    return lift_flat_values(cx, MAX_FLAT_ASYNC_PARAMS, flat_args, ft.param_types())

  def on_resolve(result):
    on_progress()
    if result is not None:
      [] = lower_flat_values(cx, 0, result, ft.result_type(), flat_args)

  subtaski = None
  def on_progress():
    if subtaski is not None:
      def subtask_event():
        if subtask.resolved():
          subtask.deliver_resolve()
        return (EventCode.SUBTASK, subtaski, subtask.state)
      subtask.set_event(subtask_event)

  await subtask.call_async(callee, on_start, on_resolve)
  if subtask.resolved():
    subtask.deliver_resolve()
    return [Subtask.State.RETURNED]

  subtaski = task.inst.table.add(subtask)
  assert(0 < subtaski <= Table.MAX_LENGTH < 2**28)
  assert(0 <= subtask.state < 2**4)
  return [subtask.state | (subtaski << 4)]
```
When `callee` blocks before returning, the `on_progress` function called by
`on_start` and `on_resolve` uses `Waitable.set_event` to asynchronously notify
the supertask when the subtask makes progress. A set event can take arbitrarily
long to deliver and thus events are represented as *functions* that are called
(by `Waitable.get_event`) right before the event is actually delivered to core
wasm. Thus, the `Subtask.deliver_resolve` call in `subtask_event` (that
releases borrowed handles back to the caller) is defined to happen only when
`RETURNED` is *delivered* to core wasm, not when `on_resolve` is first called.


### `canon resource.new`

For a canonical definition:
```wat
(canon resource.new $rt (core func $f))
```
validation specifies:
* `$rt` must refer to locally-defined (not imported) resource type
* `$f` is given type `(func (param $rt.rep) (result i32))`, where `$rt.rep` is
  currently fixed to be `i32`.

Calling `$f` invokes the following function, which adds an owning handle
containing the given resource representation to the current component
instance's table:
```python
async def canon_resource_new(rt, task, rep):
  trap_if(not task.inst.may_leave)
  h = ResourceHandle(rt, rep, own = True)
  i = task.inst.table.add(h)
  return [i]
```


### `canon resource.drop`

For a canonical definition:
```wat
(canon resource.drop $rt $async? (core func $f))
```
validation specifies:
* `$rt` must refer to resource type
* `$f` is given type `(func (param i32))`
* 🔀+🚝 - `async` is allowed (otherwise it is not allowed)

Calling `$f` invokes the following function, which removes the handle from the
current component instance's table and, if the handle was owning, calls the
resource's destructor.
```python
async def canon_resource_drop(rt, sync, task, i):
  trap_if(not task.inst.may_leave)
  inst = task.inst
  h = inst.table.remove(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not rt)
  trap_if(h.num_lends != 0)
  flat_results = [] if sync else [0]
  if h.own:
    assert(h.borrow_scope is None)
    if inst is rt.impl:
      if rt.dtor:
        await rt.dtor(h.rep)
    else:
      if rt.dtor:
        caller_opts = CanonicalOptions(sync = sync)
        callee_opts = CanonicalOptions(sync = rt.dtor_sync, callback = rt.dtor_callback)
        ft = FuncType([U32Type()],[])
        callee = partial(canon_lift, callee_opts, rt.impl, ft, rt.dtor)
        flat_results = await canon_lower(caller_opts, ft, callee, task, [h.rep])
      else:
        task.trap_if_on_the_stack(rt.impl)
  else:
    h.borrow_scope.num_borrows -= 1
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
```wat
(canon resource.rep $rt (core func $f))
```
validation specifies:
* `$rt` must refer to a locally-defined (not imported) resource type
* `$f` is given type `(func (param i32) (result $rt.rep))`, where `$rt.rep` is
  currently fixed to be `i32`.

Calling `$f` invokes the following function, which extracts the resource
representation from the handle in the current component instance's table:
```python
async def canon_resource_rep(rt, task, i):
  h = task.inst.table.get(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not rt)
  return [h.rep]
```
Note that the "locally-defined" requirement above ensures that only the
component instance defining a resource can access its representation.


### 🔀 `canon context.get`

For a canonical definition:
```wat
(canon context.get $t $i (core func $f))
```
validation specifies:
* `$t` must be `i32` (for now; see [here][context-local storage])
* `$i` must be less than `2`
* `$f` is given type `(func (result i32))`

Calling `$f` invokes the following function, which reads the [context-local
storage] of the [current task]:
```python
async def canon_context_get(t, i, task):
  assert(t == 'i32')
  assert(i < ContextLocalStorage.LENGTH)
  return [task.context.get(i)]
```


### 🔀 `canon context.set`

For a canonical definition:
```wat
(canon context.set $t $i (core func $f))
```
validation specifies:
* `$t` must be `i32` (for now; see [here][context-local storage])
* `$i` must be less than `2`
* `$f` is given type `(func (param $v i32))`

Calling `$f` invokes the following function, which writes to the [context-local
storage] of the [current task]:
```python
async def canon_context_set(t, i, task, v):
  assert(t == 'i32')
  assert(i < ContextLocalStorage.LENGTH)
  task.context.set(i, v)
  return []
```


### 🔀 `canon backpressure.set`

For a canonical definition:
```wat
(canon backpressure.set (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $enabled i32))`

Calling `$f` invokes the following function, which clears or sets the
`no_backpressure` [`asyncio.Event`] of the current `ComponentInstance`.
`no_backpressure` is waited on by `Task.enter` (at the beginning of a call to a
`lift`ed function) to prevent new calls from starting when backpressure is
enabled:
```python
async def canon_backpressure_set(task, flat_args):
  trap_if(task.opts.sync)
  assert(len(flat_args) == 1)
  if flat_args[0] == 0:
    task.inst.no_backpressure.set()
  else:
    task.inst.no_backpressure.clear()
  return []
```


### 🔀 `canon task.return`

For a canonical definition:
```wat
(canon task.return (result $t)? $opts (core func $f))
```

In addition to [general validation of `$opts`](#canonopt-validation) validation
specifies:

* `$f` is given type `flatten_functype($opts, (func (param $t)?), 'lower')`
* `$opts` may only contain `memory` and `string-encoding`
* [`lift($f.result)` above](#canonopt-validation) defines required options

Calling `$f` invokes the following function which lifts the results from core
wasm state and passes them to the caller via `Task.return_`:
```python
async def canon_task_return(task, result_type, opts: LiftOptions, flat_args):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.sync)
  trap_if(result_type != task.ft.result)
  trap_if(not LiftOptions.equal(opts, task.opts))
  cx = LiftLowerContext(opts, task.inst, task)
  result = lift_flat_values(cx, MAX_FLAT_PARAMS, CoreValueIter(flat_args), task.ft.result_type())
  task.return_(result)
  return []
```
The `trap_if(task.opts.sync)` prevents `task.return` from being called by
synchronously-lifted functions (which return their value by returning from the
lifted core function).

The `trap_if(result_type != task.ft.result)` guard ensures that, in a
component with multiple exported functions of different types, `task.return` is
not called with a mismatched result type (which, due to indirect control flow,
can in general only be caught dynamically).

The `trap_if(not LiftOptions.equal(opts, task.opts))` guard ensures that the
return value is lifted the same way as the `canon lift` from which this
`task.return` is returning. This ensures that AOT fusion of `canon lift` and
`canon lower` can generate a thunk that is indirectly called by `task.return`
after these guards. Inside `LiftOptions.equal`, `opts.memory` is compared with
`task.opts.memory` via object identity of the mutable memory instance. Since
`memory` refers to a mutable *instance* of memory, this comparison is not
concerned with the static memory indices (in `canon lift` and `canon
task.return`), only the identity of the memories created
at instantiation-/ run-time. In Core WebAssembly spec terms, the test is on the
equality of the [`memaddr`] values stored in the instance's [`memaddrs` table]
which is indexed by the static [`memidx`].


### 🔀 `canon task.cancel`

For a canonical definition:
```wat
(canon task.cancel (core func $f))
```
validation specifies:
* `$f` is given type `(func)`

Calling `$f` cancels the [current task], confirming a previous `subtask.cancel`
request made by a supertask and claiming that all `borrow` handles lent to the
current task have already been dropped (and trapping in `Task.cancel` if not).
```python
async def canon_task_cancel(task):
  trap_if(not task.inst.may_leave)
  trap_if(task.opts.sync)
  task.cancel()
  return []
```
The `trap_if(task.opts.sync)` prevents `task.cancel` from being called by
synchronously-lifted functions (which must always return a value by returning
from the lifted core function).

`Task.cancel` also traps if there has been no cancellation request (in which
case the callee expects to receive a return value) or if the task has already
returned a value or already called `task.cancel`.


### 🔀 `canon yield`

For a canonical definition:
```wat
(canon yield $cancellable? (core func $f))
```
validation specifies:
* `$f` is given type `(func (result i32))`
* 🚟 - `cancellable` is allowed (otherwise it must be absent)

Calling `$f` calls `Task.yield_` to allow other tasks to execute. This allows a
long-running computation that is not otherwise performing I/O to cooperatively
allow other tasks to execute.
```python
async def canon_yield(cancellable, task):
  trap_if(not task.inst.may_leave)
  event_code,_,_ = await task.yield_(cancellable, for_callback = False)
  match event_code:
    case EventCode.NONE:
      return [0]
    case EventCode.TASK_CANCELLED:
      return [1]
```
If `cancellable` is set, then `yield` will return whether the supertask has
already or concurrently requested cancellation. `yield` (and other cancellable
operations) will only indicate cancellation once and thus, if a caller is not
prepared to propagate cancellation, they can omit `cancellable` so that
cancellation is instead delivered at a later `cancellable` call.

Note that, since `for_callback` is not set, when called from a
synchronously-lifted or `async callback`-lifted export, `yield` will not allow
other synchronously- lifted or `async callback`-lifted code to execute before
returning.


### 🔀 `canon waitable-set.new`

For a canonical definition:
```wat
(canon waitable-set.new (core func $f))
```
validation specifies:
* `$f` is given type `(func (result i32))`

Calling `$f` invokes the following function, which adds an empty waitable set
to the current component instance's table:
```python
async def canon_waitable_set_new(task):
  trap_if(not task.inst.may_leave)
  return [ task.inst.table.add(WaitableSet()) ]
```


### 🔀 `canon waitable-set.wait`

For a canonical definition:
```wat
(canon waitable-set.wait $cancellable? (memory $mem) (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $si) (param $ptr i32) (result i32))`
* 🚟 - `cancellable` is allowed (otherwise it must be absent)

Calling `$f` invokes the following function which waits for progress to be made
on a `Waitable` in the given waitable set (indicated by index `$si`) and then
returning its `EventCode` and writing the payload values into linear memory:
```python
async def canon_waitable_set_wait(cancellable, mem, task, si, ptr):
  trap_if(not task.inst.may_leave)
  s = task.inst.table.get(si)
  trap_if(not isinstance(s, WaitableSet))
  e = await task.wait_for_event(s, cancellable, for_callback = False)
  return unpack_event(mem, task, ptr, e)

def unpack_event(mem, task, ptr, e: EventTuple):
  event, p1, p2 = e
  cx = LiftLowerContext(LiftLowerOptions(memory = mem), task.inst)
  store(cx, p1, U32Type(), ptr)
  store(cx, p2, U32Type(), ptr + 4)
  return [event]
```
If `cancellable` is set, then `waitable-set.wait` will return whether the
supertask has already or concurrently requested cancellation.
`waitable-set.wait` (and other cancellable operations) will only indicate
cancellation once and thus, if a caller is not prepared to propagate
cancellation, they can omit `cancellable` so that cancellation is instead
delivered at a later `cancellable` call.

Note that, since `for_callback` is not set, when called from a
synchronously-lifted or `async callback`-lifted export, `waitable-set.wait`
will not allow other synchronously-lifted or `async callback`-lifted code to
execute before returning.


### 🔀 `canon waitable-set.poll`

For a canonical definition:
```wat
(canon waitable-set.poll $async? (memory $mem) (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $si i32) (param $ptr i32) (result i32))`
* 🚟 - `async` is allowed (otherwise it must be `false`)

Calling `$f` invokes the following function, which returns `NONE` (`0`) instead
of blocking if there is no event available, and otherwise returns the event the
same way as `wait`.
```python
async def canon_waitable_set_poll(cancellable, mem, task, si, ptr):
  trap_if(not task.inst.may_leave)
  s = task.inst.table.get(si)
  trap_if(not isinstance(s, WaitableSet))
  e = await task.poll_for_event(s, cancellable, for_callback = False)
  return unpack_event(mem, task, ptr, e)
```
Even though `waitable-set.poll` doesn't strictly block for a waitable to have
an event, it does semantically perform a `yield` (inside `Task.poll_for_event`)
to allow other tasks to make progress and avoid busy-waiting deadlock.

If `cancellable` is set, then `waitable-set.poll` will return whether the
supertask has already or concurrently requested cancellation.
`waitable-set.poll` (and other cancellable operations) will only indicate
cancellation once and thus, if a caller is not prepared to propagate
cancellation, they can omit `cancellable` so that cancellation is instead
delivered at a later `cancellable` call.

Note that, since `for_callback` is not set, when called from a
synchronously-lifted or `async callback`-lifted export, `waitable-set.poll`
will not allow other synchronously-lifted or `async callback`-lifted code to
execute before returning.


### 🔀 `canon waitable-set.drop`

For a canonical definition:
```wat
(canon waitable-set.drop (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` invokes the following function, which removes the indicated
waitable set from the current component instance's table, performing the guards
defined by `WaitableSet.drop` above:
```python
async def canon_waitable_set_drop(task, i):
  trap_if(not task.inst.may_leave)
  s = task.inst.table.remove(i)
  trap_if(not isinstance(s, WaitableSet))
  s.drop()
  return []
```
Note that `WaitableSet.drop` will trap if it is non-empty or there is a
concurrent `yield`, `waitable-set.wait`, `waitable-set.poll` or `async
callback` currently using this waitable set.


### 🔀 `canon waitable.join`

For a canonical definition:
```wat
(canon waitable.join (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $wi i32) (param $si i32))`

Calling `$f` invokes the following function which adds the Waitable indicated
by the index `wi` to the waitable set indicated by the index `si`, removing the
waitable from any waitable set that it is currently a member of.
```python
async def canon_waitable_join(task, wi, si):
  trap_if(not task.inst.may_leave)
  w = task.inst.table.get(wi)
  trap_if(not isinstance(w, Waitable))
  if si == 0:
    w.join(None)
  else:
    s = task.inst.table.get(si)
    trap_if(not isinstance(s, WaitableSet))
    w.join(s)
  return []
```
Note that tables do not allow elements at index `0`, so `0` is a valid sentinel
that tells `join` to remove the given waitable from any set that it is
currently a part of. Waitables can be a member of at most one set, so if the
given waitable is already in one set, it will be transferred.


### 🔀 `canon subtask.cancel`

For a canonical definition:
```wat
(canon subtask.cancel (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` sends a request to the subtask at the given index to cancel its
execution ASAP. This request is cooperative and the subtask may take arbitrarily
long to receive and confirm the request. If the subtask doesn't immediately
confirm the cancellation request, `subtask.cancel` returns `BLOCKED` and the
caller must wait for a `SUBTASK` progress update using `waitable-set` methods
as usual.

When cancellation is confirmed the supertask will receive the final state of
the subtask which is one of:
* `RETURNED`, if the subtask successfully returned a value via `task.return`;
* `CANCELLED_BEFORE_STARTED`, if the subtask was cancelled before receiving its
  arguments (and thus no `own` handles were transferred); or
* `CANCELLED_BEFORE_RETURNED`, if the subtask called `task.cancel` instead of
  `task.return`.

This state is either returned by `subtask.cancel`, if the subtask resolved
without blocking, or, if `subtask.cancel` returns `BLOCKED`, then as part of
the event payload of a future `SUBTASK` event.
```python
BLOCKED = 0xffff_ffff

async def canon_subtask_cancel(sync, task, i):
  trap_if(not task.inst.may_leave)
  subtask = task.inst.table.get(i)
  trap_if(not isinstance(subtask, Subtask))
  trap_if(subtask.resolve_delivered() or subtask.cancelled())
  if subtask.resolved():
    assert(subtask.has_pending_event())
  else:
    await subtask.request_cancel()
    if sync:
      while not subtask.resolved():
        if subtask.has_pending_event():
          _ = subtask.get_event()
        await task.block_on(subtask.wait_for_pending_event())
    else:
      if not subtask.resolved():
        return [BLOCKED]
  code,index,payload = subtask.get_event()
  assert(code == EventCode.SUBTASK and index == i and payload == subtask.state)
  assert(subtask.resolve_delivered())
  return [subtask.state]
```
The initial trapping conditions disallow calling `subtask.cancel` twice for the
same subtask or after the supertask has already been notified that the subtask
has returned.

A race condition handled by the above code is that it's possible for a subtask
to have already resolved (by calling `task.return` or `task.cancel`) and
updated the `state` stored in the `Subtask` (such that `Subtask.resolved()` is
`True`) but this fact has not yet been *delivered* to the supertask by the
supertask calling `get_event` on the `Subtask` in its table. This distinction
is captured by `Subtask.resolved` vs. `Subtask.resolve_delivered`.


### 🔀 `canon subtask.drop`

For a canonical definition:
```wat
(canon subtask.drop (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` removes the subtask at the given index from the current component
instance's table, performing the guards and bookkeeping defined by
`Subtask.drop()`.
```python
async def canon_subtask_drop(task, i):
  trap_if(not task.inst.may_leave)
  s = task.inst.table.remove(i)
  trap_if(not isinstance(s, Subtask))
  s.drop()
  return []
```


### 🔀 `canon {stream,future}.new`

For canonical definitions:
```wat
(canon stream.new $stream_t (core func $f))
(canon future.new $future_t (core func $f))
```
validation specifies:
* `$f` is given type `(func (result i64))`
* `$stream_t`/`$future_t` must be a type of the form `(stream $t?)`/`(future $t?)`

Calling `$f` calls `canon_{stream,future}_new` which adds two elements to the
current component instance's table and returns their indices packed into a
single `i64`. The first element (in the low 32 bits) is the readable end (of
the new {stream, future}) and the second element (in the high 32 bits) is the
writable end. The expectation is that, after calling `{stream,future}.new`, the
readable end is subsequently transferred to another component (or the host) via
`stream` or `future` parameter/result type (see `lift_{stream,future}` above).
```python
async def canon_stream_new(stream_t, task):
  trap_if(not task.inst.may_leave)
  shared = SharedStreamImpl(stream_t.t)
  ri = task.inst.table.add(ReadableStreamEnd(shared))
  wi = task.inst.table.add(WritableStreamEnd(shared))
  return [ ri | (wi << 32) ]

async def canon_future_new(future_t, task):
  trap_if(not task.inst.may_leave)
  shared = SharedFutureImpl(future_t.t)
  ri = task.inst.table.add(ReadableFutureEnd(shared))
  wi = task.inst.table.add(WritableFutureEnd(shared))
  return [ ri | (wi << 32) ]
```


### 🔀 `canon stream.{read,write}`

For canonical definitions:
```wat
(canon stream.read $stream_t $opts (core func $f))
(canon stream.write $stream_t $opts (core func $f))
```
In addition to [general validation of `$opts`](#canonopt-validation) validation
specifies:
* `$f` is given type `(func (param i32 i32 i32) (result i32))`
* `$stream_t` must be a type of the form `(stream $t?)`
* If `$t` is present:
  * [`lower($t)` above](#canonopt-validation) defines required options for `stream.write`
  * [`lift($t)` above](#canonopt-validation) defines required options for `stream.read`
  * `memory` is required to be present

The implementation of these built-ins funnels down to a single `stream_copy`
function that is parameterized by the direction of the copy:
```python
async def canon_stream_read(stream_t, opts, task, i, ptr, n):
  return await stream_copy(ReadableStreamEnd, WritableBufferGuestImpl, EventCode.STREAM_READ,
                           stream_t, opts, task, i, ptr, n)

async def canon_stream_write(stream_t, opts, task, i, ptr, n):
  return await stream_copy(WritableStreamEnd, ReadableBufferGuestImpl, EventCode.STREAM_WRITE,
                           stream_t, opts, task, i, ptr, n)
```

Introducing the `stream_copy` function in chunks, `stream_copy` first checks
that the element at index `i` is of the right type, not already `copying`, and
not already `done` (as defined next). (In the future, the `copying` trap could
be relaxed, allowing a finite number of pipelined reads or writes.)
```python
async def stream_copy(EndT, BufferT, event_code, stream_t, opts, task, i, ptr, n):
  trap_if(not task.inst.may_leave)
  e = task.inst.table.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != stream_t.t)
  trap_if(e.copying or e.done)
```
Then a readable or writable buffer is created which (in `Buffer`'s constructor)
eagerly checks the alignment and bounds of (`i`, `n`). (In the future, the
restriction on futures/streams containing `borrow`s could be relaxed by
maintaining sufficient bookkeeping state to ensure that borrowed handles *or
streams/futures of borrowed handles* could not outlive their originating call.)
```python
  assert(not contains_borrow(stream_t))
  cx = LiftLowerContext(opts, task.inst, borrow_scope = None)
  buffer = BufferT(stream_t.t, cx, ptr, n)
```
Next, the `copy` method of `{Readable,Writable}{Stream,Future}End` is called to
perform the actual read/write. The `on_copy*` callbacks passed to `copy` bind
and store a `stream_event` closure on the readable/writable end (via the
inherited `Waitable.set_event`) which will be called right before the event is
delivered to core wasm. `stream_event` first calls `reclaim_buffer` to regain
ownership of `buffer` and prevent any further partial reads/writes. Thus, up
until event delivery, the other end of the stream is free to repeatedly
read/write from/to `buffer`, ideally filling it up and minimizing context
switches. Next, `copying` is cleared to reenable future `stream.{read,write}`
calls. However, if the `CopyResult` is `DROPPED`, `done` is set to disallow
all future use of this stream end. Lastly, `stream_event` packs the
`CopyResult` and number of elements copied up until this point into a single
`i32` payload for core wasm.
```python
  def stream_event(result, reclaim_buffer):
    reclaim_buffer()
    assert(e.copying)
    e.copying = False
    if result == CopyResult.DROPPED:
      e.done = True
    assert(0 <= result < 2**4)
    assert(buffer.progress <= Buffer.MAX_LENGTH < 2**28)
    packed_result = result | (buffer.progress << 4)
    return (event_code, i, packed_result)

  def on_copy(reclaim_buffer):
    e.set_event(partial(stream_event, CopyResult.COMPLETED, reclaim_buffer))

  def on_copy_done(result):
    e.set_event(partial(stream_event, result, reclaim_buffer = lambda:()))

  e.copying = True
  e.copy(task.inst, buffer, on_copy, on_copy_done)
```
If `stream.{read,write}` is called synchronously, the call blocks until the
operation makes progress (thereby setting a pending event):
```python
  if opts.sync and not e.has_pending_event():
    await task.block_on(e.wait_for_pending_event())
```
Finally, if there is a pending event on the stream end (which is necessarily a
`copy_event` closure), it is eagerly returned to the caller. Otherwise, the
`BLOCKED` code is returned and the caller must asynchronously wait for an event
using `waitable-set.{wait,poll}` or, if using a `callback`, by returning to the
event loop.
```python
  if e.has_pending_event():
    code,index,payload = e.get_event()
    assert(code == event_code and index == i and payload != BLOCKED)
    return [payload]
  else:
    return [BLOCKED]
```


### 🔀 `canon future.{read,write}`

For canonical definitions:
```wat
(canon future.read $future_t $opts (core func $f))
(canon future.write $future_t $opts (core func $f))
```
In addition to [general validation of `$opts`](#canonopt-validation) validation
specifies:
* `$f` is given type `(func (param i32 i32) (result i32))`
* `$future_t` must be a type of the form `(future $t?)`
* If `$t` is present:
  * [`lift($t)` above](#canonopt-validation) defines required options for `future.read`
  * [`lower($t)` above](#canonopt-validation) defines required options for `future.write`
  * `memory` is required to be present

The implementation of these built-ins funnels down to a single `future_copy`
function that is parameterized by the direction of the copy:
```python
async def canon_future_read(future_t, opts, task, i, ptr):
  return await future_copy(ReadableFutureEnd, WritableBufferGuestImpl, EventCode.FUTURE_READ,
                           future_t, opts, task, i, ptr)

async def canon_future_write(future_t, opts, task, i, ptr):
  return await future_copy(WritableFutureEnd, ReadableBufferGuestImpl, EventCode.FUTURE_WRITE,
                           future_t, opts, task, i, ptr)
```

Introducing the `future_copy` function in chunks, `future_copy` starts with the
same set of guards as `stream_copy` for parameters `i` and `ptr`. The only
difference is that, with futures, the `Buffer` length is fixed to `1`.
```python
async def future_copy(EndT, BufferT, event_code, future_t, opts, task, i, ptr):
  trap_if(not task.inst.may_leave)
  e = task.inst.table.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != future_t.t)
  trap_if(e.copying or e.done)

  assert(not contains_borrow(future_t))
  cx = LiftLowerContext(opts, task.inst, borrow_scope = None)
  buffer = BufferT(future_t.t, cx, ptr, 1)
```
Next, the `copy` method of `{Readable,Writable}FutureEnd.copy` is called to
perform the actual read/write. Other than the simplifications allowed by the
absence of repeated partial copies, the main difference in the following code
from the stream code is that `future_event` sets the `done` flag for *both* the
`DROPPED` and `COMPLETED` results, whereas `stream_event` sets `done` only for
`DROPPED`. This ensures that futures are read/written at most once and futures
are only passed to other components in a state where they are ready to be
read/written. Another important difference is that, since the buffer length is
always implied by the `CopyResult`, the number of elements copied is not packed
in the high 28 bits; they're always zero.
```python
  def future_event(result):
    assert((buffer.remain() == 0) == (result == CopyResult.COMPLETED))
    assert(e.copying)
    e.copying = False
    if result == CopyResult.DROPPED or result == CopyResult.COMPLETED:
      e.done = True
    return (event_code, i, result)

  def on_copy_done(result):
    assert(result != CopyResult.DROPPED or event_code == EventCode.FUTURE_WRITE)
    e.set_event(partial(future_event, result))

  e.copying = True
  e.copy(task.inst, buffer, on_copy_done)
```
The end of `future_copy` is the exact same as `stream_copy`: waiting if `sync`
and returning either the progress made or `BLOCKED`.
```python

  if opts.sync and not e.has_pending_event():
    await task.block_on(e.wait_for_pending_event())

  if e.has_pending_event():
    code,index,payload = e.get_event()
    assert(code == event_code and index == i)
    return [payload]
  else:
    return [BLOCKED]
```


### 🔀 `canon {stream,future}.cancel-{read,write}`

For canonical definitions:
```wat
(canon stream.cancel-read $stream_t $async? (core func $f))
(canon stream.cancel-write $stream_t $async? (core func $f))
(canon future.cancel-read $future_t $async? (core func $f))
(canon future.cancel-write $future_t $async? (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32) (result i32))`
* `$stream_t`/`$future_t` must be a type of the form `(stream $t?)`/`(future $t?)`
* 🚝 - `async` is allowed (otherwise it must be `false`)

The implementation of these four built-ins all funnel down to a single
parameterized `cancel_copy` function:
```python
async def canon_stream_cancel_read(stream_t, sync, task, i):
  return await cancel_copy(ReadableStreamEnd, EventCode.STREAM_READ, stream_t, sync, task, i)

async def canon_stream_cancel_write(stream_t, sync, task, i):
  return await cancel_copy(WritableStreamEnd, EventCode.STREAM_WRITE, stream_t, sync, task, i)

async def canon_future_cancel_read(future_t, sync, task, i):
  return await cancel_copy(ReadableFutureEnd, EventCode.FUTURE_READ, future_t, sync, task, i)

async def canon_future_cancel_write(future_t, sync, task, i):
  return await cancel_copy(WritableFutureEnd, EventCode.FUTURE_WRITE, future_t, sync, task, i)

async def cancel_copy(EndT, event_code, stream_or_future_t, sync, task, i):
  trap_if(not task.inst.may_leave)
  e = task.inst.table.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != stream_or_future_t.t)
  trap_if(not e.copying)
  if not e.has_pending_event():
    e.shared.cancel()
    if not e.has_pending_event():
      if sync:
        await task.block_on(e.wait_for_pending_event())
      else:
        return [BLOCKED]
  code,index,payload = e.get_event()
  assert(not e.copying and code == event_code and index == i)
  return [payload]
```
The *first* check for `e.has_pending_event()` catches the case where the copy has
already racily finished, in which case we must *not* call `cancel()`. Calling
`cancel()` may, but is not required to, recursively call one of the `on_*`
callbacks (passed by `canon_{stream,future}_{read,write}` above) which will set
a pending event that is caught by the *second* check for
`e.has_pending_event()`.

If the copy hasn't been cancelled, the synchronous case uses `Task.block_on` to
wait for one of the `on_*` callbacks to eventually be called (which will set
the pending event).

The asynchronous case simply returns `BLOCKING` and the client code must wait
as usual for a `{STREAM,FUTURE}_{READ,WRITE}` event. In this case, cancellation
has served only to asynchronously request that the host relinquish the buffer
ASAP without waiting for anything to be read or written.

If `BLOCKING` is *not* returned, the pending event (which is necessarily a
`stream_event`) is eagerly delivered to core wasm as the return value, thereby
saving an additional turn of the event loop. In this case, the core wasm
caller can assume that ownership of the buffer has been returned.


### 🔀 `canon {stream,future}.drop-{readable,writable}`

For canonical definitions:
```wat
(canon stream.drop-readable $stream_t (core func $f))
(canon stream.drop-writable $stream_t (core func $f))
(canon future.drop-readable $future_t (core func $f))
(canon future.drop-writable $future_t (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32 i32))`
* `$stream_t`/`$future_t` must be a type of the form `(stream $t?)`/`(future $t?)`

Calling `$f` removes the readable or writable end of the stream or future at
the given index from the current component instance's table, performing the
guards and bookkeeping defined by `{Readable,Writable}{Stream,Future}End.drop()`
above.
```python
async def canon_stream_drop_readable(stream_t, task, i):
  return await drop(ReadableStreamEnd, stream_t, task, i)

async def canon_stream_drop_writable(stream_t, task, hi):
  return await drop(WritableStreamEnd, stream_t, task, hi)

async def canon_future_drop_readable(future_t, task, i):
  return await drop(ReadableFutureEnd, future_t, task, i)

async def canon_future_drop_writable(future_t, task, hi):
  return await drop(WritableFutureEnd, future_t, task, hi)

async def drop(EndT, stream_or_future_t, task, hi):
  trap_if(not task.inst.may_leave)
  e = task.inst.table.remove(hi)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != stream_or_future_t.t)
  e.drop()
  return []
```


### 📝 `canon error-context.new`

For a canonical definition:
```wat
(canon error-context.new $opts (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32 i32) (result i32))`
* `async` is not present
* `memory` must be present

Calling `$f` calls the following function which uses the `$opts` immediate to
(non-deterministically) lift the debug message, create a new `ErrorContext`
value, store it in the current component instance's table and returns its
index.
```python
@dataclass
class ErrorContext:
  debug_message: String

async def canon_error_context_new(opts, task, ptr, tagged_code_units):
  trap_if(not task.inst.may_leave)
  if DETERMINISTIC_PROFILE or random.randint(0,1):
    s = String(('', 'utf8', 0))
  else:
    cx = LiftLowerContext(opts, task.inst)
    s = load_string_from_range(cx, ptr, tagged_code_units)
    s = host_defined_transformation(s)
  i = task.inst.table.add(ErrorContext(s))
  return [i]
```
Supporting the requirement (introduced in the
[explainer](Explainer.md#error-context-type)) that wasm code does not depend on
the contents of `error-context` values for behavioral correctness, the debug
message is completely discarded non-deterministically or, in the deterministic
profile, always. Importantly (for performance), when the debug message is
discarded, it is not even lifted and thus the O(N) well-formedness conditions
are not checked. (Note that `host_defined_transformation` is not defined by the
Canonical ABI and stands for an arbitrary host-defined function.)


### 📝 `canon error-context.debug-message`

For a canonical definition:
```wat
(canon error-context.debug-message $opts (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32 i32))`
* `async` is not present
* `memory` must be present
* `realloc` must be present

Calling `$f` calls the following function which uses the `$opts` immediate to
lowers the `ErrorContext`'s debug message. While *producing* an `error-context`
value may non-deterministically discard or transform the debug message, a
single `error-context` value must return the same debug message from
`error.debug-message` over time.
```python
async def canon_error_context_debug_message(opts, task, i, ptr):
  trap_if(not task.inst.may_leave)
  errctx = task.inst.table.get(i)
  trap_if(not isinstance(errctx, ErrorContext))
  cx = LiftLowerContext(opts, task.inst)
  store_string(cx, errctx.debug_message, ptr)
  return []
```
Note that `ptr` points to an 8-byte region of memory into which will be stored
the pointer and length of the debug string (allocated via `opts.realloc`).

### 📝 `canon error-context.drop`

For a canonical definition:
```wat
(canon error-context.drop (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` calls the following function, which drops the error context value
at the given index from the current component instance's table:
```python
async def canon_error_context_drop(task, i):
  trap_if(not task.inst.may_leave)
  errctx = task.inst.table.remove(i)
  trap_if(not isinstance(errctx, ErrorContext))
  return []
```


### 🧵 `canon thread.spawn_ref`

For a canonical definition:
```wat
(canon thread.spawn_ref $ft (core func $spawn_ref))
```
validation specifies:
* `$ft` must refer to a `shared` function type; initially, only the type
  `(shared (func (param $c i32)))` is allowed (see explanation below)
* `$spawn_ref` is given type `(func (param $f (ref null $ft)) (param $c i32)
  (result $e i32))`.

> Note: ideally, a thread could be spawned with [arbitrary thread parameters].
> Currently, that would require additional work in the toolchain to support so,
> for simplicity, the current proposal simply fixes a single `i32` parameter
> type. However, `thread.spawn_ref` could be extended to allow arbitrary thread
> parameters in the future, once it's concretely beneficial to the toolchain.
> The inclusion of `$ft` ensures backwards compatibility for when arbitrary
> parameters are allowed.

Calling `$spawn_ref` checks that the reference `$f` is not null. Then, it spawns
a thread which:
  - invokes `$f` with `$c`
  - executes `$f` until completion or trap in a `shared` context as described by
    the [shared-everything threads] proposal.

In pseudocode, `$spawn_ref` looks like:

```python
def canon_thread_spawn_ref(f, c):
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


### 🧵 `canon thread.spawn_indirect`

For a canonical definition:
```wat
(canon thread.spawn_indirect $ft $tbl (core func $spawn_indirect))
```
validation specifies:
* `$ft` must refer to a `shared` function type; initially, only the type
  `(shared (func (param $c i32)))` is allowed (see explanation in
  `thread.spawn_ref` above)
* `$tbl` must refer to a shared table whose element type matches `(ref null
  (shared func))`
* `$spawn_indirect` is given type `(func (param $i i32) (param $c i32) (result
  $e i32))`.

Calling `$spawn_indirect` retrieves a reference to function `$f` from table
`$tbl` and checks that `$f` is of type `$ft`. If that succeeds, it spawns a
thread which:
  - invokes `$f` with `$c`
  - executes `$f` until completion or trap in a `shared` context as described by
    the [shared-everything threads] proposal.

In pseudocode, `$spawn_indirect` looks like:

```python
def canon_thread_spawn_indirect(ft, tbl, i, c):
  f = tbl[i]
  trap_if(f is None)
  trap_if(f.type != ft)
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


### 🧵 `canon thread.available_parallelism`

For a canonical definition:
```wat
(canon thread.available_parallelism (core func $f))
```
validation specifies:
* `$f` is given type `(func shared (result i32))`.

Calling `$f` returns the number of threads the underlying hardware can be
expected to execute in parallel. This value can be artificially limited by
engine configuration and is not allowed to change over the lifetime of a
component instance.

```python
def canon_thread_available_parallelism():
  if DETERMINISTIC_PROFILE:
    return [1]
  else:
    return [NUM_ALLOWED_THREADS]
```


[Virtualization Goals]: Goals.md
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
[Backpressure]: Async.md#backpressure
[Current Task]: Async.md#current-task
[Readable and Writable Ends]: Async.md#streams-and-futures
[Context-Local Storage]: Async.md#context-local-storage
[Subtask State Machine]: Async.md#cancellation
[Lazy Lowering]: https://github.com/WebAssembly/component-model/issues/383

[Administrative Instructions]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-instr-admin
[Implementation Limits]: https://webassembly.github.io/spec/core/appendix/implementation.html
[Function Instance]: https://webassembly.github.io/spec/core/exec/runtime.html#function-instances
[Two-level]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-import

[Multi-value]: https://github.com/WebAssembly/multi-value/blob/master/proposals/multi-value/Overview.md
[Exceptions]: https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md
[WASI]: https://github.com/webassembly/wasi
[Deterministic Profile]: https://github.com/WebAssembly/profiles/blob/main/proposals/profiles/Overview.md
[stack-switching]: https://github.com/WebAssembly/stack-switching
[`memaddr`]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-memaddr
[`memaddrs` table]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-moduleinst
[`memidx`]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-memidx

[Alignment]: https://en.wikipedia.org/wiki/Data_structure_alignment
[UTF-8]: https://en.wikipedia.org/wiki/UTF-8
[UTF-16]: https://en.wikipedia.org/wiki/UTF-16
[Latin-1]: https://en.wikipedia.org/wiki/ISO/IEC_8859-1
[Unicode Scalar Value]: https://unicode.org/glossary/#unicode_scalar_value
[Unicode Code Point]: https://unicode.org/glossary/#code_point
[Code Units]: https://www.unicode.org/glossary/#code_unit
[Surrogate]: https://unicode.org/faq/utf_bom.html#utf16-2
[Name Mangling]: https://en.wikipedia.org/wiki/Name_mangling
[Fibers]: https://en.wikipedia.org/wiki/Fiber_(computer_science)
[Asyncify]: https://emscripten.org/docs/porting/asyncify.html

[`import_name`]: https://clang.llvm.org/docs/AttributeReference.html#import-name
[`export_name`]: https://clang.llvm.org/docs/AttributeReference.html#export-name

[Arbitrary Thread Parameters]: https://github.com/WebAssembly/shared-everything-threads/discussions/3
[wasi-libc Convention]: https://github.com/WebAssembly/wasi-libc/blob/925ad6d7/libc-top-half/musl/src/thread/pthread_create.c#L318
[Shared-Everything Threads]: https://github.com/WebAssembly/shared-everything-threads/blob/main/proposals/shared-everything-threads/Overview.md

[`asyncio`]: https://docs.python.org/3/library/asyncio.html
[`asyncio.Task`]: https://docs.python.org/3/library/asyncio-task.html#asyncio.Task
[`asyncio.Event`]: https://docs.python.org/3/library/asyncio-sync.html#event
[`asyncio.Lock`]: https://docs.python.org/3/library/asyncio-sync.html#lock
[`asyncio.Condition`]: https://docs.python.org/3/library/asyncio-sync.html#condition
[Awaitable]: https://docs.python.org/3/library/asyncio-task.html#awaitables

[OIO]: https://en.wikipedia.org/wiki/Overlapped_I/O
[io_uring]: https://en.wikipedia.org/wiki/Io_uring
