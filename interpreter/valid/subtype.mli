open Etypes

val iibb_search_inst : ctx -> extern_decl list -> int -> extern_decl -> def_type option

type resolved_tyvar =
  | RTV_definite of def_type
  | RTV_bound of int
  | RTV_evar of int * int * type_bound
  | RTV_uvar of int * int * type_bound

val resolve_tyvar : ctx -> tyvar -> resolved_tyvar

val subtype_core_extern_desc : ctx -> core_extern_desc -> core_extern_desc -> unit

val subtype_val_type : ctx -> val_type -> val_type -> unit
val subtype_val_type_option : ctx -> val_type option -> val_type option -> unit
val subtype_extern_desc : ctx -> extern_desc -> extern_desc -> unit
val def_type_is_resource : ctx -> def_type -> unit
