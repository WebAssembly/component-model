;; Binary format of `optional`

(component definition binary
  "\00asm" "\0d\00\01\00"                     ;; preamble
  "\07\1b"                                    ;; type section (27 bytes)
  "\06"                                       ;; 6 types
  "\44\00\00\01\00"                           ;; 0x44 0x00: (func)
  "\44\01\00\01\00"                           ;; 0x44 0x01: (func optional)
  "\44\02\00\01\00"                           ;; 0x44 0x02: (func async)
  "\44\03\00\01\00"                           ;; 0x44 0x03: (func optional async)
  "\45\00\00"                                 ;; 0x45 0x00: (instance)
  "\45\01\00"                                 ;; 0x45 0x01: (instance optional)
  "\0a\12"                                    ;; import section (18 bytes)
  "\03"                                       ;; 3 imports
  "\00\01f"                                   ;; plain externname "f"
  "\01\01"                                    ;; (func (type 1))
  "\00\01t"                                   ;; plain externname "t"
  "\03\02\01"                                 ;; 0x02 0x01: (type (sub optional resource))
  "\00\01u"                                   ;; plain externname "u"
  "\03\02\00"                                 ;; 0x02 0x00: (type (sub resource))
  "\05\04"                                    ;; instance section (4 bytes)
  "\01"                                       ;; 1 instance
  "\02\04\00"                                 ;; 0x02: (instance (type 4)), 0 inline exports
  "\08\07"                                    ;; canon section (7 bytes)
  "\02"                                       ;; 2 canons
  "\07\01\00"                                 ;; 0x07: optional.present (func 0)
  "\07\03\06"                                 ;; 0x07: optional.present (type 6)
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\06"                                  ;; type section (6 bytes)
    "\01"                                     ;; 1 type
    "\44\04\00\01\00"                         ;; 0x04 is not a funcimms
  )
  "invalid leading byte (0x4)"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\07\04"                                  ;; type section (4 bytes)
    "\01"                                     ;; 1 type
    "\45\02\00"                               ;; 0x02 is not an opt?
  )
  "invalid leading byte (0x2)"
)
(assert_malformed
  (component binary
    "\00asm" "\0d\00\01\00"                   ;; preamble
    "\0a\07"                                  ;; import section (7 bytes)
    "\01"                                     ;; 1 import
    "\00\01t"                                 ;; plain externname "t"
    "\03\02\02"                               ;; 0x02 is not an opt?
  )
  "invalid leading byte (0x2)"
)
