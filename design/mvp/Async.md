# 🔀 Async Explainer

*This explainer describes a feature that is part of the forthcoming "Preview 3"
release of the Component Model. The relevant parts of the [AST explainer],
[binary format] and [Canonical ABI explainer] are gated by the 🔀 emoji.*

This explainer provides a high-level summary of the native async support in the
Component Model. For a detailed presentation of the runtime semantics, see the
[Canonical ABI explainer]. See also the [Wasm I/O 2024 presentation] for a
summary of the motivation and animated sketch of the design in action.

* [Goals](#goals)
* [High-level Approach](#high-level-approach)
* [Concepts](#concepts)
  * [Sync and Async Functions](#sync-and-async-functions)
  * [Task](#task)
  * [Current task](#current-task)
  * [Subtask and Supertask](#subtask-and-supertask)
  * [Structured concurrency](#structured-concurrency)
  * [Streams and Futures](#streams-and-futures)
  * [Waiting](#waiting)
  * [Backpressure](#backpressure)
  * [Returning](#returning)
* [Examples](#examples)
* [Interaction with multi-threading](#interaction-with-multi-threading)
* [Interaction with the start function](#interaction-with-the-start-function)
* [TODO](#todo)


## Goals

Given only *synchronous* functions with values and resources, when a component
needs to do concurrent (i.e., overlapping, interleaved, streaming) I/O, the
resulting [WIT] interfaces and implementations end up being complex,
hard to compose, and less efficient. By extending the Component Model with
built-in **asynchronous** support, these pain points can be addressed.

The Component Model's [goals] and intended [use cases] suggest the following
additional goals and requirements for native async support:

* Be independent-of but complementary-to the Core WebAssembly [stack-switching]
  proposal; don't depend on this proposal being fully standard or implemented
  (just like [JSPI]).
* Be independent-of but complementary-to the Core WebAssembly
  [shared-everything-threads] proposal; don't depend on this proposal being
  fully standard or implemented and ensure that components can achieve a high
  degree of concurrency using only one.
* Avoid partitioning interfaces and components into separate strata; don't give
  functions (or components) a [color].
* Enable tight integration (e.g., automatic bindings generation) with a wide
  variety of source languages' built-in concurrency features.
* Maintain meaningful cross-language call stacks (for the benefit of debugging,
  logging and tracing).
* Provide mechanisms for applying and observing backpressure.


## High-level Approach

Based on the above goals, the Component Model's approach to native async starts
by allowing components to import and export "async" functions which abstract
over and can literally be implemented in terms of:
* `async` functions in languages like C#, JS, Python, Rust and Swift
* stackful coroutines in languages like Kotlin, Perl, PHP and (recently) C++
* green threads as-if running on a single OS thread in languages like Go and
  (initially and recently again) Java

The Component Model supports this wide variety of language features by
specifying a common low-level "async" ABI which the different languages'
compilers and runtimes can bind their different language-level concurrency
features to. This is similar to how a native OS exposes APIs for concurrency
(such as `epoll`, `io_uring`, `kqueue` or Overlapped I/O) to which most of
these languages' concurrency features are already bound (making the Component
Model "just another OS" from the language toolchains' perspective).

Moreover, this async ABI does not require components to use preemptive
multi-threading ([`thread.spawn`]) in order to achieve concurrency. Instead,
concurrency can be achieved by cooperatively switching between different
logical tasks running on a single thread. This switching may require the use of
[fibers] or a [CPS transform], but may also be avoided entirely when a
component's producer toolchain is engineered to always return to an
[event loop].

To avoid partitioning the world along sync/async lines as mentioned in the
Goals section, the Component Model allows *every* component-level function type
to be both implemented and called in either a synchronous or asynchronous
manner. Thus, function types do not dictate synchrony or asynchrony and all 4
combinations of {sync, async} x {caller, callee} are supported and given a
well-defined behavior. Specifically, the caller and callee can independently
specify `async` as an immediate flags on the [lift and lower definitions] used
to define their imports and exports.

To propagate backpressure, it's necessary for a component to be able to say
"there are too many async export calls already in progress, don't start any
more until I let some of them complete". Thus, the low-level async ABI provides
a way to apply and release backpressure.

With this backpressure protocol in place, there is a natural way for sync and
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

In addition to being able to define and call whole functions asynchronously,
the `stream` and `future` types can be used in function signatures to pass
parameters and results incrementally over time, achieving finer-grained
concurrency. Streams and futures are thus not defined to be free-standing
resources with their own internal memory buffers (like a traditional channel or
pipe) but, rather, more-primitive control-flow mechanisms that synchronize the
incremental passing of parameters and results during cross-component calls.
Higher-level resources like channels and pipes could then be defined in terms
of these lower-level `stream` and `future` primitives, e.g.:
```wit
resource pipe {
  constructor(buffer-size: u32);
  write: func(bytes: stream<u8>) -> result;
  read: func() -> stream<u8>;
}
```
but also many other domain-specific concurrent resources like WASI HTTP request
and response bodies or WASI blobs. Streams and futures are however high-level
enough to be bound automatically to many source languages' built-in concurrency
features like futures, promises, streams, generators and iterators, unlike
lower-level concurrency primitives (like callbacks or `wasi:io@0.2.0`
`pollable`s). Thus, the Component Model seeks to provide the lowest-level
fine-grained concurrency primitives that are high-level and idiomatic enough to
enable automatic generation of usable language-integrated bindings.


## Concepts

The following concepts are defined as part of the Component Model's native
async support.

### Sync and Async Functions

The distinction between sync and async functions does not appear in the
component-level function type (nor in WIT). Rather, an "async" function is a
component-level function that has been [lifted] from Core WebAssembly with the
`async` option set. Symmetrically, a "sync" function is a component-level
function that does not have the `async` option set (which is the default and
only option prior to Preview 3). Thus, the sync/async distinction appears
only independently in how a component-level function is *implemented* or
*called*.

### Task

Every time a lifted function is called (e.g., when a component's export is
called by the outside world), a new **task** is created that logically contains
all the transitive control-flow state of the export call and will be destroyed
when the export call finishes. When all of a component's exports are lifted
synchronously, there will be at most one task alive at any one time. However,
when a component exports asynchronously-lifted functions, there can be multiple
tasks alive at once.

In the Canonical ABI explainer, a "task" is represented with the Python
[`Task`] class, which is created by each call to [`canon_lift`] and has
`SyncTask` and `AsyncTask` subclasses to factor out state and behavior only
needed for sync- or async-lifted functions, resp.

### Current Task

At any point in time when executing in Core WebAssembly code, there is a
single, unambiguous **current task**. Thus, whenever a [canonical built-in] is
called by Core WebAssembly code, it is meaningful for the built-in to work in
terms "the current task".

The "current task" is modelled in the Canonical ABI's Python code
by implicitly threading the `Task` object created by [`canon_lift`] through all
the `async def` Python functions transitively called by `canon_lift`. Thus,
although there can be multiple live `Task` objects in a component instance,
"the current one" is always clear: it's the one passed to the current function
as a parameter.

### Subtask and Supertask

Each component-to-component call necessarily creates a new task in the callee.
The callee task is a **subtask** of the calling task (and, conversely, the
calling task is a **supertask** of the callee task. This sub/super relationship
is immutable and doesn't change over time (until the callee task completes and
is destroyed).

The Canonical ABI's Python code represents the subtask relationship between a
caller `Task` and a callee `Task` via the Python [`Subtask`] class. Whereas a
`Task` object is created by each call to `canon_lift`, a `Subtask` object is
created by each call to [`canon_lower`]. This allows `Subtask`s to store the
state that enforces the caller side of the Canonical ABI rules.

### Structured concurrency

To realize the above goals of always having a well-defined cross-component
async callstack, the Component Model's Canonical ABI enforces [Structured
Concurrency] by dynamically requiring that a task waits for all its subtasks to
finish before the task itself is allowed to finish. This means that a subtask
cannot be orphaned and there will always be an async callstack rooted at an
invocation of an export by the host. Moreover, at any one point in time, the
set of tasks active in a linked component graph form a forest of async call
trees which e.g., can be visualized using a traditional flamegraph.

The Canonical ABI's Python code enforces Structured Concurrency by incrementing
a per-[`Task`] counter when a `Subtask` is created, decrementing when a
`Subtask` is destroyed, and trapping if the counter is not zero when the `Task`
attempts to exit.

### Streams and Futures

Streams and Futures have two "ends": a *readable end* and *writable end*. When
*consuming* a `stream` or `future` value as a parameter (of an export call with
a `stream` or `future` somewhere in the parameter types) or result (of an
import call with a `stream` or `future` somewhere in the result type), the
receiver always gets *unique ownership* of the *readable end* of the `stream`
or `future`. When *producing* a `stream` or `future` value as a parameter (of
an import call) or result (of an export call), the producer can either
*transfer ownership* of a readable end it has already received or it can create
a fresh writable end (via `stream.new` or `future.new`) and then lift this
writable end to create a fresh readable end in the consumer while maintaining
ownership of the writable end in the producer. To maintain the invariant that
readable ends are unique, a writable end can be lifted at most once, trapping
otherwise.

Based on this, `stream<T>` and `future<T>` values can be passed between
functions as if they were synchronous `list<T>` and `T` values, resp. For
example, given `f` and `g` with types:
```wit
f: func(x: whatever) -> stream<T>;
g: func(s: stream<T>) -> stuff;
```
`g(f(x))` works as you might hope, concurrently streaming `x` into `f` which
concurrently streams its results into `g`. (The addition of [`error`](#TODO)
will provide a generic answer to the question of what happens if `f`
experiences an error: `f` can close its returned writable stream end with an
`error` that will be propagated into `g` which should then propagate the error
somehow into `stuff`.)

If a component instance *would* receive the readable end of a stream for which
it already owns the writable end, the readable end disappears and the existing
writable end is received instead (since the guest can now handle the whole
stream more efficiently wholly from within guest code). E.g., if the same
component instance defined `f` and `g` above, the composition `g(f(x))` would
just instruct the guest to stream directly from `f` into `g` without crossing a
component boundary or performing any extra copies. Thus, strengthening the
previously-mentioned invariant, the readable and writable ends of a stream are
unique *and never in the same component*.

Given the readable or writable end of a stream, core wasm code can call the
imported `stream.read` or `stream.write` canonical built-ins, resp., passing the
pointer and length of a linear-memory buffer to write-into or read-from, resp.
These built-ins can either return immediately if >0 elements were able to be
written or read immediately (without blocking) or return a sentinel "blocked"
value indicating that the read or write will execute concurrently. The
readable and writable ends of streams and futures each have a well-defined
parent `Task` that will receive "progress" events on all child streams/futures
that have previously blocked.

From a [structured-concurrency](#structured-concurrency) perspective, the
readable and writable ends of streams and futures are leaves of the async call
tree. Unlike subtasks, the parent of the readable ends of streams and future
*can* change over time (when transferred via function call, as mentioned
above). However, there is always *some* parent `Task` and this parent `Task`
is prevented from orphaning its children using the same reference-counting
guard mentioned above for subtasks.

### Waiting

When a component asynchronously lowers an import, it is explicitly requesting
that, if the import blocks, control flow be returned back to the calling task
so that it can do something else. Similarly, if `stream.read` or `stream.write`
would block, they return a "blocked" code so that the caller can continue to
make progress on other things. But eventually, a task will run out of other
things to do and will need to **wait** for progress on one of the task's
subtasks, readable stream ends, writable stream ends, readable future ends or
writable future ends, which are collectively called its **waitables**. While a
task is waiting on its waitables, the Component Model runtime can switch to
other running tasks or start new tasks by invoking exports.

The Canonical ABI provides two ways for a task to wait:
* The task can call the [`task.wait`] built-in to synchronously wait for
  progress. This is specified in the Canonical ABI by the [`canon_task_wait`]
  function.
* The task can specify a `callback` function (in the `canon lift` definition)
  and return to the event loop to wait for notification of progress by a call
  to the `callback` function. This is specified in the Canonical ABI by
  the `opts.callback` case in [`canon_lift`].

While the two approaches have significant runtime implementation differences
(the former requires [fibers] or a [CPS transform] while the latter only
requires storing a small `i32` "context" in the task), semantically they do the
same thing which, in the Canonical ABI Python code, is factored out into
[`Task`]'s `wait` method. Thus, the difference between `callback` and
non-`callback` is mostly one of optimization, not expressivity.

### Backpressure

Once a component exports asynchronously-lifted functions, multiple concurrent
export calls can start piling up, each consuming some of the component's finite
private resources (like linear memory), requiring the component to be able to
exert *backpressure* to allow some tasks to finish (and release private
resources) before admitting new async export calls. To do this, a component may
call the `task.backpressure` built-in to set a "backpressure" flag that causes
subsequent export calls to immediately return in the "starting" state without
calling the component's Core WebAssembly code.

Once task enables backpressure, it can [wait](#waiting) for existing tasks to
finish and release their associated resources. Thus, a task can choose to
[wait](#waiting) with or without backpressure enabled, depending on whether it
wants to accept new accept new export calls while waiting or not.

See the [`canon_task_backpressure`] function and [`Task.enter`] method in the
Canonical ABI explainer for the setting and implementation of backpressure.

Once a task is allowed to start according to these backpressure rules, its
arguments are lowered into the callee's linear memory and the task is in
the "started" state.

### Returning

The way an async function returns its value is by calling [`task.return`],
passing the core values that are to be lifted as *parameters*. Additionally,
when the `always-task-return` `canonopt` is set, synchronous functions also
return their values by calling `task.return` (as a more expressive and
general alternative to `post-return`).

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

A task may not call `task.return` unless it is in the "started" state. Once
`task.return` is called, the task is in the "returned" state. A task can only
finish once it is in the "returned" state. See the [`canon_task_return`]
function in the Canonical ABI explainer for more details.


## Examples

With that background, we can sketch the shape of an async component that lifts
and lowers its imports and exports with `async`. The meat of this component is
replaced with `...` to focus on the overall flow of function calls.
```wat
(component
  (import "fetch" (func $fetch (param "url" string) (result (list u8))))
  (core module $Main
    (import "" "fetch" (func $fetch (param i32 i32) (result i32)))
    (import "" "task.return" (func $task_return (param i32)))
    (import "" "task.wait" (func $wait (param i32) (result i32)))
    (func (export "summarize") (param i32 i32)
      ...
      loop
        ...
        call $fetch      ;; pass a pointer-to-string and pointer-to-list-of-bytes outparam
        ...              ;; ... and receive the index of a new async subtask
      end
      loop               ;; loop as long as there are any subtasks
        ...
        call $task_wait  ;; wait for a subtask to make progress
        ...
      end
      ...
      call $task_return  ;; return the string result
      ...
    )
  )
  (canon lower $fetch async (core func $fetch'))
  (canon task.return (core func $task_return))
  (canon task.wait (core func $task_wait))
  (core instance $main (instantiate $Main (with "" (instance
    (export "fetch" (func $fetch'))
    (export "task.return" (func $task_return))
    (export "task.wait" (func $task_wait))
  ))))
  (canon lift (core func $main "summarize") async
    (func $summarize (param "urls" (list string)) (result string)))
  (export "summarize" (func $summarize))
)
```
Because the imported `fetch` function is `canon lower`ed with `async`, its core
function type (shown in the first import of `$Main`) takes pointers to the
parameter and results (which are asynchronously read-from and written-to) and
returns the index of a new subtask. `summarize` calls `task.wait` repeatedly
until all `fetch` subtasks have finished, noting that `task.wait` can return
intermediate progress (as subtasks transition from "starting" to "started" to
"returned" to "done") which tell the surrounding core wasm code that it can
reclaim the memory passed arguments or use the results that have now been
written to the outparam memory.

Because the `summarize` function is `canon lift`ed with `async`, its core
function type has no results, since results are passed out via `task.return`.
It also means that multiple `summarize` calls can be active at once: once the
first call to `task.wait` blocks, the runtime will suspend its callstack
(fiber) and start a new stack for the new call to `summarize`. Thus,
`summarize` must be careful to allocate a separate linear-memory stack in its
entry point, if one is needed, and to save and restore this before and after
calling `task.wait`.

(Note that, for brevity this example ignores the `memory` and `realloc`
immediates required by `canon lift` and `canon lower` to allocate the `list`
param and `string` result, resp.)

This same example can be re-written to use the `callback` immediate (thereby
avoiding the need for fibers) as follows. Note that the internal structure of
this component is almost the same as the previous one (other than that
`summarize` is now lifted from *two* core wasm functions instead of one) and
the public signature of this component is the exact same. Thus, the difference
is just about whether the stack is cleared by the core wasm code between events,
not externally-visible behavior.
```wat
(component
  (import "fetch" (func $fetch (param "url" string) (result (list u8))))
  (core module $Main
    (import "" "fetch" (func $fetch (param i32 i32) (result i32)))
    (import "" "task.return" (func $task_return (param i32)))
    (import "" "task.wait" (func $wait (param i32) (result i32)))
    (func (export "summarize") (param i32 i32) (result i32)
      ...
      loop
        ...
        call $fetch           ;; pass a pointer-to-string and pointer-to-list-of-bytes outparam
        ...                   ;; ... and receive the index of a new async subtask
      end
      ...                     ;; return a non-zero "cx" value passed to the next call to "cb"
    )
    (func (export "cb") (param $cx i32) (param $event i32) (param $payload i32)
      ...
      if ... subtasks remain ...
        get_local $cx
        return                ;; wait for another subtask to make progress
      end
      ...
      call $task_return       ;; return the string result
      ...
      i32.const 0             ;; return zero to signal that this task is done
    )
  )
  (canon lower $fetch async (core func $fetch'))
  (canon task.return (core func $task_return))
  (canon task.wait (core func $task_wait))
  (core instance $main (instantiate $Main (with "" (instance
    (export "fetch" (func $fetch'))
    (export "task.return" (func $task_return))
    (export "task.wait" (func $task_wait))
  ))))
  (canon lift (core func $main "summarize") async (callback (core func $main "cb"))
    (func $summarize (param "urls" (list string)) (result string)))
  (export "summarize" (func $summarize))
)
```
While this example spawns all the subtasks in the initial call to `summarize`,
subtasks can also be spawned from `cb` (even after the call to `task.return`).
It's also possible for `summarize` to call `task.return` called eagerly in the
initial core `summarize` call.

The `$event` and `$payload` parameters passed to `cb` are the same as the return
values from `task.wait` in the previous example. The precise meaning of these
values is defined by the Canonical ABI.


## Interaction with multi-threading

For now, the integration between multi-threading (via [`thread.spawn`]) and
native async is limited. In particular, because all [lift and lower
definitions] produce non-`shared` functions, any threads spawned by a component
via `thread.spawn` will not be able to directly call imports (synchronously
*or* asynchronously) and will thus have to use Core WebAssembly `atomics.*`
instructions to switch back to a non-`shared` function running on the "main"
thread (i.e., whichever thread was used to call the component's exports).

However, a future addition to this proposal (in the [TODO](#todo)s below) would
be to allow lifting and lowering with `async` + `shared`. What's exciting about
this approach is that a non-`shared` component-level function could be safely
lowered with `async shared`. In the case that the lifted function being lowered
was also `async shared`, the entire call could happen on the non-main thread
without a context switch. But if the lifting side was non-`shared`, then the
Component Model could automatically handle the synchronization of enqueing a
call to the export (as in the backpressure case mentioned above), returning a
subtask for the async caller to wait on as usual. Thus, the sync+async
composition story described above could naturally be extended to a
sync+async+shared composition story, continuing to avoid the "what color is
your function" problem (where `shared` is the [color]).

Even without any use of `thread.new`, native async provides an opportunity to
achieve some automatic parallelism "for free". In particular, due to the
shared-nothing nature of components, each component instance could be given a
separate thread on which to interleave all tasks executing in that instance.
Thus, in a cross-component call from `C1` to `C2`, `C2`'s task can run in a
separate thread that is automatically synchronized with `C1` by the runtime.
This is analogous to how traditional OS processes can run in separate threads,
except that the component model is *allowing*, but not *requiring* the separate
threads. While it's unclear how much parallelism this would unlock in practice,
it does present interesting opportunities to experiment with optimizations over
time as applications are built with more components.


## Interaction with the start function

Since component-level start functions can be any component-level function (with
type `[] -> []`), async functions can be start functions. This raises some
interesting questions concerning how much concurrency during instantiation (of
a whole component DAG) is allowed and how parent components can control this.
For now, this remains a [TODO](#todo) and validation will reject `async`-lifted
`start` functions.


## TODO

Native async support is being proposed incrementally. The following features
will be added in future chunks roughly in the order list to complete the full
"async" story:
* add `error` type that can be included when closing a stream/future
* `nonblocking` function type attribute: allow a function to declare in its
  type that it will not transitively do anything blocking
* define what `async` means for `start` functions (top-level await + background
  tasks), along with cross-task coordination built-ins
* `subtask.cancel`: allow a supertask to signal to a subtask that its result is
  no longer wanted and to please wrap it up promptly
* zero-copy forwarding/splicing and built-in way to "tail-call" a subtask so
  that the current wasm instance can be torn down eagerly while preserving
  structured concurrency
* some way to say "no more elements are coming for a while"
* `recursive` function type attribute: allow a function to be reentered
  recursively (instead of trapping) and link inner and outer activations
* allow pipelining multiple `stream.read`/`write` calls
* allow chaining multiple async calls together ("promise pipelining")
* integrate with `shared`: define how to lift and lower functions `async` *and*
  `shared`


[Wasm I/O 2024 presentation]: https://www.youtube.com/watch?v=y3x4-nQeXxc
[Color]: https://journal.stuffwithstuff.com/2015/02/01/what-color-is-your-function/

[Fibers]: https://en.wikipedia.org/wiki/Fiber_(computer_science)
[CPS Transform]: https://en.wikipedia.org/wiki/Continuation-passing_style
[Event Loop]: https://en.wikipedia.org/wiki/Event_loop
[Structured Concurrency]: https://en.wikipedia.org/wiki/Structured_concurrency

[AST Explainer]: Explainer.md
[Lift and Lower Definitions]: Explainer.md#canonical-definitions
[Lifted]: Explainer.md#canonical-definitions
[Canonical Built-in]: Explainer.md#canonical-built-ins
[`task.return`]: Explainer.md#-async-built-ins
[`task.wait`]: Explainer.md#-async-built-ins
[`thread.spawn`]: Explainer.md#-threading-built-ins
[ESM-integration]: Explainer.md#ESM-integration

[Canonical ABI Explainer]: CanonicalABI.md
[`canon_lift`]: CanonicalABI.md#canon-lift
[`canon_lower`]: CanonicalABI.md#canon-lower
[`canon_lower`]: CanonicalABI.md#canon-task-wait
[`canon_task_wait`]: CanonicalABI.md#-canon-taskwait
[`canon_task_backpressure`]: CanonicalABI.md#-canon-taskbackpressure
[`canon_task_return`]: CanonicalABI.md#-canon-taskreturn
[`Task`]: CanonicalABI.md#runtime-state
[`Task.enter`]: CanonicalABI.md#runtime-state
[`Subtask`]: CanonicalABI.md#runtime-state
[`AsyncTask`]: CanonicalABI.md#runtime-state

[Binary Format]: Binary.md
[WIT]: WIT.md
[Goals]: ../high-level/Goals.md
[Use Cases]: ../high-level/UseCases.md

[stack-switching]: https://github.com/WebAssembly/stack-switching/
[JSPI]: https://github.com/WebAssembly/js-promise-integration/
[shared-everything-threads]: https://github.com/webAssembly/shared-everything-threads
