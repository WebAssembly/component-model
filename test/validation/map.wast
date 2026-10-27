;; (map K V) validation

(component definition
  (type (map bool u8))
  (type (map s8 u8))
  (type (map u8 u8))
  (type (map s16 u8))
  (type (map u16 u8))
  (type (map s32 u8))
  (type (map u32 u8))
  (type (map s64 u8))
  (type (map u64 u8))
  (type (map char u8))
  (type (map string u8))
  (type (map string f64))
  (type (map string string))
  (type (map string (list u8)))
  (type (map string (tuple u8 string)))
  (type (map string (record (field "a" u32) (field "b" string))))
  (type (map string (variant (case "a") (case "b" u32))))
  (type (map string (enum "x" "y")))
  (type (map string (flags "p" "q")))
  (type (map string (option string)))
  (type (map string (result u32 (error string))))
  (type (map string (map u32 (list string))))
  (type (list (map string u32)))
  (type (option (map u32 string)))
  (type (stream (map string u32)))
  (type (future (map string u32)))
  (type (func (param "m" (map string u32)) (result (map u32 string))))
)

(assert_invalid
  (component (type (map f32 u8)))
  "invalid map key type")
(assert_invalid
  (component (type (map (list u8) u8)))
  "invalid map key type")
(assert_invalid
  (component (type (map (tuple u8 u8) u8)))
  "invalid map key type")
(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (type (map (own $R) u8)))
  "invalid map key type")
(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (type (map u32 (own $R))))
  "map value type cannot contain a handle")
(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (type (map string (option (borrow $R)))))
  "map value type cannot contain a handle")
(assert_invalid
  (component
    (type (map string (record (field "f" (future u8))))))
  "map value type cannot contain a handle")
(assert_invalid
  (component
    (type (map u8 (list (stream u8)))))
  "map value type cannot contain a handle")
(assert_invalid
  (component
    (type $FT (future))
    (type (map char (variant (case "a") (case "b" $FT)))))
  "map value type cannot contain a handle")
(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (type $Rec (record (field "r" (own $R))))
    (type (map u32 $Rec)))
  "map value type cannot contain a handle")
(assert_invalid
  (component
    (type $R (resource (rep i32)))
    (type (map string (map string (tuple u32 (own $R))))))
  "map value type cannot contain a handle")
(assert_invalid
  (component
    (import "r" (type $R (sub resource)))
    (import "f" (func (param "m" (map string (own $R))))))
  "map value type cannot contain a handle")
