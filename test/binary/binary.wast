;; Binary format tests. See design/mvp/Binary.md
;; Note that 0xD is used as the version throughout, but this will be changed to
;; 1 when the component model is fully standardized.

;; preamble: magic, version (0x0d 0x00) and layer (0x01 0x00)

(component binary "\00asm\0d\00\01\00")
(component binary "\00asm" "\0d\00\01\00")
(component $B1 binary "\00asm" "\0d\00\01\00")
(assert_malformed (component binary "") "unexpected end")
(assert_malformed (component binary "\00") "unexpected end")
(assert_malformed (component binary "\00as") "unexpected end")
(assert_malformed (component binary "\00asm") "unexpected end")
(assert_malformed (component binary "\00asm" "\0d") "unexpected end")
(assert_malformed (component binary "\00asm" "\0d\00") "unexpected end")
(assert_malformed (component binary "\00asm" "\0d\00\01") "unexpected end")
(assert_malformed (component binary "asm\00" "\0d\00\01\00") "magic header not detected")
(assert_malformed (component binary "msa\00" "\0d\00\01\00") "magic header not detected")
(assert_malformed (component binary "\00ASM" "\0d\00\01\00") "magic header not detected")
(assert_malformed (component binary "\ffasm" "\0d\00\01\00") "magic header not detected")
(assert_malformed (component binary "\00asm" "\0c\00\01\00") "unknown binary version")
(assert_malformed (component binary "\00asm" "\0e\00\01\00") "unknown binary version")
(assert_malformed (component binary "\00asm" "\00\0d\01\00") "unknown binary version")
(assert_malformed (component binary "\00asm" "\0d\00\02\00") "unknown binary version")
(assert_malformed (component binary "\00asm" "\0d\00\01\01") "unknown binary version")
(assert_malformed (component binary "\00asm" "\0d\00\00\00") "unknown binary version")

;; custom sections (id 0)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\00\03"                                    ;; custom section (3 bytes)
  "\02hi"                                     ;; name "hi"
)
(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\00\12"                                    ;; custom section (18 bytes)
  "\0ecomponent-name"                         ;; name "component-name"
  "\ff\fe\01"                                 ;; garbage: validity is not required
  "\00\10"                                    ;; custom section (16 bytes)
  "\0ecomponent-name"                         ;; name "component-name"
  "\99"                                       ;; more garbage, repeated name is fine
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\00\03"                                  ;; custom section (3 bytes)
    "\05\61\62"                               ;; name length 5, only 2 bytes
  )
  "unexpected end-of-file"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\00\03"                                  ;; custom section (3 bytes)
    "\02\ff\fe"                               ;; name is not valid UTF-8
  )
  "malformed UTF-8 encoding"
)

;; non-custom sections

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\0d\00"                                  ;; section id 13, empty
  )
  "malformed section id"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\3c\00"                                  ;; section id 60, empty
  )
  "malformed section id"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\ff"                                     ;; malformed section id byte
  )
  "malformed section id"
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\03\00"                               ;; type section: size 3, one byte of contents
  )
  "unexpected end-of-file"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\01\01\73"                            ;; type section: size 1, two bytes of contents
  )
  "section size mismatch"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\00\80\80"                               ;; custom section: size LEB runs past EOF
  )
  "unexpected end-of-file"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\00"                                     ;; section id with no size
  )
  "unexpected end-of-file"
)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\01"                                    ;; type section (1 bytes)
  "\00"                                       ;; 0 types
)
(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\05\01"                                    ;; instance section (1 bytes)
  "\00"                                       ;; 0 instances
  "\08\01"                                    ;; canon section (1 bytes)
  "\00"                                       ;; 0 canons
)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\02"                                    ;; type section (2 bytes)
  "\01"                                       ;; 1 type
  "\73"                                       ;; string
  "\06\05"                                    ;; alias section (5 bytes)
  "\01"                                       ;; 1 alias
  "\03\02\00\00"                              ;; outer alias: type, ct=0, idx=0
  "\00\08"                                    ;; custom section (8 bytes)
  "\07between"                                ;; name "between"
  "\07\03"                                    ;; type section (3 bytes)
  "\01"                                       ;; 1 type
  "\70\01"                                    ;; (list <type 1>), the alias
)

;; LEB128: overlong-but-zero-padded u32 encodings are valid; set bits past
;; the 32nd are not. Vector counts larger than the remaining input fail.

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\81\80\80\80\00"                        ;; type section, 5-byte LEB size 1
  "\00"                                       ;; 0 types
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\81\80\80\80\70"                      ;; type section: size LEB with bits >u32
    "\00"                                     ;; 0 types
  )
  "integer too large"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\04"                                  ;; type section (4 bytes)
    "\bf\84\3d"                               ;; vec count 999999
    "\73"                                     ;; string
  )
  "unexpected end-of-file"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\02"                                  ;; type section (2 bytes)
    "\02"                                     ;; 2 types
    "\73"                                     ;; only one given
  )
  "unexpected end-of-file"
)

;; core module section (id 1)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\01\08"                                    ;; core module section: empty module (8 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
)
(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\01\1f"                                    ;; core module section (31 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
  "\01\04\01\60\00\00"                        ;; type section: (func)
  "\03\02\01\00"                              ;; func section: 1 func of type 0
  "\07\05\01"                                 ;; export section, 1 export
  "\01f"                                      ;; name "f"
  "\00\00"                                    ;; func 0
  "\0a\04\01\02\00\0b"                        ;; code section: 1 empty body
  "\02\04"                                    ;; core instance section (4 bytes)
  "\01"                                       ;; 1 core instance
  "\00\00\00"                                 ;; instantiate module 0, 0 args
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\01\11"                                  ;; core module section (17 bytes)
    "\00asm" "\01\00\00\00"                   ;; core module preamble
    "\01\01\00"                               ;; type section, 0 types
    "\0b\01\00"                               ;; data section, 0 segments
    "\01\01\00"                               ;; type section again: out of order
  )
  "section out of order"
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\01\08"                                  ;; core module section (8 bytes)
    "\00asm" "\0d\00\01\00"                   ;; a component preamble, not a core module
  )
  "unknown binary version"
)

