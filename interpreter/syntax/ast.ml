module Source = Wasm.Source

type name = string Source.phrase
type url = string Source.phrase
type externname = externname' Source.phrase
and externname' =
  {
    en_name : name;
    en_url : url option;
  }

type core_sort = core_sort' Source.phrase
and core_sort' =
  | Core_func
  | Core_table
  | Core_memory
  | Core_global
  | Core_type
  | Core_module
  | Core_instance
type sort = sort' Source.phrase
and sort' =
  | CoreSort of core_sort
  | Func
  | Value
  | Type
  | Component
  | Instance
type val_int_size = VI_8 | VI_16 | VI_32 | VI_64
type val_float_size = VF_32 | VF_64

let show_core_sort' (s : core_sort') : string
  = match s with
  | Core_func -> "func"
  | Core_table -> "table"
  | Core_memory -> "memory"
  | Core_global -> "global"
  | Core_type -> "type"
  | Core_module -> "module"
  | Core_instance -> "instance"
let show_sort' (s : sort') : string
  = match s with
  | CoreSort s' -> "core_" ^ show_core_sort' s'.Source.it
  | Func -> "func"
  | Value -> "value"
  | Type -> "type"
  | Component -> "component"
  | Instance -> "instance"


module type AstParams = sig
  type ident
  type 'a bound
  type 'a core_externdesc_wrapper
  type 'a typeuse
end
module type AstT = sig
  type core_memory_id
  type core_func_id
  type core_module_id
  type core_instance_id
  type component_id
  type instance_id
  type value_id
  type func_id
  type outer_id
  type core_sort_idx
  type core_sort_idx'
  type sort_idx
  type sort_idx'
  type core_export
  type core_export'
  type core_instantiate_arg
  type core_instantiate_arg'
  type core_instance_expr
  type core_instance_expr'
  type inline_export
  type inline_export'
  type export
  type export'
  type instantiate_arg
  type instantiate_arg'
  type instance_expr
  type instance_expr'
  type core_alias_target
  type core_alias_target'
  type core_alias
  type core_alias'
  type alias_target
  type alias_target'
  type alias
  type alias'
  type core_functype
  type core_deftype
  type core_deftype'
  type core_typedecl
  type core_typedecl'
  type core_externdesc
  type core_exportdecl
  type core_exportdecl'
  type core_moduledecl
  type core_moduledecl'
  type core_moduletype
  type core_moduletype'
  type core_deftype_
  type core_deftype_'
  type record_field
  type record_field'
  type variant_case
  type variant_case'
  type def_val_type
  type def_val_type'
  type val_type
  type func_ios
  type func_ios'
  type func_type
  type func_type'
  type type_bound
  type type_bound'
  type component_type
  type component_type'
  type instance_type
  type instance_type'
  type component_decl
  type component_decl'
  type instance_decl
  type instance_decl'
  type importdecl
  type importdecl'
  type exportdecl
  type exportdecl'
  type def_type
  type def_type'
  type canon_opt
  type canon_opt'
  type canon
  type canon'
  type start
  type start'
  type import
  type import'
  type core_definition
  type definition
  type definition'
  type component
  type component'
