;; Async built-in traps poisons instances as usual

(component definition $Unreachable
  (core module $M (func (export "f") unreachable))
  (core instance $m (instantiate $M))
  (func (export "f") (canon lift (core func $m "f")))
)
(component instance $i $Unreachable)
(assert_trap (invoke "f") "wasm trap: wasm `unreachable` instruction executed")
(assert_trap (invoke "f") "cannot enter component instance")

(component definition $BuiltinTrap
  (core module $Memory (memory (export "mem") 1))
  (core instance $memory (instantiate $Memory))
  (core module $M
    (import "" "mem" (memory 1))
    (import "" "stream.new" (func $stream.new (result i64)))
    (import "" "stream.write" (func $stream.write (param i32 i32 i32) (result i32)))
    (import "" "stream.drop-writable" (func $stream.drop-writable (param i32)))
    (func (export "f")
      (local $tx i32)
      (local.set $tx (i32.wrap_i64 (i64.shr_u (call $stream.new) (i64.const 32))))
      (drop (call $stream.write (local.get $tx) (i32.const 0) (i32.const 4)))
      (call $stream.drop-writable (local.get $tx)))
  )
  (type $ST (stream u8))
  (canon stream.new $ST (core func $stream.new))
  (canon stream.write $ST async (memory $memory "mem") (core func $stream.write))
  (canon stream.drop-writable $ST (core func $stream.drop-writable))
  (core instance $m (instantiate $M (with "" (instance
    (export "mem" (memory $memory "mem"))
    (export "stream.new" (func $stream.new))
    (export "stream.write" (func $stream.write))
    (export "stream.drop-writable" (func $stream.drop-writable))))))
  (func (export "f") (canon lift (core func $m "f")))
)
(component instance $j $BuiltinTrap)
(assert_trap (invoke "f") "cannot drop busy stream")
(assert_trap (invoke "f") "cannot enter component instance")