;; core instance section (id 2)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\01\1f"                                    ;; core module section (31 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
  "\01\04\01\60\00\00"                        ;; type section: (func)
  "\03\02\01\00"                              ;; func section: 1 func of type 0
  "\07\05\01"                                 ;; export section, 1 export
  "\01f"                                      ;; name "f"
  "\00\00"                                    ;; func 0
  "\0a\04\01\02\00\0b"                        ;; code section: 1 empty body
  "\02\06"                                    ;; core instance section (6 bytes)
  "\02"                                       ;; 2 core instances
  "\00\00\00"                                 ;; 0x00 instantiate module 0, 0 args
  "\01\00"                                    ;; 0x01 inline exports, 0 exports
  "\06\07"                                    ;; alias section (7 bytes)
  "\01"                                       ;; 1 aliases
  "\00\00\01\00"                              ;; core func, core export alias, instance 0
  "\01f"                                      ;; name "f"
  "\02\08"                                    ;; core instance section (8 bytes)
  "\01"                                       ;; 1 core instance
  "\01\01"                                    ;; 0x01 inline exports, 1 export:
  "\02f2"                                     ;; name "f2"
  "\00\00"                                    ;; core:sortidx func 0 (the alias)
)
(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\01\14"                                    ;; core module section: imports ("i" "mem") (20 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
  "\02\0a"                                    ;; import section (10 bytes)
  "\01"                                       ;; 1 import
  "\01i"                                      ;; name "i"
  "\03mem"                                    ;; name "mem"
  "\02\00\01"                                 ;; memory, limits {min 1}
  "\01\16"                                    ;; core module section: exports "mem" (22 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
  "\05\03\01\00\01"                           ;; memory section: 1 memory
  "\07\07"                                    ;; export section (7 bytes)
  "\01"                                       ;; 1 export
  "\03mem"                                    ;; name "mem"
  "\02\00"                                    ;; memory 0
  "\02\0b"                                    ;; core instance section (11 bytes)
  "\02"                                       ;; 2 core instances
  "\00\01\00"                                 ;; instantiate module 1, 0 args
  "\00\00\01"                                 ;; instantiate module 0, 1 arg:
  "\01i"                                      ;; name "i"
  "\12\00"                                    ;; 0x12 (instance sort) instance 0
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\01\08"                                  ;; core module section (8 bytes)
    "\00asm" "\01\00\00\00"                   ;; core module preamble
    "\02\04"                                  ;; core instance section (4 bytes)
    "\01"                                     ;; 1 core instance
    "\02\00\00"                               ;; 0x02 is not a core:instanceexpr
  )
  "invalid leading byte (0x2) for core instance"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\01\08"                                  ;; core module section (8 bytes)
    "\00asm" "\01\00\00\00"                   ;; core module preamble
    "\02\04"                                  ;; core instance section (4 bytes)
    "\01"                                     ;; 1 core instance
    "\00\00\00"                               ;; instantiate module 0, 0 args
    "\01\08"                                  ;; core module section (8 bytes)
    "\00asm" "\01\00\00\00"                   ;; core module preamble
    "\02\08"                                  ;; core instance section (8 bytes)
    "\01"                                     ;; 1 core instance
    "\00\01\01"                               ;; instantiate module 1, 1 arg:
    "\01i"                                    ;; name "i"
    "\00\00"                                  ;; arg sort must be 0x12 (instance), not 0x00 (func)
  )
  "invalid leading byte (0x0) for instantiation arg kind"
)

;; instance section (id 5)

(component definition binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\05"                                    ;; type section (5 bytes)
  "\01"                                       ;; 1 type
  "\40\00\01\00"                              ;; (func)
  "\0a\06"                                    ;; import section (6 bytes)
  "\01"                                       ;; 1 import
  "\00"                                       ;; plain externname
  "\01f"                                      ;; name "f"
  "\01\00"                                    ;; func (type 0)
  "\04\17"                                    ;; component section: nested component (23 bytes)
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\05"                                    ;; type section (5 bytes)
  "\01"                                       ;; 1 type
  "\40\00\01\00"                              ;; (func)
  "\0a\06"                                    ;; import section (6 bytes)
  "\01"                                       ;; 1 import
  "\00"                                       ;; plain externname
  "\01x"                                      ;; name "x"
  "\01\00"                                    ;; func (type 0)
  "\05\11"                                    ;; instance section (17 bytes)
  "\03"                                       ;; 3 instances
  "\00\00\01"                                 ;; 0x00 instantiate component 0, 1 arg:
  "\01x"                                      ;; name "x"
  "\01\00"                                    ;; sortidx func 0
  "\01\00"                                    ;; 0x01 inline exports, 0 exports
  "\01\01"                                    ;; 0x01 inline exports, 1 export:
  "\00"                                       ;; plain externname
  "\01g"                                      ;; name "g"
  "\01\00"                                    ;; sortidx func 0
  "\06\06"                                    ;; alias section (6 bytes)
  "\01"                                       ;; 1 alias
  "\01\00\02"                                 ;; func, 0x00 export alias, instance 2
  "\01g"                                      ;; name "g"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\05\04"                                  ;; instance section (4 bytes)
    "\01"                                     ;; 1 instance
    "\02\00\00"                               ;; 0x02 is not an instanceexpr
  )
  "invalid leading byte (0x2) for instance"
)

;; alias section (id 6)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\01\51"                                    ;; core module section (81 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
  "\01\08\02\60\00\00\60\01\7f\00"            ;; type section: (func), (func (param i32))
  "\03\03\02\00\01"                           ;; func section: 2 funcs
  "\04\04\01\70\00\01"                        ;; table section: funcref table
  "\05\03\01\00\01"                           ;; memory section: 1 memory
  "\06\06\01\7f\00\41\00\0b"                  ;; global section: i32 global
  "\07\1c\05"                                 ;; export section, 5 exports
  "\01f"                                      ;; name "f"
  "\00\00"                                    ;; func 0
  "\01g"                                      ;; name "g"
  "\00\01"                                    ;; func 1
  "\03mem"                                    ;; name "mem"
  "\02\00"                                    ;; memory 0
  "\03tbl"                                    ;; name "tbl"
  "\01\00"                                    ;; table 0
  "\04glob"                                   ;; name "glob"
  "\03\00"                                    ;; global 0
  "\0a\07\02\02\00\0b\02\00\0b"               ;; code section: 2 empty bodies
  "\02\04"                                    ;; core instance section (4 bytes)
  "\01"                                       ;; 1 core instance
  "\00\00\00"                                 ;; instantiate module 0, 0 args
  "\06\20"                                    ;; alias section (32 bytes)
  "\04"                                       ;; 4 aliases
  "\00\00\01\00"                              ;; core func, 0x01 core export alias, instance 0
  "\01f"                                      ;; name "f"
  "\00\01\01\00"                              ;; core table, core export alias, instance 0
  "\03tbl"                                    ;; name "tbl"
  "\00\02\01\00"                              ;; core memory, core export alias, instance 0
  "\03mem"                                    ;; name "mem"
  "\00\03\01\00"                              ;; core global, core export alias, instance 0
  "\04glob"                                   ;; name "glob"
)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\01\08"                                    ;; core module section (8 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
  "\03\04"                                    ;; core type section (4 bytes)
  "\01"                                       ;; 1 core type
  "\60\00\00"                                 ;; core functype ()->()
  "\07\02"                                    ;; type section (2 bytes)
  "\01"                                       ;; 1 type
  "\73"                                       ;; string
  "\04\08"                                    ;; component section: nested component (8 bytes)
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\06\13"                                    ;; alias section (19 bytes)
  "\04"                                       ;; 4 aliases
  "\00\11\02\00\00"                           ;; core module, 0x02 outer alias, ct=0, idx=0
  "\00\10\02\00\00"                           ;; core type, outer alias, ct=0, idx=0
  "\03\02\00\00"                              ;; type, outer alias, ct=0, idx=0
  "\04\02\00\00"                              ;; component, outer alias, ct=0, idx=0
)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\02"                                    ;; type section (2 bytes)
  "\01"                                       ;; 1 type
  "\73"                                       ;; string
  "\05\08"                                    ;; instance section (8 bytes)
  "\01"                                       ;; 1 instance
  "\01\01"                                    ;; inline exports, 1 export:
  "\00"                                       ;; plain externname
  "\01t"                                      ;; name "t"
  "\03\00"                                    ;; sortidx type 0
  "\06\06"                                    ;; alias section (6 bytes)
  "\01"                                       ;; 1 alias
  "\03\00\00"                                 ;; type, 0x00 export alias, instance 0
  "\01t"                                      ;; name "t"
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\02"                                  ;; type section (2 bytes)
    "\01"                                     ;; 1 type
    "\73"                                     ;; string
    "\06\05"                                  ;; alias section (5 bytes)
    "\01"                                     ;; 1 alias
    "\03\03\00\00"                            ;; 0x03 is not an alias target
  )
  "invalid leading byte (0x3) for alias"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\06\05"                                  ;; alias section (5 bytes)
    "\01"                                     ;; 1 alias
    "\06\02\00\00"                            ;; 0x06 is not a sort
  )
  "invalid leading byte (0x6) for component outer alias kind"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\06\06"                                  ;; alias section (6 bytes)
    "\01"                                     ;; 1 alias
    "\00\05\02\00\00"                         ;; 0x05 is not a core:sort
  )
  "invalid leading byte (0x5) for component outer alias kind"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\06\06"                                  ;; alias section (6 bytes)
    "\01"                                     ;; 1 alias
    "\00\13\02\00\00"                         ;; 0x13 is not a core:sort
  )
  "invalid leading byte (0x13) for component outer alias kind"
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\05\03"                                  ;; instance section (3 bytes)
    "\01"                                     ;; 1 instance
    "\01\00"                                  ;; inline exports, 0 exports
    "\06\05"                                  ;; alias section (5 bytes)
    "\01"                                     ;; 1 alias
    "\05\02\00\00"                            ;; instance is not in outeraliassort
  )
  "invalid leading byte (0x5) for component outer alias kind"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\06\05"                                  ;; alias section (5 bytes)
    "\01"                                     ;; 1 alias
    "\01\02\00\00"                            ;; func is not in outeraliassort
  )
  "invalid leading byte (0x1) for component outer alias kind"
)

