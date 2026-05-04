# Canonical ABI Explainer

This document defines the Canonical ABI used to convert between the values and
functions of components in the Component Model and the values and functions
of modules in Core WebAssembly. See the [AST explainer](Explainer.md) for a
walkthrough of the static structure of a component and the [concurrency
explainer] for a high-level description of the concurrency concepts being
specified here.

* [Introduction](#introduction)
* [Stack Switching](#stack-switching)
* [Embedding](#embedding)
* [Lifting and Lowering Context](#lifting-and-lowering-context)
* [Canonical ABI Options](#canonical-abi-options)
* [Runtime State](#runtime-state)
  * [Component Instance State](#component-instance-state)
  * [Table State](#table-state)
  * [Resource State](#resource-state)
  * [Thread State](#thread-state)
  * [Waitable State](#waitable-state)
  * [Task State](#task-state)
  * [Subtask State](#subtask-state)
  * [Buffer State](#buffer-state)
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
  * [`canon backpressure.set`](#-canon-backpressureset) 🔀✕
  * [`canon backpressure.{inc,dec}`](#-canon-backpressureincdec) 🔀
  * [`canon task.return`](#-canon-taskreturn) 🔀
  * [`canon task.cancel`](#-canon-taskcancel) 🔀
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
  * [`canon thread.index`](#-canon-threadindex) 🧵
  * [`canon thread.new-indirect`](#-canon-threadnew-indirect) 🧵
  * [`canon thread.switch-to`](#-canon-threadswitch-to) 🧵
  * [`canon thread.suspend`](#-canon-threadsuspend) 🧵
  * [`canon thread.resume-later`](#-canon-threadresume-later) 🧵
  * [`canon thread.yield-to`](#-canon-threadyield-to) 🧵
  * [`canon thread.yield`](#-canon-threadyield) 🧵
  * [`canon error-context.new`](#-canon-error-contextnew) 📝
  * [`canon error-context.debug-message`](#-canon-error-contextdebug-message) 📝
  * [`canon error-context.drop`](#-canon-error-contextdrop) 📝
  * [`canon thread.spawn-ref`](#-canon-threadspawn-ref) 🧵②
  * [`canon thread.spawn-indirect`](#-canon-threadspawn-indirect) 🧵②
  * [`canon thread.available-parallelism`](#-canon-threadavailable-parallelism) 🧵②

## Introduction

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

Lastly, independently of Python, the Canonical ABI defined below assumes that
out-of-memory conditions (such as `memory.grow` returning `-1` from within
`realloc`) will trap (via `unreachable`). This significantly simplifies the
Canonical ABI by avoiding the need to support the complicated protocols
necessary to support recovery in the middle of nested allocations. (Note: by
nature of eliminating `realloc`, switching to [lazy lowering] would obviate
this issue, allowing guest wasm code to handle failure by eagerly returning
some value of the declared return type to indicate failure.

## Stack Switching

Component Model concurrency is defined in terms of the Core WebAssembly
[stack-switching] proposal's `cont.new`, `resume` and `suspend` instructions so
that there is a clear composition story between Component Model and Core
WebAssembly concurrency in the future. Since Python does not natively provide
algebraic effects, `cont.new`, `resume` and `suspend` are implemented in this
section in terms of other Python primitives. Thus, this section can be skimmed
since the semantics of stack-switching are already rigorously defined elsewhere;
it's only important to understand the Python function signatures and how they
correspond to the stack-switching instructions.

Since the Component Model only needs a subset of the full expressivity of
stack-switching, only that subset is implemented, which significantly simplifies
things. In particular, the Component Model uses stack-switching in the following
restricted manner:

First, there are only two global [control tags] used with `suspend`:
```wat
(tag $block (param $switch-to (ref null $Thread)) (result $cancelled bool))
(tag $current-thread (result (ref $Thread)))
```
Consequently, instead of having a single generic Python `suspend()` function,
there are `block()` and `current_thread()` Python functions that implement
`suspend $block` and `suspend $current-thread`, resp.

The `$block` tag is used to suspend a [thread] until some future event. The
parameters and results will be described in the next section, where they are
used to define `Thread`.

The `$current-thread` tag is used to retrieve the [current thread], which is
semantically stored in the `resume` handler's local state (although an
optimizing implementation would instead maintain the current thread in the VM's
execution context (or a special Core WebAssembly `global`) so that it could be
cheaply loaded and/or kept in register state).

Second, there is only a single type of continuation passed to `resume` that
corresponds to the `$block` tag (`$current-thread` continuations are
immediately resumed and never "escape"):
```wat
(type $ct (cont (func (param bool) (result (ref null $Thread)))))
```

Third, every `resume` performed by the Canonical ABI always handles both
`$block` and `$current-thread` *and* every Canonical ABI `suspend` is, by
construction, always scoped by a Canonical ABI `resume`. Thus, every Canonical
ABI `suspend` unconditionally transfers control flow directly to the innermost
enclosing Canonical ABI `resume` without a general handler/tag search.

Given this restricted usage, specialized versions of `cont.new`, `resume` and
`suspend` that are "monomorphized" to the above types and tags are implemented
in terms of Python's standard preemptive threading primitives, using
[`threading.Thread`] to provide a native stack, [`threading.Lock`] to only allow
a single `threading.Thread` to execute at a time, and [`threading.local`] to
maintain the dynamic handler scope using thread-local storage. This could have
been implemented more directly and efficiently using [fibers], but the Python
standard library doesn't have fibers. However, a realistic implementation is
expected to use (a pool of) fibers.

Starting with `cont.new`, the monomorphized version takes a function type
matching `$ct`, as defined above:
```python
class Cancelled(IntEnum):
  FALSE = 0
  TRUE = 1

class Continuation:
  lock: threading.Lock
  handler: Handler
  block_result: Cancelled

class Handler:
  lock: threading.Lock
  current_thread: Thread
  cont: Optional[Continuation]
  block_arg: Optional[Thread]

thread_local_handler = threading.local()

def new_already_acquired_lock() -> threading.Lock:
  lock = threading.Lock()
  lock.acquire()
  return lock

def cont_new(f: Callable[[Cancelled], Optional[Thread]]) -> Continuation:
  cont = Continuation()
  cont.lock = new_already_acquired_lock()
  def thread_base():
    cont.lock.acquire()
    thread_local_handler.value = cont.handler
    block_arg = f(cont.block_result)
    handler = thread_local_handler.value
    handler.cont = None
    handler.block_arg = block_arg
    handler.lock.release()
  threading.Thread(target = thread_base).start()
  return cont
```
`Continuation.block_result` and `Continuation.handler` are set by `resume` right
before `resume` calls `Continuation.lock.release()` to transfer control flow to
the continuation. After resuming the continuation, `resume` calls
`Handler.lock.acquire()` to wait until the continuation signals suspension or
return by calling `Handler.lock.release()`. The `Handler` is stored in
`thread_local_handler.value` to implement the dynamic scoping that is required
for `suspend`. Because the thread created by `cont_new` can be suspended and
resumed many times (each time with a new `Continuation` and `Handler`, resp.),
`Handler` must be re-loaded from `thread_local_handler.value` after `f` returns
since it may have changed since the initial `resume`.

Next, `resume` is monomorphized to take a continuation of type `$ct`, the
argument to pass to the continuation, and the `Thread` to use to implement the
`(on $current-thread)` handler. The remaining `(on $block)` and "returned" cases
join to produce a single return value, with the `(on $block)` case returning a
`Continuation` + argument passed to `suspend $block` and the "returned" case
returning `None` + the continuation function's return value.
```python
def resume(cont: Continuation, block_result: Cancelled, current_thread: Thread) -> \
           tuple[Optional[Continuation], Optional[Thread]]:
  handler = Handler()
  handler.lock = new_already_acquired_lock()
  handler.current_thread = current_thread
  cont.handler = handler
  cont.block_result = block_result
  cont.lock.release()
  handler.lock.acquire()
  return (handler.cont, handler.block_arg)
```

Next, the `block` function implements `suspend $block`, taking its signature
from the `$block` tag defined above. Following the locking scheme already
established by `cont_new` and `resume`, the implementation passes control flow
and event arguments back to the parent `resume` and then waits to be unblocked
by a future `resume` that provides the event results.
```python
def block(switch_to: Optional[Thread]) -> Cancelled:
  cont = Continuation()
  cont.lock = new_already_acquired_lock()
  handler = thread_local_handler.value
  handler.cont = cont
  handler.block_arg = switch_to
  handler.lock.release()
  cont.lock.acquire()
  thread_local_handler.value = cont.handler
  return cont.block_result
```

Lastly, the `current_thread` function implements `suspend $current-thread`,
taking its signature from the `$current-thread` tag defined above. As mentioned
above, the handler for `$current-thread` is hard-coded by the Component Model
to simply return the `Thread` passed to `resume` which is logically stored as
part of the handler's local state. Thus, the handler can be "inlined" at the
`suspend`-site by simply returning the `Thread` stored in thread-local storage
by `resume`.
```python
def current_thread() -> Thread:
  return thread_local_handler.value.current_thread
```

Once Core WebAssembly gets stack-switching, the Component Model's `$block` and
`$current-thread` tags would *not* be exposed to Core WebAssembly. Thus, an
optimizing implementation would continue to be able to implement `block()` as a
direct control flow transfer and `current_thread()` with implicit execution
context, both without a general handler/tag search. In particular, this avoids
the pathological O(N<sup>2</sup>) behavior which would otherwise arise if
Component Model cooperative threads were used in conjunction with deeply-nested
Core WebAssembly handlers.

Additionally, once Core WebAssembly has stack switching, any unhandled events
that originate in Core WebAssembly would turn into traps if they reach a
component boundary (just like unhandled exceptions do now; see
`call_and_trap_on_throw` below). Thus, all cross-component/cross-language stack
switching would continue to be mediated by the Component Model's types and
Canonical ABI, with Core WebAssembly stack-switching used to implement
intra-component concurrency according to the language's own internal ABI.


## Embedding

A WebAssembly Component Model implementation will typically be *embedded* into
a *host* environment. An *embedder* implements the connection between such a
host environment and the WebAssembly semantics as defined by the rest of the
Python definitions below. A full Embedding interface would contain functions
for decoding, validating, instantiating and interrogating components, just like
the [Core WebAssembly Embedding]. However, for the purpose of defining the
runtime behavior of the Canonical ABI, the Embedding interface here just
includes functions for the embedder to:
1. construct a Component Model `Store`, analogous to [`store_init`]ing a Core
   WebAssembly [`store`];
2. `invoke` a Component Model `FuncInst`, analogous to [`func_invoke`]ing a
   Core WebAssembly [`funcinst`]; and
3. allow a cooperative thread (created during a previous call to to `invoke`)
   to execute until blocking or exiting.

```python
class Store:
  waiting: list[Thread]

  def __init__(self):
    self.waiting = []

  def invoke(self, f: FuncInst, caller: Optional[Supertask], on_start, on_resolve) -> OnCancel:
    host_caller = Supertask()
    host_caller.inst = None
    host_caller.supertask = caller
    return f(host_caller, on_start, on_resolve)

  def tick(self):
    random.shuffle(self.waiting)
    for thread in self.waiting:
      if thread.ready():
        thread.resume()
        return
```
The `Store.tick` method does not have an analogue in Core WebAssembly and
enables [native concurrency support](Concurrency.md) in the Component Model. The
expectation is that the host will interleave calls to `invoke` with calls to
`tick`, repeatedly calling `tick` until there is no more work to do or the
store is destroyed. The nondeterministic `random.shuffle` indicates that the
embedder is allowed to use any algorithm (involving priorities, fairness, etc)
to choose which thread to schedule next (and hopefully an algorithm more
efficient than the simple polling loop written above). The `Thread.ready` and
`Thread.resume` methods along with how the `waiting` list is populated are all
defined [below](#thread-state) as part of the `Thread` class.

The `FuncInst` passed to `Store.invoke` is defined to take 3 parameters:
* an optional `caller` `Supertask` which is used to maintain the
  [async callstack][Structured Concurrency] and enforce the
  non-reentrance [component invariant];
* an `OnStart` callback that is called by a `FuncInst` to receive its arguments
  after waiting on any [backpressure];
* an `OnResolve` callback that is called by a `FuncInst` with either a list
  of return values or, if cancellation has been requested, `None`.

```python
FuncInst: Callable[[Optional[Supertask], OnStart, OnResolve], OnCancel]
OnStart = Callable[[], list[any]]
OnResolve = Callable[[Optional[list[any]]], None]
OnCancel = Callable[[], None]

class Supertask:
  inst: Optional[ComponentInstance]
  supertask: Optional[Supertask]
```
Critically, calling a `FuncInst` never blocks at the Python level; if the callee
[blocks] at the wasm level, the Python `FuncInst` immediately returns. The
`OnStart` and `OnResolve` callbacks may be called any time during the initial
`FuncInst` call or afterwards, while the call is executing asynchronously. If
the call returns and the `OnResolve` callback has *not* yet been called, the
caller may call the returned `OnCancel` callback at most once to cooperatively
request that the callee "hurry up" and call `OnResolve` (possibly, but not
necessarily, passing `None` and/or skipping the call to `OnStart`). Otherwise,
`OnCancel` may not be called.

The optional `Supertask.inst` field either points to the `ComponentInstance`
containing the supertask or, if `None`, indicates that the supertask is a host
function. Because `Store.invoke` unconditionally appends a host `Supertask`,
every callstack is rooted by a host `Supertask`. There is no prohibition on
component-to-host-to-component calls (as long as the conditions checked by
`call_might_be_recursive` are satisfied) and thus host `Supertask`s may also
appear anywhere else in the callstack.


## Lifting and Lowering Context

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


## Canonical ABI Options

The following classes list the various Canonical ABI options ([`canonopt`])
that can be set on various Canonical ABI definitions. The default values of
the Python fields are the default values when the associated `canonopt` is
not present in the binary or text format definition.

The `MemInst` class represents a core WebAssembly [`memory` instance], with
`bytes` corresponding to the memory's bytes and `addrtype` coming from the
[`memtype`].
```python
def ptr_size(ptr_type):
  match ptr_type:
    case 'i32':
      return 4
    case 'i64':
      return 8

@dataclass
class MemInst:
  bytes: bytearray
  addrtype: Literal['i32', 'i64']

  def __getitem__(self, i):
    return self.bytes[i]

  def __setitem__(self, i, v):
    self.bytes[i] = v

  def __len__(self):
    return len(self.bytes)

  def ptr_type(self):
    return self.addrtype

  def ptr_size(self):
    return ptr_size(self.ptr_type())
```
The `ptr_type` and `ptr_size` methods return the core value type and byte
size of memory pointers.

The `LiftOptions` class contains the subset of [`canonopt`] which are needed
when lifting individual parameters and results:
```python
@dataclass
class LiftOptions:
  string_encoding: str = 'utf8'
  memory: Optional[MemInst] = None

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
  async_: bool = False
  callback: Optional[Callable] = None
```


## Runtime State

The following Python classes define spec-internal state and utility methods
that are used to define the externally-visible behavior of Canonical ABI's
lifting, lowering and built-in definitions below. These fields are chosen for
simplicity over performance and thus an optimizing implementation is expected
to use a more optimized representations as long as it preserves the same
externally-visible behavior. Some specific examples of expected optimizations
are noted below.

### Component Instance State

The `ComponentInstance` class contains all the relevant per-component-instance
state that the definitions below use to implement the Component Model's runtime
behavior and enforce invariants.
```python
class ComponentInstance:
  store: Store
  parent: Optional[ComponentInstance]
  handles: Table[ResourceHandle | Waitable | WaitableSet | ErrorContext]
  threads: Table[Thread]
  may_leave: bool
  backpressure: int
  exclusive: Optional[Task]
  num_waiting_to_enter: int

  def __init__(self, store, parent = None):
    assert(parent is None or parent.store is store)
    self.store = store
    self.parent = parent
    self.handles = Table()
    self.threads = Table()
    self.may_leave = True
    self.backpressure = 0
    self.exclusive = None
    self.num_waiting_to_enter = 0
```
Components are always instantiated in the context of a `Store` which is saved
immutably in the `store` field.

If a component is instantiated by an `instantiate` expression in a "parent"
component, the parent's `ComponentInstance` is immutably saved in the `parent`
field of the child's `ComponentInstance`. If instead a component is
instantiated directly by the host, the `parent` field is `None`. Thus, the set
of component instances in a store forms a forest rooted by the component
instances that were instantiated directly by the host.

Based on this, the "reflexive ancestors" of a component (i.e., all parent
component instances up to the root component including the component itself) can
be enumerated and tested via these two helper functions:
```python
  def reflexive_ancestors(self) -> set[ComponentInstance]:
    s = set()
    inst = self
    while inst is not None:
      s.add(inst)
      inst = inst.parent
    return s

  def is_reflexive_ancestor_of(self, other):
    while other is not None:
      if self is other:
        return True
      other = other.parent
    return False
```

How the host instantiates and invokes root components is up to the host and not
specified by the Component Model. Exports of previously-instantiated root
components *may* be supplied as the imports of subsequently-instantiated root
components. Due to the ordered nature of instantiation, root components cannot
directly import each others' exports in cyclic manner. However, the host *may*
attempt to perform cyclic component-to-host-to-component calls using host
powers.

Because a child component is fully encapsulated by its parent component (with
all child imports specified by the parent's `instantiate` expression and access
to all child exports controlled by the parent through its private instance index
space), the host does not have direct control over how a child component is
instantiated or invoked. However, if a child's ancestors transitively forward
the root component's host-supplied imports to the child, direct child-to-host
calls are possible. Symmetrically, if a child's ancestors transitively
re-export the child's exports from the root component, direct host-to-child
calls are possible.

Recursive component calls are technically possible using either host powers (as
mentioned above) or via a parent component lowering a child component's export
to a `funcref` and then recursively calling this `funcref` from a lifted parent
function passed as an import to the child. However, for the time being, both
cases are prevented via trap for several reasons:
* automatic [backpressure] would otherwise deadlock in unpredictable and
  surprising ways;
* by default, most code does not expect [recursive reentrance] and will break
  in subtle and potentially security sensitive ways if allowed;
* to properly handle recursive reentrance, an extra ABI parameter is required
  to link recursive calls and this requires opting in via some
  [TBD](Concurrency.md#TODO) function effect type or canonical ABI option.

The `call_might_be_recursive` predicate is used by `canon_lift` below to
conservatively detect recursive reentrance and subsequently trap.
```python
def call_might_be_recursive(caller: Supertask, callee_inst: ComponentInstance):
  if caller.inst is None:
    while caller is not None:
      if caller.inst and caller.inst.reflexive_ancestors() & callee_inst.reflexive_ancestors():
        return True
      caller = caller.supertask
    return False
  else:
    return (caller.inst.is_reflexive_ancestor_of(callee_inst) or
            callee_inst.is_reflexive_ancestor_of(caller.inst))
```
The first case (where `caller.inst` is `None`) covers host-to-component calls.
By testing whether any of the callers' reflexive anecestor sets intersect the
callee's ancestor set, the following case is considered recursive:
```
     +-------+
     |   A   |<-.
     | +---+ |  |
host-->| B |-->host
     | +---+ |
     +-------+
```
Here, when attempting to recursively call back into `A`, `caller` points to the
following stack:
```
|inst=None| --supertask--> |inst=B| --supertask--> |inst=None| --supertask--> None
```
while `A` does not appear as the `inst` of any `Supertask` on this stack,
`B.reflexive_ancestors()` is `{ B, A }`, so the loop correctly determines that
`A` is being reentered. This ensures that child components are kept an
encapsulated detail of the parent.

The second case (where `caller.inst` is not `None`) covers component-to-
component calls by conservatively rejecting any call from a component to its
anecestor or descendant (thereby preventing any possible recursion via ancestor
`funcref`). Thus, the following sibling-to-sibling component call is allowed:
```
     +----------------+
     |      P         |
     | +----+  +----+ |
host-->| C1 |->| C2 | |
     | +----+  +----+ |
     +----------------+
```
while the following child-to-parent and parent-to-child calls are disallowed:
```
     +----------+        +----------+
     | +---+    |        |    +---+ |
host-->| C |->P |  host->| P->| C | |
     | +---+    |        |    +---+ |
     +----------+        +----------+
```
This conservative approximation allows `call_might_be_recursive` to be computed
ahead-of-time when compiling a fused component-to-component adapter (where both
caller and callee intances and their relationship are statically known). In the
future this check will be relaxed and more sophisticated optimizations can be
used to statically eliminate the check in common cases.

The other fields of `ComponentInstance` are described below as they are used.

### Table State

The `Table` class encapsulates a mutable, growable array of opaque elements
that are represented in Core WebAssembly as `i32` indices into the array.
Currently, every component instance contains two tables: a `threads` table
containing all the component's [threads](#thread-state) and a `handles`
table containing everything else ([resource handles](#resource-state),
[waitables and waitable sets](#waitable-state) and
[error contexts](#-canon-error-contextnew)).
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

The limit of `2**28` ensures that the high 4 bits of table indices are unset
and available for other use in guest code (e.g., for tagging, packed words or
sentinel values).


### Resource State

The `ResourceHandle` class defines the elements of the component instance's
`handles` table used to represent handles to resources:
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
functions). This count is maintained by the `Subtask` bookkeeping functions
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
  dtor_async: bool
  dtor_callback: Optional[Callable]

  def __init__(self, impl, dtor = None, dtor_async = False, dtor_callback = None):
    self.impl = impl
    self.dtor = dtor
    self.dtor_async = dtor_async
    self.dtor_callback = dtor_callback
```


### Thread State

As described in the [concurrency explainer], threads are created both
*implicitly*, when calling a component export (in `canon_lift` below), and
*explicitly*, when core wasm code calls the `thread.new-indirect` built-in (in
`canon_thread_new_indirect` below). While threads are *logically* created for
each component export call, an optimizing runtime should be able to allocate
threads lazily when needed for actual thread switching operations, thereby
avoiding cross-component call overhead for simple, short-running cross-component
calls. To assist in this optimization, threads are put into their own
`ComponentInstance.threads` table to reduce interference from the other kinds of
handles.

Threads are represented in the Canonical ABI by the `Thread` class defined in
this section. The `Thread` class is implemented in terms of the stack-switching
primitives defined in the previous section and contains an optional mutable
continuation that is set and cleared whenever a thread is suspended and resumed,
resp. On top of the basic `suspend` and `resume` operations, `Thread` adds the
following higher-level concurrency concepts:
* [waiting on external I/O and yielding]
* [async call stack]
* [cancellation]
* [thread index]
* [thread-local storage]

Introducing the `Thread` class in chunks, a `Thread` can be in one of the
following 3 states:
* `running`: actively executing on the stack (thus having no continuation)
* `suspended`: waiting to be `resume`d by another thread `running` in
  the same component instance
* `waiting`: waiting to be `resume`d nondeterministically by the host after
  some condition is met, with `ready` and non-`ready` sub-states, depending on
  whether the condition is met.

```python
class Thread:
  cont: Optional[Continuation]
  ready_func: Optional[Callable[[], bool]]
  task: Task
  cancellable: bool
  index: Optional[int]
  storage: tuple[int,int]

  def running(self):
    return self.cont is None

  def suspended(self):
    return not self.running() and self.ready_func is None

  def waiting(self):
    return not self.running() and self.ready_func is not None

  def ready(self):
    assert(self.waiting())
    return self.ready_func()
```

When a `Thread` is created, a new continuation is created for `thread_func`
(wrapping the `thread_func` with `cont_func` to exactly match the function type
expected by `cont_new`) and leaving the thread initially in the `suspended`
state.
```python
  def __init__(self, task, thread_func):
    def cont_func(cancelled):
      assert(self.running() and not cancelled)
      thread_func()
      return None
    self.cont = cont_new(cont_func)
    self.ready_func = None
    self.task = task
    self.cancellable = False
    self.index = None
    self.storage = [0,0]
    assert(self.suspended())
```

One way to allow a newly-created thread to start executing is for core wasm to
call the `thread.resume-later` built-in. This built-in does not immediately
switch execution to the thread but instead transitions the thread to the
`ready` `waiting` state, allowing a future call to `Store.tick` (defined
above) to nondeterministically call `Thread.resume` (defined next).
```python
  def resume_later(self):
    assert(self.suspended())
    self.ready_func = lambda: True
    self.task.inst.store.waiting.append(self)
    assert(self.ready())
```

Once its time to execute a `suspended` or `waiting` thread, the `Thread.resume`
method is called on that thread. This method transitions the thread to the
`running` state by clearing and then `resume`ing the `Thread`'s stored
continuation. If the `resume`d continuation suspends with a `Thread` to
`switch_to`, `Thread.resume` will `resume` *that* `Thread`'s continuation, and
so on, repeatedly, until the continuation either returns or suspends with no
thread to `switch_to`.
```python
  def resume(self, cancelled = Cancelled.FALSE):
    assert(not self.running() and (self.cancellable or not cancelled))
    if self.waiting():
      assert(cancelled or self.ready())
      self.ready_func = None
      self.task.inst.store.waiting.remove(self)
    thread = self
    while thread is not None:
      cont = thread.cont
      thread.cont = None
      (thread.cont, switch_to) = resume(cont, cancelled, thread)
      thread = switch_to
      cancelled = Cancelled.FALSE
```
The `Thread.resume` method propagates cancellation requests (from
`Task.request_cancellation`) to the first continuation that is resumed, allowing
a thread that opted-in to being `cancellable` to be `resume`d even if it's not
`ready`.

Note that the `while` loop shown above is effectively implementing the `switch`
instruction of the [stack-switching] proposal since `switch` is just an
optimization of `suspend` followed by `resume`. The non-optimized version is
used here to simplify storing of the new `Continuation` into `Thread.cont`.
However, an optimized implementation could do the direct switch.

Once a thread is `Thread.resume()`ed and starts executing, it can suspend its
execution by calling the `thread.suspend` built-in which calls `Thread.suspend`
here which transfers control flow back to `Thread.resume()` via `block()`. The
`switch_to` argument `None` tells `Thread.resume()` to return immediately.
```python
  def suspend(self, cancellable) -> Cancelled:
    assert(self.running() and self.task.may_block())
    if self.task.deliver_pending_cancel(cancellable):
      return Cancelled.TRUE
    self.cancellable = cancellable
    cancelled = block(switch_to = None)
    assert(self.running() and (cancellable or not cancelled))
    return cancelled
```
The `cancellable` parameter of `Thread.suspend` indicates whether the caller is
prepared to handle cancellation. If `cancellable` is false for all of a task's
threads, the cancellation request will be stored in `Task.state` and delivered
the next time `Task.deliver_pending_cancel()` is called with `cancellable` set
(including here in `Thread.suspend`). If `cancellable` is true and the caller
subsequently requests cancellation, `Thread.resume(Cancelled.TRUE)` may be
called on this `suspended` thread causing `Cancelled.TRUE` to be returned here.

The `Thread.wait_until` method is used by all the synchronous blocking
built-ins, as well as auto-backpressure and the `callback` event loop, to wait
until a particular condition is met, as specified by the boolean-valued
`ready_func` parameter:
```python
  def wait_until(self, ready_func, cancellable = False) -> Cancelled:
    assert(self.running() and self.task.may_block())
    if self.task.deliver_pending_cancel(cancellable):
      return Cancelled.TRUE
    if ready_func() and not DETERMINISTIC_PROFILE and random.randint(0,1):
      return Cancelled.FALSE
    self.ready_func = ready_func
    self.task.inst.store.waiting.append(self)
    return self.suspend(cancellable)
```
Before anything else, `wait_until` reports any pending cancellation requests if
the caller is `cancellable`. The `randomint` conjunct on the early return if
`ready_func()` is already `True` means that, at any potential suspension point,
the embedder can nondeterministically decide whether to switch to another thread
or keep running the current one. In particular, when a caller makes an `async`
call to a callee which `wait_until`s a condition that's already met (e.g. in the
case of `yield`), the embedder can use scheduling heuristics to decide whether
or not to block the current thread.

The `Thread.yield_until` method modifies the generic `Thread.wait_until` method
for the `thread.yield` built-in (and `callback`s returning the `YIELD` code) so
that, when executing in a non-blocking context, yielding does not trap and
simply continues executing. This behavior allows `thread.yield` calls to be
scattered liberally throughout code, possibly via automatic code generation
emulating preemptive multi-threading.
```python
  def yield_until(self, ready_func, cancellable) -> Cancelled:
    assert(self.running())
    if self.task.may_block():
      return self.wait_until(ready_func, cancellable)
    else:
      assert(ready_func())
      return Cancelled.FALSE

  def yield_(self, cancellable) -> Cancelled:
    return self.yield_until(lambda: True, cancellable)
```

The `Thread.switch_to` method is used by the `thread.switch-to` built-in to
suspend the current thread and immediately transfer execution to some other
`suspended` thread in the same component instance. Like the other methods,
before anything else, `Thread.switch_to` reports any pending cancellation if the
caller is `cancellable`. Then the current thread transfers control flow back to
`Thread.resume()`, passing the `other` `Thread` to `switch_to`.
```python
  def switch_to(self, cancellable, other: Thread) -> Cancelled:
    assert(self.running() and other.suspended())
    if self.task.deliver_pending_cancel(cancellable):
      return Cancelled.TRUE
    self.cancellable = cancellable
    cancelled = block(switch_to = other)
    assert(self.running() and (cancellable or not cancelled))
    return cancelled
```

Lastly, the `Thread.yield_to` method is used by the `thread.yield-to` built-in
to switch execution to some other thread, leaving the current thread in a
`ready` `waiting` state so that it can nondeterministically `resume` execution
at the next `Store.tick`.
```python
  def yield_to(self, cancellable, other: Thread) -> Cancelled:
    assert(self.running() and other.suspended())
    self.ready_func = lambda: True
    self.task.inst.store.waiting.append(self)
    return self.switch_to(cancellable, other)
```


### Waitable State

A "waitable" is a concurrent activity that can be waited on by the built-ins
`waitable-set.wait` and `waitable-set.poll`. Currently, there are 5 different
kinds of waitables: [subtasks] and the 4 combinations of the [readable and
writable ends] of futures and streams.

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
of waitables, which are each defined as subclasses of `Waitable` below.

Every `Waitable` can store at most one pending event in its `pending_event`
field which will be delivered to core wasm as soon as the core wasm code
explicitly waits on this `Waitable` (which may take an arbitrarily long time).
A `pending_event` is represented in the Python code below as a *closure* so
that the closure can specify behaviors that trigger *right before* events are
delivered to core wasm and so that the closure can compute the event based on
the state of the world at delivery time (as opposed to when `pending_event` was
first set). Currently, `pending_event` holds a closure of the `subtask_event`,
`stream_event` or `future_event` functions defined below. An optimizing
implementation would avoid closure allocation by inlining a union containing
the closure fields directly in the component instance table.

A waitable can belong to at most one "waitable set" (defined next) which is
referred to by the `wset` field. A `Waitable`'s `pending_event` is delivered
(via `get_pending_event`) when core wasm code waits on its waitable set (via
`waitable-set.wait` or, when using `callback`, by returning to the event loop).
```python
class Waitable:
  pending_event: Optional[Callable[[], EventTuple]]
  wset: Optional[WaitableSet]

  def __init__(self):
    self.pending_event = None
    self.wset = None

  def set_pending_event(self, pending_event):
    self.pending_event = pending_event

  def has_pending_event(self):
    return bool(self.pending_event)

  def get_pending_event(self) -> EventTuple:
    pending_event = self.pending_event
    self.pending_event = None
    return pending_event()

  def join(self, wset):
    if self.wset:
      self.wset.elems.remove(self)
    self.wset = wset
    if wset:
      wset.elems.append(self)

  def drop(self):
    assert(not self.has_pending_event())
    self.join(None)
```

A "waitable set" contains a collection of waitables that can be waited on or
polled for *any* element to make progress. Although the `WaitableSet` class
below represents `elems` as a `list` and implements `{has,get}_pending_event`
with an O(n) search, because a waitable can be associated with at most one set
and can contain at most one pending event, a real implementation could instead
store a list of waitables-with-pending-events as a linked list embedded
directly in the component instance's table element to avoid the separate
allocation while providing O(1) polling.
```python
class WaitableSet:
  elems: list[Waitable]
  num_waiting: int

  def __init__(self):
    self.elems = []
    self.num_waiting = 0

  def has_pending_event(self):
    return any(w.has_pending_event() for w in self.elems)

  def get_pending_event(self) -> EventTuple:
    assert(self.has_pending_event())
    random.shuffle(self.elems)
    for w in self.elems:
      assert(self is w.wset)
      if w.has_pending_event():
        return w.get_pending_event()

  def wait_for_event_and(self, ready_func, cancellable) -> EventTuple:
    def ready_and_has_event():
      return ready_func() and self.has_pending_event()
    self.num_waiting += 1
    cancelled = current_thread().wait_until(ready_and_has_event, cancellable)
    if cancelled:
      event = (EventCode.TASK_CANCELLED, 0, 0)
    else:
      event = self.get_pending_event()
    self.num_waiting -= 1
    return event

  def wait_for_event(self, cancellable) -> EventTuple:
    return self.wait_for_event_and(lambda: True, cancellable)

  def poll(self, cancellable) -> EventTuple:
    if current_thread().task.deliver_pending_cancel(cancellable):
      return (EventCode.TASK_CANCELLED, 0, 0)
    elif not self.has_pending_event():
      return (EventCode.NONE, 0, 0)
    else:
      return self.get_pending_event()

  def drop(self):
    trap_if(len(self.elems) > 0)
    trap_if(self.num_waiting > 0)
```
The `random.shuffle` in `get_pending_event` give embedders the semantic freedom
to schedule delivery of events nondeterministically (e.g., taking into account
priorities); runtimes do not have to literally randomize event delivery.

The `ready_func` passed to `WaitableSet.wait_for_event_and` allows the caller to
stipulate extra conditions that have to be met, *in addition* to there being an
event ready for delivery. In particular, this is used by the `async callback`
event loop to avoid overlapping callback execution.

The `WaitableSet.drop` method traps if dropped while it still contains elements
(whose `Waitable.wset` field would become dangling) or if it is being
waited-upon by another `Task` (as indicated by a non-zero `num_waiting`).


### Task State

As described in the [concurrency explainer], a "task" is created for each call
to a component export (in `canon_lift` below), tracking the metadata needed to
enforce the Canonical ABI rules associated with the callee as well as implement
caller-requested cancellation. Each task contains 0..N threads that execute on
behalf of the task, starting with the thread that is spawned to execute the
exported function and transitively including additional threads spawned by that
thread via `thread.new-indirect`.

Tasks are represented here by the `Task` class and the [current task] is
represented by the `Thread.task` field of `current_thread()`. `Task` implements
the `Supertask` interface defined as part of the [Embedding](#embedding)
interface since `Task` serves as the `Supertask` of calls it makes to imports.

`Task` is introduced in chunks, starting with fields and initialization:
```python
class Task(Supertask):
  class State(Enum):
    INITIAL = 1
    PENDING_CANCEL = 2
    CANCEL_DELIVERED = 3
    RESOLVED = 4

  state: State
  opts: CanonicalOptions
  inst: ComponentInstance
  ft: FuncType
  supertask: Supertask
  on_resolve: OnResolve
  num_borrows: int
  waiting_to_enter: Optional[Thread]
  threads: list[Thread]

  def __init__(self, opts, inst, ft, supertask, on_resolve):
    self.state = Task.State.INITIAL
    self.opts = opts
    self.inst = inst
    self.ft = ft
    self.supertask = supertask
    self.on_resolve = on_resolve
    self.num_borrows = 0
    self.waiting_to_enter = None
    self.threads = []
```

The `Task.needs_exclusive` predicate returns whether the Canonical ABI options
indicate that the core wasm being executed does not expect to be reentered
(e.g., because the code is using a single global linear memory shadow stack).
Concretely, this is assumed to be the case when core wasm is lifted
synchronously or with `async callback`. This predicate is used by the other
`Task` methods to determine whether to acquire/release the component instance's
`exclusive` lock.
```python
  def needs_exclusive(self):
    return not self.opts.async_ or self.opts.callback
```

The `Task.may_block` predicate returns whether the [current task]'s function's
type is allowed to [block]. Specifically, functions that do not declare the
`async` effect that have not yet returned a value may not block.
```python
  def may_block(self):
    return self.ft.async_ or self.state == Task.State.RESOLVED
```

The `Task.enter` method implements [backpressure] between when the caller of an
`async`-typed function initiates the call and when the callee's core wasm entry
point is executed. This interstitial placement allows a component instance that
has been overloaded with concurrent function invocations to avoid OOM. When
backpressure is enabled, `enter` will block new `async`-typed calls until
backpressure is disabled. There are three sources of backpressure:
 1. *Explicit backpressure* is triggered by core wasm calling
    `backpressure.{inc,dec}` which modify the `ComponentInstance.backpressure`
    counter.
 2. *Implicit backpressure* triggered when `Task.needs_exclusive()` is true and
    the `exclusive` lock is already held.
 3. *Residual backpressure* triggered by explicit or implicit backpressure
    having been enabled then disabled, but there still being tasks waiting to
    `enter` that need to be given the chance to start without getting starved
    by new tasks.

Note that, because non-`async`-typed functions ignore backpressure entirely,
they may reenter core wasm when an `async`-typed function would have been
blocked by implicit backpressure. Thus, export bindings generators must be
careful to handle this possibility (e.g., while maintaining the linear-memory
shadow stack pointer) for components with mixed `async`- and non-`async`- typed
exports.
```python
  def enter(self):
    thread = current_thread()
    if self.ft.async_:
      def has_backpressure():
        return self.inst.backpressure > 0 or (self.needs_exclusive() and bool(self.inst.exclusive))
      if has_backpressure() or self.inst.num_waiting_to_enter > 0:
        self.inst.num_waiting_to_enter += 1
        self.waiting_to_enter = thread
        cancelled = thread.wait_until(lambda: not has_backpressure(), cancellable = True)
        self.waiting_to_enter = None
        self.inst.num_waiting_to_enter -= 1
        if cancelled:
          self.cancel()
          return False
      if self.needs_exclusive():
        assert(self.inst.exclusive is None)
        self.inst.exclusive = self
    self.register_thread(thread)
    return True

  def register_thread(self, thread):
    assert(thread not in self.threads and thread.task is self)
    self.threads.append(thread)
    assert(thread.index is None)
    thread.index = self.inst.threads.add(thread)
```
Since the order in which suspended threads are resumed is nondeterministic (see
`Store.tick` above), once `Task.enter` suspends the task's implicit thread due
to backpressure, the above definition allows the host to arbitrarily select
which threads to resume in which order. Additionally, the above definition
ensures the following properties:
* While a callee is waiting to `enter`, if the caller requests cancellation,
  the callee is immediately cancelled. The `Task.waiting_to_enter` field is
  used by `Task.request_cancellation` below to know which thread to
  `resume` with `Cancelled.TRUE`.
* When backpressure is disabled then reenabled, no new tasks start, even
  tasks that were blocked and then unblocked by the first occurrence of
  backpressure (i.e., disabling backpressure never unleashes an unstoppable
  thundering heard of pending tasks).

Once a task's implicit thread has cleared the backpressure gate, it is added to
the lists of threads running inside the current task and component instance by
`Task.register_thread()` (which is also called by `thread.new-indirect`, below).

Symmetrically, the `Task.exit` method is called before a task's implicit thread
returns to reverse the effects of `Task.enter`. In particular, for a synchronous
or `async callback` task, `Task.exit` clears `exclusive` to allow the next such
task to start. `Task.unregister_thread` (which is also called by
`thread.new-indirect`, below) traps if the task's last thread is unregistered
and the task has not yet returned a value to its caller.
```python
  def exit(self):
    self.unregister_thread(current_thread())
    if self.ft.async_ and self.needs_exclusive():
      assert(self.inst.exclusive is self)
      self.inst.exclusive = None

  def unregister_thread(self, thread):
    assert(thread in self.threads and thread.task is self)
    self.threads.remove(thread)
    if len(self.threads) == 0:
      trap_if(self.state != Task.State.RESOLVED)
      assert(self.num_borrows == 0)
    assert(thread.index is not None)
    self.inst.threads.remove(thread.index)
```

The `Task.request_cancellation` method is called by the host or wasm caller
to signal that they don't need the return value and that the caller should hurry
up and call the `OnResolve` callback. If a task is waiting to start in
`Task.enter` due to backpressure, then it is immediately cancelled without
running any guest code. Otherwise, if *any* of a cancelled `Task`'s `Thread`s
are expecting cancellation (e.g., when an `async callback` export returns to the
event loop or when a `waitable-set.*` or `thread.*` built-in is called with
`cancellable` set), `request_cancellation` immediately resumes that thread
(picking one nondeterministically if there are multiple), giving the thread the
chance to handle cancellation promptly (allowing `subtask.cancel` to complete
eagerly without returning `BLOCKED`).
```python
  def request_cancellation(self):
    if self.waiting_to_enter is not None:
      assert(not self.threads)
      self.state = Task.State.CANCEL_DELIVERED
      self.waiting_to_enter.resume(Cancelled.TRUE)
      return
    assert(self.state == Task.State.INITIAL)
    if not self.needs_exclusive() or not self.inst.exclusive or self.inst.exclusive is self:
      random.shuffle(self.threads)
      for thread in self.threads:
        if thread.cancellable:
          self.state = Task.State.CANCEL_DELIVERED
          thread.resume(Cancelled.TRUE)
          return
    self.state = Task.State.PENDING_CANCEL
```
As handled above, cancellation must avoid running two `needs_exclusive` tasks at
the same time in the corner case where the first task starts and blocks and then
the other task is cancelled. However, a single `needs_exclusive` task that
starts and blocks calling a built-in with `cancellable` set *can* be immediately
resumed. Thus, the `exclusive` lock tracks *which* task is exclusively running
to distinguish these cases.

If cancellation cannot be immediately delivered by `Task.request_cancellation`,
the request is remembered in `Task.state` and delivered at the next opportunity
by `Task.deliver_pending_cancel`, which is checked at all cancellation points:
```python
  def deliver_pending_cancel(self, cancellable) -> bool:
    if cancellable and self.state == Task.State.PENDING_CANCEL:
      self.state = Task.State.CANCEL_DELIVERED
      return True
    return False
```

The `Task.return_` method is called by `canon_task_return` and `canon_lift` to
return a list of lifted values to the task's caller via the `OnResolve`
callback. There is a dynamic error if the callee has not dropped all borrowed
handles by the time `task.return` is called which means that the caller can
assume that all its lent handles have been returned to it when it receives the
`SUBTASK` `RETURNED` event. Note that the initial `trap_if` allows a task to
return a value even after cancellation has been requested.
```python
  def return_(self, result):
    trap_if(self.state == Task.State.RESOLVED)
    trap_if(self.num_borrows > 0)
    assert(result is not None)
    self.on_resolve(result)
    self.state = Task.State.RESOLVED
```

Lastly, the `Task.cancel` method is called by `canon_task_cancel` and
enforces the same `num_borrows` condition as `return_`, ensuring that when
the caller's `OnResolve` callback is called, the caller knows all borrows
have been returned. The initial `trap_if` only allows cancellation after
cancellation has been *delivered* to core wasm. In particular, if
`request_cancellation` cannot synchronously deliver cancellation and sets
`Task.state` to `PENDING_CANCEL`, core wasm will still trap if it tries to
call `task.cancel`.
```python
  def cancel(self):
    trap_if(self.state != Task.State.CANCEL_DELIVERED)
    trap_if(self.num_borrows > 0)
    self.on_resolve(None)
    self.state = Task.State.RESOLVED
```


### Subtask State

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
  on_cancel: Optional[OnCancel]
  lenders: Optional[list[ResourceHandle]]
  cancellation_requested: bool

  def __init__(self):
    Waitable.__init__(self)
    self.state = Subtask.State.STARTING
    self.on_cancel = None
    self.lenders = []
    self.cancellation_requested = False
```

The `state` field of `Subtask` tracks the callee's progression from the initial
[`STARTING`][Backpressure] state along the [subtask state machine].
A `Subtask` is considered "resolved" if it has returned a value or if, after
having had cancellation requested by the caller, called `task.cancel` (either
before or after calling `OnStart`):
```python
  def resolved(self):
    match self.state:
      case (Subtask.State.STARTING |
            Subtask.State.STARTED):
        return False
      case (Subtask.State.RETURNED |
            Subtask.State.CANCELLED_BEFORE_STARTED |
            Subtask.State.CANCELLED_BEFORE_RETURNED):
        return True
```

The `Subtask.add_lender` method is called by `lift_borrow` (below). This method
increments the `num_lends` counter on the handle being lifted, which is guarded
to be zero by `canon_resource_drop` (below). The `Subtask.deliver_resolve`
method is called right before the `SUBTASK` resolve event is delivered to
wasm (for any of the `RETURNED`, `CANCELLED_BEFORE_STARTED` or
`CANCELLED_BEFORE_RETURNED` states), at which point all the borrowed handles
are logically returned to the caller by decrementing all the `num_lend` counts
that were initially incremented.
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
the current component instance's `handles` table and checks that the callee has
been allowed to resolve and explicitly relinquish any borrowed handles.
```python
  def drop(self):
    trap_if(not self.resolve_delivered())
    Waitable.drop(self)
```


### Buffer State

A "buffer" is an abstract region of memory that can either be read-from or
written-to. This region of memory can either be owned by the host or by wasm.
Currently wasm memory is always 32-bit or 64-bit linear memory, but soon GC
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
is zero-length. Internally, buffers do have a maximum length of `2^28 - 1` which
is independent of the type of memory backing the buffer. Based on this, buffers
are represented by the following 3 abstract Python classes:
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
      trap_if(ptr != align_to(ptr, alignment(t, cx.opts.memory.ptr_type())))
      trap_if(ptr + length * elem_size(t, cx.opts.memory.ptr_type()) > len(cx.opts.memory))
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
      self.ptr += n * elem_size(self.t, self.cx.opts.memory.ptr_type())
    else:
      vs = n * [()]
    self.progress += n
    return vs

class WritableBufferGuestImpl(BufferGuestImpl, WritableBuffer):
  def write(self, vs):
    assert(len(vs) <= self.remain())
    if self.t:
      store_list_into_valid_range(self.cx, vs, self.ptr, self.t)
      self.ptr += len(vs) * elem_size(self.t, self.cx.opts.memory.ptr_type())
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


### Stream State

Values of `stream` type are represented in the Canonical ABI as `i32` indices
into the current component instance's `handles` table referring to either the
[readable or writable end] of a stream. Reading from the readable end of a
stream is achieved by calling `stream.read` and supplying a `WritableBuffer`.
Conversely, writing to the writable end of a stream is achieved by calling
`stream.write` and supplying a `ReadableBuffer`. The runtime waits until both
a readable and writable buffer have been supplied and then performs a direct
copy between the two buffers. This rendezvous-based design avoids the need
for an intermediate buffer and copy (unlike, e.g., a Unix pipe; a Unix pipe
would instead be implemented as a resource type owning the buffer memory and
*two* streams; on going in and one coming out).

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

class SharedBase:
  t: ValType
  cancel: Callable[[], None]
  drop: Callable[[], None]

class ReadableStream(SharedBase):
  read: Callable[[ComponentInstance, WritableBuffer, OnCopy, OnCopyDone], None]

class WritableStream(SharedBase):
  write: Callable[[ComponentInstance, ReadableBuffer, OnCopy, OnCopyDone], None]
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
called). This reduces the number of context-switches required by the spec,
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
      trap_if(inst is self.pending_inst and not none_or_number_type(self.t)) # temporary
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
component instance and there is a non-empty, non-number element type. This trap
will be removed in a subsequent release; the reason for the trap is that when
lifting and lowering can alias the same memory, interleavings can be complex
and must be handled carefully. Future improvements to the Canonical ABI ([lazy
lowering]) can greatly simplify this interleaving and be more practical to
implement.

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
      trap_if(inst is self.pending_inst and not none_or_number_type(self.t)) # temporary
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
`read` and make progress. See the [stream readiness] section in the async
explainer for more background on purpose of zero-length reads and writes.

The `none_or_number_type` predicate used above includes both the integer and
floating point number types:
```python
def none_or_number_type(t):
  return t is None or isinstance(t, U8Type | U16Type | U32Type | U64Type |
                                    S8Type | S16Type | S32Type | S64Type |
                                    F32Type | F64Type)
```

The two ends of a stream are stored as separate elements in the component
instance `handles` table and each end has a separate `CopyState` that reflects
what *that end* is currently doing or has done. This `state` field is factored
out into the `CopyEnd` class that is derived below. The two ends also share some
state which is referenced by the `shared` field and either points to a
`SharedStreamImpl` (for component-created streams) or something host-defined for
(host-created streams).
```python
class CopyState(Enum):
  IDLE = 1
  SYNC_COPYING = 2
  ASYNC_COPYING = 3
  CANCELLING_COPY = 4
  DONE = 5

class CopyEnd(Waitable):
  state: CopyState
  shared: SharedBase

  def __init__(self, shared):
    Waitable.__init__(self)
    self.state = CopyState.IDLE
    self.shared = shared

  def copying(self):
    match self.state:
      case CopyState.IDLE | CopyState.DONE:
        return False
      case CopyState.SYNC_COPYING | CopyState.ASYNC_COPYING | CopyState.CANCELLING_COPY:
        return True
    assert(False)

  def drop(self):
    trap_if(self.copying())
    self.shared.drop()
    Waitable.drop(self)

class ReadableStreamEnd(CopyEnd):
  def copy(self, inst, dst, on_copy, on_copy_done):
    self.shared.read(inst, dst, on_copy, on_copy_done)

class WritableStreamEnd(CopyEnd):
  def copy(self, inst, src, on_copy, on_copy_done):
    self.shared.write(inst, src, on_copy, on_copy_done)
```
As shown in `drop`, attempting to drop a readable or writable end while a copy
is in progress or in the process of being cancelled traps. This means that
client code must take care to wait for these operations to finish (potentially
cancelling them via `stream.cancel-{read,write}`) before dropping. The
`SYNC_COPY` vs. `ASYNC_COPY` distinction is tracked in the state to determine
whether the copy operation can be cancelled.

The polymorphic `copy` method dispatches to either `ReadableStream.read` or
`WritableStream.write` and allows the implementations of `stream.{read,write}`
to share a single definition (in `stream_copy` below).


### Future State

Futures are similar to streams, except that instead of passing 0..N values,
exactly one value is passed from the writer end to the reader end unless the
reader end is explicitly dropped first.

Futures are defined in terms of abstract `ReadableFuture` and `WritableFuture`
interfaces:
```python
class ReadableFuture(SharedBase):
  read: Callable[[ComponentInstance, WritableBuffer, OnCopyDone], None]

class WritableFuture(SharedBase):
  write: Callable[[ComponentInstance, ReadableBuffer, OnCopyDone], None]
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
    self.reset_and_notify_pending(CopyResult.CANCELLED)
```
Dropping works the same in futures as in streams, except that a future
writable end cannot be dropped without having written a value. This is guarded
by `WritableFutureEnd.drop` so it can be asserted here:
```python
  def drop(self):
    if not self.dropped:
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
      trap_if(inst is self.pending_inst and not none_or_number_type(self.t)) # temporary
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
      trap_if(inst is self.pending_inst and not none_or_number_type(self.t)) # temporary
      self.pending_buffer.write(src_buffer.read(1))
      self.reset_and_notify_pending(CopyResult.COMPLETED)
      on_copy_done(CopyResult.COMPLETED)
```
As with streams, the `# temporary` limitation shown above is that a future
cannot be read and written from the same component instance when it has a
non-empty, non-number value type.

Lastly, the `{Readable,Writable}FutureEnd` classes are mostly symmetric with
`{Readable,Writable}StreamEnd`, defining a polymorphic `copy` method that
dispatches to either `ReadableFuture.read` or `WritableFuture.write`, which
allows the implementation of `future.{read,write}` to share a single
definition (in `future_copy` below). The only difference is that
`WritableFutureEnd.drop` traps if the writer hasn't successfully written a value
or been notified of the reader dropping their end:
```python
class ReadableFutureEnd(CopyEnd):
  def copy(self, inst, dst_buffer, on_copy_done):
    self.shared.read(inst, dst_buffer, on_copy_done)

class WritableFutureEnd(CopyEnd):
  def copy(self, inst, src_buffer, on_copy_done):
    self.shared.write(inst, src_buffer, on_copy_done)

  def drop(self):
    trap_if(self.state != CopyState.DONE)
    CopyEnd.drop(self)
```


## Despecialization

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


## Type Predicates

The `contains_borrow` and `contains_async_value` predicates return whether the
given type contains a `borrow` or `future`/`stream`, respectively.
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

## Alignment

Each value type is assigned an [alignment] which is used by subsequent
Canonical ABI definitions. Presenting the definition of `alignment` piecewise,
we start with the top-level case analysis:
```python
def alignment(t, ptr_type):
  match despecialize(t):
    case BoolType()                  : return 1
    case S8Type() | U8Type()         : return 1
    case S16Type() | U16Type()       : return 2
    case S32Type() | U32Type()       : return 4
    case S64Type() | U64Type()       : return 8
    case F32Type()                   : return 4
    case F64Type()                   : return 8
    case CharType()                  : return 4
    case StringType()                : return ptr_size(ptr_type)
    case ErrorContextType()          : return 4
    case ListType(t, l)              : return alignment_list(t, l, ptr_type)
    case RecordType(fields)          : return alignment_record(fields, ptr_type)
    case VariantType(cases)          : return alignment_variant(cases, ptr_type)
    case FlagsType(labels)           : return alignment_flags(labels)
    case OwnType() | BorrowType()    : return 4
    case StreamType() | FutureType() : return 4
```

List alignment is the same as tuple alignment when the length is fixed and
otherwise uses the alignment of pointers.
```python
def alignment_list(elem_type, maybe_length, ptr_type):
  if maybe_length is not None:
    return alignment(elem_type, ptr_type)
  return ptr_size(ptr_type)
```

Record alignment is tuple alignment, with the definitions split for reuse below:
```python
def alignment_record(fields, ptr_type):
  a = 1
  for f in fields:
    a = max(a, alignment(f.t, ptr_type))
  return a
```

As an optimization, `variant` discriminants are represented by the smallest integer
covering the number of cases in the variant (with cases numbered in order from
`0` to `len(cases)-1`). Depending on the payload type, this can allow more
compact representations of variants in memory. This smallest integer type is
selected by the following function, used above and below:
```python
def alignment_variant(cases, ptr_type):
  return max(alignment(discriminant_type(cases), ptr_type), max_case_alignment(cases, ptr_type))

def discriminant_type(cases):
  n = len(cases)
  assert(0 < n < (1 << 32))
  match math.ceil(math.log2(n)/8):
    case 0: return U8Type()
    case 1: return U8Type()
    case 2: return U16Type()
    case 3: return U32Type()

def max_case_alignment(cases, ptr_type):
  a = 1
  for c in cases:
    if c.t is not None:
      a = max(a, alignment(c.t, ptr_type))
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


## Element Size

Each value type is also assigned an `elem_size` which is the number of bytes
used when values of the type are stored as elements of a `list`. Having this
byte size be a static property of the type instead of attempting to use a
variable-length element-encoding scheme both simplifies the implementation and
maps well to languages which represent `list`s as random-access arrays. Empty
types, such as records with no fields, are not permitted, to avoid
complications in source languages.
```python
def elem_size(t, ptr_type):
  match despecialize(t):
    case BoolType()                  : return 1
    case S8Type() | U8Type()         : return 1
    case S16Type() | U16Type()       : return 2
    case S32Type() | U32Type()       : return 4
    case S64Type() | U64Type()       : return 8
    case F32Type()                   : return 4
    case F64Type()                   : return 8
    case CharType()                  : return 4
    case StringType()                : return 2 * ptr_size(ptr_type)
    case ErrorContextType()          : return 4
    case ListType(t, l)              : return elem_size_list(t, l, ptr_type)
    case RecordType(fields)          : return elem_size_record(fields, ptr_type)
    case VariantType(cases)          : return elem_size_variant(cases, ptr_type)
    case FlagsType(labels)           : return elem_size_flags(labels)
    case OwnType() | BorrowType()    : return 4
    case StreamType() | FutureType() : return 4

def elem_size_list(elem_type, maybe_length, ptr_type):
  if maybe_length is not None:
    return maybe_length * elem_size(elem_type, ptr_type)
  return 2 * ptr_size(ptr_type)

def elem_size_record(fields, ptr_type):
  s = 0
  for f in fields:
    s = align_to(s, alignment(f.t, ptr_type))
    s += elem_size(f.t, ptr_type)
  assert(s > 0)
  return align_to(s, alignment_record(fields, ptr_type))

def align_to(ptr, alignment):
  return math.ceil(ptr / alignment) * alignment

def elem_size_variant(cases, ptr_type):
  s = elem_size(discriminant_type(cases), ptr_type)
  s = align_to(s, max_case_alignment(cases, ptr_type))
  cs = 0
  for c in cases:
    if c.t is not None:
      cs = max(cs, elem_size(c.t, ptr_type))
  s += cs
  return align_to(s, alignment_variant(cases, ptr_type))

def elem_size_flags(labels):
  n = len(labels)
  assert(0 < n <= 32)
  if n <= 8: return 1
  if n <= 16: return 2
  return 4
```

## Loading

The `load` function defines how to read a value of a given value type `t`
out of linear memory starting at offset `ptr`, returning the value represented
as a Python value. Presenting the definition of `load` piecewise, we start with
the top-level case analysis:
```python
def load(cx, ptr, t):
  assert(ptr == align_to(ptr, alignment(t, cx.opts.memory.ptr_type())))
  assert(ptr + elem_size(t, cx.opts.memory.ptr_type()) <= len(cx.opts.memory))
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

Strings are loaded from two pointer-sized values: a pointer (offset in linear
memory) and a number of [code units]. There are three supported string encodings
in [`canonopt`]: [UTF-8], [UTF-16] and `latin1+utf16`. This last option allows a
*dynamic* choice between [Latin-1] and UTF-16, indicated by the high bit of the
second pointer-sized value (32nd bit on 32-bit memories, 64th bit on 64-bit
memories). String values include their original encoding and length in tagged
code units as a "hint" that enables `store_string` (defined below) to make
better up-front allocation size choices in many cases. Thus, the value produced
by `load_string` isn't simply a Python `str`, but a *tuple* containing a `str`,
the original encoding and the number of source code units.

The `MAX_STRING_BYTE_LENGTH` constant limits the byte length of a string when
loading. This limit is low enough to ensure that when storing the string via
`store_string`, the number of bytes allocated stays below `REALLOC_I32_MAX` even
when converting to other encodings. This means that any loaded string will be
short enough to be stored in 32-bit components. The worst case inflation in
string byte length is by a factor of 2 (e.g. this could occur when converting
from [UTF-8] to [UTF-16]).
```python
String = tuple[str, str, int]

def load_string(cx, ptr) -> String:
  begin = load_int(cx, ptr, cx.opts.memory.ptr_size())
  tagged_code_units = load_int(cx, ptr + cx.opts.memory.ptr_size(), cx.opts.memory.ptr_size())
  return load_string_from_range(cx, begin, tagged_code_units)

def utf16_tag(ptr_type):
  return 1 << (ptr_size(ptr_type) * 8 - 1)

REALLOC_I32_MAX = 2**32 - 1
MAX_STRING_BYTE_LENGTH = (1 << 28) - 1
assert(REALLOC_I32_MAX > 2 * MAX_STRING_BYTE_LENGTH)

def load_string_from_range(cx, ptr, tagged_code_units) -> String:
  tag = utf16_tag(cx.opts.memory.ptr_type())
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
      if bool(tagged_code_units & tag):
        byte_length = 2 * (tagged_code_units ^ tag)
        encoding = 'utf-16-le'
      else:
        byte_length = tagged_code_units
        encoding = 'latin-1'

  trap_if(byte_length > MAX_STRING_BYTE_LENGTH)
  trap_if(ptr != align_to(ptr, alignment))
  trap_if(ptr + byte_length > len(cx.opts.memory))
  try:
    s = cx.opts.memory[ptr : ptr+byte_length].decode(encoding)
  except UnicodeError:
    trap()

  return (s, cx.opts.string_encoding, tagged_code_units)
```

Error context values are lifted directly from the current component instance's
`handles` table:
```python
def lift_error_context(cx, i):
  errctx = cx.inst.handles.get(i)
  trap_if(not isinstance(errctx, ErrorContext))
  return errctx
```

Lists and records are loaded by recursively loading their elements/fields. The
byte length of a list is limited to `MAX_LIST_BYTE_LENGTH` which, similar to
`MAX_STRING_BYTE_LENGTH`, keeps list lengths well below the 32-bit address space
limit. The worst case inflation of a list length in bytes is by a factor of 2
(which could occur when pointer sizes increase from 4 to 8 bytes) so
`MAX_LIST_BYTE_LENGTH` is small enough that the byte length passed to `realloc`
stays below `REALLOC_I32_MAX` even when doubled.
```python
MAX_LIST_BYTE_LENGTH = (1 << 28) - 1
assert(REALLOC_I32_MAX > 2 * MAX_LIST_BYTE_LENGTH)

def load_list(cx, ptr, elem_type, maybe_length):
  if maybe_length is not None:
    return load_list_from_valid_range(cx, ptr, maybe_length, elem_type)
  begin = load_int(cx, ptr, cx.opts.memory.ptr_size())
  length = load_int(cx, ptr + cx.opts.memory.ptr_size(), cx.opts.memory.ptr_size())
  return load_list_from_range(cx, begin, length, elem_type)

def load_list_from_range(cx, ptr, length, elem_type):
  trap_if(length * elem_size(elem_type, cx.opts.memory.ptr_type()) > MAX_LIST_BYTE_LENGTH)
  trap_if(ptr != align_to(ptr, alignment(elem_type, cx.opts.memory.ptr_type())))
  trap_if(ptr + length * elem_size(elem_type, cx.opts.memory.ptr_type()) > len(cx.opts.memory))
  return load_list_from_valid_range(cx, ptr, length, elem_type)

def load_list_from_valid_range(cx, ptr, length, elem_type):
  a = []
  for i in range(length):
    a.append(load(cx, ptr + i * elem_size(elem_type, cx.opts.memory.ptr_type()), elem_type))
  return a

def load_record(cx, ptr, fields):
  record = {}
  for field in fields:
    ptr = align_to(ptr, alignment(field.t, cx.opts.memory.ptr_type()))
    record[field.label] = load(cx, ptr, field.t)
    ptr += elem_size(field.t, cx.opts.memory.ptr_type())
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
  disc_size = elem_size(discriminant_type(cases), cx.opts.memory.ptr_type())
  case_index = load_int(cx, ptr, disc_size)
  ptr += disc_size
  trap_if(case_index >= len(cases))
  c = cases[case_index]
  ptr = align_to(ptr, max_case_alignment(cases, cx.opts.memory.ptr_type()))
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
instance's `handles` table so that ownership is *transferred* to the lowering
component.  The lifting operation fails if unique ownership of the handle isn't
possible, for example if the index was actually a `borrow` or if the `own`
handle is currently being lent out as borrows.
```python
def lift_own(cx, i, t):
  h = cx.inst.handles.remove(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not t.rt)
  trap_if(h.num_lends != 0)
  trap_if(not h.own)
  return h.rep
```
The abstract lifted value for handle types is currently just the internal
resource representation `i32`, which is kept opaque from the receiving
component (it's stored in the `handles` table and only accessed indirectly via
index). (This assumes that resource representations are immutable. If
representations were to become mutable, the address of the mutable cell would
be passed as the lifted value instead.)

In contrast to `own`, `borrow` handles are lifted by reading the representation
from the source handle, leaving the source handle intact in the current
component instance's `handles` table:
```python
def lift_borrow(cx, i, t):
  assert(isinstance(cx.borrow_scope, Subtask))
  h = cx.inst.handles.get(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not t.rt)
  cx.borrow_scope.add_lender(h)
  return h.rep
```
The `Subtask.add_lender` participates in the enforcement of the dynamic borrow
rules, which keep the source handle alive until the end of the call (as a
conservative upper bound on how long the `borrow` handle can be held). Note
that `add_lender` is called for borrowed source handles so that they must be
kept alive until the subtask completes, which in turn prevents the [current task]
from `task.return`ing while its non-returned subtask still holds a
transitively-borrowed handle.

Streams and futures are entirely symmetric, transferring ownership of the
readable end from the lifting component to the host or lowering component and
trapping if the readable end is in the middle of copying (which would create
a dangling-pointer situation) or is in the `DONE` state (in which case the only
valid operation is `{stream,future}.drop-{readable,writable}`).
```python
def lift_stream(cx, i, t):
  return lift_async_value(ReadableStreamEnd, cx, i, t)

def lift_future(cx, i, t):
  return lift_async_value(ReadableFutureEnd, cx, i, t)

def lift_async_value(ReadableEndT, cx, i, t):
  assert(not contains_borrow(t))
  e = cx.inst.handles.remove(i)
  trap_if(not isinstance(e, ReadableEndT))
  trap_if(e.shared.t != t)
  trap_if(e.state != CopyState.IDLE)
  return e.shared
```


## Storing

The `store` function defines how to write a value `v` of a given value type
`t` into linear memory starting at offset `ptr`. Presenting the definition of
`store` piecewise, we start with the top-level case analysis:
```python
def store(cx, v, t, ptr):
  assert(ptr == align_to(ptr, alignment(t, cx.opts.memory.ptr_type())))
  assert(ptr + elem_size(t, cx.opts.memory.ptr_type()) <= len(cx.opts.memory))
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
values modified nondeterministically. This reflects the practical reality that
different languages, protocols and CPUs have different effects on NaNs.

Although this nondeterminism is expressed in the Python code below as
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
  assert(0 <= i <= 0xD7FF or 0xE000 <= i <= 0x10FFFF)
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
`utf16` based on the `utf16_tag` flag set by `load_string`:
```python
def store_string(cx, v: String, ptr):
  begin, tagged_code_units = store_string_into_range(cx, v)
  store_int(cx, begin, ptr, cx.opts.memory.ptr_size())
  store_int(cx, tagged_code_units, ptr + cx.opts.memory.ptr_size(), cx.opts.memory.ptr_size())

def store_string_into_range(cx, v: String):
  src, src_encoding, src_tagged_code_units = v
  tag = utf16_tag(cx.opts.memory.ptr_type())

  if src_encoding == 'latin1+utf16':
    if bool(src_tagged_code_units & tag):
      src_simple_encoding = 'utf16'
      src_code_units = src_tagged_code_units ^ tag
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
def store_string_copy(cx, src, src_code_units, dst_code_unit_size, dst_alignment, dst_encoding):
  dst_byte_length = dst_code_unit_size * src_code_units
  assert(dst_byte_length <= REALLOC_I32_MAX)
  ptr = cx.opts.realloc(0, 0, dst_alignment, dst_byte_length)
  trap_if(ptr != align_to(ptr, dst_alignment))
  trap_if(ptr + dst_byte_length > len(cx.opts.memory))
  encoded = src.encode(dst_encoding)
  assert(dst_byte_length == len(encoded))
  cx.opts.memory[ptr : ptr+len(encoded)] = encoded
  return (ptr, src_code_units)
```
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
  assert(src_code_units <= REALLOC_I32_MAX)
  ptr = cx.opts.realloc(0, 0, 1, src_code_units)
  trap_if(ptr + src_code_units > len(cx.opts.memory))
  for i,code_point in enumerate(src):
    if ord(code_point) < 2**7:
      cx.opts.memory[ptr + i] = ord(code_point)
    else:
      assert(worst_case_size <= REALLOC_I32_MAX)
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
  assert(worst_case_size <= REALLOC_I32_MAX)
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
  assert(src_code_units <= REALLOC_I32_MAX)
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
      assert(worst_case_size <= REALLOC_I32_MAX)
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
      tagged_code_units = int(len(encoded) / 2) | utf16_tag(cx.opts.memory.ptr_type())
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
  assert(src_byte_length <= REALLOC_I32_MAX)
  ptr = cx.opts.realloc(0, 0, 2, src_byte_length)
  trap_if(ptr != align_to(ptr, 2))
  trap_if(ptr + src_byte_length > len(cx.opts.memory))
  encoded = src.encode('utf-16-le')
  cx.opts.memory[ptr : ptr+len(encoded)] = encoded
  if any(ord(c) >= (1 << 8) for c in src):
    tagged_code_units = int(len(encoded) / 2) | utf16_tag(cx.opts.memory.ptr_type())
    return (ptr, tagged_code_units)
  latin1_size = int(len(encoded) / 2)
  for i in range(latin1_size):
    cx.opts.memory[ptr + i] = cx.opts.memory[ptr + 2*i]
  ptr = cx.opts.realloc(ptr, src_byte_length, 1, latin1_size)
  trap_if(ptr + latin1_size > len(cx.opts.memory))
  return (ptr, latin1_size)
```

Error context values are lowered by storing them directly into the current
component instance's `handles` table and passing the `i32` index to wasm:
```python
def lower_error_context(cx, v):
  return cx.inst.handles.add(v)
```

Lists and records are stored by recursively storing their elements and
are symmetric to the loading functions. Unlike strings, lists can
simply allocate based on the up-front knowledge of length and static
element size. Storing a list that exceeds the size of a 32-bit memory traps even
when storing on 64-bit platform to avoid having interfaces that 32-bit
components can't use.
```python
def store_list(cx, v, ptr, elem_type, maybe_length):
  if maybe_length is not None:
    assert(maybe_length == len(v))
    store_list_into_valid_range(cx, v, ptr, elem_type)
    return
  begin, length = store_list_into_range(cx, v, elem_type)
  store_int(cx, begin, ptr, cx.opts.memory.ptr_size())
  store_int(cx, length, ptr + cx.opts.memory.ptr_size(), cx.opts.memory.ptr_size())

def store_list_into_range(cx, v, elem_type):
  byte_length = len(v) * elem_size(elem_type, cx.opts.memory.ptr_type())
  assert(byte_length <= REALLOC_I32_MAX)
  ptr = cx.opts.realloc(0, 0, alignment(elem_type, cx.opts.memory.ptr_type()), byte_length)
  trap_if(ptr != align_to(ptr, alignment(elem_type, cx.opts.memory.ptr_type())))
  trap_if(ptr + byte_length > len(cx.opts.memory))
  store_list_into_valid_range(cx, v, ptr, elem_type)
  return (ptr, len(v))

def store_list_into_valid_range(cx, v, ptr, elem_type):
  for i,e in enumerate(v):
    store(cx, e, elem_type, ptr + i * elem_size(elem_type, cx.opts.memory.ptr_type()))

def store_record(cx, v, ptr, fields):
  for f in fields:
    ptr = align_to(ptr, alignment(f.t, cx.opts.memory.ptr_type()))
    store(cx, v[f.label], f.t, ptr)
    ptr += elem_size(f.t, cx.opts.memory.ptr_type())
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
  disc_size = elem_size(discriminant_type(cases), cx.opts.memory.ptr_type())
  store_int(cx, case_index, ptr, disc_size)
  ptr += disc_size
  ptr = align_to(ptr, max_case_alignment(cases, cx.opts.memory.ptr_type()))
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
elements in the current component instance's `handles` table. The increment of
`num_borrows` is complemented by a decrement in `canon_resource_drop` and
ensures that all borrowed handles are dropped before the end of the task.
```python
def lower_own(cx, rep, t):
  h = ResourceHandle(t.rt, rep, own = True)
  return cx.inst.handles.add(h)

def lower_borrow(cx, rep, t):
  assert(isinstance(cx.borrow_scope, Task))
  if cx.inst is t.rt.impl:
    return rep
  h = ResourceHandle(t.rt, rep, own = False, borrow_scope = cx.borrow_scope)
  h.borrow_scope.num_borrows += 1
  return cx.inst.handles.add(h)
```
The special case in `lower_borrow` is an optimization, recognizing that, when
a borrowed handle is passed to the component that implemented the resource
type, the only thing the borrowed handle is good for is calling
`resource.rep`, so lowering might as well avoid the overhead of creating an
intermediate borrow handle.

Lowering a `stream` or `future` is entirely symmetric and simply adds a new
readable end to the current component instance's `handles` table, passing the
index of the new element to core wasm:
```python
def lower_stream(cx, v, t):
  assert(isinstance(v, ReadableStream))
  assert(not contains_borrow(t))
  return cx.inst.handles.add(ReadableStreamEnd(v))

def lower_future(cx, v, t):
  assert(isinstance(v, ReadableFuture))
  assert(not contains_borrow(t))
  return cx.inst.handles.add(ReadableFutureEnd(v))
```


## Flattening

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
  flat_params = flatten_types(ft.param_types(), opts)
  flat_results = flatten_types(ft.result_type(), opts)
  if not opts.async_:
    if len(flat_params) > MAX_FLAT_PARAMS:
      flat_params = [opts.memory.ptr_type()]
    if len(flat_results) > MAX_FLAT_RESULTS:
      match context:
        case 'lift':
          flat_results = [opts.memory.ptr_type()]
        case 'lower':
          flat_params += [opts.memory.ptr_type()]
          flat_results = []
    return CoreFuncType(flat_params, flat_results)
  else:
    match context:
      case 'lift':
        if len(flat_params) > MAX_FLAT_PARAMS:
          flat_params = [opts.memory.ptr_type()]
        if opts.callback:
          flat_results = ['i32']
        else:
          flat_results = []
      case 'lower':
        if len(flat_params) > MAX_FLAT_ASYNC_PARAMS:
          flat_params = [opts.memory.ptr_type()]
        if len(flat_results) > 0:
          flat_params += [opts.memory.ptr_type()]
        flat_results = ['i32']
    return CoreFuncType(flat_params, flat_results)

def flatten_types(ts, opts):
  return [ft for t in ts for ft in flatten_type(t, opts)]
```
As shown here, the core signatures `async` functions use a lower limit on the
maximum number of parameters (4) and results (0) passed as scalars before
falling back to passing through memory.

Presenting the definition of `flatten_type` piecewise, we start with the
top-level case analysis:
```python
def flatten_type(t, opts):
  match despecialize(t):
    case BoolType()                       : return ['i32']
    case U8Type() | U16Type() | U32Type() : return ['i32']
    case S8Type() | S16Type() | S32Type() : return ['i32']
    case S64Type() | U64Type()            : return ['i64']
    case F32Type()                        : return ['f32']
    case F64Type()                        : return ['f64']
    case CharType()                       : return ['i32']
    case StringType()                     : return [opts.memory.ptr_type(), opts.memory.ptr_type()]
    case ErrorContextType()               : return ['i32']
    case ListType(t, l)                   : return flatten_list(t, l, opts)
    case RecordType(fields)               : return flatten_record(fields, opts)
    case VariantType(cases)               : return flatten_variant(cases, opts)
    case FlagsType(labels)                : return ['i32']
    case OwnType() | BorrowType()         : return ['i32']
    case StreamType() | FutureType()      : return ['i32']
```

List flattening of a fixed-length list uses the same flattening as a tuple
(via `flatten_record` below).
```python
def flatten_list(elem_type, maybe_length, opts):
  if maybe_length is not None:
    return flatten_type(elem_type, opts) * maybe_length
  return [opts.memory.ptr_type(), opts.memory.ptr_type()]
```

Record flattening simply flattens each field in sequence.
```python
def flatten_record(fields, opts):
  flat = []
  for f in fields:
    flat += flatten_type(f.t, opts)
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
def flatten_variant(cases, opts):
  flat = []
  for c in cases:
    if c.t is not None:
      for i,ft in enumerate(flatten_type(c.t, opts)):
        if i < len(flat):
          flat[i] = join(flat[i], ft)
        else:
          flat.append(ft)
  return flatten_type(discriminant_type(cases), opts) + flat

def join(a, b):
  if a == b: return a
  if (a == 'i32' and b == 'f32') or (a == 'f32' and b == 'i32'): return 'i32'
  return 'i64'
```

## Flat Lifting

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
only difference is that the pointer and length come from ptr-sized values
instead of from linear memory. Fixed-length lists are lifted the same way as a
tuple (via `lift_flat_record` below).
```python
def lift_flat_string(cx, vi):
  ptr = vi.next(cx.opts.memory.ptr_type())
  packed_length = vi.next(cx.opts.memory.ptr_type())
  return load_string_from_range(cx, ptr, packed_length)

def lift_flat_list(cx, vi, elem_type, maybe_length):
  if maybe_length is not None:
    a = []
    for i in range(maybe_length):
      a.append(lift_flat(cx, vi, elem_type))
    return a
  ptr = vi.next(cx.opts.memory.ptr_type())
  length = vi.next(cx.opts.memory.ptr_type())
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
  flat_types = flatten_variant(cases, cx.opts)
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

## Flat Lowering

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
  flat_types = flatten_variant(cases, cx.opts)
  assert(flat_types.pop(0) == 'i32')
  c = cases[case_index]
  if c.t is None:
    payload = []
  else:
    payload = lower_flat(cx, case_value, c.t)
    for i,(fv,have) in enumerate(zip(payload, flatten_type(c.t, cx.opts))):
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

## Lifting and Lowering Values

The `lift_flat_values` function defines how to lift a list of core
parameters or results (given by the `CoreValueIter` `vi`) into a tuple
of component-level values with types `ts`.
```python
def lift_flat_values(cx, max_flat, vi, ts):
  flat_types = flatten_types(ts, cx.opts)
  if len(flat_types) > max_flat:
    ptr = vi.next(cx.opts.memory.ptr_type())
    tuple_type = TupleType(ts)
    trap_if(ptr != align_to(ptr, alignment(tuple_type, cx.opts.memory.ptr_type())))
    trap_if(ptr + elem_size(tuple_type, cx.opts.memory.ptr_type()) > len(cx.opts.memory))
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
  flat_types = flatten_types(ts, cx.opts)
  if len(flat_types) > max_flat:
    tuple_type = TupleType(ts)
    tuple_value = {str(i): v for i,v in enumerate(vs)}
    if out_param is None:
      ptr = cx.opts.realloc(0, 0, alignment(tuple_type, cx.opts.memory.ptr_type()), elem_size(tuple_type, cx.opts.memory.ptr_type()))
      flat_vals = [ptr]
    else:
      ptr = out_param.next(cx.opts.memory.ptr_type())
      flat_vals = []
    trap_if(ptr != align_to(ptr, alignment(tuple_type, cx.opts.memory.ptr_type())))
    trap_if(ptr + elem_size(tuple_type, cx.opts.memory.ptr_type()) > len(cx.opts.memory))
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
* `memory` - this is a subtype of `(memory 0)`
  * 🐘 `memory` may also be a subtype of `(memory i64 0)`
* `realloc` - the function has type `(func (param addr addr addr addr) (result addr))`
  where `addr` is the address type coming from the [`memtype`] of the `memory`
  canonopt (restricted to `i32`, but with 🐘 may also be `i64`).
* if `realloc` is present then `memory` must be present
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
* if `len(flatten_types(ft.result_type())) > max` (where `max = MAX_FLAT_RESULTS` for sync lifts, and `max = MAX_FLAT_PARAMS` for async lifts), `memory` is required

Note that an `async`-lifted function whose result type requires a memory to lift
(either because it contains lists or strings or because the number of flattened
types exceeds `MAX_FLAT_PARAMS`) must include a `memory` option, and that option
must exactly match that of the `task.return` built-in called at runtime.

When instantiating component instance `$inst`, `$f` is defined to be the
partially-bound closure `canon_lift($opts, $inst, $ft, $callee)` which has 3
remaining arguments and matches the `FuncInst` type defined by the
[Embedding](#embedding) interface.

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
def canon_lift(opts, inst, ft, callee, caller, on_start, on_resolve) -> OnCancel:
  trap_if(call_might_be_recursive(caller, inst))
  task = Task(opts, inst, ft, caller, on_resolve)
  def thread_func():
    if not task.enter():
      return

    cx = LiftLowerContext(opts, inst, task)
    args = on_start()
    flat_args = lower_flat_values(cx, MAX_FLAT_PARAMS, args, ft.param_types())
    flat_ft = flatten_functype(opts, ft, 'lift')
    assert(types_match_values(flat_ft.params, flat_args))
```
Each lifted function call starts by immediately trapping on possible recursive
reentrance (as defined by `call_might_be_recursive` above).

The `thread_func` is immediately called from a new implicit [thread] created and
resumed at the end of this function and thus control flow proceeds directly into
`Task.enter` after checking for recursion. `Task.enter` (defined above) suspends
if there is any backpressure until the backpressure is resolved. If the caller
cancels the new task (by calling `Task.request_cancellation`) while the task
is still waiting on backpressure, the call is aborted before the arguments are
lowered (which means that owned-handle arguments are not transferred).

Once the backpressure gate is cleared, the arguments are lowered into core wasm
values and memory according to the `canonopt` immediates of `canon lift` (as
defined by `lower_flat_values` above).

If the `async` `canonopt` is *not* specified, a `lift`ed function then calls
the core wasm callee, passing the lowered arguments in core function parameters
and receiving the return value as core function results. Once the core results
are lifted according to `lift_flat_values` above, the optional `post-return`
function (specified as a `canonopt` immediate of `canon lift`) is called,
passing the same core wasm results as parameters so that the `post-return`
function can free any associated allocations.
```python
    if not opts.async_:
      flat_results = call_and_trap_on_throw(callee, flat_args)
      assert(types_match_values(flat_ft.results, flat_results))
      result = lift_flat_values(cx, MAX_FLAT_RESULTS, CoreValueIter(flat_results), ft.result_type())
      task.return_(result)
      if opts.post_return is not None:
        inst.may_leave = False
        [] = call_and_trap_on_throw(opts.post_return, flat_results)
        inst.may_leave = True
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
time the `Task`'s last `Thread` exits, there is a trap (in `Task.unregister_thread`).

In the `async` non-`callback` ("stackful async") case, there is a single call
to the core wasm callee which must return empty core results. Waiting for async
I/O happens by the callee synchronously calling built-ins like
`waitable-set.wait`. Note that, since `Task.enter` does *not* acquire the
`exclusive` lock for stackful async functions, calls to `waitable-set.wait` made
by a stackful async function do not prevent any other threads from starting or
resuming in the same component instance.
```python
    if not opts.callback:
      [] = call_and_trap_on_throw(callee, flat_args)
      assert(types_match_values(flat_ft.results, []))
      task.exit()
      return
```

Lastly, in the `async callback` ("stackless async") case, waiting happens by
first calling the core wasm callee and then repeatedly calling the `callback`
function (specified as a `funcidx` immediate in `canon lift`) until the
`EXIT` code (`0`) is returned:
```python
    [packed] = call_and_trap_on_throw(callee, flat_args)
    code,si = unpack_callback_result(packed)
    while code != CallbackCode.EXIT:
      assert(inst.exclusive is task)
      inst.exclusive = None
      match code:
        case CallbackCode.YIELD:
          cancelled = thread.yield_until(lambda: not inst.exclusive, cancellable = True)
          if cancelled:
            event = (EventCode.TASK_CANCELLED, 0, 0)
          else:
            event = (EventCode.NONE, 0, 0)
        case CallbackCode.WAIT:
          trap_if(not task.may_block())
          wset = inst.handles.get(si)
          trap_if(not isinstance(wset, WaitableSet))
          event = wset.wait_for_event_and(lambda: not inst.exclusive, cancellable = True)
        case _:
          trap()
      assert(inst.exclusive is None)
      inst.exclusive = task
      event_code, p1, p2 = event
      [packed] = call_and_trap_on_throw(opts.callback, [event_code, p1, p2])
      code,si = unpack_callback_result(packed)
    task.exit()
    return
```
The `Thread.yield_until` and `WaitableSet.wait_for_event_and` methods called by
the event loop are the same methods called by the `thread.yield` and
`waitable-set.wait` built-ins. Thus, the main difference between stackful and
stackless async is whether these suspending operations are performed from an
empty or non-empty core wasm callstack (with the former allowing additional
engine optimization).

If a `Task` is not allowed to block (because it was created for a non-`async`-
typed function call and has not yet returned a value), `YIELD` is always a
no-op and `WAIT` always traps. Thus, a component may implement a
non-`async`-typed function with the `async callback` ABI, but the component
*must* call `task.return` *before* returning `WAIT`.

The event loop also releases `ComponentInstance.exclusive` (which was acquired
by `Task.enter` and will be released by `Task.exit`) before potentially
suspending the thread to allow other synchronous and `async callback` tasks to
execute in the interim. However, other synchronous and `async callback` tasks
*cannot* execute while running core wasm called from the event loop as this
could break the non-reentrancy assumptions of the core wasm code. Thus,
`async callback` tasks allow less concurrency than non-`callback` `async`
tasks, which entirely ignore `ComponentInstance.exclusive`.

The end of `canon_lift` immediately runs the `thread_func` function (which
contains all the steps above) in a new `Thread`, allowing `thread_func` to make
as much progress as it can before blocking (which transitively calls
`Thread.suspend`, deterministically returning control flow here and then to the
caller. If `thread_func` and the core wasm `callee` return a value (by calling
the `OnResolve` callback) before blocking, the call will complete synchronously
even for `async` callers. Note that if an `async` callee calls `OnResolve` and
*then* blocks, the caller will see the call complete synchronously even though
the callee is still running concurrently in the `Thread` created here (see
the [concurrency explainer] for more on this).
```python
  thread = Thread(task, thread_func)
  thread.resume()
  return task.request_cancellation
```

The bit-packing scheme used for the `i32` `packed` return value is defined as
follows:
```python
class CallbackCode(IntEnum):
  EXIT = 0
  YIELD = 1
  WAIT = 2
  MAX = 2

def unpack_callback_result(packed):
  code = packed & 0xf
  trap_if(code > CallbackCode.MAX)
  assert(packed < 2**32)
  assert(Table.MAX_LENGTH < 2**28)
  waitable_set_index = packed >> 4
  return (CallbackCode(code), waitable_set_index)
```
The ability to asynchronously wait, yield and exit is thus available to
both the `callback` and non-`callback` cases, making `callback` just an
optimization to avoid allocating stacks for async languages that have avoided
the need for stackful coroutines by design (e.g., `async`/`await` in JS,
Python, C# and Rust).

Uncaught Core WebAssembly [exceptions] or, in a future with [stack-switching],
unhandled events, result in a trap at component boundaries. Thus, if a component
wishes to signal an error, it must use some sort of explicit type such as
`result` (whose `error` case particular language bindings may choose to map to
and from exceptions):
```python
def call_and_trap_on_throw(callee, args):
  try:
    return callee(args)
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

When instantiating component instance `$inst`, `$f` is defined to be the
partially-bound closure `canon_lower($opts, $ft, $callee)` which leaves only
the `flat_args` remaining argument to be passed at runtime, which contains the
list of core wasm values that are passed by the core wasm caller. Based on
this, `canon_lower` is defined in chunks as follows:
```python
def canon_lower(opts, ft, callee: FuncInst, flat_args):
  thread = current_thread()
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block() and ft.async_ and not opts.async_)
```
A non-`async`-typed function export that has not yet returned a value
unconditionally traps if it transitively attempts to make a synchronous call to
an `async`-typed function import (even if the callee wouldn't have actually
blocked at runtime). It is however fine to make an `async`-lowered call to an
`async`-typed function import, since this never blocks (only a subsequent call
to, e.g., `waitable-set.wait` would block).

Each call to `canon_lower` creates a new `Subtask`. However, this `Subtask` is
only added to the current component instance's `handles` table (below) if
`async` is specified *and* `callee` blocks. In any case, this `Subtask` is used
as the `LiftLowerContext.borrow_scope` for `borrow` arguments, ensuring that
owned handles are not dropped before `Subtask.deliver_return` is called (below).
```python
  subtask = Subtask()
  cx = LiftLowerContext(opts, thread.task.inst, subtask)
```

The next chunk makes the call to `callee` (which has type `FuncInst`, as
defined in the [Embedding](#embedding) interface). The [current task] serves as
the `Supertask` argument and the `OnStart` and `OnResolve` callback arguments
are defined in terms of the `$opts` immediates of the `canon lower` definition
and the Canonical ABI's `lift_flat_values` and `lower_flat_values` (defined
above).
```python
  flat_ft = flatten_functype(opts, ft, 'lower')
  assert(types_match_values(flat_ft.params, flat_args))
  flat_args = CoreValueIter(flat_args)

  if not opts.async_:
    max_flat_params = MAX_FLAT_PARAMS
    max_flat_results = MAX_FLAT_RESULTS
  else:
    max_flat_params = MAX_FLAT_ASYNC_PARAMS
    max_flat_results = 0

  on_progress = lambda:()
  flat_results = None

  def on_start():
    on_progress()
    assert(subtask.state == Subtask.State.STARTING)
    subtask.state = Subtask.State.STARTED
    return lift_flat_values(cx, max_flat_params, flat_args, ft.param_types())

  def on_resolve(result):
    on_progress()
    if result is None:
      assert(subtask.cancellation_requested)
      if subtask.state == Subtask.State.STARTING:
        subtask.state = Subtask.State.CANCELLED_BEFORE_STARTED
      else:
        assert(subtask.state == Subtask.State.STARTED)
        subtask.state = Subtask.State.CANCELLED_BEFORE_RETURNED
    else:
      assert(subtask.state == Subtask.State.STARTED)
      subtask.state = Subtask.State.RETURNED
      nonlocal flat_results
      flat_results = lower_flat_values(cx, max_flat_results, result, ft.result_type(), flat_args)

  subtask.on_cancel = callee(thread.task, on_start, on_resolve)
  assert(ft.async_ or subtask.state == Subtask.State.RETURNED)
```
The `Subtask.state` field is updated by the callbacks to keep track of the
call progres. The `on_progress` variable starts as a no-op, but is used by the
`async` case below to trigger event delivery.

According to the `FuncInst` calling contract, the call to `callee` should never
"block" (i.e., wait on I/O). If the `callee` *would* block, it will instead
return an `OnCancel` callback which is stored in the `Subtask` (so that it can
be used to request cancellation in the future). Furthermore, if the function
type does not have the `async` effect, the function *must* have returned a
value.

In the synchronous case (when the `async` `canonopt` is not set), if the
`callee` blocked before calling `on_resolve`, the synchronous caller's thread
is non-cancellably suspended until the callee calls `on_resolve` to return a
value. Note that just because the `callee` called `on_resolve` doesn't mean
that the `callee` has finished execution: `async` functions are allowed to keep
executing after returning their value. However, if the `callee` is also
synchronous then (since `post-return` is prevented from blocking via
`may_leave`) the `callee` cannot keep executing concurrently after returning a
value and thus the implementation can avoid the creation of any `Thread` and
use a plain synchronous function call instead, as expected.
```python
  if not opts.async_:
    if not subtask.resolved():
      thread.wait_until(subtask.resolved)
    assert(types_match_values(flat_ft.results, flat_results))
    subtask.deliver_resolve()
    return flat_results
```
The call to `Subtask.deliver_resolve` decrements the counters on handles that
were lent for `borrow`ed parameters during the call. These counters are
necessary even during a synchronous call to prevent a concurrent `async` task
from dropping lent handles while the synchronous call is blocked.

In the `async` case, if the `callee` already called `on_resolve`, then the
`RETURNED` code is eagerly returned to the core wasm caller without needing to
add a `Subtask` to the current component instance's `handles` table. Otherwise,
the index of a new `Subtask` is returned, bit-packed with the current state of
the `Subtask` (which will either be `STARTING` or `STARTED`). `STARTING` tells
the caller that they need to keep the memory for both the arguments and results
allocated; `STARTED` tells the caller that the arguments have been ready and
thus any argument memory can be reused, but the result buffer has to be kept
reserved.
```python
  else:
    if subtask.resolved():
      assert(flat_results == [])
      subtask.deliver_resolve()
      return [Subtask.State.RETURNED]
    else:
      subtaski = thread.task.inst.handles.add(subtask)
      def on_progress():
        def subtask_event():
          if subtask.resolved():
            subtask.deliver_resolve()
          return (EventCode.SUBTASK, subtaski, subtask.state)
        subtask.set_pending_event(subtask_event)
      assert(0 < subtaski <= Table.MAX_LENGTH < 2**28)
      assert(0 <= subtask.state < 2**4)
      return [subtask.state | (subtaski << 4)]
```
When `on_start` and `on_resolve` are called after this initial `async`-lowered
call returns, the `on_progress` callback (called by `on_start` and `on_return`)
will set a pending event on the `Subtask` (which derives `Waitable`) so that it
can be waited on via `waitable-set.{wait,poll}` or, if a `callback` is used, by
returning to the event loop. If `on_start` is called followed by `on_resolve`
before core wasm receives the first event, core wasm will only receive the
second event, not two events. Note `Subtask.drop` prevents (via trap) a
`Subtask` from being dropped before `on_resolve` is called and the event is
delivered to core wasm to ensure that `Subtask.deliver_resolve` always performs
its lend-count accounting.


### `canon resource.new`

For a canonical definition:
```wat
(canon resource.new $rt (core func $f))
```
validation specifies:
* `$rt` must refer to locally-defined (not imported) resource type
* `$f` is given type `(func (param $rt.rep) (result i32))`, where `$rt.rep` is
  fixed to be `i32`
  * 🐘 - `$rt.rep` may be `i32` or `i64`

Calling `$f` invokes the following function, which adds an owning handle
containing the given resource representation to the current component
instance's `handles` table:
```python
def canon_resource_new(rt, rep):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  h = ResourceHandle(rt, rep, own = True)
  i = inst.handles.add(h)
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

Calling `$f` invokes the following function, which removes the handle from the
current component instance's `handles` table and, if the handle was owning,
calls the resource's destructor.
```python
def canon_resource_drop(rt, i):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  h = inst.handles.remove(i)
  trap_if(not isinstance(h, ResourceHandle))
  trap_if(h.rt is not rt)
  trap_if(h.num_lends != 0)
  if h.own:
    assert(h.borrow_scope is None)
    if inst is rt.impl:
      if rt.dtor:
        rt.dtor(h.rep)
    else:
      caller_opts = CanonicalOptions(async_ = False)
      callee_opts = CanonicalOptions(async_ = rt.dtor_async, callback = rt.dtor_callback)
      ft = FuncType([U32Type()],[], async_ = False)
      dtor = rt.dtor or (lambda rep: [])
      callee = partial(canon_lift, callee_opts, rt.impl, ft, dtor)
      [] = canon_lower(caller_opts, ft, callee, [h.rep])
  else:
    h.borrow_scope.num_borrows -= 1
  return []
```
The call to a resource's destructor is defined as a non-`async`-lowered,
non-`async`-typed function call to a possibly-`async`-lifted callee, passing
the private `i32` representation as a parameter. Thus, destructors *may* block
on I/O, but only after they `task.return`, ensuring that `resource.drop` never
blocks.

Since there are valid reasons to call `resource.drop` in the same component
instance that defined the resource, which would otherwise trap at the
reentrance guard of `Task.enter`, an exception is made when the resource type's
implementation-instance is the same as the current instance (which is
statically known for any given `canon resource.drop`).

When a destructor isn't present, there is still a trap on recursive reentrance
since this is the caller's responsibility and the presence or absence of a
destructor is an encapsulated implementation detail of the resource type.


### `canon resource.rep`

For a canonical definition:
```wat
(canon resource.rep $rt (core func $f))
```
validation specifies:
* `$rt` must refer to a locally-defined (not imported) resource type
* `$f` is given type `(func (param i32) (result $rt.rep))`, where `$rt.rep` is
  fixed to be `i32`
  * 🐘 - `$rt.rep` may be `i32` or `i64`

Calling `$f` invokes the following function, which extracts the resource
representation from the handle in the current component instance's `handles`
table:
```python
def canon_resource_rep(rt, i):
  h = current_thread().task.inst.handles.get(i)
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
* `$t` must be `i32` (see [here][thread-local storage]).
  * 🐘 - `$t` may also be `i64`. All `context.get` and `context.set` built-ins
    defined in a single component must specify the same `$t`.
* `$i` must be less than `2`
* `$f` is given type `(func (result $t))`

Calling `$f` invokes the following function, which reads the [thread-local
storage] of the [current thread].
```python
def canon_context_get(t, i):
  thread = current_thread()
  assert(t == 'i32' or t == 'i64')
  assert(i < len(thread.storage))
  result = thread.storage[i]
  assert(result < (2 ** (ptr_size(t) * 8)))
  return [result]
```


### 🔀 `canon context.set`

For a canonical definition:
```wat
(canon context.set $t $i (core func $f))
```
validation specifies:
* `$t` must be `i32` (see [here][thread-local storage])
  * 🐘 - `$t` may also be `i64`. All `context.get` and `context.set` built-ins
    defined in a single component must specify the same `$t`.
* `$i` must be less than `2`
* `$f` is given type `(func (param $v $t))`

Calling `$f` invokes the following function, which writes to the [thread-local
storage] of the [current thread]:
```python
def canon_context_set(t, i, v):
  thread = current_thread()
  assert(t == 'i32' or t == 'i64')
  assert(i < len(thread.storage))
  assert(v < (2 ** (ptr_size(t) * 8)))
  thread.storage[i] = v
  return []
```


### 🔀✕ `canon backpressure.set`

> This built-in is deprecated in favor of `backpressure.{inc,dec}` and will be
> removed once producer tools have transitioned. Producer tools should avoid
> emitting calls to both `set` and `inc`/`dec` since `set` will clobber the
> counter.

For a canonical definition:
```wat
(canon backpressure.set (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $enabled i32))`

Calling `$f` invokes the following function, which sets the `backpressure`
counter to `1` or `0`. `Task.enter` waits for `backpressure` to be `0` before
allowing new tasks to start.
```python
def canon_backpressure_set(flat_args):
  assert(len(flat_args) == 1)
  current_thread().task.inst.backpressure = int(bool(flat_args[0]))
  return []
```

### 🔀 `canon backpressure.{inc,dec}`

For a canonical definition:
```wat
(canon backpressure.inc (core func $inc))
(canon backpressure.dec (core func $dec))
```
validation specifies:
* `$inc`/`$dec` are given type `(func)`

Calling `$inc` or `$dec` invokes one of the following functions:
```python
def canon_backpressure_inc():
  inst = current_thread().task.inst
  assert(0 <= inst.backpressure < 2**16)
  inst.backpressure += 1
  trap_if(inst.backpressure == 2**16)
  return []

def canon_backpressure_dec():
  inst = current_thread().task.inst
  assert(0 <= inst.backpressure < 2**16)
  inst.backpressure -= 1
  trap_if(inst.backpressure < 0)
  return []
```
`Task.enter` waits for `backpressure` to return to `0` before allowing new
tasks to start, implementing [backpressure].


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
wasm state and passes them to the [current task]'s caller via `Task.return_`:
```python
def canon_task_return(result_type, opts: LiftOptions, flat_args):
  task = current_thread().task
  trap_if(not task.inst.may_leave)
  trap_if(not task.opts.async_)
  trap_if(result_type != task.ft.result)
  trap_if(not LiftOptions.equal(opts, task.opts))
  cx = LiftLowerContext(opts, task.inst, task)
  result = lift_flat_values(cx, MAX_FLAT_PARAMS, CoreValueIter(flat_args), task.ft.result_type())
  task.return_(result)
  return []
```
The `trap_if(not task.opts.async_)` prevents `task.return` from being called by
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
[current task] have already been dropped (and trapping in `Task.cancel` if not).
```python
def canon_task_cancel():
  task = current_thread().task
  trap_if(not task.inst.may_leave)
  trap_if(not task.opts.async_)
  task.cancel()
  return []
```
The `trap_if(not task.opts.async_)` prevents `task.cancel` from being called by
synchronously-lifted functions (which must always return a value by returning
from the lifted core function).

`Task.cancel` also traps if there has been no cancellation request (in which
case the callee expects to receive a return value) or if the task has already
returned a value or already called `task.cancel`.


### 🔀 `canon waitable-set.new`

For a canonical definition:
```wat
(canon waitable-set.new (core func $f))
```
validation specifies:
* `$f` is given type `(func (result i32))`

Calling `$f` invokes the following function, which adds an empty waitable set
to the current component instance's `handles` table:
```python
def canon_waitable_set_new():
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  i = inst.handles.add(WaitableSet())
  return [i]
```


### 🔀 `canon waitable-set.wait`

For a canonical definition:
```wat
(canon waitable-set.wait $cancellable? (memory $mem) (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $si i32) (param $ptr T) (result i32))` where
  `T` is `i32`
  * 🐘 - `T` is `i32` or `i64` as determined by the address type of `$mem`

Calling `$f` invokes the following function which waits for progress to be made
on a `Waitable` in the given waitable set (indicated by index `$si`) and then
returning its `EventCode` and writing the payload values into linear memory:
```python
def canon_waitable_set_wait(cancellable, mem, si, ptr):
  task = current_thread().task
  trap_if(not task.inst.may_leave)
  trap_if(not task.may_block())
  wset = task.inst.handles.get(si)
  trap_if(not isinstance(wset, WaitableSet))
  event = wset.wait_for_event(cancellable)
  return unpack_event(mem, task.inst, ptr, event)

def unpack_event(mem, inst, ptr, e: EventTuple):
  event, p1, p2 = e
  cx = LiftLowerContext(LiftLowerOptions(memory = mem), inst)
  store(cx, p1, U32Type(), ptr)
  store(cx, p2, U32Type(), ptr + 4)
  return [event]
```
A non-`async`-typed function export that has not yet returned a value
unconditionally traps if it transitively attempts to call `wait` (regardless of
whether there are any waitables with pending events).

If `cancellable` is set, then `waitable-set.wait` will return whether the
supertask has already or concurrently requested cancellation.
`waitable-set.wait` (and other cancellable operations) will only indicate
cancellation once and thus, if a caller is not prepared to propagate
cancellation, they can omit `cancellable` so that cancellation is instead
delivered at a later `cancellable` call.


### 🔀 `canon waitable-set.poll`

For a canonical definition:
```wat
(canon waitable-set.poll $cancellable? (memory $mem) (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $si i32) (param $ptr T) (result i32))` where
  `T` is `i32`
  * 🐘 - `T` is `i32` or `i64` as determined by the address type of `$mem`

Calling `$f` invokes the following function, which either returns an event that
was pending on one of the waitables in the given waitable set (the same way as
`waitable-set.wait`) or, if there is none, returns `0`.
```python
def canon_waitable_set_poll(cancellable, mem, si, ptr):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  wset = inst.handles.get(si)
  trap_if(not isinstance(wset, WaitableSet))
  event = wset.poll(cancellable)
  return unpack_event(mem, inst, ptr, event)
```
If `cancellable` is set, then `waitable-set.poll` will return whether the
supertask has already or concurrently requested cancellation.
`waitable-set.poll` (and other cancellable operations) will only indicate
cancellation once and thus, if a caller is not prepared to propagate
cancellation, they can omit `cancellable` so that cancellation is instead
delivered at a later `cancellable` call.


### 🔀 `canon waitable-set.drop`

For a canonical definition:
```wat
(canon waitable-set.drop (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` invokes the following function, which removes the indicated
waitable set from the current component instance's `handles` table, performing
the guards defined by `WaitableSet.drop` above:
```python
def canon_waitable_set_drop(i):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  wset = inst.handles.remove(i)
  trap_if(not isinstance(wset, WaitableSet))
  wset.drop()
  return []
```
Note that `WaitableSet.drop` will trap if it is non-empty or there is a
concurrent `waitable-set.wait` or `async callback` currently using this
waitable set.


### 🔀 `canon waitable.join`

For a canonical definition:
```wat
(canon waitable.join (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $wi i32) (param $si i32))`

Calling `$f` invokes the following function which adds the waitable indicated
by the index `wi` to the waitable set indicated by the index `si`, removing the
waitable from any waitable set that it is currently a member of.
```python
def canon_waitable_join(wi, si):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  w = inst.handles.get(wi)
  trap_if(not isinstance(w, Waitable))
  if si == 0:
    w.join(None)
  else:
    wset = inst.handles.get(si)
    trap_if(not isinstance(wset, WaitableSet))
    w.join(wset)
  return []
```
Note that tables do not allow elements at index `0`, so `0` is a valid sentinel
that tells `join` to remove the given waitable from any set that it is
currently a part of. Waitables can be a member of at most one set, so if the
given waitable is already in one set, it will be transferred.


### 🔀 `canon subtask.cancel`

For a canonical definition:
```wat
(canon subtask.cancel async? (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32) (result i32))`
* 🚝 - `async` is allowed (otherwise it must be absent)

Calling `$f` sends a request to a nondeterministically-chosen thread of the
subtask at the given index to cancel the subtask ASAP. This request is
cooperative and the subtask may take arbitrarily long to receive and confirm
the request. If the subtask doesn't immediately confirm the cancellation
request, `subtask.cancel` returns `BLOCKED` and the caller must wait for a
`SUBTASK` progress update using `waitable-set` methods as usual.

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

def canon_subtask_cancel(async_, i):
  thread = current_thread()
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block() and not async_)
  subtask = thread.task.inst.handles.get(i)
  trap_if(not isinstance(subtask, Subtask))
  trap_if(subtask.resolve_delivered())
  trap_if(subtask.cancellation_requested)
  if subtask.resolved():
    assert(subtask.has_pending_event())
  else:
    subtask.cancellation_requested = True
    subtask.on_cancel()
    if not subtask.resolved():
      if not async_:
        thread.wait_until(subtask.resolved)
      else:
        return [BLOCKED]
  code,index,payload = subtask.get_pending_event()
  assert(code == EventCode.SUBTASK and index == i and payload == subtask.state)
  assert(subtask.resolve_delivered())
  return [subtask.state]
```
A non-`async`-typed function export that has not yet returned a value
unconditionally traps if it transitively attempts to make a synchronous call to
`subtask.cancel` (regardless of whether the cancellation would have succeeded
without blocking). The other traps disallow calling `subtask.cancel` twice for
the same subtask or after the supertask has already been notified that the
subtask has returned.

A race condition handled by the above code is that it's possible for a subtask
to have already resolved (by calling `task.return` or `task.cancel`) and
updated the `state` stored in the `Subtask` (such that `Subtask.resolved()` is
`True`) but this fact has not yet been *delivered* to the supertask by the
supertask calling `get_pending_event` on the `Subtask` in its table. This
distinction is captured by `Subtask.resolved` vs. `Subtask.resolve_delivered`.


### 🔀 `canon subtask.drop`

For a canonical definition:
```wat
(canon subtask.drop (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` removes the subtask at the given index from the current component
instance's `handles` table, performing the guards and bookkeeping defined by
`Subtask.drop()`.
```python
def canon_subtask_drop(i):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  s = inst.handles.remove(i)
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
current component instance's `handles` table and returns their indices packed
into a single `i64`. The first element (in the low 32 bits) is the readable end
(of the new {stream, future}) and the second element (in the high 32 bits) is
the writable end. The expectation is that, after calling `{stream,future}.new`,
the readable end is subsequently transferred to another component (or the host)
via `stream` or `future` parameter/result type (see `lift_{stream,future}`
above).
```python
def canon_stream_new(stream_t):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  shared = SharedStreamImpl(stream_t.t)
  ri = inst.handles.add(ReadableStreamEnd(shared))
  wi = inst.handles.add(WritableStreamEnd(shared))
  return [ ri | (wi << 32) ]

def canon_future_new(future_t):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  shared = SharedFutureImpl(future_t.t)
  ri = inst.handles.add(ReadableFutureEnd(shared))
  wi = inst.handles.add(WritableFutureEnd(shared))
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
* `$f` is given type `(func (param i32 T T) (result T))` where `T` is `i32`
  * 🐘 - `T` is `i32` or `i64` as determined by the address type of `memory` from
    `$opts` (or `i32` by default if no `memory` is present)
* `$stream_t` must be a type of the form `(stream $t?)`
* If `$t` is present:
  * [`lower($t)` above](#canonopt-validation) defines required options for `stream.write`
  * [`lift($t)` above](#canonopt-validation) defines required options for `stream.read`
  * `memory` is required to be present
* 🚝 - `async` is allowed to be omitted, otherwise it must be present

The implementation of these built-ins funnels down to a single `stream_copy`
function that is parameterized by the direction of the copy:
```python
def canon_stream_read(stream_t, opts, i, ptr, n):
  return stream_copy(ReadableStreamEnd, WritableBufferGuestImpl, EventCode.STREAM_READ,
                     stream_t, opts, i, ptr, n)

def canon_stream_write(stream_t, opts, i, ptr, n):
  return stream_copy(WritableStreamEnd, ReadableBufferGuestImpl, EventCode.STREAM_WRITE,
                     stream_t, opts, i, ptr, n)
```

Introducing the `stream_copy` function in chunks, a non-`async`-typed function
export that has not yet returned a value unconditionally traps if it
transitively attempts to perform a synchronous `read` or `write` (regardless of
whether the operation would have succeeded eagerly without blocking).
```python
def stream_copy(EndT, BufferT, event_code, stream_t, opts, i, ptr, n):
  thread = current_thread()
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block() and not opts.async_)
```

Next, `stream_copy` checks that the element at index `i` is of the right type
and allowed to start a new copy. (In the future, the "trap if not `IDLE`"
condition could be relaxed to allow multiple pipelined reads or writes.)
```python
  e = thread.task.inst.handles.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != stream_t.t)
  trap_if(e.state != CopyState.IDLE)
```

Then a readable or writable buffer is created which (in `Buffer`'s constructor)
eagerly checks the alignment and bounds of (`i`, `n`). (In the future, the
restriction on futures/streams containing `borrow`s could be relaxed by
maintaining sufficient bookkeeping state to ensure that borrowed handles *or
streams/futures of borrowed handles* could not outlive their originating call.
Additionally, `stream<char>` will be allowed and defined to encode and decode
according to the `string-encoding`.)
```python
  assert(not isinstance(stream_t, CharType))
  assert(not contains_borrow(stream_t))
  cx = LiftLowerContext(opts, thread.task.inst, borrow_scope = None)
  buffer = BufferT(stream_t.t, cx, ptr, n)
```

Next, the `copy` method of `{Readable,Writable}{Stream,Future}End` is called to
perform the actual read/write. The `on_copy*` callbacks passed to `copy` bind
and store a `stream_event` closure on the readable/writable end (via the
inherited `Waitable.set_pending_event`) which will be called right before the
event is delivered to core wasm. `stream_event` first calls `reclaim_buffer` to
regain ownership of `buffer` and prevent any further partial reads/writes.
Thus, up until event delivery, the other end of the stream is free to
repeatedly read/write from/to `buffer`, ideally filling it up and minimizing
context switches. Next, the stream's `state` is updated based on the result
being delivered to core wasm so that, once a stream end has been notified that
the other end dropped, calling anything other than `stream.drop-*` traps.
Lastly, `stream_event` packs the `CopyResult` and number of elements copied up
until this point into a single `i32` or `i64`-sized payload for core wasm. The
size is determined by the `addrtype` coming from the [`memtype`] of the
`memory` immediate. Note that even though the number of elements copied is
packed into an `addrtype`, the maximum length of the buffer is fixed at `2^28 - 1`
independently of the `addrtype`.
```python
  def stream_event(result, reclaim_buffer):
    reclaim_buffer()
    if result == CopyResult.DROPPED:
      e.state = CopyState.DONE
    else:
      e.state = CopyState.IDLE
    assert(0 <= result < 2**4)
    assert(buffer.progress <= Buffer.MAX_LENGTH < 2**28)
    packed_result = result | (buffer.progress << 4)
    return (event_code, i, packed_result)

  def on_copy(reclaim_buffer):
    e.set_pending_event(partial(stream_event, CopyResult.COMPLETED, reclaim_buffer))

  def on_copy_done(result):
    e.set_pending_event(partial(stream_event, result, reclaim_buffer = lambda:()))

  e.copy(thread.task.inst, buffer, on_copy, on_copy_done)
```

When this `copy` makes progress, a `stream_event` is set on the stream end's
`Waitable` base object. If `stream.{read,write}` is called synchronously, the
call suspends the current thread until an event is set, so that the event can
be returned. Otherwise, asynchronous calls deliver the event if it was produced
synchronously and return `BLOCKED` if not:
```python
  if not e.has_pending_event():
    if not opts.async_:
      e.state = CopyState.SYNC_COPYING
      thread.wait_until(e.has_pending_event)
    else:
      e.state = CopyState.ASYNC_COPYING
      return [BLOCKED]
  code,index,payload = e.get_pending_event()
  assert(code == event_code and index == i and payload != BLOCKED)
  return [payload]
```


### 🔀 `canon future.{read,write}`

For canonical definitions:
```wat
(canon future.read $future_t $opts (core func $f))
(canon future.write $future_t $opts (core func $f))
```
In addition to [general validation of `$opts`](#canonopt-validation) validation
specifies:
* `$f` is given type `(func (param i32 T) (result i32))` where `T` is `i32`
  * 🐘 - `T` is `i32` or `i64` as determined by the address type of `memory` from
    `$opts` (or `i32` by default if no `memory` is present)
* `$future_t` must be a type of the form `(future $t?)`
* If `$t` is present:
  * [`lift($t)` above](#canonopt-validation) defines required options for `future.read`
  * [`lower($t)` above](#canonopt-validation) defines required options for `future.write`
  * `memory` is required to be present
* 🚝 - `async` is allowed to be omitted, otherwise it must be present

The implementation of these built-ins funnels down to a single `future_copy`
function that is parameterized by the direction of the copy:
```python
def canon_future_read(future_t, opts, i, ptr):
  return future_copy(ReadableFutureEnd, WritableBufferGuestImpl, EventCode.FUTURE_READ,
                     future_t, opts, i, ptr)

def canon_future_write(future_t, opts, i, ptr):
  return future_copy(WritableFutureEnd, ReadableBufferGuestImpl, EventCode.FUTURE_WRITE,
                     future_t, opts, i, ptr)
```

Introducing the `future_copy` function in chunks, `future_copy` starts with the
same set of guards as `stream_copy` regarding whether suspension is allowed and
parameters `i` and `ptr`. The only difference is that, with futures, the
`Buffer` length is fixed to `1`.
```python
def future_copy(EndT, BufferT, event_code, future_t, opts, i, ptr):
  thread = current_thread()
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block() and not opts.async_)

  e = thread.task.inst.handles.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != future_t.t)
  trap_if(e.state != CopyState.IDLE)

  assert(not contains_borrow(future_t))
  cx = LiftLowerContext(opts, thread.task.inst, borrow_scope = None)
  buffer = BufferT(future_t.t, cx, ptr, 1)
```

Next, the `copy` method of `{Readable,Writable}FutureEnd.copy` is called to
perform the actual read/write. Other than the simplifications allowed by the
absence of repeated partial copies, the main difference in the following code
from the stream code is that `future_event` transitions the end to the `DONE`
state (in which the only valid operation is to call `future.drop-*`) on
*either* the `DROPPED` and `COMPLETED` results. This ensures that futures are
read/written at most once and futures are only passed to other components in a
state where they are ready to be read/written. Another important difference is
that, since the buffer length is always implied by the `CopyResult`, the number
of elements copied is not packed in the high 28 bits; they're always zero.
```python
  def future_event(result):
    assert((buffer.remain() == 0) == (result == CopyResult.COMPLETED))
    if result == CopyResult.DROPPED or result == CopyResult.COMPLETED:
      e.state = CopyState.DONE
    else:
      e.state = CopyState.IDLE
    return (event_code, i, result)

  def on_copy_done(result):
    assert(result != CopyResult.DROPPED or event_code == EventCode.FUTURE_WRITE)
    e.set_pending_event(partial(future_event, result))

  e.copy(thread.task.inst, buffer, on_copy_done)
```

The end of `future_copy` is the exact same as `stream_copy`: waiting if called
synchronously and returning either the progress made or `BLOCKED`.
```python
  if not e.has_pending_event():
    if not opts.async_:
      e.state = CopyState.SYNC_COPYING
      thread.wait_until(e.has_pending_event)
    else:
      e.state = CopyState.ASYNC_COPYING
      return [BLOCKED]
  code,index,payload = e.get_pending_event()
  assert(code == event_code and index == i)
  return [payload]
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
* 🚝 - `async` is allowed (otherwise it must be absent)

The implementation of these four built-ins all funnel down to a single
parameterized `cancel_copy` function:
```python
def canon_stream_cancel_read(stream_t, async_, i):
  return cancel_copy(ReadableStreamEnd, EventCode.STREAM_READ, stream_t, async_, i)

def canon_stream_cancel_write(stream_t, async_, i):
  return cancel_copy(WritableStreamEnd, EventCode.STREAM_WRITE, stream_t, async_, i)

def canon_future_cancel_read(future_t, async_, i):
  return cancel_copy(ReadableFutureEnd, EventCode.FUTURE_READ, future_t, async_, i)

def canon_future_cancel_write(future_t, async_, i):
  return cancel_copy(WritableFutureEnd, EventCode.FUTURE_WRITE, future_t, async_, i)

def cancel_copy(EndT, event_code, stream_or_future_t, async_, i):
  thread = current_thread()
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block() and not async_)
  e = thread.task.inst.handles.get(i)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != stream_or_future_t.t)
  trap_if(e.state != CopyState.ASYNC_COPYING)
  e.state = CopyState.CANCELLING_COPY
  if not e.has_pending_event():
    e.shared.cancel()
    if not e.has_pending_event():
      if not async_:
        thread.wait_until(e.has_pending_event)
      else:
        return [BLOCKED]
  code,index,payload = e.get_pending_event()
  assert(not e.copying() and code == event_code and index == i)
  return [payload]
```
A non-`async`-typed function export that has not yet returned a value
unconditionally traps if it transitively attempts to make a synchronous call to
`cancel-read` or `cancel-write` (regardless of whether the cancellation would
have completed without blocking). There is also a trap if there is not
currently an async copy in progress (sync copies do not expect or check for
cancellation and thus cannot be cancelled, and repeatedly cancelling the same
async copy after the first call blocked is not allowed).

The *first* check for `e.has_pending_event()` catches the case where the copy has
already racily finished, in which case we must *not* call `cancel()`. Calling
`cancel()` may, but is not required to, recursively call one of the `on_*`
callbacks (passed by `canon_{stream,future}_{read,write}` above) which will set
a pending event that is caught by the *second* check for
`e.has_pending_event()`.

If the copy hasn't been cancelled, the synchronous case suspends the thread to
wait for one of the `on_*` callbacks to eventually be called (which will set
the pending event).

The asynchronous case simply returns `BLOCKED` and the client code must wait
as usual for a `{STREAM,FUTURE}_{READ,WRITE}` event. In this case, cancellation
has served only to asynchronously request that the host relinquish the buffer
ASAP without waiting for anything to be read or written.

If `BLOCKED` is *not* returned, the pending event (which is necessarily a
`stream_event` or `future_event`) is eagerly delivered to core wasm as the return value, thereby
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
* `$f` is given type `(func (param i32))`
* `$stream_t`/`$future_t` must be a type of the form `(stream $t?)`/`(future $t?)`

Calling `$f` removes the readable or writable end of the stream or future at
the given index from the current component instance's `handles` table,
performing the guards and bookkeeping defined by
`{Readable,Writable}{Stream,Future}End.drop()` above.
```python
def canon_stream_drop_readable(stream_t, i):
  return drop(ReadableStreamEnd, stream_t, i)

def canon_stream_drop_writable(stream_t, hi):
  return drop(WritableStreamEnd, stream_t, hi)

def canon_future_drop_readable(future_t, i):
  return drop(ReadableFutureEnd, future_t, i)

def canon_future_drop_writable(future_t, hi):
  return drop(WritableFutureEnd, future_t, hi)

def drop(EndT, stream_or_future_t, hi):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  e = inst.handles.remove(hi)
  trap_if(not isinstance(e, EndT))
  trap_if(e.shared.t != stream_or_future_t.t)
  e.drop()
  return []
```


### 🧵 `canon thread.index`

For a canonical definition:
```wat
(canon thread.index (core func $index))
```
validation specifies:
* `$index` is given type `(func (result i32))`

Calling `$index` invokes the following function, which extracts the index
of the [current thread]:
```python
def canon_thread_index():
  thread = current_thread()
  assert(thread.index is not None)
  return [thread.index]
```


### 🧵 `canon thread.new-indirect`

For a canonical definition:
```wat
(canon thread.new-indirect $ft $ftbl (core func $new_indirect))
```
validation specifies
* `$ft` must refer to the type `(func (param $c T))` where `T` is `i32`
  * 🐘 - `T` may be `i32` or `i64`
* `$ftbl` must refer to a table whose element type matches `funcref`
* `$new_indirect` is given type `(func (param $fi U) (param $c T) (result i32))`
  where `T` comes from `$ft`, as described above, and `U` is `i32`
  * 🐘 - `U` is `i32` or `i64` as determined by `$ftbl`'s address type

Calling `$new_indirect` invokes the following function which reads a `funcref`
from `$ftbl` (trapping if out-of-bounds, null or the wrong type), calls the
`funcref` passing the closure parameter `$c`, and returns the index of the new
thread in the current component instance's `threads` table.
```python
@dataclass
class CoreFuncRef:
  t: CoreFuncType
  callee: Callable[[list[CoreValType]], list[CoreValType]]

def canon_thread_new_indirect(ft, ftbl: Table[CoreFuncRef], fi, c):
  task = current_thread().task
  trap_if(not task.inst.may_leave)
  f = ftbl.get(fi)
  assert(ft == CoreFuncType(['i32'], []) or ft == CoreFuncType(['i64'], []))
  trap_if(f.t != ft)
  def thread_func():
    [] = call_and_trap_on_throw(f.callee, [c])
    task.unregister_thread(new_thread)
  new_thread = Thread(task, thread_func)
  assert(new_thread.suspended())
  task.register_thread(new_thread)
  return [new_thread.index]
```
The newly-created thread starts out in a "suspended" state and so, to
actually start executing, Core WebAssembly code must call one of the other
`thread.*` built-ins defined below.


### 🧵 `canon thread.switch-to`

For a canonical definition:
```wat
(canon thread.switch-to $cancellable? (core func $switch-to))
```
validation specifies:
* `$switch-to` is given type `(func (param $i i32) (result i32))`

Calling `$switch-to` invokes the following function which loads a thread at
index `$i` from the current component instance's `threads` table, traps if it's
not [suspended], and then switches to that thread, leaving the [current thread]
suspended.
```python
def canon_thread_switch_to(cancellable, i):
  thread = current_thread()
  trap_if(not thread.task.inst.may_leave)
  other_thread = thread.task.inst.threads.get(i)
  trap_if(not other_thread.suspended())
  cancelled = thread.switch_to(cancellable, other_thread)
  return [cancelled]
```
If `cancellable` is set, then `thread.switch-to` will return a `Cancelled`
value to indicate whether the supertask has already or concurrently requested
cancellation. `thread.switch-to` (and other cancellable operations) will only
indicate cancellation once and thus, if a caller is not prepared to propagate
cancellation, they can omit `cancellable` so that cancellation is instead
delivered at a later `cancellable` call.


### 🧵 `canon thread.suspend`

For a canonical definition:
```wat
(canon thread.suspend $cancellable? (core func $suspend))
```
validation specifies:
* `$suspend` is given type `(func (result i32))`

Calling `$suspend` invokes the following function which suspends the [current
thread], immediately returning control flow to any transitive `async`-lowered
calling component.
```python
def canon_thread_suspend(cancellable):
  thread = current_thread()
  trap_if(not thread.task.inst.may_leave)
  trap_if(not thread.task.may_block())
  cancelled = thread.suspend(cancellable)
  return [cancelled]
```
A non-`async`-typed function export that has not yet returned a value traps if
it transitively attempts to call `thread.suspend`.

If `cancellable` is set, then `thread.suspend` will return a `Cancelled`
value to indicate whether the supertask has already or concurrently requested
cancellation. `thread.suspend` (and other cancellable operations) will only
indicate cancellation once and thus, if a caller is not prepared to propagate
cancellation, they can omit `cancellable` so that cancellation is instead
delivered at a later `cancellable` call.


### 🧵 `canon thread.resume-later`

For a canonical definition:
```wat
(canon thread.resume-later (core func $resume-later))
```
validation specifies:
* `$resume-later` is given type `(func (param $i i32))`

Calling `$resume-later` invokes the following function which loads a thread at
index `$i` from the current component instance's `threads` table, traps if it's
not [suspended], and then marks that thread as ready to run at some
nondeterministic point in the future chosen by the embedder.
```python
def canon_thread_resume_later(i):
  thread = current_thread()
  trap_if(not thread.task.inst.may_leave)
  other_thread = thread.task.inst.threads.get(i)
  trap_if(not other_thread.suspended())
  other_thread.resume_later()
  return []
```
`thread.resume-later` never suspends the [current thread] and so there is no
possibility of cancellation and thus no `cancellable` immediate.


### 🧵 `canon thread.yield-to`

For a canonical definition:
```wat
(canon thread.yield-to $cancellable? (core func $yield-to))
```
validation specifies:
* `$yield-to` is given type `(func (param $i i32) (result i32))`

Calling `$yield-to` invokes the following function which loads a thread at
index `$i` from the current component instance's `threads` table, traps if it's
not [suspended], and then switches to that thread, leaving the [current thread]
ready to run at some nondeterministic point in the future chosen by the
embedder.
```python
def canon_thread_yield_to(cancellable, i):
  thread = current_thread()
  trap_if(not thread.task.inst.may_leave)
  other_thread = thread.task.inst.threads.get(i)
  trap_if(not other_thread.suspended())
  cancelled = thread.yield_to(cancellable, other_thread)
  return [cancelled]
```
If `cancellable` is set, then `thread.yield-to` will return a `Cancelled`
value indicating whether the supertask has already or concurrently requested
cancellation. `thread.yield-to` (and other cancellable operations) will only
indicate cancellation once and thus, if a caller is not prepared to propagate
cancellation, they can omit `cancellable` so that cancellation is instead
delivered at a later `cancellable` call.


### 🧵 `canon thread.yield`

For a canonical definition:
```wat
(canon thread.yield $cancellable? (core func $yield))
```
validation specifies:
* `$yield` is given type `(func (result i32))`

Calling `$yield` invokes the following function which yields execution so that
others threads can execute, leaving the current thread ready to run at some
nondeterministic point in the future chosen by the embedder. This allows a
long-running computation that is not otherwise performing I/O to avoid starving
other threads in a cooperative setting.
```python
def canon_thread_yield(cancellable):
  thread = current_thread()
  trap_if(not thread.task.inst.may_leave)
  cancelled = thread.yield_(cancellable)
  return [cancelled]
```
If a non-`async`-typed function export that has not yet returned a value
transitively calls `thread.yield`, it returns immediately without blocking
(instead of trapping, as with other possibly-blocking operations like
`waitable-set.wait`). This is because, unlike other built-ins, `thread.yield`
may be scattered liberally throughout code that might show up in the transitive
call tree of a synchronous function call.

If `cancellable` is set, then `thread.yield` will return a `Cancelled`
value indicating whether the supertask has already or concurrently requested
cancellation. `thread.yield` (and other cancellable operations) will only
indicate cancellation once and thus, if a caller is not prepared to propagate
cancellation, they can omit `cancellable` so that cancellation is instead
delivered at a later `cancellable` call.


### 📝 `canon error-context.new`

For a canonical definition:
```wat
(canon error-context.new $opts (core func $f))
```
validation specifies:
* `$f` is given type `(func (param $ptr T) (param $units T) (result i32))` where
  `T` is `i32`
  * 🐘 - `T` is `i32` or `i64` as determined by the `memory` field of `$opts`
* `async` is not present
* `memory` must be present

Calling `$f` calls the following function which uses the `$opts` immediate to
(nondeterministically) lift the debug message, create a new `ErrorContext`
value, store it in the current component instance's `handles` table and returns
its index.
```python
@dataclass
class ErrorContext:
  debug_message: String

def canon_error_context_new(opts, ptr, tagged_code_units):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  if DETERMINISTIC_PROFILE or random.randint(0,1):
    s = String(('', 'utf8', 0))
  else:
    cx = LiftLowerContext(opts, inst)
    s = load_string_from_range(cx, ptr, tagged_code_units)
    s = host_defined_transformation(s)
  i = inst.handles.add(ErrorContext(s))
  return [i]
```
Supporting the requirement (introduced in the
[explainer](Explainer.md#error-context-type)) that wasm code does not depend on
the contents of `error-context` values for behavioral correctness, the debug
message is completely discarded nondeterministically or, in the deterministic
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
* `$f` is given type `(func (param i32) (param $ptr T))` where `T` is `i32`
  * 🐘 - `T` is `i32` or `i64` as determined by the address type of
    `memory` from `$opts`
* `async` is not present
* `memory` must be present
* `realloc` must be present

Calling `$f` calls the following function which uses the `$opts` immediate to
lowers the `ErrorContext`'s debug message. While *producing* an `error-context`
value may nondeterministically discard or transform the debug message, a
single `error-context` value must return the same debug message from
`error.debug-message` over time.
```python
def canon_error_context_debug_message(opts, i, ptr):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  errctx = inst.handles.get(i)
  trap_if(not isinstance(errctx, ErrorContext))
  cx = LiftLowerContext(opts, inst)
  store_string(cx, errctx.debug_message, ptr)
  return []
```
Note that `ptr` points to a region of memory (8 bytes for memory32, 16 bytes
for memory64) into which will be stored the pointer and length of the debug
string (allocated via `opts.realloc`).


### 📝 `canon error-context.drop`

For a canonical definition:
```wat
(canon error-context.drop (core func $f))
```
validation specifies:
* `$f` is given type `(func (param i32))`

Calling `$f` calls the following function, which drops the error context value
at the given index from the current component instance's `handles` table:
```python
def canon_error_context_drop(i):
  inst = current_thread().task.inst
  trap_if(not inst.may_leave)
  errctx = inst.handles.remove(i)
  trap_if(not isinstance(errctx, ErrorContext))
  return []
```


### 🧵② `canon thread.spawn-ref`

For a canonical definition:
```wat
(canon thread.spawn-ref shared? $ft (core func $spawn_ref))
```
validation specifies:
* `$ft` must refer to the type `(shared? (func (param $c T)))` where `T` is `i32`
  * 🐘 - `T` may be `i32` or `i64`.
* `$spawn_ref` is given type
  `(shared? (func (param $f (ref null $ft)) (param $c T) (result $e i32)))`
  where `T` comes from `$ft` as defined above

When the `shared` immediate is not present, the spawned thread is
*cooperative*, only switching at specific program points. When the `shared`
immediate is present, the spawned thread is *preemptive* and able to execute in
parallel with all other threads.

> Note: ideally, a thread could be spawned with [arbitrary thread parameters].
> Currently, that would require additional work in the toolchain to support so,
> for simplicity, the current proposal simply fixes a single `i32` or `i64` parameter
> type. However, `thread.spawn-ref` could be extended to allow arbitrary thread
> parameters in the future, once it's concretely beneficial to the toolchain.
> The inclusion of `$ft` ensures backwards compatibility for when arbitrary
> parameters are allowed.

Calling `$spawn_ref` invokes the following function which simply fuses the
`thread.new_ref` and `thread.resume-later` built-ins, allowing
thread-creation to skip the intermediate "suspended" state transition.
```python
def canon_thread_spawn_ref(shared, ft, f, c):
  trap_if(not current_thread().task.inst.may_leave)
  if DETERMINISTIC_PROFILE:
    return [0]
  [new_thread_index] = canon_thread_new_ref(shared, ft, f, c)
  [] = canon_thread_resume_later(shared, new_thread_index)
  return [new_thread_index]
```
Note: `canon_thread_new_ref` has not yet been defined, but will be added as
part of adding a [GC ABI option] to the Canonical ABI and would work
like `canon_thread_new_indirect` minus the table access and type check.


### 🧵② `canon thread.spawn-indirect`

For a canonical definition:
```wat
(canon thread.spawn-indirect shared? $ft $tbl (core func $spawn_indirect))
```
validation specifies:
* `$ft` must refer to the type `(shared? (func (param $c T)))` where `T` is `i32`
  * 🐘 - `T` may be `i32` or `i64`
* `$tbl` must refer to a shared table whose element type matches
  `(ref null (shared? func))`
* `$spawn_indirect` is given type `(shared? (func (param $i U) (param $c T) (result $e i32)))`
  where `T` comes from `$ft` as defined above and `U` is `i32`
  * 🐘 - `U` is `i32` or `i64` as determined by `$tbl`'s address type

When the `shared` immediate is not present, the spawned thread is
*cooperative*, only switching at specific program points. When the `shared`
immediate is present, the spawned thread is *preemptive* and able to execute in
parallel with all other threads.

Calling `$spawn_indirect` invokes the following function which simply fuses
the `thread.new-indirect` and `thread.resume-later` built-ins, allowing
thread-creation to skip the intermediate "suspended" state transition.
```python
def canon_thread_spawn_indirect(shared, ft, ftbl: Table[CoreFuncRef], fi, c):
  trap_if(not current_thread().task.inst.may_leave)
  if DETERMINISTIC_PROFILE:
    return [0]
  [new_thread_index] = canon_thread_new_indirect(shared, ft, ftbl, fi, c)
  [] = canon_thread_resume_later(shared, new_thread_index)
  return [new_thread_index]
```
Note: `canon_thread_new_indirect` has not yet been extended to take a
`shared` parameter, but will be as [shared-everything-threads] progresses.


### 🧵② `canon thread.available-parallelism`

For a canonical definition:
```wat
(canon thread.available-parallelism shared? (core func $f))
```
validation specifies:
* `$f` is given type `(func shared? (result i32))`.

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
[Concurrency Explainer]: Concurrency.md
[Suspended]: Concurrency.md#thread-built-ins
[Thread Index]: Concurrency.md#thread-built-ins
[Async Call Stack]: Concurrency.md#subtasks-and-supertasks
[Structured Concurrency]: Concurrency.md#subtasks-and-supertasks
[Recursive Reentrance]: Concurrency.md#subtasks-and-supertasks
[Backpressure]: Concurrency.md#backpressure
[Thread]: Concurrency.md#threads-and-tasks
[Current Thread]: Concurrency.md#current-thread-and-task
[Current Task]: Concurrency.md#current-thread-and-task
[Blocks]: Concurrency.md#blocking
[Block]: Concurrency.md#blocking
[Waiting On External I/O And Yielding]: Concurrency.md#blocking
[Subtasks]: Concurrency.md#subtasks-and-supertasks
[Readable and Writable Ends]: Concurrency.md#streams-and-futures
[Readable or Writable End]: Concurrency.md#streams-and-futures
[Thread-Local Storage]: Concurrency.md#thread-local-storage
[Cancellation]: Concurrency.md#cancellation
[Subtask State Machine]: Concurrency.md#cancellation
[Stream Readiness]: Concurrency.md#stream-readiness

[Lazy Lowering]: https://github.com/WebAssembly/component-model/issues/383
[GC ABI Option]: https://github.com/WebAssembly/component-model/issues/525

[Core WebAssembly Embedding]: https://webassembly.github.io/spec/core/appendix/embedding.html
[`store_init`]: https://webassembly.github.io/spec/core/appendix/embedding.html#store
[`store`]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-store
[`func_invoke`]: https://webassembly.github.io/spec/core/appendix/embedding.html#functions
[`funcinst`]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-funcinst

[Administrative Instructions]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-instr-admin
[Implementation Limits]: https://webassembly.github.io/spec/core/appendix/implementation.html
[Function Instance]: https://webassembly.github.io/spec/core/exec/runtime.html#function-instances
[Two-level]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-import

[Multi-value]: https://github.com/WebAssembly/multi-value/blob/master/proposals/multi-value/Overview.md
[Exceptions]: https://github.com/WebAssembly/exception-handling/blob/main/proposals/exception-handling/Exceptions.md
[WASI]: https://github.com/webassembly/wasi
[Deterministic Profile]: https://github.com/WebAssembly/profiles/blob/main/proposals/profiles/Overview.md
[stack-switching]: https://github.com/WebAssembly/stack-switching
[Control Tags]: https://github.com/WebAssembly/stack-switching/blob/main/proposals/stack-switching/Explainer.md#declaring-control-tags
[`memaddr`]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-memaddr
[`memaddrs` table]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-moduleinst
[`memidx`]: https://webassembly.github.io/spec/core/syntax/modules.html#syntax-memidx
[`memory` instance]: https://webassembly.github.io/spec/core/exec/runtime.html#memory-instances
[`memtype`]: https://webassembly.github.io/spec/core/syntax/types.html#memory-types

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

[shared-everything-threads]: https://github.com/WebAssembly/shared-everything-threads
[Arbitrary Thread Parameters]: https://github.com/WebAssembly/shared-everything-threads/discussions/3

[`threading`]: https://docs.python.org/3/library/threading.html
[`threading.Thread`]: https://docs.python.org/3/library/threading.html#thread-objects
[`threading.Lock`]: https://docs.python.org/3/library/threading.html#lock-objects
[`threading.local`]: https://docs.python.org/3/library/threading.html#thread-local-data

[OIO]: https://en.wikipedia.org/wiki/Overlapped_I/O
[io_uring]: https://en.wikipedia.org/wiki/Io_uring
