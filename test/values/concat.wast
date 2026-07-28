;; Lift a wide variety of WIT value types as export parameters, concatenate
;; them, and return the result as a string.
(component
  (core module $M
    (memory (export "mem") 4)

    ;; "true"=[64,4] "false"=[68,5] "red"=[73,3] "green"=[76,5] "blue"=[81,4]
    ;; "some"=[85,4] "none"=[89,4] "ok"=[93,2] "err"=[95,3]
    (data (i32.const 64) "truefalseredgreenbluesomenoneokerr")

    (global $next (mut i32) (i32.const 65536))
    (func (export "realloc") (param $old i32) (param $os i32) (param $al i32) (param $ns i32) (result i32)
      (local $r i32)
      (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
      (local.set $r (global.get $next))
      (global.set $next (i32.add (global.get $next) (local.get $ns)))
      (local.get $r))

    (global $w (mut i32) (i32.const 1024))
    (func $emit (param $src i32) (param $len i32)
      (memory.copy (global.get $w) (local.get $src) (local.get $len))
      (global.set $w (i32.add (global.get $w) (local.get $len))))
    (func $emit_char (param $c i32)
      (i32.store8 (global.get $w) (local.get $c))
      (global.set $w (i32.add (global.get $w) (i32.const 1))))
    (func $u64toa (param $v i64) (result i32 i32)
      (local $p i32)
      (local.set $p (i32.const 48))
      (block $z
        (br_if $z (i64.eqz (local.get $v)))
        (loop $l
          (local.set $p (i32.sub (local.get $p) (i32.const 1)))
          (i32.store8 (local.get $p)
            (i32.add (i32.const 48)
              (i32.wrap_i64 (i64.rem_u (local.get $v) (i64.const 10)))))
          (local.set $v (i64.div_u (local.get $v) (i64.const 10)))
          (br_if $l (i64.ne (local.get $v) (i64.const 0))))
        (return (local.get $p) (i32.sub (i32.const 48) (local.get $p))))
      (i32.store8 (i32.const 47) (i32.const 48))
      (i32.const 47) (i32.const 1))
    (func $emit_u64 (param $v i64)
      (local $p i32) (local $l i32)
      (call $u64toa (local.get $v))
      (local.set $l)
      (local.set $p)
      (call $emit (local.get $p) (local.get $l)))
    (func $emit_s64 (param $v i64)
      (if (i64.lt_s (local.get $v) (i64.const 0))
        (then
          (call $emit_char (i32.const 45))
          (local.set $v (i64.sub (i64.const 0) (local.get $v)))))
      (call $emit_u64 (local.get $v)))
    (func $emit_bool (param $b i32)
      (if (local.get $b)
        (then (call $emit (i32.const 64) (i32.const 4)))
        (else (call $emit (i32.const 68) (i32.const 5)))))
    (func $emit_u32_list (param $ptr i32) (param $len i32)
      (local $i i32)
      (block $d (loop $l
        (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
        (call $emit_u64 (i64.extend_i32_u (i32.load (i32.add (local.get $ptr) (i32.mul (local.get $i) (i32.const 4))))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l))))
    (func $finish (result i32)
      (i32.store (i32.const 0) (i32.const 1024))
      (i32.store (i32.const 4) (i32.sub (global.get $w) (i32.const 1024)))
      (i32.const 0))

    (func (export "prims")
        (param $b i32) (param $u8 i32) (param $s8 i32) (param $u16 i32) (param $s16 i32)
        (param $u32 i32) (param $s32 i32) (param $u64 i64) (param $s64 i64)
        (param $c i32) (param $sp i32) (param $sl i32) (result i32)
      (global.set $w (i32.const 1024))
      (call $emit_bool (local.get $b))
      (call $emit_u64 (i64.extend_i32_u (local.get $u8)))
      (call $emit_s64 (i64.extend_i32_s (local.get $s8)))
      (call $emit_u64 (i64.extend_i32_u (local.get $u16)))
      (call $emit_s64 (i64.extend_i32_s (local.get $s16)))
      (call $emit_u64 (i64.extend_i32_u (local.get $u32)))
      (call $emit_s64 (i64.extend_i32_s (local.get $s32)))
      (call $emit_u64 (local.get $u64))
      (call $emit_s64 (local.get $s64))
      (call $emit_char (local.get $c))
      (call $emit (local.get $sp) (local.get $sl))
      (call $finish))

    (func (export "list") (param $p i32) (param $n i32) (result i32)
      (local $i i32)
      (global.set $w (i32.const 1024))
      (block $done
        (loop $l
          (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
          (call $emit
            (i32.load (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 8))))
            (i32.load offset=4 (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 8)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
      (call $finish))

    (func (export "tuple") (param $sp i32) (param $sl i32) (param $u i32) (param $b i32) (result i32)
      (global.set $w (i32.const 1024))
      (call $emit (local.get $sp) (local.get $sl))
      (call $emit_u64 (i64.extend_i32_u (local.get $u)))
      (call $emit_bool (local.get $b))
      (call $finish))

    (func (export "record") (param $sp i32) (param $sl i32) (param $n i32) (result i32)
      (global.set $w (i32.const 1024))
      (call $emit (local.get $sp) (local.get $sl))
      (call $emit_u64 (i64.extend_i32_u (local.get $n)))
      (call $finish))

    (func (export "variant") (param $d i32) (param $a i32) (param $b i32) (result i32)
      (global.set $w (i32.const 1024))
      (if (local.get $d)
        (then (call $emit_u64 (i64.extend_i32_u (local.get $a))))
        (else (call $emit (local.get $a) (local.get $b))))
      (call $finish))

    (func (export "enum") (param $d i32) (result i32)
      (global.set $w (i32.const 1024))
      (if (i32.eq (local.get $d) (i32.const 0)) (then (call $emit (i32.const 73) (i32.const 3))))
      (if (i32.eq (local.get $d) (i32.const 1)) (then (call $emit (i32.const 76) (i32.const 5))))
      (if (i32.eq (local.get $d) (i32.const 2)) (then (call $emit (i32.const 81) (i32.const 4))))
      (call $finish))

    (func (export "flags") (param $f i32) (result i32)
      (global.set $w (i32.const 1024))
      (if (i32.and (local.get $f) (i32.const 1)) (then (call $emit_char (i32.const 97))))
      (if (i32.and (local.get $f) (i32.const 2)) (then (call $emit_char (i32.const 98))))
      (if (i32.and (local.get $f) (i32.const 4)) (then (call $emit_char (i32.const 99))))
      (call $finish))

    (func (export "option") (param $d i32) (param $v i32) (result i32)
      (global.set $w (i32.const 1024))
      (if (local.get $d)
        (then
          (call $emit (i32.const 85) (i32.const 4))
          (call $emit_u64 (i64.extend_i32_u (local.get $v))))
        (else (call $emit (i32.const 89) (i32.const 4))))
      (call $finish))

    (func (export "result") (param $d i32) (param $a i32) (param $b i32) (result i32)
      (global.set $w (i32.const 1024))
      (if (local.get $d)
        (then
          (call $emit (i32.const 95) (i32.const 3))
          (call $emit_u64 (i64.extend_i32_u (local.get $a))))
        (else
          (call $emit (i32.const 93) (i32.const 2))
          (call $emit (local.get $a) (local.get $b))))
      (call $finish))

    ;; list<list<string>>
    (func (export "nested-list") (param $ptr i32) (param $len i32) (result i32)
      (local $i i32) (local $e i32) (local $ip i32) (local $il i32) (local $j i32) (local $se i32)
      (global.set $w (i32.const 1024))
      (block $od (loop $ol
        (br_if $od (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $e (i32.add (local.get $ptr) (i32.mul (local.get $i) (i32.const 8))))
        (local.set $ip (i32.load (local.get $e)))
        (local.set $il (i32.load offset=4 (local.get $e)))
        (local.set $j (i32.const 0))
        (block $id (loop $il2
          (br_if $id (i32.ge_u (local.get $j) (local.get $il)))
          (local.set $se (i32.add (local.get $ip) (i32.mul (local.get $j) (i32.const 8))))
          (call $emit (i32.load (local.get $se)) (i32.load offset=4 (local.get $se)))
          (local.set $j (i32.add (local.get $j) (i32.const 1)))
          (br $il2)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $ol)))
      (call $finish))

    ;; record { name: string, scores: list<u32> }
    (func (export "profile") (param $np i32) (param $nl i32) (param $sp i32) (param $sl i32) (result i32)
      (global.set $w (i32.const 1024))
      (call $emit (local.get $np) (local.get $nl))
      (call $emit_u32_list (local.get $sp) (local.get $sl))
      (call $finish))

    ;; option<tuple<string, u32>>
    (func (export "maybe-pair") (param $d i32) (param $p0 i32) (param $p1 i32) (param $p2 i32) (result i32)
      (global.set $w (i32.const 1024))
      (if (local.get $d)
        (then (call $emit (local.get $p0) (local.get $p1)) (call $emit_u64 (i64.extend_i32_u (local.get $p2))))
        (else (call $emit (i32.const 89) (i32.const 4))))
      (call $finish))

    ;; list<record { k: string, v: u32 }>, record stride 12
    (func (export "entries") (param $ptr i32) (param $len i32) (result i32)
      (local $i i32) (local $e i32)
      (global.set $w (i32.const 1024))
      (block $d (loop $l
        (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $e (i32.add (local.get $ptr) (i32.mul (local.get $i) (i32.const 12))))
        (call $emit (i32.load (local.get $e)) (i32.load offset=4 (local.get $e)))
        (call $emit_u64 (i64.extend_i32_u (i32.load offset=8 (local.get $e))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $finish))

    ;; list<option<tuple<string, list<u32>>>>
    (func (export "deep") (param $ptr i32) (param $len i32) (result i32)
      (local $i i32) (local $e i32)
      (global.set $w (i32.const 1024))
      (block $d (loop $l
        (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $e (i32.add (local.get $ptr) (i32.mul (local.get $i) (i32.const 20))))
        (if (i32.load (local.get $e))
          (then
            (call $emit (i32.load offset=4 (local.get $e)) (i32.load offset=8 (local.get $e)))
            (call $emit_u32_list (i32.load offset=12 (local.get $e)) (i32.load offset=16 (local.get $e))))
          (else (call $emit (i32.const 89) (i32.const 4))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $finish))

    (func (export "concat-u32s") (param $ptr i32) (param $len i32) (result i32)
      (global.set $w (i32.const 1024))
      (call $emit_u32_list (local.get $ptr) (local.get $len))
      (call $finish))

    (func (export "echo") (param $p i32) (param $l i32) (result i32)
      (global.set $w (i32.const 1024))
      (call $emit (local.get $p) (local.get $l))
      (call $finish))

    (func (export "bignum") (param $v i64) (result i32)
      (global.set $w (i32.const 1024))
      (call $emit_u64 (local.get $v))
      (call $finish))

    ;; variant { a: u32, b: f32, c: u64, d: f64 }
    (func (export "flat-mix") (param $d i32) (param $p i64) (result i32)
      (global.set $w (i32.const 1024))
      (block $done
        (if (i32.eqz (local.get $d)) (then  ;; a: u32
          (call $emit_u64 (i64.extend_i32_u (i32.wrap_i64 (local.get $p)))) (br $done)))
        (if (i32.eq (local.get $d) (i32.const 1)) (then  ;; b: f32
          (call $emit_u64 (i64.trunc_f32_u (f32.reinterpret_i32 (i32.wrap_i64 (local.get $p))))) (br $done)))
        (if (i32.eq (local.get $d) (i32.const 2)) (then  ;; c: u64
          (call $emit_u64 (local.get $p)) (br $done)))
        (if (i32.eq (local.get $d) (i32.const 3)) (then  ;; d: f64
          (call $emit_u64 (i64.trunc_f64_u (f64.reinterpret_i64 (local.get $p)))) (br $done))))
      (call $finish))

    ;; variant { p: tuple<f32, f32>, q: u32 }
    (func (export "flat-pad") (param $d i32) (param $s0 i32) (param $s1 f32) (result i32)
      (global.set $w (i32.const 1024))
      (if (local.get $d)
        (then  ;; q: u32 (disc 1)
          (call $emit_u64 (i64.extend_i32_u (local.get $s0))))
        (else  ;; p: tuple<f32, f32> (disc 0)
          (call $emit_u64 (i64.trunc_f32_u (f32.reinterpret_i32 (local.get $s0))))
          (call $emit_u64 (i64.trunc_f32_u (local.get $s1)))))
      (call $finish))

    ;; list<variant { n: u32, s: string }>
    (func (export "list-variant") (param $ptr i32) (param $len i32) (result i32)
      (local $i i32) (local $e i32)
      (global.set $w (i32.const 1024))
      (block $d (loop $l
        (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $e (i32.add (local.get $ptr) (i32.mul (local.get $i) (i32.const 12))))
        (if (i32.load8_u (local.get $e))
          (then (call $emit (i32.load offset=4 (local.get $e)) (i32.load offset=8 (local.get $e))))   ;; s
          (else (call $emit_u64 (i64.extend_i32_u (i32.load offset=4 (local.get $e))))))              ;; n
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $finish))

    ;; list<variant { b: u8, w: u64 }>
    (func (export "list-variant2") (param $ptr i32) (param $len i32) (result i32)
      (local $i i32) (local $e i32)
      (global.set $w (i32.const 1024))
      (block $d (loop $l
        (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
        (local.set $e (i32.add (local.get $ptr) (i32.mul (local.get $i) (i32.const 16))))
        (if (i32.load8_u (local.get $e))
          (then (call $emit_u64 (i64.load offset=8 (local.get $e))))                       ;; w: u64
          (else (call $emit_u64 (i64.extend_i32_u (i32.load8_u offset=8 (local.get $e)))))) ;; b: u8
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $l)))
      (call $finish))
  )
  (core instance $m (instantiate $M))

  (func (export "prims")
    (param "p0" bool) (param "p1" u8) (param "p2" s8) (param "p3" u16) (param "p4" s16)
    (param "p5" u32) (param "p6" s32) (param "p7" u64) (param "p8" s64)
    (param "p9" char) (param "p10" string) (result string)
    (canon lift (core func $m "prims") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (func (export "list") (param "a" (list string)) (result string)
    (canon lift (core func $m "list") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (func (export "tuple") (param "a" (tuple string u32 bool)) (result string)
    (canon lift (core func $m "tuple") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (type $rec-t (record (field "s" string) (field "n" u32)))
  (export $rec-e "rec-t" (type $rec-t))
  (func (export "record") (param "a" $rec-e) (result string)
    (canon lift (core func $m "record") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (type $var-t (variant (case "s" string) (case "n" u32)))
  (export $var-e "var-t" (type $var-t))
  (func (export "variant") (param "a" $var-e) (result string)
    (canon lift (core func $m "variant") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (type $enum-t (enum "red" "green" "blue"))
  (export $enum-e "enum-t" (type $enum-t))
  (func (export "enum") (param "a" $enum-e) (result string)
    (canon lift (core func $m "enum") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (type $flags-t (flags "a" "b" "c"))
  (export $flags-e "flags-t" (type $flags-t))
  (func (export "flags") (param "a" $flags-e) (result string)
    (canon lift (core func $m "flags") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (func (export "option") (param "a" (option u32)) (result string)
    (canon lift (core func $m "option") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (func (export "result") (param "a" (result string (error u32))) (result string)
    (canon lift (core func $m "result") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (func (export "nested-list") (param "a" (list (list string))) (result string)
    (canon lift (core func $m "nested-list") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (type $profile-t (record (field "name" string) (field "scores" (list u32))))
  (export $profile-e "profile-t" (type $profile-t))
  (func (export "profile") (param "a" $profile-e) (result string)
    (canon lift (core func $m "profile") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (func (export "maybe-pair") (param "a" (option (tuple string u32))) (result string)
    (canon lift (core func $m "maybe-pair") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (type $entry-t (record (field "k" string) (field "v" u32)))
  (export $entry-e "entry-t" (type $entry-t))
  (func (export "entries") (param "a" (list $entry-e)) (result string)
    (canon lift (core func $m "entries") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (func (export "deep") (param "a" (list (option (tuple string (list u32))))) (result string)
    (canon lift (core func $m "deep") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (func (export "concat-u32s") (param "a" (list u32)) (result string)
    (canon lift (core func $m "concat-u32s") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (func (export "echo") (param "a" string) (result string)
    (canon lift (core func $m "echo") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (func (export "bignum") (param "a" u64) (result string)
    (canon lift (core func $m "bignum") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (type $mix-t (variant (case "a" u32) (case "b" f32) (case "c" u64) (case "d" f64)))
  (export $mix-e "mix-t" (type $mix-t))
  (func (export "flat-mix") (param "a" $mix-e) (result string)
    (canon lift (core func $m "flat-mix") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (type $pad-t (variant (case "p" (tuple f32 f32)) (case "q" u32)))
  (export $pad-e "pad-t" (type $pad-t))
  (func (export "flat-pad") (param "a" $pad-e) (result string)
    (canon lift (core func $m "flat-pad") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (type $lv-t (variant (case "n" u32) (case "s" string)))
  (export $lv-e "lv-t" (type $lv-t))
  (func (export "list-variant") (param "a" (list $lv-e)) (result string)
    (canon lift (core func $m "list-variant") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
  (type $lv2-t (variant (case "b" u8) (case "w" u64)))
  (export $lv2-e "lv2-t" (type $lv2-t))
  (func (export "list-variant2") (param "a" (list $lv2-e)) (result string)
    (canon lift (core func $m "list-variant2") (memory (core memory $m "mem")) (realloc (core func $m "realloc"))))
)

(assert_return
  (invoke "prims"
    (bool.const true) (u8.const 7) (s8.const -8) (u16.const 9) (s16.const -10)
    (u32.const 11) (s32.const -12) (u64.const 13) (s64.const -14)
    (char.const "Z") (str.const "!"))
  (str.const "true7-89-1011-1213-14Z!"))

(assert_return
  (invoke "list" (list.const (str.const "foo") (str.const "bar") (str.const "baz")))
  (str.const "foobarbaz"))
(assert_return (invoke "list" (list.const)) (str.const ""))

(assert_return
  (invoke "tuple" (tuple.const (str.const "x=") (u32.const 42) (bool.const true)))
  (str.const "x=42true"))

(assert_return
  (invoke "record" (record.const (field "s" str.const "v=") (field "n" u32.const 7)))
  (str.const "v=7"))

(assert_return (invoke "variant" (variant.const "s" (str.const "hi"))) (str.const "hi"))
(assert_return (invoke "variant" (variant.const "n" (u32.const 99))) (str.const "99"))

(assert_return (invoke "enum" (enum.const "red")) (str.const "red"))
(assert_return (invoke "enum" (enum.const "green")) (str.const "green"))
(assert_return (invoke "enum" (enum.const "blue")) (str.const "blue"))

(assert_return (invoke "flags" (flags.const "a" "c")) (str.const "ac"))
(assert_return (invoke "flags" (flags.const)) (str.const ""))
(assert_return (invoke "flags" (flags.const "a" "b" "c")) (str.const "abc"))

(assert_return (invoke "option" (option.some (u32.const 5))) (str.const "some5"))
(assert_return (invoke "option" (option.none)) (str.const "none"))

(assert_return (invoke "result" (result.ok (str.const "yo"))) (str.const "okyo"))
(assert_return (invoke "result" (result.err (u32.const 404))) (str.const "err404"))

(assert_return
  (invoke "nested-list"
    (list.const
      (list.const (str.const "a") (str.const "b"))
      (list.const)
      (list.const (str.const "c"))))
  (str.const "abc"))

(assert_return
  (invoke "profile"
    (record.const (field "name" str.const "p:") (field "scores" list.const (u32.const 10) (u32.const 20) (u32.const 30))))
  (str.const "p:102030"))

(assert_return
  (invoke "maybe-pair" (option.some (tuple.const (str.const "n=") (u32.const 7))))
  (str.const "n=7"))
(assert_return (invoke "maybe-pair" (option.none)) (str.const "none"))

(assert_return
  (invoke "entries"
    (list.const
      (record.const (field "k" str.const "a") (field "v" u32.const 1))
      (record.const (field "k" str.const "b") (field "v" u32.const 2))))
  (str.const "a1b2"))

(assert_return
  (invoke "deep"
    (list.const
      (option.some (tuple.const (str.const "x") (list.const (u32.const 1) (u32.const 2))))
      (option.none)
      (option.some (tuple.const (str.const "y") (list.const (u32.const 3))))))
  (str.const "x12noney3"))

(assert_return
  (invoke "concat-u32s"
    (list.const (u32.const 0) (u32.const 1) (u32.const 2) (u32.const 3) (u32.const 4) (u32.const 5) (u32.const 6) (u32.const 7) (u32.const 8) (u32.const 9) (u32.const 10) (u32.const 11) (u32.const 12) (u32.const 13) (u32.const 14) (u32.const 15) (u32.const 16) (u32.const 17) (u32.const 18) (u32.const 19) (u32.const 20) (u32.const 21) (u32.const 22) (u32.const 23) (u32.const 24) (u32.const 25) (u32.const 26) (u32.const 27) (u32.const 28) (u32.const 29) (u32.const 30) (u32.const 31) (u32.const 32) (u32.const 33) (u32.const 34) (u32.const 35) (u32.const 36) (u32.const 37) (u32.const 38) (u32.const 39) (u32.const 40) (u32.const 41) (u32.const 42) (u32.const 43) (u32.const 44) (u32.const 45) (u32.const 46) (u32.const 47) (u32.const 48) (u32.const 49) (u32.const 50) (u32.const 51) (u32.const 52) (u32.const 53) (u32.const 54) (u32.const 55) (u32.const 56) (u32.const 57) (u32.const 58) (u32.const 59) (u32.const 60) (u32.const 61) (u32.const 62) (u32.const 63)))
  (str.const "0123456789101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263"))

(assert_return
  (invoke "echo" (str.const "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"))
  (str.const "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz"))

(assert_return (invoke "bignum" (u64.const 18446744073709551615)) (str.const "18446744073709551615"))

(assert_return (invoke "flat-mix" (variant.const "a" (u32.const 42))) (str.const "42"))
(assert_return (invoke "flat-mix" (variant.const "b" (f32.const 5))) (str.const "5"))
(assert_return (invoke "flat-mix" (variant.const "c" (u64.const 18446744073709551615))) (str.const "18446744073709551615"))
(assert_return (invoke "flat-mix" (variant.const "d" (f64.const 9))) (str.const "9"))
(assert_return (invoke "flat-pad" (variant.const "p" (tuple.const (f32.const 2) (f32.const 3)))) (str.const "23"))
(assert_return (invoke "flat-pad" (variant.const "q" (u32.const 42))) (str.const "42"))

(assert_return
  (invoke "list-variant"
    (list.const
      (variant.const "n" (u32.const 1))
      (variant.const "s" (str.const "two"))
      (variant.const "n" (u32.const 3))
      (variant.const "s" (str.const "!"))))
  (str.const "1two3!"))
(assert_return (invoke "list-variant" (list.const)) (str.const ""))
(assert_return
  (invoke "list-variant2"
    (list.const
      (variant.const "b" (u8.const 7))
      (variant.const "w" (u64.const 18446744073709551615))
      (variant.const "b" (u8.const 255))))
  (str.const "718446744073709551615255"))

;; map<K,V> values cannot be written directly in WAST (there is no map.const
;; yet), so each map-taking function in $C is called through a forwarding
;; component $D whose exports take the despecialized list<tuple<K,V>> instead.
(component
  (component $C
    (core module $CM
      (memory (export "mem") 4)

      ;; "true"=[64,4] "false"=[68,5]
      (data (i32.const 64) "truefalse")

      (global $next (mut i32) (i32.const 65536))
      (func (export "realloc") (param $old i32) (param $os i32) (param $al i32) (param $ns i32) (result i32)
        (local $r i32)
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $ns)))
        (local.get $r))

      (global $w (mut i32) (i32.const 1024))
      (func $emit (param $src i32) (param $len i32)
        (memory.copy (global.get $w) (local.get $src) (local.get $len))
        (global.set $w (i32.add (global.get $w) (local.get $len))))
      (func $emit_char (param $c i32)
        (i32.store8 (global.get $w) (local.get $c))
        (global.set $w (i32.add (global.get $w) (i32.const 1))))
      (func $u64toa (param $v i64) (result i32 i32)
        (local $p i32)
        (local.set $p (i32.const 48))
        (block $z
          (br_if $z (i64.eqz (local.get $v)))
          (loop $l
            (local.set $p (i32.sub (local.get $p) (i32.const 1)))
            (i32.store8 (local.get $p)
              (i32.add (i32.const 48)
                (i32.wrap_i64 (i64.rem_u (local.get $v) (i64.const 10)))))
            (local.set $v (i64.div_u (local.get $v) (i64.const 10)))
            (br_if $l (i64.ne (local.get $v) (i64.const 0))))
          (return (local.get $p) (i32.sub (i32.const 48) (local.get $p))))
        (i32.store8 (i32.const 47) (i32.const 48))
        (i32.const 47) (i32.const 1))
      (func $emit_u64 (param $v i64)
        (local $p i32) (local $l i32)
        (call $u64toa (local.get $v))
        (local.set $l)
        (local.set $p)
        (call $emit (local.get $p) (local.get $l)))
      (func $emit_bool (param $b i32)
        (if (local.get $b)
          (then (call $emit (i32.const 64) (i32.const 4)))
          (else (call $emit (i32.const 68) (i32.const 5)))))
      (func $emit_u32_list (param $ptr i32) (param $len i32)
        (local $i i32)
        (block $d (loop $l
          (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
          (call $emit_u64 (i64.extend_i32_u (i32.load (i32.add (local.get $ptr) (i32.mul (local.get $i) (i32.const 4))))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l))))
      (func $emit_u8_list (param $ptr i32) (param $len i32)
        (local $i i32)
        (block $d (loop $l
          (br_if $d (i32.ge_u (local.get $i) (local.get $len)))
          (call $emit_u64 (i64.extend_i32_u (i32.load8_u (i32.add (local.get $ptr) (local.get $i)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l))))
      (func $finish (result i32)
        (i32.store (i32.const 0) (i32.const 1024))
        (i32.store (i32.const 4) (i32.sub (global.get $w) (i32.const 1024)))
        (i32.const 0))

      (func (export "map-str-u32") (param $p i32) (param $n i32) (result i32)
        (local $i i32) (local $e i32)
        (global.set $w (i32.const 1024))
        (block $d (loop $l
          (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $e (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 12))))
          (call $emit (i32.load (local.get $e)) (i32.load offset=4 (local.get $e)))
          (call $emit_u64 (i64.extend_i32_u (i32.load offset=8 (local.get $e))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
        (call $finish))

      (func (export "map-u32-str") (param $p i32) (param $n i32) (result i32)
        (local $i i32) (local $e i32)
        (global.set $w (i32.const 1024))
        (block $d (loop $l
          (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $e (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 12))))
          (call $emit_u64 (i64.extend_i32_u (i32.load (local.get $e))))
          (call $emit (i32.load offset=4 (local.get $e)) (i32.load offset=8 (local.get $e)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
        (call $finish))

      (func (export "map-char-bool") (param $p i32) (param $n i32) (result i32)
        (local $i i32) (local $e i32)
        (global.set $w (i32.const 1024))
        (block $d (loop $l
          (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $e (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 8))))
          (call $emit_char (i32.load (local.get $e)))
          (call $emit_bool (i32.load8_u offset=4 (local.get $e)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
        (call $finish))

      (func (export "map-u8-u64") (param $p i32) (param $n i32) (result i32)
        (local $i i32) (local $e i32)
        (global.set $w (i32.const 1024))
        (block $d (loop $l
          (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $e (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 16))))
          (call $emit_u64 (i64.extend_i32_u (i32.load8_u (local.get $e))))
          (call $emit_u64 (i64.load offset=8 (local.get $e)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
        (call $finish))

      (func (export "map-str-list") (param $p i32) (param $n i32) (result i32)
        (local $i i32) (local $e i32)
        (global.set $w (i32.const 1024))
        (block $d (loop $l
          (br_if $d (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $e (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 16))))
          (call $emit (i32.load (local.get $e)) (i32.load offset=4 (local.get $e)))
          (call $emit_u32_list (i32.load offset=8 (local.get $e)) (i32.load offset=12 (local.get $e)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $l)))
        (call $finish))

      ;; map<string, map<string, list<u8>>>:
      (func (export "map-str-map") (param $p i32) (param $n i32) (result i32)
        (local $i i32) (local $e i32) (local $ip i32) (local $il i32) (local $j i32) (local $ie i32)
        (global.set $w (i32.const 1024))
        (block $od (loop $ol
          (br_if $od (i32.ge_u (local.get $i) (local.get $n)))
          (local.set $e (i32.add (local.get $p) (i32.mul (local.get $i) (i32.const 16))))
          (call $emit (i32.load (local.get $e)) (i32.load offset=4 (local.get $e)))
          (local.set $ip (i32.load offset=8 (local.get $e)))
          (local.set $il (i32.load offset=12 (local.get $e)))
          (local.set $j (i32.const 0))
          (block $id (loop $il2
            (br_if $id (i32.ge_u (local.get $j) (local.get $il)))
            (local.set $ie (i32.add (local.get $ip) (i32.mul (local.get $j) (i32.const 16))))
            (call $emit (i32.load (local.get $ie)) (i32.load offset=4 (local.get $ie)))
            (call $emit_u8_list (i32.load offset=8 (local.get $ie)) (i32.load offset=12 (local.get $ie)))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $il2)))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br $ol)))
        (call $finish))
    )
    (core instance $cm (instantiate $CM))
    (func (export "map-str-u32") (param "a" (map string u32)) (result string)
      (canon lift (core func $cm "map-str-u32") (memory (core memory $cm "mem")) (realloc (core func $cm "realloc"))))
    (func (export "map-u32-str") (param "a" (map u32 string)) (result string)
      (canon lift (core func $cm "map-u32-str") (memory (core memory $cm "mem")) (realloc (core func $cm "realloc"))))
    (func (export "map-char-bool") (param "a" (map char bool)) (result string)
      (canon lift (core func $cm "map-char-bool") (memory (core memory $cm "mem")) (realloc (core func $cm "realloc"))))
    (func (export "map-u8-u64") (param "a" (map u8 u64)) (result string)
      (canon lift (core func $cm "map-u8-u64") (memory (core memory $cm "mem")) (realloc (core func $cm "realloc"))))
    (func (export "map-str-list") (param "a" (map string (list u32))) (result string)
      (canon lift (core func $cm "map-str-list") (memory (core memory $cm "mem")) (realloc (core func $cm "realloc"))))
    (func (export "map-str-map") (param "a" (map string (map string (list u8)))) (result string)
      (canon lift (core func $cm "map-str-map") (memory (core memory $cm "mem")) (realloc (core func $cm "realloc"))))
  )

  (component $D
    (import "c" (instance $c
      (export "map-str-u32" (func (param "a" (map string u32)) (result string)))
      (export "map-u32-str" (func (param "a" (map u32 string)) (result string)))
      (export "map-char-bool" (func (param "a" (map char bool)) (result string)))
      (export "map-u8-u64" (func (param "a" (map u8 u64)) (result string)))
      (export "map-str-list" (func (param "a" (map string (list u32))) (result string)))
      (export "map-str-map" (func (param "a" (map string (map string (list u8)))) (result string)))))

    (core module $DM
      (memory (export "mem") 4)
      (global $next (mut i32) (i32.const 65536))
      (func (export "realloc") (param $old i32) (param $os i32) (param $al i32) (param $ns i32) (result i32)
        (local $r i32)
        (global.set $next (i32.and (i32.add (global.get $next) (i32.const 7)) (i32.const -8)))
        (local.set $r (global.get $next))
        (global.set $next (i32.add (global.get $next) (local.get $ns)))
        (local.get $r))
    )
    (core instance $dm (instantiate $DM))

    (core func $map-str-u32' (canon lower (func $c "map-str-u32")
      (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
    (core func $map-u32-str' (canon lower (func $c "map-u32-str")
      (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
    (core func $map-char-bool' (canon lower (func $c "map-char-bool")
      (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
    (core func $map-u8-u64' (canon lower (func $c "map-u8-u64")
      (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
    (core func $map-str-list' (canon lower (func $c "map-str-list")
      (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
    (core func $map-str-map' (canon lower (func $c "map-str-map")
      (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))

    ;; Each forwarder passes its (ptr, len) list-of-pairs args straight through
    ;; to the map-taking import and returns the string written at retptr 16.
    (core module $Fwd
      (import "" "map-str-u32" (func $str-u32 (param i32 i32 i32)))
      (import "" "map-u32-str" (func $u32-str (param i32 i32 i32)))
      (import "" "map-char-bool" (func $char-bool (param i32 i32 i32)))
      (import "" "map-u8-u64" (func $u8-u64 (param i32 i32 i32)))
      (import "" "map-str-list" (func $str-list (param i32 i32 i32)))
      (import "" "map-str-map" (func $str-map (param i32 i32 i32)))
      (func (export "map-str-u32") (param $p i32) (param $n i32) (result i32)
        (call $str-u32 (local.get $p) (local.get $n) (i32.const 16))
        (i32.const 16))
      (func (export "map-u32-str") (param $p i32) (param $n i32) (result i32)
        (call $u32-str (local.get $p) (local.get $n) (i32.const 16))
        (i32.const 16))
      (func (export "map-char-bool") (param $p i32) (param $n i32) (result i32)
        (call $char-bool (local.get $p) (local.get $n) (i32.const 16))
        (i32.const 16))
      (func (export "map-u8-u64") (param $p i32) (param $n i32) (result i32)
        (call $u8-u64 (local.get $p) (local.get $n) (i32.const 16))
        (i32.const 16))
      (func (export "map-str-list") (param $p i32) (param $n i32) (result i32)
        (call $str-list (local.get $p) (local.get $n) (i32.const 16))
        (i32.const 16))
      (func (export "map-str-map") (param $p i32) (param $n i32) (result i32)
        (call $str-map (local.get $p) (local.get $n) (i32.const 16))
        (i32.const 16))
    )
    (core instance $fwd (instantiate $Fwd
      (with "" (instance
        (export "map-str-u32" (func $map-str-u32'))
        (export "map-u32-str" (func $map-u32-str'))
        (export "map-char-bool" (func $map-char-bool'))
        (export "map-u8-u64" (func $map-u8-u64'))
        (export "map-str-list" (func $map-str-list'))
        (export "map-str-map" (func $map-str-map'))))))

    (func (export "map-str-u32") (param "a" (list (tuple string u32))) (result string)
      (canon lift (core func $fwd "map-str-u32") (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
    (func (export "map-u32-str") (param "a" (list (tuple u32 string))) (result string)
      (canon lift (core func $fwd "map-u32-str") (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
    (func (export "map-char-bool") (param "a" (list (tuple char bool))) (result string)
      (canon lift (core func $fwd "map-char-bool") (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
    (func (export "map-u8-u64") (param "a" (list (tuple u8 u64))) (result string)
      (canon lift (core func $fwd "map-u8-u64") (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
    (func (export "map-str-list") (param "a" (list (tuple string (list u32)))) (result string)
      (canon lift (core func $fwd "map-str-list") (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
    (func (export "map-str-map") (param "a" (list (tuple string (list (tuple string (list u8)))))) (result string)
      (canon lift (core func $fwd "map-str-map") (memory (core memory $dm "mem")) (realloc (core func $dm "realloc"))))
  )

  (instance $c (instantiate $C))
  (instance $d (instantiate $D (with "c" (instance $c))))
  (func (export "map-str-u32") (alias export $d "map-str-u32"))
  (func (export "map-u32-str") (alias export $d "map-u32-str"))
  (func (export "map-char-bool") (alias export $d "map-char-bool"))
  (func (export "map-u8-u64") (alias export $d "map-u8-u64"))
  (func (export "map-str-list") (alias export $d "map-str-list"))
  (func (export "map-str-map") (alias export $d "map-str-map"))
)

(assert_return
  (invoke "map-str-u32"
    (list.const
      (tuple.const (str.const "a") (u32.const 1))
      (tuple.const (str.const "b") (u32.const 2))
      (tuple.const (str.const "c") (u32.const 3))))
  (str.const "a1b2c3"))
(assert_return (invoke "map-str-u32" (list.const)) (str.const ""))

(assert_return
  (invoke "map-str-u32"
    (list.const
      (tuple.const (str.const "z") (u32.const 26))
      (tuple.const (str.const "k") (u32.const 1))
      (tuple.const (str.const "k") (u32.const 2))
      (tuple.const (str.const "a") (u32.const 0))))
  (str.const "z26k1k2a0"))

(assert_return
  (invoke "map-u32-str"
    (list.const
      (tuple.const (u32.const 10) (str.const "x"))
      (tuple.const (u32.const 20) (str.const "y"))))
  (str.const "10x20y"))

(assert_return
  (invoke "map-char-bool"
    (list.const
      (tuple.const (char.const "A") (bool.const true))
      (tuple.const (char.const "z") (bool.const false))))
  (str.const "Atruezfalse"))

(assert_return
  (invoke "map-u8-u64"
    (list.const
      (tuple.const (u8.const 255) (u64.const 18446744073709551615))
      (tuple.const (u8.const 0) (u64.const 7))))
  (str.const "2551844674407370955161507"))

(assert_return
  (invoke "map-str-list"
    (list.const
      (tuple.const (str.const "p") (list.const (u32.const 1) (u32.const 2)))
      (tuple.const (str.const "q") (list.const))
      (tuple.const (str.const "r") (list.const (u32.const 3)))))
  (str.const "p12qr3"))

(assert_return
  (invoke "map-str-map"
    (list.const
      (tuple.const (str.const "a")
        (list.const
          (tuple.const (str.const "x") (list.const (u8.const 1) (u8.const 2)))
          (tuple.const (str.const "y") (list.const))))
      (tuple.const (str.const "b") (list.const))
      (tuple.const (str.const "c")
        (list.const
          (tuple.const (str.const "z") (list.const (u8.const 255) (u8.const 0) (u8.const 7)))))
      (tuple.const (str.const "k")
        (list.const (tuple.const (str.const "d") (list.const (u8.const 0)))))
      (tuple.const (str.const "k")
        (list.const
          (tuple.const (str.const "d") (list.const (u8.const 7) (u8.const 8)))
          (tuple.const (str.const "d") (list.const (u8.const 9)))))
    ))
  (str.const "ax12ybcz25507kd0kd78d9"))
(assert_return (invoke "map-str-map" (list.const)) (str.const ""))