(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\02"                                  ;; type section (2 bytes)
    "\01"                                     ;; 1 type
    "\73"                                     ;; string
    "\06\05"                                  ;; alias section (5 bytes)
    "\01"                                     ;; 1 alias
    "\03\02\02\00"                            ;; outer alias ct=2: only 1 enclosing scope
  )
  "invalid outer alias count of 2"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\05\03"                                  ;; instance section (3 bytes)
    "\01"                                     ;; 1 instance
    "\01\00"                                  ;; inline exports, 0 exports
    "\06\06"                                  ;; alias section (6 bytes)
    "\01"                                     ;; 1 alias
    "\03\00\00"                               ;; type export alias, instance 0
    "\01t"                                    ;; name "t": no such export
  )
  "instance 0 has no export named `t`"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\01\08"                                  ;; core module section (8 bytes)
    "\00asm" "\01\00\00\00"                   ;; core module preamble
    "\02\04"                                  ;; core instance section (4 bytes)
    "\01"                                     ;; 1 core instance
    "\00\00\00"                               ;; instantiate module 0, 0 args
    "\06\07"                                  ;; alias section (7 bytes)
    "\01"                                     ;; 1 alias
    "\00\00\01\00"                            ;; core func export alias, core instance 0
    "\01f"                                    ;; name "f": no such export
  )
  "core instance 0 has no export named `f`"
)

;; type section (id 7): primitive value types

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\0e"                                    ;; type section (14 bytes)
  "\0d"                                       ;; 13 types
  "\7f"                                       ;; bool
  "\7e"                                       ;; s8
  "\7d"                                       ;; u8
  "\7c"                                       ;; s16
  "\7b"                                       ;; u16
  "\7a"                                       ;; s32
  "\79"                                       ;; u32
  "\78"                                       ;; s64
  "\77"                                       ;; u64
  "\76"                                       ;; f32
  "\75"                                       ;; f64
  "\74"                                       ;; char
  "\73"                                       ;; string
)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\4f"                                    ;; type section (79 bytes)
  "\13"                                       ;; 19 types
  "\3f\7f\00"                                 ;; (resource (rep i32)), no dtor
  "\72\02"                                    ;; 0x72 record, 2 fields
  "\01a"                                      ;; name "a"
  "\7f"                                       ;; bool
  "\01b"                                      ;; name "b"
  "\7d"                                       ;; u8
  "\71\02"                                    ;; 0x71 variant, 2 cases
  "\01x"                                      ;; name "x"
  "\01\7e"                                    ;; payload present: s8
  "\00"                                       ;; case immediate (must be zero)
  "\01y"                                      ;; name "y"
  "\00"                                       ;; no payload
  "\00"                                       ;; case immediate (must be zero)
  "\70\7b"                                    ;; 0x70 (list u16)
  "\6f\02\7c\79"                              ;; 0x6f (tuple s16 u32)
  "\6e\02"                                    ;; 0x6e flags, 2 labels
  "\02f1"                                     ;; name "f1"
  "\02f2"                                     ;; name "f2"
  "\6d\02"                                    ;; 0x6d enum, 2 labels
  "\02e1"                                     ;; name "e1"
  "\02e2"                                     ;; name "e2"
  "\6b\7a"                                    ;; 0x6b (option s32)
  "\6a\00\00"                                 ;; 0x6a (result)
  "\6a\01\77\00"                              ;; (result u64)
  "\6a\00\01\78"                              ;; (result (error s64))
  "\6a\01\76\01\75"                           ;; (result f32 (error f64))
  "\69\00"                                    ;; 0x69 (own 0)
  "\68\00"                                    ;; 0x68 (borrow 0)
  "\66\01\7d"                                 ;; 0x66 (stream u8)
  "\66\00"                                    ;; (stream)
  "\65\01\73"                                 ;; 0x65 (future string)
  "\65\00"                                    ;; (future)
  "\70\02"                                    ;; (list <type 2>): valtype as typeidx
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\02"                                  ;; type section (2 bytes)
    "\01"                                     ;; 1 type
    "\62"                                     ;; 0x62 is unallocated
  )
  "invalid leading byte (0x62) for component defined type"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\02"                                  ;; type section (2 bytes)
    "\01"                                     ;; 1 type
    "\44"                                     ;; 0x44 is unallocated
  )
  "invalid leading byte (0x44) for component defined type"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\02"                                  ;; type section (2 bytes)
    "\01"                                     ;; 1 type
    "\3e"                                     ;; 0x3e is unallocated
  )
  "invalid leading byte (0x3e) for component defined type"
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\07"                                  ;; type section (7 bytes)
    "\01"                                     ;; 1 type
    "\71\01"                                  ;; variant, 1 case
    "\01c"                                    ;; name "c"
    "\00"                                     ;; no payload
    "\01"                                     ;; nonzero case immediate
  )
  "invalid leading byte (0x1) for zero byte required"
)

