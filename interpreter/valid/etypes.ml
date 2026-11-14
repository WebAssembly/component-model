open Ast

exception Invalid of Source.region * string

type bound_tyvar = int (* de bruijn index *)
type free_tyvar =
  | FTV_uvar of int * int
  | FTV_evar of int * int
type tyvar =
  | TV_bound of bound_tyvar
  | TV_free of free_tyvar

type 'a alive_dead = { ad_contents : 'a ; ad_live : bool }

type val_type =
  | Bool
  | Signed of val_int_size | Unsigned of val_int_size
  | Float of val_float_size
  | Char
  | List of val_type
  | Record of record_field list
  | Variant of variant_case list
  | Own of def_type
  | Borrow of def_type
and record_field =
  {
    rf_name : name;
    rf_type : val_type;
  }
and variant_case =
  {
    vc_name : name;
    vc_type : val_type option;
    vc_default : int32 option;
  }
and val_type_ad = val_type alive_dead

and func_ios =
  | Fio_one of val_type
  | Fio_many of (name * val_type) list
and func_type = { ft_params : func_ios; ft_result : func_ios }

and type_bound =
  | Tbound_eq of def_type
  | Tbound_subr
and boundedtyvar = type_bound

and instance_type =
  { it_evars : boundedtyvar list ; it_exports : extern_decl list }
and instance_type_ad =
  { itad_exports : extern_decl_ad list }
and extern_decl =
  { ed_name : externname ; ed_desc : extern_desc }
and extern_decl_ad = extern_decl alive_dead
and extern_desc =
  | ED_core_module of core_module_type
  | ED_func of func_type
  | ED_value of val_type
  | ED_type of def_type
  | ED_instance of instance_type
  | ED_component of component_type
and component_type =
  { ct_uvars : boundedtyvar list
  ; ct_imports : extern_decl list
  ; ct_instance : instance_type }
and resource_type =
  { rt_dtor : int32 option }

and def_type =
  | DT_var of tyvar
  | DT_resource_type of int32
  | DT_val_type of val_type
  | DT_func_type of func_type
  | DT_instance_type of instance_type
  | DT_component_type of component_type

and core_func_type     = Wasm.Types.func_type
and core_extern_desc   = Wasm.Types.extern_type
and core_export_decl   =
  { ced_name : name ; ced_desc : core_extern_desc }
and core_instance_type =
  { cit_exports : core_export_decl list }
and core_import_decl   =
  { cid_name1 : name ; cid_name2 : name ; cid_desc : core_extern_desc }
and core_module_type   =
  { cmt_imports : core_import_decl list ; cmt_instance : core_instance_type }
and core_table_type    = Wasm.Types.table_type
and core_mem_type      = Wasm.Types.memory_type
and core_global_type   = Wasm.Types.global_type

type core_type =
  | CT_func of core_func_type
  | CT_module of core_module_type
  | CT_instance of core_instance_type
  | CT_table of core_table_type
  | CT_memory of core_mem_type
  | CT_global of core_global_type

type core_ctx =
  { core_types : core_type list
  ; core_funcs : core_func_type list
  ; core_modules : core_module_type list
  ; core_instances : core_instance_type list
  ; core_tables : core_table_type list
  ; core_mems : core_mem_type list
  ; core_globals : core_global_type list
  }

type ctx =
  { parent_ctx : ctx option
  ; outer_boundary : bool (* should type variables from the parent be blocked? *)
  ; core_ctx : core_ctx
  ; uvars : (boundedtyvar * bool) list
  ; evars : (boundedtyvar * def_type option) list
  ; rtypes : resource_type list
  ; types : def_type list
  ; components : component_type list
  ; instances : instance_type_ad list
  ; funcs : func_type list
  ; values : val_type_ad list
  }

let empty_core_ctx () =
  { core_types = []
  ; core_funcs = []
  ; core_modules = []
  ; core_instances = []
  ; core_tables = []
  ; core_mems = []
  ; core_globals = []
  }

let empty_ctx parent ob =
  { parent_ctx = parent
  ; outer_boundary = ob
  ; core_ctx = empty_core_ctx ()
  ; uvars = []
  ; evars = []
  ; rtypes = []
  ; types = []
  ; components = []
  ; instances = []
  ; funcs = []
  ; values = []
  }
