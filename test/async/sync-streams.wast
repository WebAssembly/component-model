;; This test calls sync stream.write in $C.get and sync stream.read in $C.set.
;; Both of these calls block because $C is first to the rendezvous. But since
;; they are synchronous, control flow switches to $D.run which will do
;; a complementary read/write that rendezvous, and then control flow will
;; switch back to $C.get/set where the synchronous read/write will return
;; without blocking.
(component
  (component $C
    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $CM
      (import "" "mem" (memory 1))
      (import "" "task.return0" (func $task.return0))
      (import "" "task.return1" (func $task.return1 (param i32)))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
      (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-readable" (func $stream.drop-readable (param i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))

      (func (export "get") (result i32)
        (local $ret i32) (local $ret64 i64)
        (local $tx i32) (local $rx i32)
        (local $bufp i32)

        ;; ($rx, $tx) = stream.new
        (local.set $ret64 (call $stream.new))
        (local.set $rx (i32.wrap_i64 (local.get $ret64)))
        (local.set $tx (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))

        ;; return $rx
        (call $task.return1 (local.get $rx))

        ;; (stream.write $tx $bufp 4) will block and, because called
        ;; synchronously, switch to the caller who will read and rendezvous
        (local.set $bufp (i32.const 16))
        (i32.store (local.get $bufp) (i32.const 0x01234567))
        (local.set $ret (call $stream.write (local.get $tx) (local.get $bufp) (i32.const 4)))
        (if (i32.ne (i32.const 0x41 (; DROPPED=1 | (4<<4) ;)) (local.get $ret))
          (then unreachable))

        (call $stream.drop-writable (local.get $tx))
        (return (i32.const 0 (; EXIT ;)))
      )
      (func (export "get_cb") (param i32 i32 i32) (result i32)
        unreachable
      )

      (func (export "set") (param $rx i32) (result i32)
        (local $ret i32) (local $ret64 i64)
        (local $bufp i32)

        ;; (stream.read $rx $bufp 4) will block and, because called
        ;; synchronously, switch to the caller who will write and rendezvous
        (local.set $bufp (i32.const 16))
        (local.set $ret (call $stream.read (local.get $rx) (local.get $bufp) (i32.const 4)))
        (if (i32.ne (i32.const 0x41 (; DROPPED=1 | (4<<4) ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (i32.const 0x89abcdef) (i32.load (local.get $bufp)))
          (then unreachable))

        (call $stream.drop-readable (local.get $rx))

        ;; only return once all the above checks have passed so that the
        ;; caller can wait for this subtask to observe that they passed
        (call $task.return0)
        (return (i32.const 0 (; EXIT ;)))
      )
      (func (export "set_cb") (param i32 i32 i32) (result i32)
        unreachable
      )
    )
    (type $ST (stream u8))
    (canon task.return (memory (core memory $memory "mem")) (core func $task.return0))
    (canon task.return (result $ST) (memory (core memory $memory "mem")) (core func $task.return1))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.read $ST (memory (core memory $memory "mem")) (core func $stream.read))
    (canon stream.write $ST (memory (core memory $memory "mem")) (core func $stream.write))
    (canon stream.drop-readable $ST (core func $stream.drop-readable))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (core instance $cm (instantiate $CM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "task.return0" (func $task.return0))
      (export "task.return1" (func $task.return1))
      (export "stream.new" (func $stream.new))
      (export "stream.read" (func $stream.read))
      (export "stream.write" (func $stream.write))
      (export "stream.drop-readable" (func $stream.drop-readable))
      (export "stream.drop-writable" (func $stream.drop-writable))
    ))))
    (func (export "get") async (result (stream u8)) (canon lift
      (core func $cm "get")
      async (memory (core memory $memory "mem")) (callback (core func $cm "get_cb"))
    ))
    (func (export "set") async (param "in" (stream u8)) (canon lift
      (core func $cm "set")
      async (memory (core memory $memory "mem")) (callback (core func $cm "set_cb"))
    ))
  )
  (component $D
    (import "get" (func $get async (result (stream u8))))
    (import "set" (func $set async (param "in" (stream u8))))

    (core module $Memory (memory (export "mem") 1))
    (core instance $memory (instantiate $Memory))
    (core module $DM
      (import "" "mem" (memory 1))
      (import "" "stream.new" (func $stream.new (result i64)))
      (import "" "stream.read" (func $stream.read (param i32 i32 i32) (result i32)))
      (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
      (import "" "stream.drop-readable" (func $stream.drop-readable (param i32)))
      (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))
      (import "" "waitable-set.new" (func $waitable-set.new (result i32)))
      (import "" "waitable-set.wait" (func $waitable-set.wait (param i32 i32) (result i32)))
      (import "" "waitable.join" (func $waitable.join (param i32 i32)))
      (import "" "subtask.drop" (func $subtask.drop (param i32)))
      (import "" "get" (func $get (result i32)))
      (import "" "set" (func $set (param i32) (result i32)))

      (func (export "run") (result i32)
        (local $ret i32) (local $ret64 i64)
        (local $rx i32) (local $tx i32)
        (local $bufp i32)
        (local $subtask i32) (local $ws i32)

        ;; $rx = $C.get()
        (local.set $rx (call $get))

        ;; (stream.read $rx $bufp 4) will succeed without blocking
        (local.set $bufp (i32.const 20))
        (local.set $ret (call $stream.read (local.get $rx) (local.get $bufp) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (i32.const 0x01234567) (i32.load (local.get $bufp)))
          (then unreachable))

        (call $stream.drop-readable (local.get $rx))

        ;; ($rx, $tx) = stream.new
        ;; $C.set($rx) blocks on stream.read, so the async call returns STARTED
        (local.set $ret64 (call $stream.new))
        (local.set $rx (i32.wrap_i64 (local.get $ret64)))
        (local.set $tx (i32.wrap_i64 (i64.shr_u (local.get $ret64) (i64.const 32))))
        (local.set $ret (call $set (local.get $rx)))
        (if (i32.ne (i32.const 1 (; STARTED ;)) (i32.and (local.get $ret) (i32.const 0xf)))
          (then unreachable))
        (local.set $subtask (i32.shr_u (local.get $ret) (i32.const 4)))

        ;; (stream.write $tx $bufp 4) will succeed without blocking
        (local.set $bufp (i32.const 16))
        (i32.store (local.get $bufp) (i32.const 0x89abcdef))
        (local.set $ret (call $stream.write (local.get $tx) (local.get $bufp) (i32.const 4)))
        (if (i32.ne (i32.const 0x40 (; COMPLETED=0 | (4<<4) ;)) (local.get $ret))
          (then unreachable))

        (call $stream.drop-writable (local.get $tx))

        ;; wait for $C.set to finish, which implies all its checks passed
        (local.set $ws (call $waitable-set.new))
        (call $waitable.join (local.get $subtask) (local.get $ws))
        (local.set $ret (call $waitable-set.wait (local.get $ws) (i32.const 0)))
        (if (i32.ne (i32.const 1 (; SUBTASK ;)) (local.get $ret))
          (then unreachable))
        (if (i32.ne (local.get $subtask) (i32.load (i32.const 0)))
          (then unreachable))
        (if (i32.ne (i32.const 2 (; RETURNED ;)) (i32.load (i32.const 4)))
          (then unreachable))
        (call $subtask.drop (local.get $subtask))
        (i32.const 42)
      )
    )
    (type $ST (stream u8))
    (canon stream.new $ST (core func $stream.new))
    (canon stream.read $ST async (memory (core memory $memory "mem")) (core func $stream.read))
    (canon stream.write $ST async (memory (core memory $memory "mem")) (core func $stream.write))
    (canon stream.drop-readable $ST (core func $stream.drop-readable))
    (canon stream.drop-writable $ST (core func $stream.drop-writable))
    (canon waitable-set.new (core func $waitable-set.new))
    (canon waitable-set.wait (memory (core memory $memory "mem")) (core func $waitable-set.wait))
    (canon waitable.join (core func $waitable.join))
    (canon subtask.drop (core func $subtask.drop))
    (canon lower (func $get) (core func $get'))
    (canon lower (func $set) async (memory (core memory $memory "mem")) (core func $set'))
    (core instance $dm (instantiate $DM (with "" (instance
      (export "mem" (memory $memory "mem"))
      (export "stream.new" (func $stream.new))
      (export "stream.read" (func $stream.read))
      (export "stream.write" (func $stream.write))
      (export "stream.drop-readable" (func $stream.drop-readable))
      (export "stream.drop-writable" (func $stream.drop-writable))
      (export "waitable-set.new" (func $waitable-set.new))
      (export "waitable-set.wait" (func $waitable-set.wait))
      (export "waitable.join" (func $waitable.join))
      (export "subtask.drop" (func $subtask.drop))
      (export "get" (func $get'))
      (export "set" (func $set'))
    ))))
    (func (export "run") async (result u32) (canon lift (core func $dm "run")))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D
    (with "get" (func $c "get"))
    (with "set" (func $c "set"))
  ))
  (func (export "run") (alias export $d "run"))
)
(assert_return (invoke "run") (u32.const 42))