(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\03"                                  ;; type section (3 bytes)
    "\01"                                     ;; 1 type
    "\72\00"                                  ;; record, 0 fields
  )
  "record type must have at least one field"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\03"                                  ;; type section (3 bytes)
    "\01"                                     ;; 1 type
    "\71\00"                                  ;; variant, 0 cases
  )
  "variant type must have at least one case"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\03"                                  ;; type section (3 bytes)
    "\01"                                     ;; 1 type
    "\6f\00"                                  ;; tuple, 0 types
  )
  "tuple type must have at least one type"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\03"                                  ;; type section (3 bytes)
    "\01"                                     ;; 1 type
    "\6e\00"                                  ;; flags, 0 labels
  )
  "flags must have at least one entry"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\03"                                  ;; type section (3 bytes)
    "\01"                                     ;; 1 type
    "\6d\00"                                  ;; enum, 0 labels
  )
  "enum type must have at least one variant"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\87\01"                               ;; type section (135 bytes)
    "\01"                                     ;; 1 type
    "\6e\21"                                  ;; flags, 33 labels
    "\03f00"                                  ;; name "f00"
    "\03f01"                                  ;; name "f01"
    "\03f02"                                  ;; name "f02"
    "\03f03"                                  ;; name "f03"
    "\03f04"                                  ;; name "f04"
    "\03f05"                                  ;; name "f05"
    "\03f06"                                  ;; name "f06"
    "\03f07"                                  ;; name "f07"
    "\03f08"                                  ;; name "f08"
    "\03f09"                                  ;; name "f09"
    "\03f10"                                  ;; name "f10"
    "\03f11"                                  ;; name "f11"
    "\03f12"                                  ;; name "f12"
    "\03f13"                                  ;; name "f13"
    "\03f14"                                  ;; name "f14"
    "\03f15"                                  ;; name "f15"
    "\03f16"                                  ;; name "f16"
    "\03f17"                                  ;; name "f17"
    "\03f18"                                  ;; name "f18"
    "\03f19"                                  ;; name "f19"
    "\03f20"                                  ;; name "f20"
    "\03f21"                                  ;; name "f21"
    "\03f22"                                  ;; name "f22"
    "\03f23"                                  ;; name "f23"
    "\03f24"                                  ;; name "f24"
    "\03f25"                                  ;; name "f25"
    "\03f26"                                  ;; name "f26"
    "\03f27"                                  ;; name "f27"
    "\03f28"                                  ;; name "f28"
    "\03f29"                                  ;; name "f29"
    "\03f30"                                  ;; name "f30"
    "\03f31"                                  ;; name "f31"
    "\03f32"                                  ;; name "f32"
  )
  "cannot have more than 32 flags"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\03"                                  ;; type section (3 bytes)
    "\01"                                     ;; 1 type
    "\70\05"                                  ;; (list <type 5>): no such type
  )
  "type index out of bounds"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\04"                                  ;; type section (4 bytes)
    "\02"                                     ;; 2 types
    "\73"                                     ;; string
    "\69\00"                                  ;; (own 0): not a resource type
  )
  "type index 0 is not a resource type"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\04"                                  ;; type section (4 bytes)
    "\01"                                     ;; 1 type
    "\66\01\74"                               ;; (stream char)
  )
  "is not valid at this time"
)

;; function types

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\10"                                    ;; type section (16 bytes)
  "\03"                                       ;; 3 types
  "\40\00\01\00"                              ;; 0x40 (func): 0 params, resultlist 0x01 0x00
  "\40\01"                                    ;; (func): 1 param:
  "\01p"                                      ;; name "p"
  "\7f"                                       ;; bool
  "\00\79"                                    ;; resultlist: 0x00 u32
  "\43\00\01\00"                              ;; 0x43 (func async)
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\05"                                  ;; type section (5 bytes)
    "\01"                                     ;; 1 type
    "\40\00"                                  ;; (func): 0 params
    "\01\01"                                  ;; resultlist 0x01 must be followed by 0x00
  )
  "invalid leading byte (0x1) for number of results"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\05"                                  ;; type section (5 bytes)
    "\01"                                     ;; 1 type
    "\40\00"                                  ;; (func): 0 params
    "\02\00"                                  ;; 0x02 is not a resultlist
  )
  "invalid leading byte (0x2) for component function results"
)

;; resource types

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\01\51"                                    ;; core module section (81 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
  "\01\08\02\60\00\00\60\01\7f\00"            ;; type section: (func), (func (param i32))
  "\03\03\02\00\01"                           ;; func section: 2 funcs
  "\04\04\01\70\00\01"                        ;; table section: funcref table
  "\05\03\01\00\01"                           ;; memory section: 1 memory
  "\06\06\01\7f\00\41\00\0b"                  ;; global section: i32 global
  "\07\1c\05"                                 ;; export section, 5 exports
  "\01f"                                      ;; name "f"
  "\00\00"                                    ;; func 0
  "\01g"                                      ;; name "g"
  "\00\01"                                    ;; func 1
  "\03mem"                                    ;; name "mem"
  "\02\00"                                    ;; memory 0
  "\03tbl"                                    ;; name "tbl"
  "\01\00"                                    ;; table 0
  "\04glob"                                   ;; name "glob"
  "\03\00"                                    ;; global 0
  "\0a\07\02\02\00\0b\02\00\0b"               ;; code section: 2 empty bodies
  "\02\04"                                    ;; core instance section (4 bytes)
  "\01"                                       ;; 1 core instance
  "\00\00\00"                                 ;; instantiate module 0, 0 args
  "\06\0d"                                    ;; alias section (13 bytes)
  "\02"                                       ;; 2 aliases
  "\00\00\01\00"                              ;; core func, core export alias, instance 0
  "\01f"                                      ;; name "f"
  "\00\00\01\00"                              ;; core func, core export alias, instance 0
  "\01g"                                      ;; name "g"
  "\07\08"                                    ;; type section (8 bytes)
  "\02"                                       ;; 2 types
  "\3f\7f\00"                                 ;; (resource (rep i32)), no dtor
  "\3f\7f\01\01"                              ;; (resource (rep i32) (dtor <core func 1>))
)

