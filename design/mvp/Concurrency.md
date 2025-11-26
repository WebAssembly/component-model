# Concurrency Explainer

This document contains a high-level summary of the native concurrency support
added as part of [WASI Preview 3], providing background for understanding the
definitions in the [WIT], [AST explainer], [binary format] and [Canonical ABI
explainer] documents that are gated by the 🔀 (async) and 🧵 (threading)
emojis. For an even higher-level introduction, see [these][wasmio-2024]
[presentations][wasmio-2025].

* [Goals](#goals)
* [Summary](#summary)
* [Concepts](#concepts)
  * [Threads and Tasks](#threads-and-tasks)
  * [Subtasks and Supertasks](#subtasks-and-supertasks)
  * [Current Thread and Task](#current-thread-and-task)
  * [Thread-Local Storage](#thread-local-storage)
  * [Streams and Futures](#streams-and-futures)
  * [Stream Readiness](#stream-readiness)
  * [Waiting](#waiting)
  * [Backpressure](#backpressure)
  * [Returning](#returning)
  * [Borrows](#borrows)
  * [Cancellation](#cancellation)
  * [Nondeterminism](#nondeterminism)
* [Interaction with the start function](#interaction-with-the-start-function)
* [Async ABI](#async-abi)
  * [Async Import ABI](#async-import-abi)
  * [Async Export ABI](#async-export-abi)
* [Examples](#examples)
* [TODO](#todo)


## Goals

Refining the Component Model's high-level [goals](../high-level/Goals.md) and
[use cases](../high-level/UseCases.md), [WASI Preview 3] adds the following
concurrency-specific goals and use cases:

* Integrate with idiomatic source-language concurrency features including:
  * `async` functions in languages like C#, JS, Python, Rust and Swift
  * coroutines in languages like Kotlin, Perl, PHP and (recently) C++
  * green threads scheduled by the language's own runtime in languages like Go
    and (initially and recently again) Java
  * host threads that are scheduled outside the language's own runtime in
    languages like C, C++, C#, Python, Rust and many more that expose pthreads
    or other OS threads
  * promises, futures, streams and channels
  * callbacks, in languages with no other built-in concurrency mechanisms
* Provide [fiber]-like stack-switching capabilities via Core WebAssembly
  import calls in a way that complements, but doesn't depend on, new Core
  WebAssembly proposals including [stack-switching] and
  [shared-everything-threads].
* Allow polyfilling in browsers via JavaScript Promise Integration ([JSPI])
* Avoid partitioning interfaces and components into separate ecosystems based
  on degree of concurrency; don't give functions or components a "[color]".
* Maintain meaningful cross-language call stacks (for the benefit of debugging,
  logging and tracing).
* Consider backpressure and cancellation as part of the design.
* Allow non-reentrant synchronous and event-loop-driven core wasm code that
  assumes a single global linear memory stack to not have to worry about
  additional reentrancy.


## Summary

To support the wide variety of language-level concurrency mechanisms listed
above, the Component Model defines a new low-level, language-agnostic async
calling convention (the "async ABI") for both calling into and calling out of
Core WebAssembly. Language compilers and runtimes can bind to this async ABI in
the same way that they already bind to various OS's concurrent I/O APIs (such
as `select`, `epoll`, `io_uring`, `kqueue` and Overlapped I/O) making the
Component Model "just another OS" from the language toolchain's perspective.

The new async ABI can be used alongside or instead of the existing Preview 2
"sync ABI" to call or implement *any* WIT function type, not just functions
with specific signatures. This allows *all* function types to be called or
implemented concurrently. When *calling* an imported function via the async
ABI, if the callee blocks, control flow is returned immediately to the caller,
and the callee resumes execution concurrently. When *implementing* an exported
function via the async ABI, multiple concurrent export calls are allowed to
be made by the caller. Critically, both sync-to-async and async-to-sync
pairings have well-defined, composable behavior for both inter-component and
intra-component calls, so that functions and components are not forced to pick
a "[color]".

Although Component Model function *types* are colorless, it can still be
beneficial, especially in languages with `async`/`await`-style concurrency, to
give the bindings generator a *hint* as to whether or not a particular function
declared in WIT should appear as an `async` function in the generated bindings
by default. Even in languages with colorless functions, developers and their
tools can still benefit from such a hint when determining whether they want to
call a particular imported function concurrently or not. To support these use
cases, functions in WIT can be annotated with an `async` hint. E.g.:
```wit
interface http-handler {
  use http-types.{request, response, error};
  handle: async func(r: request) -> result<response, error>;
}
```
Since `async` is just a hint, this `handle` function can be called using both
the sync and async ABIs. Bindings generators can even generate both variants
side-by-side, giving the developer the choice.

Each time a component export is called, the wasm runtime logically spawns a new
[green thread]  (as opposed to a [kernel thread]) to execute the export call
concurrently with other calls in the runtime. This means that [thread-local
storage](#thread-local-storage) is never reused between export calls and, in
general, a caller's thread's identity is never observable to the callee. In
some cases (such as when only sync ABI components are used) the runtime can
statically, as an optimization, make a plain synchronous function call with the
same wasm-observable behavior as-if it had created a new thread. But in
general, when one component makes an async call that transitively blocks in
another component, having the callee on its own native callstack is needed for
the runtime to be able to switch back to the caller without having to unwind
the stack.

In addition to the *implicit* threads logically created for export calls, Core
WebAssembly code can also *explicitly* create new green threads by calling the
[`thread.new-indirect`] built-in. Regardless of how they were created, all
threads can call a set of Component Model-defined `thread.*` built-in functions
(listed [below](#waiting)) to suspend themselves and/or resume other threads.
These built-ins provide sufficient functionality to implement both the
internally-scheduled "green thread" and the externally-scheduled "host thread"
use cases mentioned in the [goals](#goals).

Until the Core WebAssembly [shared-everything-threads] proposal allows Core
WebAssembly function types to be annotated with `shared`, `thread.new-indirect`
can only call non-`shared` functions (via `i32` `(table funcref)` index, just
like `call_indirect`) and thus currently all threads must execute
[cooperatively] in a sequentially-interleaved fashion, switching between
threads only at explicit program points just like (and implementable via) a
traditional OS [fiber]. While these **cooperative threads** do not allow a
single component instance to increase its internal parallelism, cooperative
threads are still quite useful for getting existing threaded code to Just Work
(as-if running on a single core) without the overhead of [CPS Transform]
techniques like [Asyncify] and without depending on [shared-everything-threads].
Moreover, in various embeddings, all available parallelism is already saturated
by running independent component instances on separate kernel threads.

Because new threads are (semantically, if not physically) created at all
cross-component call boundaries, the degree of `shared` and non-`shared` thread
use is kept an encapsulated implementation detail of a component (similar to
the choice of linear vs. GC memory). This enables component authors to
compatibly change their implementation strategy over time, starting simple and
adding complexity for performance as needed over time.

To provide wasm runtimes with additional optimization opportunities for
languages with "stackless" concurrency (e.g. languages using `async`/`await`),
two async ABI sub-options are provided: a "stackless" async ABI selected by
providing a `callback` function and a "stackful" async ABI selected by *not*
providing a `callback` function. The stackless async ABI allows core wasm to
repeatedly return to an event loop to receive events (delivered to the
`callback`), thereby clearing the native stack for the benefit of the wasm
runtime while waiting in the event loop.

To propagate backpressure, it's necessary for a component to be able to say
"there are too many concurrent export calls already in progress, don't start
any more until I let some of them complete". Thus, the Component Model provides
a built-in way for a component instance to apply and release backpressure that
callers must always be prepared to handle.

With this backpressure mechanism in place, there is a natural way for sync and
async code to interoperate:
1. If an async component calls a sync component and the sync component blocks,
   execution is immediately returned to the async component, effectively
   suspending the sync component.
2. If anyone tries to reenter the now-suspended sync component, the Component
   Model automatically signals backpressure on the suspended component's
   behalf.

Thus, backpressure combined with the partitioning of low-level state provided
by the Component Model enables sync and async code to interoperate while
preserving the expectations of both.

Lastly, WIT is extended with two new type constructors—`future<T>` and
`stream<T>`—to allow new WIT interfaces to explicitly represent concurrency in
*both* the sync and async ABIs in way that can be bound to many language's
idiomatic futures, promises, streams and channels. Futures and streams are,
semantically, unidirectional unbuffered channels with a dynamically-enforced
[session type] describing the passing of exactly 1 or 0..N values, resp., with
the additional ability for the reader end to signal a loss of interest
to the writer end. Thus, futures and streams are more primitive concepts than,
e.g., Unix pipes (which have an associated intermediate memory buffer that
values are copied into and out of). Rather, streams could be used to *define*
higher-level concepts like pipes, HTTP response bodies or stream transformers.
E.g.:
```wit
resource pipe {
  constructor(buffer-size: u32);
  write: func(bytes: stream<u8>) -> result;
  read: func() -> stream<u8>;
}
resource response {
  constructor(body: stream<u8>);
  consume-body: func() -> stream<u8>;
}
transform: func(in: stream<point>) -> stream<point>;
```
A `future` or `stream` in a function signature always refers to the transfer of
unique ownership of the *readable end* of the future or stream. To get a
*writable end*, a component must first internally create a (readable, writable)
end pair (via the [`{stream,future}.new`] built-ins) and then pass the readable
end elsewhere (e.g., in the above WIT, as a parameter to an imported
`pipe.write` or as a result of an exported `transform`). Given the readable or
writable end of a future or stream (represented as an `i32` index into the
component instance's handle table), Core WebAssembly can then call a
[`{stream,future}.{read,write}`] built-in to synchronously or asynchronously
copy into or out of a caller-provided buffer of Core WebAssembly linear (or,
soon, GC) memory.

## Concepts

The following concepts are defined as part of the Component Model's concurrency
support.

### Threads and Tasks

As described in the [summary](#summary), each call to a component export
logically creates a new ([green][green thread]) **thread** which, in many
cases, can be optimized away and replaced with a synchronous function call.
Each call to a component export also creates a new **task** that *contains*
this new thread. Whereas a *thread* contains a callstack and other execution
state, a *task* contains ABI bookkeeping state that is used to enforce the
Canonical ABI's rules for export calls. Tasks are themselves contained by the
component instance whose export was called. Thus, the overall containment
relationship is:
```
Component Store
  ↓ contains
Component Instance
  ↓ contains
Task
  ↓ contains
Thread
```
where a **component store** is the top-level "thing" and analogous to a Core
WebAssembly [store].

The reason for the thread/task split is that, when one thread creates a new
thread, the new thread is contained by the task of the original thread which
creates an N:1 relationship between threads and tasks that ties N threads to
the original export call (= "task") that transitively spawned those N threads.
This relationship serves several purposes described in the following sections.

In the Canonical ABI explainer, threads, tasks, component instances and
component stores are represented by the [`Thread`], [`Task`],
[`ComponentInstance`] and [`Store`] classes, resp.

### Subtasks and Supertasks

As mentioned above, calling a component export creates a task to track the
state used to enforce Canonical ABI rules that apply to the callee (an example
being: the number of received borrowed handles that still need to be dropped
before the call returns).

Symmetrically, calling a component *import* creates a **subtask** to track the
state used to enforce Canonical ABI rules that apply to the *caller* (an
example being: which handles have been lent that the caller can't drop until
the call resolves).

When one component calls another, there is thus a new task+subtask pair created
to ensure that both components uphold their end of the Canonical ABI rules. But
when the host calls a component export, there is only a task and,
symmetrically, when a component calls a host-defined import, there is only a
subtask. Thus, the **async call stack** at the point when a component calls a
host-defined import will have the general form:
```
[Host]
  ↓ host calls component export
[Component Task]
  ↓ component calls import implemented by another component's export 0..N times
[Component Subtask <> Component Task]*
  ↓ component calls import implemented by the host
[Component Subtask <> Host task]
```
Here, the `↓` arrow represents the **subtask** relationship (the dual of which
is the **supertask** relationship). Since a task+subtask pair have the same
supertask, they can be thought of as a single node in the async call stack.

A subtask/supertask relationship is immutably established when an import is
called, setting the [current task](#current-thread-and-task) as the supertask
of the new subtask created for the import call. Thus, one reason for
associating every thread with a "containing task" is to ensure that there is
always a well-defined async call stack.

A semantically-observable use of the async call stack is to distinguish between
hazardous **recursive reentrance**, in which a component instance is reentered
when one of its tasks is already on the callstack, from business-as-usual
**sibling reentrance**, in which a component instance is reentered for the
first time on a particular async call stack. Recursive reentrance currently
always traps, but will be allowed (and indicated to core wasm) in an opt-in
manner in the [future](#TODO).

The async call stack is also useful for non-semantic purposes such as providing
backtraces when debugging, profiling and tracing. While particular languages
can and do maintain their own async call stacks in core wasm state, without the
Component Model's async call stack, linkage *between* different languages would
be lost at component boundaries, leading to a loss of overall context in
multi-component applications.

There is an important gap between the Component Model's minimal form of
Structured Concurrency and the Structured Concurrency support that appears in
popular source language features/libraries. Often, "[Structured Concurrency]"
refers to an invariant that all "child tasks" finish or are cancelled before a
"parent task" completes. However, the Component Model doesn't force a subtask's
threads to all return before the supertask's threads all return. The reason for
not enforcing a stricter form of Structured Concurrency at the Component Model
level is that there are important use cases where forcing a supertask's thread
to stay resident just to wait for subtasks to finish would waste resources
without tangible benefit. Instead, we can say that once a supertask's last
thread finishes execution, the supertask semantically "tail calls" any still-
executing subtasks, staying technically-alive and on the async call stack until
they complete, but not consuming real resources.

For scenarios where one component wants to *non-cooperatively* put an upper
bound on execution of a call into another component, a separate "[blast zone]"
feature is necessary in any case (due to iloops and traps).

### Current Thread and Task

At any point in time while executing Core WebAssembly code or a [canonical
built-in] called by Core WebAssembly code, there is a well-defined **current
thread** whose containing task is the **current task**. The "current thread" is
modelled in the Canonical ABI's Python code by explicitly passing a [`Thread`]
object as an argument to all function calls so that the semantic "current
thread" is always the value of the `thread` parameter. Threads store their
containing task so that the "current task" is always `thread.task`.

### Thread-Local Storage

Each thread contains a distinct mutable **thread-local storage** array. The
current thread's thread-local storage can be read and written from core wasm
code by calling the [`context.get`] and [`context.set`] built-ins.

The thread-local storage array's length is currently fixed to contain exactly
2 `i32`s with the goal of allowing this array to be stored inline in whatever
existing runtime data structure is already efficiently reachable from ambient
compiled wasm code. Because module instantiation is declarative in the
Component Model, the imported `context.{get,set}` built-ins can be inlined by
the core wasm compiler as-if they were instructions, allowing the generated
machine code to be a single load or store. This makes thread-local storage a
natural place to store:
1. a pointer to the linear-memory "shadow stack" pointer
2. a pointer to a struct used by the runtime to implement the language's
   thread-local features

When threads are created explicitly by `thread.new-indirect`, the lifetime of
the thread-local storage array ends when the function passed to
`thread.new-indirect` returns and thus any linear-memory allocations associated
with the thread-local storage array should be eagerly freed by guest code right
before returning. Similarly, since each call to an export logically creates a
fresh thread, thread-local allocations can be eagerly released when this
implicit thread exits by returning from the exported function or, if the
stackless async ABI is used, returning the "exit" code to the event loop. This
non-reuse of thread-local storage between distinct export calls avoids what
would otherwise be a likely source of TLS-related memory leaks.

When [memory64] is integrated into the Component Model's Canonical ABI,
`context.{get,set}` will be backwards-compatibly relaxed to allow `i64`
pointers (overlaying the `i32` values like hardware 32/64-bit registers). When
[wasm-gc] is integrated, these integral context values can serve as indices
into guest-managed tables of typed GC references.

Since the same mutable thread-local storage cells are shared by all core wasm
running under the same thread in the same component, the cells' contents must
be carefully coordinated in the same way as native code has to carefully
coordinate native ISA state (e.g., the [FS or GS segment base address]). In the
common case, thread-local storage is only `context.set` by the entry trampoline
invoked by [`canon_lift`] and then all transitively reachable core wasm code
(including from any `callback`) assumes `context.get` returns the same value.
Thus, if any *non*-entry-trampoline code calls `context.set`, it is the
responsibility of *that code* to restore this default assumption before
allowing control flow to escape into the wild.

For more information, see [`context.get`] in the AST explainer.

### Streams and Futures

Streams and Futures have two "ends": a *readable end* and *writable end*. When
*consuming* a `stream` or `future` value as a parameter (of an export call with
a `stream` or `future` somewhere in the parameter types) or result (of an
import call with a `stream` or `future` somewhere in the result type), the
receiver always gets *unique ownership* of the *readable end* of the `stream`
or `future`. When *producing* a `stream` or `future` value as a parameter (of
an import call) or result (of an export call), the producer can *transfer
ownership* of a readable end that it has either been given by the outside world
or freshly created via `{stream,future}.new` (which also return a fresh paired
writable end that is permanently owned by the calling component instance).

Based on this, `stream<T>` and `future<T>` values can be passed between
functions as if they were synchronous `list<T>` and `T` values, resp. For
example, given `f` and `g` with types:
```wit
f: func(x: whatever) -> stream<T>;
g: func(s: stream<T>) -> stuff;
```
Given this, `g(f(x))` works as you might hope, concurrently streaming the
results of `f` into `g`.

Given the readable or writable end of a stream, core wasm code can call the
imported `stream.read` or `stream.write` canonical built-ins, resp., passing the
pointer and length of a linear-memory buffer to write-into or read-from, resp.
These built-ins can either return immediately if >0 elements were able to be
written or read immediately (without blocking) or return a sentinel "blocked"
value indicating that the read or write will execute concurrently. The readable
and writable ends of streams and futures can then be [waited](#waiting) on to
make progress. Notification of progress signals *completion* of a read or write
(i.e., the bytes have already been copied into the buffer). Additionally,
*readiness* (to perform a read or write in the future) can be queried and
signalled by performing a `0`-length read or write (see the [Stream State]
section in the Canonical ABI explainer for details).

As a temporary limitation, if a `read` and `write` for a single stream or
future occur from within the same component and the element type is non-empty,
there is a trap. In the future this limitation will be removed.

The `T` element type of streams and futures is optional, such that `future` and
`stream` can be written in WIT without a trailing `<T>`. In this case, the
asynchronous "values(s)" being delivered are effectively meaningless [unit]
values. However, the *timing* of delivery is meaningful and thus `future` and
`stream` can used to convey timing-related information. Note that, since
functions are asynchronous by default, a plain `f: func()` conveys completion
without requiring an explicit `future` return type. Thus, a function like
`f2: func() -> future` would convey *two* events: first, the return of `f2`, at
which point the caller receives the readable end of a `future` that, when
successfully read, conveys the completion of a second event.

The [Stream State] and [Future State] sections describe the runtime state
maintained for streams and futures by the Canonical ABI.

### Stream Readiness

When passed a non-zero-length buffer, the `stream.read` and `stream.write`
built-ins are "completion-based" (in the style of, e.g., [Overlapped I/O] or
[`io_uring`]) in that they complete only once one or more values have been
copied to or from the memory buffer passed in at the start of the operation.
In a Component Model context, completion-based I/O avoids intermediate copies
and enables a greater degree of concurrency in a number of cases and thus
language producer toolchains should attempt to pass non-zero-length buffers
whenever possible.

Given completion-based `stream.{read,write}` built-ins, "readiness-based" APIs
(in the style of, e.g., [`select`] or [`epoll`] used in combination with
[`O_NONBLOCK`]) can be implemented by passing an intermediate non-zero-length
memory buffer to `stream.{read,write}` and signalling "readiness" once the
operation completes. However, this approach incurs extra copying overhead. To
avoid this overhead in a best-effort manner, `stream.{read,write}` allow the
buffer length to be zero in which case "completion" of the operation is allowed
(but not required) to wait to complete until the other end is "ready". As the
"but not required" caveat suggests, after a zero-length `stream.{read,write}`
completes, there is *no* guarantee that a subsequent non-zero-length
`stream.{read,write}` call will succeed without blocking. This lack of
guarantee is due to practical externalities and because readiness may simply
not be possible to implement given certain underlying host APIs.

As an example, to implement `select()` and non-blocking `write()` in
[wasi-libc], the following implementation strategy could be used (a symmetric
scheme is also possible for `read()`):
* The libc-internal file descriptor table tracks whether there is currently a
  pending write and whether `select()` has indicated that this file descriptor
  is ready to write.
* When `select()` is called to wait for a stream-backed file descriptor to be
  writable:
  * `select()` starts a zero-length write if there is not already a pending
    write in progress and then [waits](#waiting) on the stream (along with the
    other `select()` arguments).
  * If the pending write completes, `select()` updates the file descriptor and
    returns that the file descriptor is ready.
* When `write()` is called for an `O_NONBLOCKING` file descriptor:
  * If there is already a pending `stream.write` for this file descriptor,
    `write()` immediately returns `EWOULDBLOCK`.
  * Otherwise:
    * `write()` calls `stream.write`, forwarding the caller's buffer.
    * If `stream.write` returns that it successfully copied some bytes without
      blocking, `write()` returns success.
    * Otherwise, to avoid blocking:
      * `write()` calls [`stream.cancel-write`] to regain ownership of the
        caller's buffer.
      * If `select()` has *not* indicated that this file descriptor is ready,
        `write()` starts a zero-length write and returns `EWOULDBLOCK`.
      * Otherwise, to avoid the potential infinite loop:
        * `write()` copies the contents of the caller's buffer into an
          internal buffer, starts a new `stream.write` to complete in the
          background using the internal buffer, and then returns success.
        * The above logic implicitly waits for this background `stream.write`
          to complete before the file descriptor is considered ready again.

The fallback path for when the zero-length write does not accurately signal
readiness resembles the buffering normally performed by the kernel for a
`write` syscall and reflects the fact that streams do not perform internal
buffering between the readable and writable ends.

### Waiting

When a component asynchronously lowers an import, it is explicitly requesting
that, if the import blocks, control flow be returned back to the calling thread
so that it can do something else. Similarly, if `stream.read` or `stream.write`
are called asynchronously and block, they return a "blocked" code so that the
caller can continue to make progress on other things. But eventually, a thread
will run out of other things to do and will need to wait for something else to
happen by **suspending** itself until something else happens.

The following three built-ins put threads into a suspended state:
* [`thread.new-indirect`]: create a new thread that is initially suspended
  and continue executing the current thread
* [`thread.switch-to`]: suspend the current thread and immediately resume a
  given thread
* [`thread.suspend`]: suspend the current thread and resume any transitive
  async caller on the stack

These built-ins enable "green thread" [use cases](#goals), allowing the
language's runtime (compiled to wasm) to deterministically control which thread
executes when.

The following three built-ins can additionally be called to
nondeterministically resume a thread at some point in the future (allowing the
embedder to use whatever scheduler heuristics based on, e.g., timing and
priority):

* [`thread.resume-later`]: resume a given thread at some point in the future
  and continue executing in the current thread
* [`thread.yield-to`]: immediately resume a given thread and resume the current
  thread at some point in the future
* [`thread.yield`]: immediately resume *some* (nondeterministically-selected)
  other thread and resume the current thread at some point in the future

These built-ins enable the "host thread" [use cases](#goals), allowing the
embedder to nondeterministically control which thread is resumed when. In
particular, [`pthread_create`] can be implemented using `thread.new-indirect`
and either `thread.resume-later` or `thread.yield-to` (thereby allowing the
pthreads implementation to choose whether to execute a new pthread eagerly or
not).

Additionally, a thread may need to wait for progress to be made on an async
subtask or stream/future read/write in progress. Subtasks and readable/writable
ends of streams/futures are collectively called **waitables** and can be put
into **waitable sets** which a thread can wait on. Waitable sets avoid the O(N)
cost of passing and examining a list of waitables every time a thread needs to
wait for progress in the same manner as, e.g., `epoll`.

In particular, the following built-ins allow building and using waitable sets:
* [`waitable-set.new`]: return a new empty waitable set
* [`waitable.join`]: add, move, or remove a given waitable to/from a given
  waitable set
* [`waitable-set.wait`]: suspend until one of the waitables in the given set
  has a pending event and then return that event
* [`waitable-set.poll`]: first `thread.yield` and, once resumed, if any of the
  waitables in the given set has a pending event, return that event; otherwise
  return a sentinel "none" value

Threads that are explicitly suspended (via `thread.new-indirect`,
`thread.switch-to` or `thread.suspend`) will stay suspended indefinitely until
explicitly resumed (via `thread.switch-to`, `thread.resume-later`,
`thread.yield-to`). Attempting to explicitly resume a thread that was *not*
explicitly suspended by one of these three built-ins traps. For example,
attempting to `thread.resume-later` a thread waiting on `waitable-set.wait` or
a synchronous import call will trap. Thus, language runtimes and compilers have
to be careful when using a mix of explicit and implicit suspension/resumption.

Lastly, when an async function is implemented using the `callback` suboption
(mentioned in the [summary](#summary)), instead of calling `wait`, `poll` or
`yield`, as an optimization, the `callback` function can *return* to wait in
the event loop, minimizing switching costs and freeing up the stack in the
interim.

### Backpressure

Once a component exports functions using the async ABI, multiple concurrent
export calls can start piling up, each consuming some of the component's finite
private resources (like linear memory), requiring the component to be able to
exert *backpressure* to allow some tasks to finish (and release private
resources) before admitting new async export calls. To do this, a component may
call the [`backpressure.inc`] built-in to increment a component-instance-wide
"backpressure" counter until resources are freed and then call
[`backpressure.dec`] to decrement the counter. When the backpressure counter is
greater than zero, new export calls immediately return in the "starting" state
without calling the component's Core WebAssembly code. By using a counter
instead of a boolean flag, unrelated pieces of code can report backpressure for
distinct limited resources without prior coordination.

In addition to *explicit* backpressure set by wasm code, there is also an
*implicit* source of backpressure used to protect non-reentrant core wasm code.
In particular, when an export uses the sync ABI or the stackless async ABI, a
component-instance-wide lock is implicitly acquired every time core wasm is
executed. By returning to the event loop after every event (instead of once at
the end of the task), stackless async exports release the lock between every
event, allowing a higher degree of concurrency than synchronous exports.
Stackfull async exports ignore the lock entirely and thus achieve the highest
degree of (cooperative) concurrency.

Once a task is allowed to start according to these backpressure rules, its
arguments are lowered into the callee's linear memory and the task is in
the "started" state.

### Returning

The way an async export call returns its value is by calling [`task.return`],
passing the core values that are to be lifted as *parameters*.

Returning values by calling `task.return` allows a task to continue executing
even after it has passed its initial results to the caller. This can be useful
for various finalization tasks (freeing memory or performing logging, billing
or metrics operations) that don't need to be on the critical path of returning
a value to the caller, but the major use of executing code after `task.return`
is to continue to read and write from streams and futures. For example, a
stream transformer function of type `func(in: stream<T>) -> stream<U>` will
immediately `task.return` a stream created via `stream.new` and then sit in a
loop interleaving `stream.read`s (of the readable end passed for `in`) and
`stream.write`s (of the writable end it `stream.new`ed) before exiting the
task.

*Any* of the threads contained by a task can call `task.return`; there is no
"main thread" of a task. When the last thread of a task returns, there is a
trap if `task.return` has not been called. Thus, *some* thread (either the
thread created implicitly for the initial export call or some thread
transitively created by that thread) must call `task.return`.

Once `task.return` is called, the task is in the "returned" state. Calling
`task.return` when not in the "started" state traps.

### Borrows

Component Model async support is careful to ensure that `borrow`ed handles work
as expected in an asynchronous setting, extending the dynamic enforcement used
for synchronous code:

When a caller initially lends an `own`ed or `borrow`ed handle to a callee, a
`num_lends` counter on the lent handle is incremented when the subtask starts
and decremented when the caller is notified that the subtask has
[returned](#returning). If the caller tries to drop a handle while the handle's
`num_lends` is greater than zero, the caller traps. Symmetrically, each
`borrow` handle passed to a callee increments a `num_borrows` counter on the
callee task that is decremented when the `borrow` handle is dropped. If a
callee task attempts to return when its `num_borrows` is greater than zero, the
callee traps.

In an asynchronous setting, since there can be multiple overlapping async tasks
executing in a component instance, a borrowed handle must track *which* task's
`num_borrow`s was incremented so that the correct counter can be decremented
and there is a trap upon `task.return` if `num_borrows` is nonzero.

### Cancellation

Once an async call has started, blocked and been added to the caller's table,
the caller may decide that it no longer needs the results or effects of the
subtask. In this case, the caller may **cancel** the subtask by calling the
[`subtask.cancel`] built-in.

Once cancellation is requested, since the subtask may have already racily
returned a value, the caller may still receive a return value. However, the
caller may also be notified that the subtask is in one of two additional
terminal states:
* the subtask was **cancelled before it started**, in which case the caller's
  arguments were not passed to the callee (in particular, owned handles were
  not transferred); or
* the subtask was **cancelled before it returned**, in which case the arguments
  were passed, but no values were returned. However, all borrowed handles lent
  during the call have been dropped.

Thus there are *three* terminal states for a subtask: returned,
cancelled-before-started and cancelled-before-returned. A subtask in one of
these terminal states is said to be **resolved**. A resolved subtask has always
dropped all the borrowed handles that it was lent during the call.

Cancellation is *cooperative*, delivering the request for cancellation to one
of the subtask's threads and then allowing the subtask to continue executing
for an arbitrary amount of time (calling imports, performing I/O and everything
else) until the subtask decides to call [`task.cancel`] to confirm the
cancellation or, for whatever reason, call `task.return` as-if there had been
no cancellation. `task.cancel` enforces the same "all borrowed handles dropped"
rule as `task.return`, so that once a subtask is resolved, the caller knows its
lent handles have been returned. If the subtask was waiting to start due to
backpressure, the subtask is immediately aborted without running the callee at
all.

When `subtask.cancel` is called, it will attempt to immediately resume one of
the subtask's threads which is in a cancellable state, passing it a sentinel
"cancelled" value. A thread is in a "cancellable" state if it calls one of the
[waiting](#waiting) built-ins with the `cancellable` immediate set (indicating
that the caller expects and propagates cancellation appropriately) or, if using
a `callback`, returns to the event loop (which always waits cancellably). If a
subtask has no cancellable threads, no thread is resumed and the request for
cancellation is remembered in the task state, to be delivered immediately at
the next cancellable wait. In the worst case, though, a component may never
wait cancellably and thus cancellation may be silently ignored.

`subtask.cancel` can be called synchronously or asynchronously. If called
synchronously, `subtask.cancel` waits until the subtask reaches a resolved
state and returns which state was reached. If called asynchronously, then if a
cancellable subtask thread is resumed *and* the subtask reaches a resolved
state before suspending itself for whatever reason `subtask.cancel` will return
which state was reached. Otherwise, `subtask.cancel` will return a "blocked"
sentinel value and the caller must [wait][waiting] via waitable set until the
subtask reaches a resolved state.

The Component Model does not provide a mechanism to force prompt termination of
threads as this can lead to leaks and corrupt state in a still-live component
instance. In the future, prompt termination could be added as part of a "[blast
zone]" feature that promptly destroys whole component instances, automatically
dropping all handles held by the destroyed instance, thereby avoiding the leak
and corruption hazards.

### Nondeterminism

Component Model concurrency support necessarily introduces a degree of
nondeterminism. However, until Core WebAssembly adds
[shared-everything-threads], Component Model concurrency is [cooperative],
which means that nondeterministic behavior can only be observed at well-defined
points in the program. Once [shared-everything-threads] is added,
WebAssembly's full [weak memory model] will be observable, but only within
components that use the new `shared` attribute on functions.

One inherent source of potential nondeterminism that is independent of the
Component Model is the behavior of host-defined import and export calls.
Component Model concurrency extends this host-dependent nondeterminism to the
behavior of the `read` and `write` built-ins called on `stream`s and `future`s
that have been passed to and from the host. However, just as with import and
export calls, it is possible for a host to define a deterministic ordering of
`stream` and `future` `read` and `write` behavior such that overall component
execution is deterministic.

In addition to the inherent host-dependent nondeterminism, the Component Model
adds several internal sources of nondeterministic behavior that are described
next. However, each of these sources of nondeterminism can be removed by a host
implementing the WebAssembly [Deterministic Profile], maintaining the ability for
a host to provide spec-defined deterministic component execution for components.

The following sources of nondeterminism arise via internal built-in operations
defined by the Component Model:
* If there are multiple waitables with a pending event in a waitable set that
  is being waited on or polled, there is a nondeterministic choice of which
  waitable's event is delivered first.
* If multiple threads wait on or poll the same waitable set at the same time,
  the distribution of events to threads is nondeterministic.
* Whenever a thread yields or waits on (or polls) a waitable set with an already
  pending event, whether the thread suspends and transfers execution to an
  async caller is nondeterministic.
* If multiple threads that previously suspended can be resumed at the same
  time, the order in which they are resumed is nondeterministic.
* If multiple tasks are blocked by backpressure and the backpressure is
  disabled, the order in which these pending tasks start, along with how
  they interleave with new tasks, is nondeterministic.
* If a task containing multiple threads is cancelled, the choice of which
  thread receives the request for cancellation is nondeterministic.

Despite the above, the following scenarios do behave deterministically:
* If a component `a` asynchronously calls the export of another component `b`,
  control flow deterministically transfers to `b` and then back to `a` when
  `b` returns or suspends.
* If a component `a` asynchronously cancels a subtask in another component `b`,
  control flow deterministically transfers to `b` and then back to `a` when `b`
  resolves or suspends.
* If a component `a` asynchronously cancels a subtask in another component `b`
  that was blocked before starting due to backpressure, cancellation completes
  deterministically and immediately.
* When both ends of a stream or future are owned by wasm components, the
  behavior of all read, write, cancel and drop operations is deterministic
  (modulo any nondeterminitic execution that determines the ordering in which
  the operations are performed).


## Interaction with the start function

Since any component-level function with an empty signature can be used as a
[`start`] function, there's nothing to stop an `async`-lifted function from
being used as a `start` function. Async start functions are useful when
executing general-purpose code at initialization time, e.g.:
* If the top-level scripts of a scripting language are executed by the `start`
  function, asychrony arises from regular use of the language's concurrency
  features. For example, in JS, this takes the form of [top-level `await`].
* If C++ or other OOPLs global object constructors are executed by the `start`
  function, these can execute general-purpose code which may use concurrent
  I/O APIs.

Since component `start` functions are already defined to be executed
synchronously before the component is considered initialized and ready for its
exports to be called, the natural thing for `start` to do when calling an
`async`-lifted function is wait for the callee to reach the ["returned"
state](#returning). This gives `async` `start` functions a simple way to do
concurrent initialization and signal completion using the same language
bindings as regular `async` `export` functions.

However, as explained above, an async task can always continue executing after
reaching the "returned" state and thus an async task spawned by `start` may
continue executing even after the component instance is initialized and
receiving export calls. These post-return `start`-tasks can be used by the
language toolchain to implement traditional "background tasks" (e.g., the
`setInterval()` or `requestIdleCallback()` JavaScript APIs). From the
perspective of [structured concurrency], these background tasks are new task
tree roots (siblings to the roots created when component exports are
called by the host). Thus, subtasks and threads spawned by the background task
will have proper async callstacks as used to define reentrancy and support
debugging/profiling/tracing.

In future, when [runtime instantiation] is added to the Component Model, the
component-level function used to create a component instance could be lowered
with `async` to allow a parent component to instantiate child components
concurrently, relaxing the fully synchronous model of instantiation supported
by declarative instantiation and `start` above.


## Async ABI

At an ABI level, native async in the Component Model defines for every WIT
function an async-oriented core function signature that can be used instead of
or in addition to the existing (Preview-2-defined) synchronous core function
signature. This async-oriented core function signature is intended to be called
or implemented by generated bindings which then map the low-level core async
protocol to the languages' higher-level native concurrency features. Because
the WIT-level `async` attribute is purely a *hint* (as mentioned
[above](#summary)), *every* WIT function has an async core function signature;
`async` just provides hints to the bindings generator for which to use by
default.

### Async Import ABI

Given these imported WIT functions (using the fixed-length-list feature 🔧):
```wit
world w {
  import foo: func(s: string) -> u32;
  import bar: func(s: string) -> string;
  import baz: func(t: list<u64; 5>) -> string;
  import quux: func(t: list<u32; 17>) -> string;
}
```
the default/synchronous lowered import function signatures are:
```wat
;; sync
(func $foo (param $s-ptr i32) (param $s-len i32) (result i32))
(func $bar (param $s-ptr i32) (param $s-len i32) (param $out-ptr i32))
(func $baz (param i64 i64 i64 i64 i64) (param $out-ptr i32))
(func $quux (param $in-ptr i32) (param $out-ptr i32))
```
Here: `foo`, `bar` and `baz` pass their parameters as "flattened" core value
types while `quux` passes its parameters via the `$in-ptr` linear memory
pointer (due to the Canonical ABI limitation of 16 maximum flattened
parameters). Similarly, `foo` returns its result as a single core value while
`bar`, `baz` and `quux` return their results via the `$out-ptr` linear memory
pointer (due to the current Canonical ABI limitation of 1 maximum flattened
result).

The corresponding asynchronous lowered import function signatures are:
```wat
;; async
(func $foo (param $s-ptr i32) (param $s-len i32) (param $out-ptr i32) (result i32))
(func $bar (param $s-ptr i32) (param $s-len i32) (param $out-ptr i32) (result i32))
(func $baz (param $in-ptr i32) (param $out-ptr i32) (result i32))
(func $quux (param $in-ptr i32) (param $out-ptr i32) (result i32))
```
Comparing signatures, the differences are:
* Async-lowered functions have a maximum of 4 flat parameters (not 16).
* Async-lowered functions always return their value via linear memory pointer.
* Async-lowered functions always have a single `i32` "status" code.

Additionally, *when* the parameter and result pointers are read/written depends
on the status code:
* If the low 4 bits of the status are `0`, the call didn't even start and so
  `$in-ptr` hasn't been read and `$out-ptr` hasn't been written and the high
  28 bits are the index of a new async subtask to wait on.
* If the low 4 bits of the status are `1`, the call started, `$in-ptr` was
  read, but `$out-ptr` hasn't been written and the high 28 bits are the index
  of a new async subtask to wait on.
* If the low 4 bits of the status are `2`, the call returned and so `$in-ptr`
  and `$out-ptr` have been read/written and the high 28 bits are `0` because
  there is no async subtask to wait on.

When a parameter/result pointer hasn't yet been read/written, the async caller
must take care to keep the region of memory allocated to the call until
receiving an event indicating that the async subtask has started/returned.

Other example asynchronous lowered signatures:

| WIT function type                         | Async ABI             |
| ----------------------------------------- | --------------------- |
| `func()`                                  | `(func (result i32))` |
| `func() -> string`                        | `(func (param $out-ptr i32) (result i32))` |
| `func(x: f32) -> f32`                     | `(func (param $x f32) (param $out-ptr i32) (result i32))` |
| `func(s: string, t: string)`              | `(func (param $s-ptr i32) (param $s-len i32) (result $t-ptr i32) (param $t-len i32) (result i32))` |

`future` and `stream` can appear anywhere in the parameter or result types. For example:
```wit
func(s1: stream<future<string>>, s2: list<stream<string>>) -> result<stream<string>, stream<error>>
```
In *both* the sync and async ABIs, a `future` or `stream` in the WIT-level type
translates to a single `i32` in the ABI.  This `i32` is an index into the
current component instance's handle table. For example, for the WIT function type:
```wit
func(f: future<string>) -> future<u32>
```
the synchronous ABI has signature:
```wat
(func (param $f i32) (result i32))
```
and the asynchronous ABI has the signature:
```wat
(func (param $f i32) (param $out-ptr i32) (result i32))
```
where `$f` is the index of a future (not a pointer to one) while while
`$out-ptr` is a pointer to a linear memory location that will receive an `i32`
index.

For the runtime semantics of this `i32` index, see `lift_stream`,
`lift_future`, `lower_stream` and `lower_future` in the [Canonical ABI
Explainer]. For a complete description of how async imports work, see
[`canon_lower`] in the Canonical ABI Explainer.


#### Async Export ABI

Given an exported WIT function:
```wit
world w {
  export foo: func(s: string) -> string;
}
```

The default sync export function signature for export `foo` is:
```wat
;; sync
(func (param $s-ptr i32) (param $s-len i32) (result $retp i32))
```
where (working around the continued lack of multi-return support throughout
the core wasm toolchain) `$retp` must be a 4-byte-aligned pointer into linear
memory from which the 8-byte (pointer, length) of the string result can be
loaded.

The async export ABI provides two flavors: stackful and stackless.

##### Stackful Async Exports

The stackful ABI is currently gated by the 🚟 feature.

The async stackful export function signature for export `foo` (defined above
in world `w`) is:
```wat
;; async, no callback
(func (param $s-ptr i32) (param $s-len i32))
```

The parameters work just like synchronous parameters.

There is no core function result because a callee [returns](#returning) their
value by *calling* the *imported* `task.return` function which has signature:
```wat
;; task.return
(func (param $ret-ptr i32) (param $ret-len i32))
```

The parameters of `task.return` work the same as if the WIT return type was the
WIT parameter type of a synchronous function. For example, if more than 16
core parameters would be needed, a single `i32` pointer into linear memory is
used.

##### Stackless Async Exports

The async stackless export function signature for export `foo` (defined above
in world `w`) is:
```wat
;; async, callback
(func (param $s-ptr i32) (param $s-len i32) (result i32))
```

The parameters also work just like synchronous parameters. The callee returns
their value by calling `task.return` just like the stackful case.

The `(result i32)` lets the core function return what it wants the runtime to do next:
* If the low 4 bits are `0`, the callee completed (and called `task.return`)
  without blocking.
* If the low 4 bits are `1`, the callee wants to yield, allowing other code
  to run, but resuming thereafter without waiting on anything else.
* If the low 4 bits are `2`, the callee wants to wait for an event to occur in
  the waitable set whose index is stored in the high 28 bits.
* If the low 4 bits are `3`, the callee wants to poll for any events that have
  occurred in the waitable set whose index is stored in the high 28 bits.

When an async stackless function is exported, a companion "callback" function
must also be exported with signature:
```wat
(func (param i32 i32 i32) (result i32))
```

The `(result i32)` has the same interpretation as the stackless export function
and the runtime will repeatedly call the callback until a value of `0` is
returned. The `i32` parameters describe what happened that caused the callback
to be called again.

For a complete description of how async exports work, see [`canon_lift`] in the
Canonical ABI Explainer.


## Examples

For a list of working examples expressed as executable WebAssembly Test (WAST)
files, see [this directory](../../test/async).

This rest of this section sketches the shape of a component that uses `async`
to lift and lower its imports and exports with both the stackful and stackless
ABI options.

### Stackful ABI example

Starting with the stackful ABI, the meat of this example component is replaced
with `...` to focus on the overall flow of function calls:
```wat
(component
  (import "fetch" (func $fetch (param "url" string) (result (list u8))))
  (core module $Libc
    (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) ...)
    ...
  )
  (core module $Main
    (import "" "mem" (memory 1))
    (import "" "realloc" (func (param i32 i32 i32 i32) (result i32)))
    (import "" "fetch" (func $fetch (param i32 i32 i32) (result i32)))
    (import "" "waitable-set.new" (func $new_waitable_set (result i32)))
    (import "" "waitable-set.wait" (func $wait (param i32 i32) (result i32)))
    (import "" "waitable.join" (func $join (param i32 i32)))
    (import "" "task.return" (func $task_return (param i32 i32)))
    (global $wsi (mut i32))
    (func $start
      (global.set $wsi (call $new_waitable_set))
    )
    (start $start)
    (func (export "summarize") (param i32 i32)
      ...
      loop
        ...
        call $fetch      ;; pass a string pointer, string length and pointer-to-list-of-bytes outparam
        ...              ;; ... and receive the index of a new async subtask
        global.get $wsi
        call $join       ;; ... and add it to the waitable set
        ...
      end
      loop               ;; loop as long as there are any subtasks
        ...
        global.get $wsi
        call $wait       ;; wait for a subtask in the waitable set to make progress
        ...
      end
      ...
      call $task_return  ;; return the string result (pointer,length)
      ...
    )
  )
  (core instance $libc (instantiate $Libc))
  (alias $libc "mem" (core memory $mem))
  (alias $libc "realloc" (core func $realloc))
  ;; requires 🚟 for the stackful abi
  (canon lower $fetch async (memory $mem) (realloc $realloc) (core func $fetch'))
  (canon waitable-set.new (core func $new))
  (canon waitable-set.wait async (memory $mem) (core func $wait))
  (canon waitable.join (core func $join))
  (canon task.return (result string) (memory $mem) (core func $task_return))
  (core instance $main (instantiate $Main (with "" (instance
    (export "mem" (memory $mem))
    (export "realloc" (func $realloc))
    (export "fetch" (func $fetch'))
    (export "waitable-set.new" (func $new))
    (export "waitable-set.wait" (func $wait))
    (export "waitable.join" (func $join))
    (export "task.return" (func $task_return))
  ))))
  (canon lift (core func $main "summarize")
    async (memory $mem) (realloc $realloc)
    (func $summarize (param "urls" (list string)) (result string)))
  (export "summarize" (func $summarize))
)
```
Because the imported `fetch` function is `canon lower`ed with `async`, its core
function type (shown in the first import of `$Main`) takes pointers to the
parameter and results (which are asynchronously read-from and written-to) and
returns the index of a new subtask. `summarize` calls `waitable-set.wait`
repeatedly until all `fetch` subtasks have finished, noting that
`waitable-set.wait` can return intermediate progress (as subtasks transition
from "starting" to "started" to "returned") which tell the surrounding core
wasm code that it can reclaim the memory passed arguments or use the results
that have now been written to the outparam memory.

Because the `summarize` function is `canon lift`ed with `async`, its core
function type has no results; results are passed out via `task.return`. It also
means that multiple `summarize` calls can be active at once: once the first
call to `waitable-set.wait` blocks, the runtime will suspend its callstack
(fiber) and start a new stack for the new call to `summarize`. Thus,
`summarize` must be careful to allocate a separate linear-memory stack in its
entry point and store it in context-local storage (via `context.set`) instead
of simply using a `global`, as in a synchronous function.

### Stackless ABI example

The stackful example can be re-written to use the `callback` immediate (thereby
avoiding the need for fibers) as follows.

Note that the internal structure of this component is almost the same as the
previous one (other than that `summarize` is now lifted from *two* core wasm
functions instead of one) and the public signature of this component is
the exact same.

Thus, the difference is just about whether the stack is cleared by the
core wasm code between events, not externally-visible behavior.

```wat
(component
  (import "fetch" (func $fetch (param "url" string) (result (list u8))))
  (core module $Libc
    (memory (export "mem") 1)
    (func (export "realloc") (param i32 i32 i32 i32) (result i32) ...)
    ...
  )
  (core module $Main
    (import "libc" "mem" (memory 1))
    (import "libc" "realloc" (func (param i32 i32 i32 i32) (result i32)))
    (import "" "fetch" (func $fetch (param i32 i32 i32) (result i32)))
    (import "" "waitable-set.new" (func $new_waitable_set (result i32)))
    (import "" "waitable.join" (func $join (param i32 i32)))
    (import "" "task.return" (func $task_return (param i32 i32)))
    (global $wsi (mut i32))
    (func $start
      (global.set $wsi (call $new_waitable_set))
    )
    (start $start)
    (func (export "summarize") (param i32 i32) (result i32)
      ...
      loop
        ...
        call $fetch           ;; pass a string pointer, string length and pointer-to-list-of-bytes outparam
        ...                   ;; ... and receive the index of a new async subtask
        global.get $wsi
        call $join            ;; ... and add it to the waitable set
        ...
      end
      (i32.or                 ;; return (WAIT | ($wsi << 4))
        (i32.const 2)         ;; 2 -> WAIT
        (i32.shl
          (global.get $wsi)
          (i32.const 4)))
    )
    (func (export "cb") (param $event i32) (param $p1 i32) (param $p2 i32)
      ...
      if (result i32)         ;; if subtasks remain:
        (i32.or               ;; return (WAIT | ($wsi << 4))
          (i32.const 2)
          (i32.shl
            (global.get $wsi)
            (i32.const 4)))
      else                    ;; if no subtasks remain:
        ...
        call $task_return     ;; return the string result (pointer,length)
        ...
        i32.const 0           ;; return EXIT
      end
    )
  )
  (core instance $libc (instantiate $Libc))
  (alias $libc "mem" (core memory $mem))
  (alias $libc "realloc" (core func $realloc))
  (canon lower $fetch async (memory $mem) (realloc $realloc) (core func $fetch'))
  (canon waitable-set.new (core func $new))
  (canon waitable.join (core func $join))
  (canon task.return (result string) async (memory $mem) (realloc $realloc) (core func $task_return))
  (core instance $main (instantiate $Main (with "" (instance
    (export "mem" (memory $mem))
    (export "realloc" (func $realloc))
    (export "fetch" (func $fetch'))
    (export "waitable-set.new" (func $new))
    (export "waitable.join" (func $join))
    (export "task.return" (func $task_return))
  ))))
  (canon lift (core func $main "summarize")
    async (callback (core func $main "cb")) (memory $mem) (realloc $realloc)
    (func $summarize (param "urls" (list string)) (result string)))
  (export "summarize" (func $summarize))
)
```
For an explanation of the bitpacking of the `i32` callback return value,
see [`unpack_callback_result`] in the Canonical ABI explainer.

While this example spawns all the subtasks in the initial call to `summarize`,
subtasks can also be spawned from `cb` (even after the call to `task.return`).
It's also possible for `summarize` to call `task.return` called eagerly in the
initial core `summarize` call.

The `$event`, `$p1` and `$p2` parameters passed to `cb` are the same as the
return values from `task.wait` in the previous example. The precise meaning of
these values is defined by the Canonical ABI.


## TODO

Native async support is being proposed incrementally. The following features
will be added in future chunks roughly in the order listed to complete the full
"async" story, with a TBD cutoff between what's in [WASI Preview 3] and what
comes after:
* remove the temporary trap mentioned above that occurs when a `read` and
  `write` of a stream/future happen from within the same component instance
* zero-copy forwarding/splicing
* some way to say "no more elements are coming for a while"
* `recursive` function type attribute: allow a function to opt in to
  recursive [reentrance], extending the ABI to link the inner and
  outer activations
* add a `strict-callback` option that adds extra trapping conditions to
  provide the semantic guarantees needed for engines to statically avoid
  fiber creation at component-to-component `async` call boundaries
* add `stringstream` specialization of `stream<char>` (just like `string` is
  a specialization of `list<char>`)
* allow pipelining multiple `stream.read`/`write` calls
* allow chaining multiple async calls together ("promise pipelining")
* integrate with `shared`: define how to lift and lower functions `async` *and*
  `shared`


[wasmio-2024]: https://www.youtube.com/watch?v=y3x4-nQeXxc
[wasmio-2025]: https://www.youtube.com/watch?v=mkkYNw8gTQg

[Color]: https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/
[Weak Memory Model]: https://people.mpi-sws.org/~rossberg/papers/Watt,%20Rossberg,%20Pichon-Pharabod%20-%20Weakening%20WebAssembly%20[Extended].pdf

[Fiber]: https://en.wikipedia.org/wiki/Fiber_(computer_science)
[CPS Transform]: https://en.wikipedia.org/wiki/Continuation-passing_style
[Asyncify]: https://emscripten.org/docs/porting/asyncify.html
[Session Types]: https://en.wikipedia.org/wiki/Session_type
[Structured Concurrency]: https://en.wikipedia.org/wiki/Structured_concurrency
[Unit]: https://en.wikipedia.org/wiki/Unit_type
[FS or GS Segment Base Address]: https://docs.kernel.org/arch/x86/x86_64/fsgs.html
[Green Thread]: https://en.wikipedia.org/wiki/Green_thread
[Kernel Thread]: https://en.wikipedia.org/wiki/Thread_(computing)#kernel_thread
[Cooperative]: https://en.wikipedia.org/wiki/Cooperative_multitasking
[Cooperatively]: https://en.wikipedia.org/wiki/Cooperative_multitasking
[Multithreading]: https://en.wikipedia.org/wiki/Multithreading_(computer_architecture)
[Overlapped I/O]: https://en.wikipedia.org/wiki/Overlapped_I/O
[`io_uring`]: https://en.wikipedia.org/wiki/Io_uring
[`epoll`]: https://en.wikipedia.org/wiki/Epoll

[`select`]: https://pubs.opengroup.org/onlinepubs/007908799/xsh/select.html
[`O_NONBLOCK`]: https://pubs.opengroup.org/onlinepubs/7908799/xsh/open.html
[`pthread_create`]: https://pubs.opengroup.org/onlinepubs/7908799/xsh/pthread_create.html

[AST Explainer]: Explainer.md
[Canonical Built-in]: Explainer.md#canonical-built-ins
[`context.get`]: Explainer.md#-contextget
[`context.set`]: Explainer.md#-contextset
[`backpressure.inc`]: Explainer.md#-backpressureinc-and-backpressuredec
[`backpressure.dec`]: Explainer.md#-backpressureinc-and-backpressuredec
[`task.return`]: Explainer.md#-taskreturn
[`task.cancel`]: Explainer.md#-taskcancel
[`subtask.cancel`]: Explainer.md#-subtaskcancel
[`waitable-set.new`]: Explainer.md#-waitable-setnew
[`waitable-set.wait`]: Explainer.md#-waitable-setwait
[`waitable-set.poll`]: Explainer.md#-waitable-setpoll
[`waitable.join`]: Explainer.md#-waitablejoin
[`thread.new-indirect`]: Explainer.md#-threadnew-indirect
[`thread.index`]: Explainer.md#-threadindex
[`thread.suspend`]: Explainer.md#-threadsuspend
[`thread.switch-to`]: Explainer.md#-threadswitch-to
[`thread.resume-later`]: Explainer.md#-threadresume-later
[`thread.yield-to`]: Explainer.md#-threadyield-to
[`thread.yield`]: Explainer.md#-threadyield
[`{stream,future}.new`]: Explainer.md#-streamnew-and-futurenew
[`{stream,future}.{read,write}`]: Explainer.md#-streamread-and-streamwrite
[`stream.cancel-write`]: Explainer.md#-streamcancel-read-streamcancel-write-futurecancel-read-and-futurecancel-write

[Canonical ABI Explainer]: CanonicalABI.md
[`canon_lift`]: CanonicalABI.md#canon-lift
[`unpack_callback_result`]: CanonicalABI.md#canon-lift
[`canon_lower`]: CanonicalABI.md#canon-lower
[`Store`]: CanonicalABI.md#embedding
[`ComponentInstance`]: CanonicalABI.md#component-instance-state
[`Thread`]: CanonicalABI.md#thread-state
[`Task`]: CanonicalABI.md#task-state
[Stream State]: CanonicalABI.md#stream-state
[Future State]: CanonicalABI.md#future-state

[Binary Format]: Binary.md
[WIT]: WIT.md
[Blast Zone]: FutureFeatures.md#blast-zones
[Reentrance]: Explainer.md#component-invariants
[`start`]: Explainer.md#start-definitions

[Store]: https://webassembly.github.io/spec/core/exec/runtime.html#syntax-store
[Deterministic Profile]: https://webassembly.github.io/spec/versions/core/WebAssembly-3.0-draft.pdf#subsubsection*.798

[stack-switching]: https://github.com/WebAssembly/stack-switching/
[JSPI]: https://github.com/WebAssembly/js-promise-integration/
[shared-everything-threads]: https://github.com/webAssembly/shared-everything-threads
[memory64]: https://github.com/webAssembly/memory64
[wasm-gc]: https://github.com/WebAssembly/gc/blob/main/proposals/gc/MVP.md
[wasi-libc]: https://github.com/WebAssembly/wasi-libc

[WASI Preview 3]: https://github.com/WebAssembly/WASI/tree/main/wasip2#looking-forward-to-preview-3
[Runtime Instantiation]: https://github.com/WebAssembly/component-model/issues/423

[Top-level `await`]: https://github.com/tc39/proposal-top-level-await