end
module Make (P : AstParams) = struct

  type core_memory_id = P.ident
  type core_func_id = P.ident
  type core_module_id = P.ident
  type core_instance_id = P.ident

  type component_id = P.ident
  type instance_id = P.ident
  type value_id = P.ident
  type func_id = P.ident

  type outer_id = P.ident

  type core_sort_idx = core_sort_idx' Source.phrase
  and core_sort_idx' =
    {
      c_s_sort : core_sort;
      c_s_idx : P.ident;
    }

  type sort_idx = sort_idx' Source.phrase
  and sort_idx' =
    {
      s_sort : sort;
      s_idx : P.ident;
    }

  (* # Core instantiate *)

  type core_export = core_export' Source.phrase
  and core_export' =
    {
      c_e_name : name;
      c_e_value : core_sort_idx;
    }
  type core_instantiate_arg = core_instantiate_arg' Source.phrase
  and core_instantiate_arg' =
    {
      c_ia_name  : name;
      c_ia_value : core_sort_idx;
    }
  type core_instance_expr = core_instance_expr' Source.phrase
  and core_instance_expr' =
    | Core_instantiate_module of core_module_id * core_instantiate_arg list
    | Core_instantiate_inline of core_export list

  (* # Instantiate *)

  type inline_export = inline_export' Source.phrase
  and inline_export' =
    {
      ie_name : externname;
      ie_value : sort_idx;
    }
  type instantiate_arg = instantiate_arg' Source.phrase
  and instantiate_arg' =
    {
      ia_name : name;
      ia_value : sort_idx;
    }
  type instance_expr = instance_expr' Source.phrase
  and instance_expr' =
    | Instantiate_component of component_id * instantiate_arg list
    | Instantiate_inline of inline_export list

  (* # Core Alias *)

  type core_alias_target = core_alias_target' Source.phrase
  and core_alias_target' =
    | Core_alias_export of core_instance_id * name
    | Core_alias_outer of outer_id * P.ident

  type core_alias = core_alias' Source.phrase
  and core_alias' =
    {
      c_a_target : core_alias_target;
      c_a_sort : core_sort
    }

  (* # Alias *)

  type alias_target = alias_target' Source.phrase
  and alias_target' =
    | Alias_export of instance_id * name
    | Alias_core_export of core_instance_id * name
    | Alias_outer of outer_id * P.ident
  type alias = alias' Source.phrase
  and alias' =
    {
      a_target : alias_target;
      a_sort : sort;
    }

  (* # Core Type *)

  type core_functype = Wasm.Ast.type_

  type core_deftype = core_deftype' Source.phrase
  and core_deftype' =
    | Core_deftype_functype of core_functype
  (* With GC:modul
     | Core_deftype_structtype of core_structtype
     | Core_deftype_arraytype of core_arraytype
   *)

  type core_typedecl = core_typedecl' Source.phrase
  and core_typedecl' =
    {
      c_td_type : core_deftype
    }
  type core_externdesc = Wasm.Ast.import_desc P.core_externdesc_wrapper
  type core_exportdecl = core_exportdecl' Source.phrase
  and core_exportdecl' =
    {
      c_ed_name : name;
      c_ed_ty : core_externdesc;
    }
  type core_importdecl = core_importdecl' Source.phrase
  and core_importdecl' =
    {
      c_id_name1 : name;
      c_id_name2 : name;
      c_id_ty : core_externdesc;
    }
  type core_moduledecl = core_moduledecl' Source.phrase
  and core_moduledecl' =
    (* imports are conceptually bound, but the binding is inside of
       P.core_externdesc_wrapper *)
    | Core_md_importdecl of core_importdecl
    | Core_md_typedecl of core_deftype P.bound
    | Core_md_aliasdecl of core_alias P.bound
    | Core_md_exportdecl of core_exportdecl

  type core_moduletype = core_moduletype' Source.phrase
  and core_moduletype' =
    {
      decls : core_moduledecl list
    }

  type core_deftype_ = core_deftype_' Source.phrase
  and core_deftype_' =
    | Core_deftype__deftype of core_deftype
    | Core_deftype__moduletype of core_moduletype

  (* # Type *)
  type record_field = record_field' Source.phrase
  and record_field' =
    {
      rf_name : name;
      rf_type : val_type;
    }
  and variant_case = variant_case' Source.phrase
  and variant_case' =
    {
      vc_name : name;
      vc_type : val_type option;
      vc_default : P.ident option;
    }
  and def_val_type = def_val_type' Source.phrase
  and def_val_type' =
    | Record of record_field list
    | Variant of (variant_case P.bound) list
    | List of val_type
    | Tuple of val_type list
    | Flags of name list
    | Enum of name list
    | Union of val_type list
    | Option of val_type
    | Expected of val_type option * val_type option
    | Own of P.ident
    | Borrow of P.ident
    | Bool
    | Signed of val_int_size | Unsigned of val_int_size
    | Float of val_float_size
    | Char | String
  and val_type = def_val_type P.typeuse
  type func_ios = func_ios' Source.phrase
  and func_ios' =
    | Fio_one of val_type
    | Fio_many of (name * val_type) list
  type func_type = func_type' Source.phrase
  and func_type' =
    {
      ft_params : func_ios;
      ft_result : func_ios;
    }
  and component_type = component_type' Source.phrase
  and component_type' = component_decl list
  and instance_type = instance_type' Source.phrase
  and instance_type' = instance_decl list
  and component_decl = component_decl' Source.phrase
  and component_decl' =
    | Component_import of importdecl
    | Component_instance of instance_decl
  and instance_decl = instance_decl' Source.phrase
  and instance_decl' =
    | Instance_type of def_type P.bound
    | Instance_alias of alias P.bound
    | Instance_export of exportdecl
  and importdecl = importdecl' Source.phrase
  and importdecl' = { id_name : externname; id_type : importdesc }
  and exportdecl = exportdecl' Source.phrase
  and exportdecl' = { ed_name : externname; ed_type : importdesc }
  and importdesc = exportdesc P.bound
  and exportdesc = exportdesc' Source.phrase
  and exportdesc' =
    | Export_sort_id of sort * P.ident
    | Export_core_mod of core_moduletype
    | Export_func of func_type
    | Export_comp of component_type
    | Export_inst of instance_type
    | Export_val of val_type
    | Export_type of type_bound
  and type_bound = type_bound' Source.phrase
  and type_bound' =
    | Tbound_subr
    | Tbound_eq of def_type P.typeuse
  and def_type = def_type' Source.phrase
  and def_type' =
    | Deftype_val of def_val_type
    | Deftype_func of func_type
    | Deftype_comp of component_type
    | Deftype_inst of instance_type
    | Deftype_rsrc of P.ident option (* destructor index *)

  (* # Canon *)
  type canon_opt = canon_opt' Source.phrase
  and canon_opt' =
    | String_utf8
    | String_utf16
    | String_latin1_utf16
    | Memory of core_memory_id
    | Realloc of core_func_id
    | PostReturn of core_func_id
  type canon_resource_builtin = canon_resource_builtin' Source.phrase
  and canon_resource_builtin' =
    | CRB_new of def_type P.typeuse
    | CRB_drop of val_type
    | CRB_rep of def_type P.typeuse
  type canon = canon' Source.phrase
  and canon' =
    | Canon_lift of core_func_id * exportdesc * canon_opt list
    | Canon_lower of func_id * canon_opt list
    | Canon_resource_builtin of canon_resource_builtin

  (* # Start *)
  type start = start' Source.phrase
  and start' =
    {
      s_func : func_id;
      s_params : value_id list;
      s_result : unit P.bound list;
    }

  type import = import' Source.phrase
  and import' = { i_name : externname; i_type : importdesc; }

  type export = export' Source.phrase
  and export' =
    {
      e_name : externname;
      e_value : sort_idx;
      e_type : exportdesc option
    }

  type core_definition =
    | CoreModuleDef of Wasm.Ast.module_ P.bound
    | CoreInstanceDef of core_instance_expr P.bound
    | CoreTypeDef of core_deftype_ P.bound
  type definition = definition' Source.phrase
  and definition' =
    | CoreDef of core_definition
    | ComponentDef of component
    | InstanceDef of instance_expr P.bound
    | AliasDef of alias P.bound
    | TypeDef of def_type P.bound
    | CanonDef of canon P.bound
    | StartDef of start
    | ImportDef of import (* the binder is inside the importdesc *)
    | ExportDef of export P.bound
  and component = component' P.bound Source.phrase
  and component' =
    {
      defns : definition list
    }
end

module Int32_AstParams : (AstParams
                          with type ident = int32
                          with type 'a bound = 'a
                          with type 'a core_externdesc_wrapper =
                                      Wasm.ParseUtil.context * 'a
                          with type 'a typeuse = int32) = struct
  type ident = int32
  type 'a bound = 'a
  type 'a core_externdesc_wrapper = Wasm.ParseUtil.context * 'a
  type 'a typeuse = int32
end
module IntAst = Make(Int32_AstParams)

type var = string Source.phrase
module VarQ (VarAst : AstT) = struct
  type ident =
    | Idx    of int32 Source.phrase
    | Var    of var
    | Export of sort * ident * name list (* inline export alias *)
    | CoreInlineInstance of VarAst.core_export list
    | InlineInstance of VarAst.inline_export list
  type binder =
    | No_binder
    | Var_binder of var
    (*| Export_binder of externname (* TODO TEMPORARY REMOVE REMOVE *)*)
    | Export_binders of externname list
  type 'a bound = { body : 'a; binder : binder }
  let bind b a = { body = a; binder = b }
  let string_of_binder x =
    let open Source in
    match x with
    | No_binder -> "_"
    | Var_binder v -> v.it
    | Export_binders es -> "(" ^ String.concat " " (List.map (fun x -> x.it.en_name.it) es) ^ ")"
  type 'a core_externdesc_wrapper = Wasm.ParseUtil.context -> unit -> 'a
  type 'a typeuse =
    | TVar of ident
    | TInline of 'a
end
module rec VarD :
             (AstParams
              with type ident = VarQ(Make(VarD)).ident
              with type 'a bound = 'a VarQ(Make(VarD)).bound
              with type 'a core_externdesc_wrapper =
                          'a VarQ(Make(VarD)).core_externdesc_wrapper
              with type 'a typeuse = 'a VarQ(Make(VarD)).typeuse) = struct
  include VarQ(Make(VarD))
end

module VarAst = Make(VarD)
module Var = VarQ(Make(VarD))