;; component types and instance types

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\17"                                    ;; type section (23 bytes)
  "\01"                                       ;; 1 type
  "\41\04"                                    ;; 0x41 componenttype, 4 decls
  "\01\73"                                    ;; 0x01 type: string
  "\03\00"                                    ;; 0x03 importdecl, plain externname:
  "\01a"                                      ;; name "a"
  "\03\00\00"                                 ;; (type (eq 0))
  "\01\40\00\01\00"                           ;; 0x01 type: (func)
  "\04\00"                                    ;; 0x04 exportdecl, plain externname:
  "\01b"                                      ;; name "b"
  "\01\02"                                    ;; (func (type 2))
)
(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\02"                                    ;; type section (2 bytes)
  "\01"                                       ;; 1 type
  "\73"                                       ;; string
  "\07\13"                                    ;; type section (19 bytes)
  "\01"                                       ;; 1 type
  "\42\03"                                    ;; 0x42 instancetype, 3 decls
  "\00\60\00\00"                              ;; 0x00 core type: functype ()->()
  "\02\03\02\01\00"                           ;; 0x02 alias: type, outer, ct=1, idx=0
  "\04\00"                                    ;; 0x04 exportdecl, plain externname:
  "\01t"                                      ;; name "t"
  "\03\00\00"                                 ;; (type (eq 0))
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\05"                                  ;; type section (5 bytes)
    "\01"                                     ;; 1 type
    "\41\01"                                  ;; componenttype, 1 decl
    "\05\73"                                  ;; 0x05 is not a declarator
  )
  "invalid leading byte (0x5) for component or instance type declaration"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\09"                                  ;; type section (9 bytes)
    "\01"                                     ;; 1 type
    "\42\01"                                  ;; instancetype, 1 decl
    "\03\00"                                  ;; 0x03 importdecl is not an instancedecl:
    "\01a"                                    ;; name "a"
    "\03\01"                                  ;; (type (sub resource))
  )
  "invalid leading byte (0x3) for component or instance type declaration"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\07"                                  ;; type section (7 bytes)
    "\01"                                     ;; 1 type
    "\41\01"                                  ;; componenttype, 1 decl
    "\01\3f\7f\00"                            ;; 0x01 type: resource type
  )
  "resources can only be defined within a concrete component"
)

;; core type section (id 3): core functypes and core module types. Because
;; the 0x50 opcode is shared with a non-final core:subtype, a non-final
;; `sub` in this position takes a 0x00 prefix (`0x00 0x50 ...`) while a bare
;; 0x50 is a core:moduletype (pre-1.0 wart).
(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\03\04"                                    ;; core type section (4 bytes)
  "\01"                                       ;; 1 core type
  "\60\00\00"                                 ;; core functype ()->()
  "\03\07"                                    ;; core type section (7 bytes)
  "\01"                                       ;; 1 core type
  "\00\50"                                    ;; 0x00-prefixed non-final subtype
  "\00"                                       ;; 0 supertypes
  "\60\00\00"                                 ;; core functype ()->()
  "\03\18"                                    ;; core type section (24 bytes)
  "\01"                                       ;; 1 core type
  "\50\04"                                    ;; 0x50 core:moduletype, 4 decls
  "\01\60\00\00"                              ;; 0x01 type: core functype ()->()
  "\00"                                       ;; 0x00 import:
  "\01a"                                      ;; name "a"
  "\01b"                                      ;; name "b"
  "\00\00"                                    ;; (func (type 0))
  "\02\10\01\01\00"                           ;; 0x02 alias: 0x10 type, 0x01 outer, ct=1, idx=0
  "\03"                                       ;; 0x03 exportdecl:
  "\01e"                                      ;; name "e"
  "\00\00"                                    ;; (func (type 0))
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\03\07"                                  ;; core type section (7 bytes)
    "\01"                                     ;; 1 core type
    "\50\01"                                  ;; core:moduletype, 1 decl
    "\04\60\00\00"                            ;; 0x04 is not a core:moduledecl
  )
  "invalid leading byte (0x4) for type definition"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\03\08"                                  ;; core type section (8 bytes)
    "\01"                                     ;; 1 core type
    "\50\01"                                  ;; core:moduletype, 1 decl
    "\02\00\01\01\00"                         ;; core:alias sort must be 0x10 (type)
  )
  "invalid leading byte (0x0) for outer alias kind"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\03\08"                                  ;; core type section (8 bytes)
    "\01"                                     ;; 1 core type
    "\50\01"                                  ;; core:moduletype, 1 decl
    "\02\10\00\01\00"                         ;; core:alias target must be 0x01 (outer)
  )
  "invalid leading byte (0x0) for outer alias target"
)

(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\03\0a"                                  ;; core type section (10 bytes)
    "\01"                                     ;; 1 core type
    "\50\02"                                  ;; core:moduletype, 2 decls
    "\01\50\00"                               ;; 0x01 type: nested core:moduletype
    "\01\60\00\00"                            ;; 0x01 type: core functype
  )
  "invalid leading byte"
)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\04"                                    ;; type section (4 bytes)
  "\01"                                       ;; 1 type
  "\67\7d\03"                                 ;; (list u8 3)
)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\04"                                    ;; type section (4 bytes)
  "\01"                                       ;; 1 type
  "\63\73\79"                                 ;; (map string u32)
)

;; canonical section (id 8)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\01\9b\01"                                 ;; core module section: f, g, run, cb, dtor, realloc, mem, tbl (155 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
  "\01\20\06"                                 ;; type section, 6 types
  "\60\00\00"                                 ;; ()->()
  "\60\02\7f\7f\00"                           ;; (i32,i32)->()
  "\60\00\01\7f"                              ;; ()->(i32)
  "\60\03\7f\7f\7f\01\7f"                     ;; (i32,i32,i32)->(i32)
  "\60\01\7f\00"                              ;; (i32)->()
  "\60\04\7f\7f\7f\7f\01\7f"                  ;; (i32,i32,i32,i32)->(i32)
  "\03\07\06\00\01\02\03\04\05"               ;; func section: 6 funcs
  "\04\04\01\70\00\01"                        ;; table section: funcref table
  "\05\03\01\00\01"                           ;; memory section: 1 memory
  "\06\06\01\7f\00\41\00\0b"                  ;; global section: i32 global
  "\07\38\09"                                 ;; export section, 9 exports
  "\01f"                                      ;; name "f"
  "\00\00"                                    ;; func 0
  "\01g"                                      ;; name "g"
  "\00\01"                                    ;; func 1
  "\03run"                                    ;; name "run"
  "\00\02"                                    ;; func 2
  "\02cb"                                     ;; name "cb"
  "\00\03"                                    ;; func 3
  "\04dtor"                                   ;; name "dtor"
  "\00\04"                                    ;; func 4
  "\07realloc"                                ;; name "realloc"
  "\00\05"                                    ;; func 5
  "\03mem"                                    ;; name "mem"
  "\02\00"                                    ;; memory 0
  "\03tbl"                                    ;; name "tbl"
  "\01\00"                                    ;; table 0
  "\04glob"                                   ;; name "glob"
  "\03\00"                                    ;; global 0
  "\0a\19\06"                                 ;; code section, 6 bodies
  "\02\00\0b"                                 ;; f
  "\02\00\0b"                                 ;; g
  "\04\00\41\00\0b"                           ;; run: i32.const 0
  "\04\00\41\00\0b"                           ;; cb: i32.const 0
  "\02\00\0b"                                 ;; dtor
  "\04\00\41\00\0b"                           ;; realloc: i32.const 0
  "\02\04"                                    ;; core instance section (4 bytes)
  "\01"                                       ;; 1 core instance
  "\00\00\00"                                 ;; instantiate module 0, 0 args
  "\06\41"                                    ;; alias section (65 bytes)
  "\08"                                       ;; 8 aliases
  "\00\00\01\00"                              ;; core func f: ()->()
  "\01f"                                      ;; name "f"
  "\00\00\01\00"                              ;; core func g: (i32,i32)->()
  "\01g"                                      ;; name "g"
  "\00\00\01\00"                              ;; core func run: ()->(i32)
  "\03run"                                    ;; name "run"
  "\00\00\01\00"                              ;; core func cb: (i32,i32,i32)->(i32)
  "\02cb"                                     ;; name "cb"
  "\00\00\01\00"                              ;; core func dtor: (i32)->()
  "\04dtor"                                   ;; name "dtor"
  "\00\00\01\00"                              ;; core func realloc
  "\07realloc"                                ;; name "realloc"
  "\00\02\01\00"                              ;; core memory
  "\03mem"                                    ;; name "mem"
  "\00\01\01\00"                              ;; core table
  "\03tbl"                                    ;; name "tbl"
  "\07\19"                                    ;; type section (25 bytes)
  "\06"                                       ;; 6 types
  "\40\00\01\00"                              ;; type 0: (func)
  "\40\01"                                    ;; type 1: (func (param "p" string)):
  "\01p"                                      ;; name "p"
  "\73"                                       ;; string
  "\01\00"                                    ;; no result
  "\43\00\01\00"                              ;; type 2: (func async)
  "\66\01\7d"                                 ;; type 3: (stream u8)
  "\65\00"                                    ;; type 4: (future)
  "\3f\7f\01\04"                              ;; type 5: (resource (rep i32) (dtor <dtor>))
  "\03\05"                                    ;; core type section (5 bytes)
  "\01"                                       ;; 1 core type
  "\60\01\7f\00"                              ;; core functype (i32)->()
  "\08\93\01"                                 ;; canon section (147 bytes)
  "\2f"                                       ;; 47 canons
  "\00\00\00\00\00"                           ;; lift core func 0 (f), no opts, type 0
  "\00\00\01\03\00\03\00\04\05\01"            ;; lift core func 1 (g), utf8 + (memory 0) + (realloc 5), type 1
  "\00\00\02\02\06\07\03\02"                  ;; lift core func 2 (run), async + (callback 3), type 2
  "\00\00\00\01\05\00\00"                     ;; lift core func 0, (post-return 0), type 0
  "\01\00\00\01\01"                           ;; lower func 0, string-encoding=utf16
  "\01\00\00\01\02"                           ;; lower func 0, string-encoding=latin1+utf16
  "\02\05"                                    ;; 0x02 resource.new (type 5)
  "\03\05"                                    ;; 0x03 resource.drop (type 5)
  "\04\05"                                    ;; 0x04 resource.rep (type 5)
  "\24"                                       ;; 0x24 backpressure.inc
  "\25"                                       ;; 0x25 backpressure.dec
  "\09\01\00\00"                              ;; 0x09 task.return, no result, no opts
  "\09\00\79\00"                              ;; task.return (result u32), no opts
  "\05"                                       ;; 0x05 task.cancel
  "\0a\7f\00"                                 ;; 0x0a context.get i32 0
  "\0b\7f\00"                                 ;; 0x0b context.set i32 0
  "\06\00"                                    ;; 0x06 subtask.cancel
  "\06\01"                                    ;; subtask.cancel async
  "\0d"                                       ;; 0x0d subtask.drop
  "\0e\03"                                    ;; 0x0e stream.new (type 3)
  "\0f\03\02\03\00\04\05"                     ;; 0x0f stream.read, (memory 0) (realloc 5)
  "\10\03\02\03\00\04\05"                     ;; 0x10 stream.write, (memory 0) (realloc 5)
  "\11\03\00"                                 ;; 0x11 stream.cancel-read
  "\12\03\01"                                 ;; 0x12 stream.cancel-write async
  "\13\03"                                    ;; 0x13 stream.drop-readable
  "\14\03"                                    ;; 0x14 stream.drop-writable
  "\15\04"                                    ;; 0x15 future.new (type 4)
  "\16\04\02\03\00\04\05"                     ;; 0x16 future.read, (memory 0) (realloc 5)
  "\17\04\02\03\00\04\05"                     ;; 0x17 future.write, (memory 0) (realloc 5)
  "\18\04\00"                                 ;; 0x18 future.cancel-read
  "\19\04\01"                                 ;; 0x19 future.cancel-write async
  "\1a\04"                                    ;; 0x1a future.drop-readable
  "\1b\04"                                    ;; 0x1b future.drop-writable
  "\1f"                                       ;; 0x1f waitable-set.new
  "\20\00\00"                                 ;; 0x20 waitable-set.wait (memory 0)
  "\21\01\00"                                 ;; 0x21 waitable-set.poll cancellable (memory 0)
  "\22"                                       ;; 0x22 waitable-set.drop
  "\23"                                       ;; 0x23 waitable.join
  "\26"                                       ;; 0x26 thread.index
  "\27\00\00"                                 ;; 0x27 thread.new-indirect (core type 0) (table 0)
  "\28"                                       ;; 0x28 thread.resume-later
  "\29\00"                                    ;; 0x29 thread.suspend
  "\0c\01"                                    ;; 0x0c thread.yield cancellable
  "\2a\00"                                    ;; 0x2a thread.suspend-then-resume
  "\2b\00"                                    ;; 0x2b thread.yield-then-resume
  "\2c\00"                                    ;; 0x2c thread.suspend-then-promote
  "\2d\01"                                    ;; 0x2d thread.yield-then-promote cancellable
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\08\02"                                  ;; canon section (2 bytes)
    "\01"                                     ;; 1 canon
    "\07"                                     ;; 0x07 is unallocated
  )
  "invalid leading byte (0x7) for canonical function"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\08\02"                                  ;; canon section (2 bytes)
    "\01"                                     ;; 1 canon
    "\2e"                                     ;; 0x2e is unallocated
  )
  "invalid leading byte (0x2e) for canonical function"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\08\02"                                  ;; canon section (2 bytes)
    "\01"                                     ;; 1 canon
    "\43"                                     ;; 0x43 is unallocated
  )
  "invalid leading byte (0x43) for canonical function"
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\08\06"                                  ;; canon section (6 bytes)
    "\01"                                     ;; 1 canon
    "\00\01\00\00\00"                         ;; lift with sort byte 0x01
  )
  "invalid leading byte (0x1) for canonical function lift"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\08\05"                                  ;; canon section (5 bytes)
    "\01"                                     ;; 1 canon
    "\01\01\00\00"                            ;; lower with sort byte 0x01
  )
  "invalid leading byte (0x1) for canonical function lower"
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\05"                                  ;; type section (5 bytes)
    "\01"                                     ;; 1 type
    "\40\00\01\00"                            ;; (func)
    "\0a\06"                                  ;; import section (6 bytes)
    "\01"                                     ;; 1 import
    "\00"                                     ;; plain externname
    "\01f"                                    ;; name "f"
    "\01\00"                                  ;; func (type 0)
    "\08\06"                                  ;; canon section (6 bytes)
    "\01"                                     ;; 1 canon
    "\01\00\00\01\0a"                         ;; lower func 0, 1 opt: 0x0a is unallocated
  )
  "invalid leading byte (0xa) for canonical option"
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\08\03"                                  ;; canon section (3 bytes)
    "\01"                                     ;; 1 canon
    "\0c\02"                                  ;; thread.yield with flag 0x02
  )
  "invalid boolean value"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\08\04"                                  ;; canon section (4 bytes)
    "\01"                                     ;; 1 canon
    "\20\02\00"                               ;; waitable-set.wait with flag 0x02
  )
  "invalid boolean value"
)

;; import section (id 10) and export section (id 11)

(component definition binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\05"                                    ;; type section (5 bytes)
  "\01"                                       ;; 1 type
  "\40\00\01\00"                              ;; (func)
  "\0a\11"                                    ;; import section (17 bytes)
  "\03"                                       ;; 3 imports
  "\00"                                       ;; 0x00-prefixed externname
  "\01a"                                      ;; name "a"
  "\01\00"                                    ;; func (type 0)
  "\01"                                       ;; 0x01-prefixed externname: same meaning
  "\01b"                                      ;; name "b"
  "\01\00"                                    ;; func (type 0)
  "\02"                                       ;; 0x02-prefixed externname
  "\01c"                                      ;; name "c"
  "\00"                                       ;; 0 attributes
  "\01\00"                                    ;; func (type 0)
)

(component definition binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\03"                                    ;; type section (3 bytes)
  "\01"                                       ;; 1 type
  "\42\00"                                    ;; empty instancetype
  "\0a\2f"                                    ;; import section (47 bytes)
  "\02"                                       ;; 2 imports
  "\02"                                       ;; externname with attributes
  "\02i1"                                     ;; name "i1"
  "\01"                                       ;; 1 attribute:
  "\00"                                       ;; 0x00 implements:
  "\0cmy:dep/iface"                           ;; name "my:dep/iface"
  "\05\00"                                    ;; instance (type 0)
  "\02"                                       ;; externname with attributes
  "\02i2"                                     ;; name "i2"
  "\01"                                       ;; 1 attribute:
  "\02"                                       ;; 0x02 external-id:
  "\10some-external-id"                       ;; name "some-external-id"
  "\05\00"                                    ;; instance (type 0)
)

(component definition binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\03\03"                                    ;; core type section (3 bytes)
  "\01"                                       ;; 1 core type
  "\50\00"                                    ;; empty core:moduletype
  "\07\08"                                    ;; type section (8 bytes)
  "\03"                                       ;; 3 types
  "\40\00\01\00"                              ;; (func)
  "\42\00"                                    ;; empty instancetype
  "\73"                                       ;; string
  "\0a\1e"                                    ;; import section (30 bytes)
  "\05"                                       ;; 5 imports
  "\00"                                       ;; plain externname
  "\01m"                                      ;; name "m"
  "\00\11\00"                                 ;; 0x00 0x11 core module (core type 0)
  "\00"                                       ;; plain externname
  "\01f"                                      ;; name "f"
  "\01\00"                                    ;; 0x01 func (type 0)
  "\00"                                       ;; plain externname
  "\02t1"                                     ;; name "t1"
  "\03\00\02"                                 ;; 0x03 type, bound 0x00: (eq 2)
  "\00"                                       ;; plain externname
  "\02t2"                                     ;; name "t2"
  "\03\01"                                    ;; 0x03 type, bound 0x01: (sub resource)
  "\00"                                       ;; plain externname
  "\01i"                                      ;; name "i"
  "\05\01"                                    ;; 0x05 instance (type 1)
)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\04\15"                                    ;; component section: nested component (21 bytes)
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\03"                                    ;; type section (3 bytes)
  "\01"                                       ;; 1 type
  "\41\00"                                    ;; empty componenttype
  "\0a\06"                                    ;; import section (6 bytes)
  "\01"                                       ;; 1 import
  "\00"                                       ;; plain externname
  "\01c"                                      ;; name "c"
  "\04\00"                                    ;; 0x04 component (type 0)
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\0a\06"                                  ;; import section (6 bytes)
    "\01"                                     ;; 1 import
    "\03"                                     ;; 0x03 is not a nameattributes prefix
    "\01a"                                    ;; name "a"
    "\01\00"                                  ;; func (type 0)
  )
  "invalid leading byte (0x3) for component name"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\0a\0a"                                  ;; import section (10 bytes)
    "\01"                                     ;; 1 import
    "\02"                                     ;; externname with attributes
    "\01a"                                    ;; name "a"
    "\01"                                     ;; 1 attribute:
    "\03"                                     ;; 0x03 is not an attribute
    "\01x"                                    ;; name "x"
    "\01\00"                                  ;; func (type 0)
  )
  "invalid leading byte (0x3) for name option"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\0a\06"                                  ;; import section (6 bytes)
    "\01"                                     ;; 1 import
    "\00"                                     ;; plain externname
    "\01t"                                    ;; name "t"
    "\03\02"                                  ;; 0x02 is not a typebound
  )
  "invalid leading byte (0x2) for type bound"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\0a\06"                                  ;; import section (6 bytes)
    "\01"                                     ;; 1 import
    "\00"                                     ;; plain externname
    "\01x"                                    ;; name "x"
    "\06\00"                                  ;; 0x06 is not an externtype
  )
  "invalid leading byte (0x6) for component external kind"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\0a\06"                                  ;; import section (6 bytes)
    "\01"                                     ;; 1 import
    "\00"                                     ;; plain externname
    "\01m"                                    ;; name "m"
    "\00\00"                                  ;; externtype 0x00 must be followed by 0x11
  )
  "invalid leading byte (0x0) for component external kind"
)

(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\0a\05"                                  ;; import section (5 bytes)
    "\01"                                     ;; 1 import
    "\00"                                     ;; plain externname
    "\7f\61\62"                               ;; name length 127, only 2 bytes follow
  )
  "unexpected end-of-file"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\0a\07"                                  ;; import section (7 bytes)
    "\01"                                     ;; 1 import
    "\00"                                     ;; plain externname
    "\02\ff\fe"                               ;; name is not valid UTF-8
    "\01\00"                                  ;; func (type 0)
  )
  "malformed UTF-8 encoding"
)

(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\05"                                  ;; type section (5 bytes)
    "\01"                                     ;; 1 type
    "\40\00\01\00"                            ;; (func)
    "\0a\08"                                  ;; import section (8 bytes)
    "\01"                                     ;; 1 import
    "\00"                                     ;; plain externname
    "\03Foo"                                  ;; name "Foo": not kebab-case
    "\01\00"                                  ;; func (type 0)
  )
  "is not a valid extern name"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\05"                                  ;; type section (5 bytes)
    "\01"                                     ;; 1 type
    "\40\00\01\00"                            ;; (func)
    "\0a\05"                                  ;; import section (5 bytes)
    "\01"                                     ;; 1 import
    "\00"                                     ;; plain externname
    "\00"                                     ;; empty name
    "\01\00"                                  ;; func (type 0)
  )
  "is not a valid extern name"
)
(assert_invalid
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\03"                                  ;; type section (3 bytes)
    "\01"                                     ;; 1 type
    "\42\00"                                  ;; empty instancetype
    "\0a\15"                                  ;; import section (21 bytes)
    "\01"                                     ;; 1 import
    "\02"                                     ;; externname with attributes
    "\01i"                                    ;; name "i"
    "\02"                                     ;; 2 attributes:
    "\00"                                     ;; implements:
    "\05a:b/x"                                ;; name "a:b/x"
    "\00"                                     ;; implements again: at most one of each kind
    "\05a:b/y"                                ;; name "a:b/y"
    "\05\00"                                  ;; instance (type 0)
  )
  "duplicate 'implements' option in name"
)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\01\1f"                                    ;; core module section (31 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
  "\01\04\01\60\00\00"                        ;; type section: (func)
  "\03\02\01\00"                              ;; func section: 1 func of type 0
  "\07\05\01"                                 ;; export section, 1 export
  "\01f"                                      ;; name "f"
  "\00\00"                                    ;; func 0
  "\0a\04\01\02\00\0b"                        ;; code section: 1 empty body
  "\02\04"                                    ;; core instance section (4 bytes)
  "\01"                                       ;; 1 core instance
  "\00\00\00"                                 ;; instantiate module 0, 0 args
  "\06\07"                                    ;; alias section (7 bytes)
  "\01"                                       ;; 1 aliases
  "\00\00\01\00"                              ;; core func, core export alias, instance 0
  "\01f"                                      ;; name "f"
  "\07\05"                                    ;; type section (5 bytes)
  "\01"                                       ;; 1 type
  "\40\00\01\00"                              ;; (func)
  "\08\06"                                    ;; canon section (6 bytes)
  "\01"                                       ;; 1 canon
  "\00\00\00\00\00"                           ;; lift core func 0, no opts, type 0
  "\0b\11"                                    ;; export section (17 bytes)
  "\02"                                       ;; 2 exports
  "\00"                                       ;; plain externname
  "\02e1"                                     ;; name "e1"
  "\01\00"                                    ;; sortidx func 0
  "\00"                                       ;; no ascribed type
  "\00"                                       ;; plain externname
  "\02e2"                                     ;; name "e2"
  "\01\00"                                    ;; sortidx func 0
  "\01\01\00"                                 ;; ascribed type: func (type 0)
)
(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\01\08"                                    ;; core module section (8 bytes)
  "\00asm" "\01\00\00\00"                     ;; core module preamble
  "\0b\08"                                    ;; export section (8 bytes)
  "\01"                                       ;; 1 export
  "\00"                                       ;; plain externname
  "\01m"                                      ;; name "m"
  "\00\11\00"                                 ;; sortidx core module 0
  "\00"                                       ;; no ascribed type
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\01\1f"                                  ;; core module section (31 bytes)
    "\00asm" "\01\00\00\00"                   ;; core module preamble
    "\01\04\01\60\00\00"                      ;; type section: (func)
    "\03\02\01\00"                            ;; func section: 1 func of type 0
    "\07\05\01"                               ;; export section, 1 export
    "\01f"                                    ;; name "f"
    "\00\00"                                  ;; func 0
    "\0a\04\01\02\00\0b"                      ;; code section: 1 empty body
    "\02\04"                                  ;; core instance section (4 bytes)
    "\01"                                     ;; 1 core instance
    "\00\00\00"                               ;; instantiate module 0, 0 args
    "\06\07"                                  ;; alias section (7 bytes)
    "\01"                                     ;; 1 aliases
    "\00\00\01\00"                            ;; core func, core export alias, instance 0
    "\01f"                                    ;; name "f"
    "\07\05"                                  ;; type section (5 bytes)
    "\01"                                     ;; 1 type
    "\40\00\01\00"                            ;; (func)
    "\08\06"                                  ;; canon section (6 bytes)
    "\01"                                     ;; 1 canon
    "\00\00\00\00\00"                         ;; lift core func 0, no opts, type 0
    "\0b\07"                                  ;; export section (7 bytes)
    "\01"                                     ;; 1 export
    "\00"                                     ;; plain externname
    "\01e"                                    ;; name "e"
    "\01\00"                                  ;; sortidx func 0
    "\02"                                     ;; optional-externtype byte must be 0x00 or 0x01
  )
  "invalid leading byte (0x2) for optional component export type"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\01\1f"                                  ;; core module section (31 bytes)
    "\00asm" "\01\00\00\00"                   ;; core module preamble
    "\01\04\01\60\00\00"                      ;; type section: (func)
    "\03\02\01\00"                            ;; func section: 1 func of type 0
    "\07\05\01"                               ;; export section, 1 export
    "\01f"                                    ;; name "f"
    "\00\00"                                  ;; func 0
    "\0a\04\01\02\00\0b"                      ;; code section: 1 empty body
    "\02\04"                                  ;; core instance section (4 bytes)
    "\01"                                     ;; 1 core instance
    "\00\00\00"                               ;; instantiate module 0, 0 args
    "\06\07"                                  ;; alias section (7 bytes)
    "\01"                                     ;; 1 aliases
    "\00\00\01\00"                            ;; core func, core export alias, instance 0
    "\01f"                                    ;; name "f"
    "\07\05"                                  ;; type section (5 bytes)
    "\01"                                     ;; 1 type
    "\40\00\01\00"                            ;; (func)
    "\08\06"                                  ;; canon section (6 bytes)
    "\01"                                     ;; 1 canon
    "\00\00\00\00\00"                         ;; lift core func 0, no opts, type 0
    "\0b\07"                                  ;; export section (7 bytes)
    "\01"                                     ;; 1 export
    "\00"                                     ;; plain externname
    "\01e"                                    ;; name "e"
    "\06\00"                                  ;; 0x06 is not a sort
    "\00"                                     ;; no ascribed type
  )
  "invalid leading byte (0x6) for component external kind"
)

;; component section (id 4)

(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\04\08"                                    ;; component section (8 bytes)
  "\00asm" "\0d\00\01\00"                     ;; preamble
)
(component binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\04\16"                                    ;; component section (22 bytes)
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\04\0c"                                    ;; component section (nested twice) (12 bytes)
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\02"                                    ;; type section (2 bytes)
  "\01"                                       ;; 1 type
  "\73"                                       ;; string
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\04\08"                                  ;; component section (8 bytes)
    "\00asm" "\0c\00\01\00"                   ;; nested preamble with bad version
  )
  "unknown binary version"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\04\08"                                  ;; component section (8 bytes)
    "\00asm" "\01\00\00\00"                   ;; a core module preamble, not a component
  )
  "expected a version header for a component"
)
