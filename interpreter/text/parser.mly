%{

(* work around Menhir type inference bug *)
module Wasm_components = struct
  (* for some reason, warning 60 (unused module) can't be disabled, but warning
     34, unused type, can be... *)
  type this_module_is_not_unused
end
type workaround_menhir_bug = Wasm_components.this_module_is_not_unused
                               [@@warning "-34"]

open Script
open Ast
open VarAst
open Wasm.Source

open Putil
%}
%start component_module component_script
%type<Ast.Var.binder * Ast.VarAst.component> component_module
%type<Script.script> component_script

%type<Ast.Var.binder> perhaps_var
%type<definition list> defs
%type<definition> def
%type<VarAst.def_type> def_type

%token LPAR RPAR
%token CORE MODULE COMPONENT INSTANCE ALIAS
%token INSTANTIATE WITH
%token<string> VAR STRING
%token<Putil.var option * Wasm.Ast.module_> COREMOD
%token<Wasm.Ast.type_> COREDEFTYPE
%token<Wasm.ParseUtil.context -> unit -> Wasm.Ast.import_desc'> COREIMPORTDESC

%token IMPORT EXPORT OUTER

%token FUNC TABLE MEMORY GLOBAL
%token VALUE TYPE
%token<string> NAT

%token BOOL CHAR TSTRING RECORD VARIANT LIST TUPLE FLAGS ENUM UNION OWN BORROW
%token OPTION ERROR
%token<Ast.val_int_size> SIGNED UNSIGNED
%token<Ast.val_float_size> FLOAT
%token FIELD CASE REFINES
%token PARAM RESULT SUB EQ
%token CANON LIFT LOWER
%token STRINGENCODING EQS UTF8 UTF16 LATIN1UTF16 REALLOC POSTRETURN
%token START

%token INPUT
%token QUOTE BIN

%token ASSERT_INVALID ASSERT_MALFORMED

%token RESOURCE RESOURCE_NEW RESOURCE_DROP RESOURCE_REP REP I32 DTOR

%token EOF

%%

component_module :
  | LPAR COMPONENT perhaps_var defs RPAR
    { $3, (Var.bind $3 { defns = $4 } @@ ptr $symbolstartpos $endpos) }

prim_var :
  | VAR { Var.Var ($1 @@ ptr $symbolstartpos $endpos) }
  | NAT { Var.Idx (Int32.of_string $1 @@ ptr $symbolstartpos $endpos) }
core_var :
  | prim_var { $1 }
  | LPAR core_sort core_var name+ RPAR
    { Var.Export (CoreSort $2 @@ ptr $startpos($2) $endpos($2), $3, $4) }
var :
  | prim_var { $1 }
  | LPAR core_marker_shenanigan_sort var name+ RPAR
    { Var.Export ($2, $3, $4) }

name :
  | STRING { $1 @@ ptr $symbolstartpos $endpos }
%inline perhaps_var :
  | /* empty */ { Var.No_binder }
  | VAR { Var.Var_binder ($1 @@ ptr $symbolstartpos $endpos) }
%inline perhaps_var_E :
  | perhaps_var { $1 }
  | export_binder  { Var.Export_binders ($1::[]) }
%inline export_binder :
  | LPAR EXPORT externname RPAR { $3 }

%inline perhaps_var_E_ :
  | perhaps_var { $1 }
  | export_binder_ { Var.Export_binders ($1::[]) }
%inline export_binder_ :
  | LPAR core_exportdecl_marker externname RPAR { $3 }

url :
  | STRING { $1 @@ ptr $symbolstartpos $endpos }
externname :
  | name url? { { en_name = $1; en_url = $2; } @@ ptr $symbolstartpos $endpos }


defs :
  | /* empty */ { [] }
  | def defs
    { $1::$2 }
def :
  | component_module
    { let (a, b) = $1 in ComponentDef b @@ ptr $symbolstartpos $endpos }
  | core_def { CoreDef $1 @@ ptr $symbolstartpos $endpos }
  | LPAR INSTANCE perhaps_var_E instance_expr RPAR
    { InstanceDef (Var.bind $3 $4) @@ ptr $symbolstartpos $endpos }
  | alias { AliasDef $1 @@ ptr $symbolstartpos $endpos }
  | type_ { TypeDef $1 @@ ptr $symbolstartpos $endpos }
  | canon { CanonDef $1 @@ ptr $symbolstartpos $endpos }
  | start { StartDef $1 @@ ptr $symbolstartpos $endpos }
  | import { ImportDef $1 @@ ptr $symbolstartpos $endpos }
  | export_ { ExportDef $1 @@ ptr $symbolstartpos $endpos }

(* Yes, this is structured a bit strangely.
 * See note on nonterminal 'core' below. *)
core_def :
  | LPAR core_marker core_def_right { $3 }
core_def_right :
  | MODULE COREMOD
    { let (b, m) = $2 in
      let b' = match b with | None -> Var.No_binder
                            | Some v -> Var.Var_binder v in
      CoreModuleDef (Var.bind b' m) }
  | INSTANCE perhaps_var_E core_instance_expr RPAR
    { CoreInstanceDef (Var.bind $2 $3) }
  | TYPE perhaps_var_E core_deftype__right
    { CoreTypeDef (Var.bind $2 $3) }

core_alias :
  | ALIAS core_alias_target LPAR core_sort perhaps_var_E RPAR RPAR
    { Var.bind $5 ({ c_a_target = $2; c_a_sort = $4 }
                   @@ ptr $symbolstartpos $endpos) }

(* This production looks totally useless, and in most grammars it would be.
 * However, it is actually here to be used as a signal to the parser driving
 * code in parse.ml (function parse'). Because this nonterminal is not used
 * anywhere that the grammar needs to recognize a CORE token save for in
 * core_def, the feeding code knows that any time this production is being
 * reduced, if the lookahead token is MODULE, this might be a core module
 * definition---and so next time the lexer is prompted for a token, it instead
 * investigates whether this is the case (via some extra lookahead), and then,
 * if it is, invokes the core lexer and parser over the next bit of the input
 * stream, generating a synthetic COREMOD token which is used by the first
 * production in the core_def_right rule above. *)
core_marker :
  | CORE { () }

core_instance_expr :
  | LPAR INSTANTIATE core_var core_instantiate_arg* RPAR
    { Core_instantiate_module ($3, $4) @@ ptr $symbolstartpos $endpos}
  | core_export*
    { Core_instantiate_inline $1  @@ ptr $symbolstartpos $endpos }
core_instantiate_arg :
  | LPAR WITH name core_sort_idx RPAR
    { { c_ia_name = $3; c_ia_value = $4 } @@ ptr $symbolstartpos $endpos }
  | LPAR WITH name LPAR INSTANCE core_export* RPAR RPAR
    { let herepos = ptr $symbolstartpos $endpos in
      { c_ia_name = $3;
        c_ia_value = { c_s_sort = Core_instance @@ no_region;
                       c_s_idx = Var.CoreInlineInstance $6; } @@ herepos }
      @@ herepos }

core_export :
  | LPAR EXPORT name core_sort_idx RPAR
    { { c_e_name = $3; c_e_value = $4 } @@ ptr $symbolstartpos $endpos }

core_sort_idx :
  | LPAR core_sort core_var RPAR
    { { c_s_sort = $2; c_s_idx = $3 } @@ ptr $symbolstartpos $endpos }
  | LPAR core_sort core_var name+ RPAR
    { { c_s_sort = $2;
        c_s_idx = Var.Export (CoreSort $2 @@ ptr $startpos($2) $endpos($2),
                              $3, $4); }
      @@ ptr $symbolstartpos $endpos }
%inline core_sort_sans_module_type :
  | FUNC { Core_func @@ ptr $symbolstartpos $endpos }
  | TABLE { Core_table @@ ptr $symbolstartpos $endpos }
  | MEMORY { Core_memory @@ ptr $symbolstartpos $endpos }
  | GLOBAL { Core_global @@ ptr $symbolstartpos $endpos }
  | INSTANCE { Core_instance @@ ptr $symbolstartpos $endpos }
%inline core_sort :
  | core_sort_sans_module_type { $1 }
  | MODULE { Core_module @@ ptr $symbolstartpos $endpos }
  | TYPE { Core_type @@ ptr $symbolstartpos $endpos }

core_alias_target :
  | EXPORT core_var name
    { Core_alias_export ($2, $3) @@ ptr $symbolstartpos $endpos }
  | OUTER prim_var prim_var
    { Core_alias_outer ($2, $3) @@ ptr $symbolstartpos $endpos }

core_deftype__right :
  | COREDEFTYPE RPAR
    { Core_deftype__deftype (Core_deftype_functype $1
                             @@ ptr $symbolstartpos $endpos)
      @@ ptr $symbolstartpos $endpos }
  | LPAR MODULE core_moduledecl* RPAR RPAR
    { Core_deftype__moduletype ({ decls = $3; } @@ ptr $symbolstartpos $endpos)
      @@ ptr $symbolstartpos $endpos }
core_moduledecl :
  | core_importdecl { Core_md_importdecl $1 @@ ptr $symbolstartpos $endpos }
  | core_type { Core_md_typedecl $1 @@ ptr $symbolstartpos $endpos }
  | core_alias { Core_md_aliasdecl $1 @@ ptr $symbolstartpos $endpos }
  | core_exportdecl { Core_md_exportdecl $1 @@ ptr $symbolstartpos $endpos }
core_importdecl :
  | LPAR IMPORT core_importdecl_marker name COREIMPORTDESC RPAR
    { { c_id_name1 = $3; c_id_name2 = $4;
        c_id_ty = fun c u -> $5 c u @@ ptr $startpos($5) $endpos($5); }
      @@ ptr $symbolstartpos $endpos }
core_importdecl_marker :
  | name { $1 }
core_type :
  | core_type_marker TYPE perhaps_var COREDEFTYPE RPAR
    { Var.bind $3 (Core_deftype_functype $4 @@ ptr $symbolstartpos $endpos) }
core_type_marker :
  | LPAR { () }
core_exportdecl :
  | LPAR core_exportdecl_marker name COREIMPORTDESC RPAR
    { { c_ed_name = $3;
        c_ed_ty = fun c u -> $4 c u @@ ptr $startpos($4) $endpos($4); }
      @@ ptr $symbolstartpos $endpos }
core_exportdecl_marker :
  | EXPORT { () }

instance_expr :
  | LPAR INSTANTIATE var instantiate_arg* RPAR
    { Instantiate_component ($3, $4) @@ ptr $symbolstartpos $endpos }
  | export*
    { Instantiate_inline $1 @@ ptr $symbolstartpos $endpos }
instantiate_arg :
  | LPAR WITH name sort_idx RPAR
    { { ia_name = $3; ia_value = $4; } @@ ptr $symbolstartpos $endpos }
  | LPAR WITH name LPAR INSTANCE export* RPAR RPAR
    { let herepos = ptr $symbolstartpos $endpos in
      { ia_name = $3;
        ia_value = { s_sort = Instance @@ no_region;
                     s_idx = Var.InlineInstance $6; } @@ herepos }
      @@ herepos }

export :
  | LPAR EXPORT externname sort_idx RPAR
    { { ie_name = $3; ie_value = $4 } @@ ptr $symbolstartpos $endpos }

export_ :
  | LPAR EXPORT perhaps_var externname sort_idx exportdesc? RPAR
    { let t = match $6 with
              | None -> None
              | Some (Var.No_binder, t) -> Some t
              | Some _ -> error (ptr $startpos($6) $endpos($6)) "Binder not allowed on export definition type ascription"
      in
      Var.bind $3 ({ e_name = $4; e_value = $5; e_type = t }
                   @@ ptr $symbolstartpos $endpos) }

sort_idx :
  | LPAR sort var RPAR
    { { s_sort = $2; s_idx = $3 } @@ ptr $symbolstartpos $endpos }
  | LPAR sort var name+ RPAR
    { { s_sort = $2;
        s_idx = Var.Export ($2, $3, $4); }
      @@ ptr $symbolstartpos $endpos }
%inline core_marker_shenanigan_sort_sans_module_type :
  | core_marker core_sort_sans_module_type { CoreSort $2 @@ ptr $symbolstartpos $endpos }
  | comp_sort { $1 }
%inline core_marker_shenanigan_sort :
  | core_marker core_sort { CoreSort $2 @@ ptr $symbolstartpos $endpos }
  | comp_sort { $1 }
%inline sort :
  | CORE core_sort { CoreSort $2 @@ ptr $symbolstartpos $endpos }
  | comp_sort { $1 }
%inline comp_sort :
  | FUNC { Func @@ ptr $symbolstartpos $endpos }
  | VALUE { Value @@ ptr $symbolstartpos $endpos }
  | TYPE { Type @@ ptr $symbolstartpos $endpos }
  | INSTANCE { Instance @@ ptr $symbolstartpos $endpos }
  | COMPONENT { Ast.Component @@ ptr $symbolstartpos $endpos }

%inline alias :
  | LPAR ALIAS alias_target LPAR sort perhaps_var_E RPAR RPAR
    { Var.bind $6 ({ a_target = $3; a_sort = $5 }
                   @@ ptr $symbolstartpos $endpos) }
  | LPAR core_marker_shenanigan_sort_sans_module_type perhaps_var_E LPAR ALIAS alias_target RPAR RPAR
    { Var.bind $3 ({ a_target = $6; a_sort = $2 }
                   @@ ptr $symbolstartpos $endpos) }
  | LPAR core_marker MODULE perhaps_var_E_ LPAR ALIAS alias_target RPAR RPAR
    { Var.bind $4 ({ a_target = $7; a_sort = CoreSort (Core_module @@ ptr $startpos($3) $endpos($3)) @@ ptr $startpos($2) $endpos($2) }
                   @@ ptr $symbolstartpos $endpos) }
  | LPAR core_marker TYPE perhaps_var_E LPAR ALIAS alias_target RPAR RPAR
    { Var.bind $4 ({ a_target = $7; a_sort = CoreSort (Core_type @@ ptr $startpos($3) $endpos($3)) @@ ptr $startpos($2) $endpos($2) }
                   @@ ptr $symbolstartpos $endpos) }
alias_target :
  | EXPORT var name
    { Alias_export ($2, $3) @@ ptr $symbolstartpos $endpos }
  | CORE EXPORT var name
    { Alias_core_export ($3, $4) @@ ptr $symbolstartpos $endpos }
  | OUTER prim_var prim_var
    { Alias_outer ($2, $3) @@ ptr $symbolstartpos $endpos }

type_ :
  | LPAR TYPE perhaps_var_E def_type RPAR
    { Var.bind $3 $4 }
def_type :
  | def_val_type { Deftype_val $1 @@ ptr $symbolstartpos $endpos }
  | func_type { let b, x = $1 in Deftype_func x @@ ptr $symbolstartpos $endpos }
  | component_type { let b, x = $1 in Deftype_comp x @@ ptr $symbolstartpos $endpos }
  | instance_type { let b, x = $1 in Deftype_inst x @@ ptr $symbolstartpos $endpos }
  | resource_type { Deftype_rsrc $1 @@ ptr $symbolstartpos $endpos }
def_val_type :
  | BOOL { Bool @@ ptr $symbolstartpos $endpos }
  | SIGNED { Signed $1 @@ ptr $symbolstartpos $endpos }
  | UNSIGNED { Unsigned $1 @@ ptr $symbolstartpos $endpos }
  | FLOAT { Float $1 @@ ptr $symbolstartpos $endpos }
  | CHAR { Char @@ ptr $symbolstartpos $endpos }
  | TSTRING { String @@ ptr $symbolstartpos $endpos }
  | LPAR RECORD recordfield* RPAR { Record $3 @@ ptr $symbolstartpos $endpos }
  | LPAR VARIANT variantcase+ RPAR { Variant $3 @@ ptr $symbolstartpos $endpos }
  | LPAR LIST val_type RPAR { List $3 @@ ptr $symbolstartpos $endpos }
  | LPAR TUPLE val_type* RPAR { Tuple $3 @@ ptr $symbolstartpos $endpos}
  | LPAR FLAGS name* RPAR { Flags $3 @@ ptr $symbolstartpos $endpos }
  | LPAR ENUM name+ RPAR { Enum $3 @@ ptr $symbolstartpos $endpos }
  | LPAR UNION val_type+ RPAR { Union $3 @@ ptr $symbolstartpos $endpos}
  | LPAR OPTION val_type RPAR {Option $3 @@ ptr $symbolstartpos $endpos}
  | LPAR RESULT ioption(val_type) ioption(result_error_clause) RPAR
    { Expected ($3,$4) @@ ptr $symbolstartpos $endpos }
  | LPAR OWN var RPAR { Own $3 @@ ptr $symbolstartpos $endpos }
  | LPAR BORROW var RPAR { Borrow $3 @@ ptr $symbolstartpos $endpos }
%inline result_error_clause:
  | LPAR ERROR val_type RPAR { $3 }
recordfield :
  | LPAR FIELD name val_type RPAR
    { { rf_name = $3; rf_type = $4; } @@ ptr $symbolstartpos $endpos }
caserefines :
  | LPAR REFINES var RPAR { $3 }
variantcase :
  | LPAR CASE perhaps_var name ioption(val_type) ioption(caserefines) RPAR
    { Var.bind $3 ({ vc_name = $4; vc_type = $5; vc_default = $6 }
                   @@ ptr $symbolstartpos $endpos) }
resource_type :
  | LPAR RESOURCE LPAR REP I32 RPAR rt_dtor? RPAR
    { $7 }
rt_dtor :
  | LPAR DTOR var RPAR { $3 }

%inline typeuse(inner) :
  | inner { Var.TInline $1 }
  | var { Var.TVar $1 }
val_type :
  | typeuse(def_val_type) { $1 }
func_type :
  | func_type_IBFB(func_type_empty, func_type_empty) { let a, b, c = $1 in a, b }
%inline func_type_empty :
  | { () }
func_type_IBFB(ib, fb) :
  | LPAR FUNC perhaps_var_E ib functype_decls_FB(fb) RPAR
    { let a, b = $5 in $3, a @@ ptr $symbolstartpos $endpos, ($4, b) }
functype_decls_FB(fb) :
  | functype_result_decls(fb)
    { let r, x = $1 in
      { ft_params = Fio_many [] @@ ptr $startpos($1) $endpos($1)
      ; ft_result = r }, x }
  | LPAR PARAM val_type RPAR functype_result_decls(fb)
    { let r, x = $5 in
      { ft_params = Fio_one $3 @@ ptr $startpos($3) $endpos($3)
      ; ft_result = r }, x }
  | functype_param_decl functype_param_decls(fb)
    { let p, (r, x) = $2 in
      { ft_params = Fio_many ($1::p) @@ ptr $startpos($1) $endpos($2);
        ft_result = r }, x }
functype_param_decls(fb) :
  | functype_param_decl functype_param_decls(fb)
    { let p, r = $2 in ($1::p), r }
  | functype_result_decls(fb) { [], $1 }
%inline functype_result_decls(fb) :
  | fb { Fio_many [] @@ ptr $startpos($1) $endpos($1), $1 }
  | LPAR RESULT val_type RPAR fb { Fio_one $3 @@ ptr $startpos($3) $endpos($3), $5 }
  | functype_result_decl functype_result_decll(fb)
    { let r, x = $2 in Fio_many ($1::r) @@ ptr $startpos($1) $endpos($2), x }
functype_result_decll(fb) :
  | fb { [], $1 }
  | functype_result_decl functype_result_decll(fb)
    { let r, x = $2 in ($1::r), x }
%inline functype_result_decl :
  | LPAR RESULT name val_type RPAR { $3, $4 }
%inline functype_param_decl :
  | LPAR PARAM name val_type RPAR
    { $3, $4 }
component_type :
  | component_type_IBFB(component_type_empty, component_type_empty) { let a, b, c = $1 in a, b }
%inline component_type_empty :
  | { () }
component_type_IBFB(ib, fb) :
  | LPAR COMPONENT perhaps_var ib component_decl* fb RPAR
    { $3, $5 @@ ptr $symbolstartpos $endpos, ($4, $6) }
instance_type :
  | instance_type_IBFB(instance_type_empty, instance_type_empty) { let a, b, c = $1 in a, b }
%inline instance_type_empty :
  | { () }
instance_type_IBFB(ib, fb) :
  | LPAR INSTANCE perhaps_var ib instance_decl* fb RPAR
    { $3, $5 @@ ptr $symbolstartpos $endpos, ($4, $6) }
component_decl :
  | import_decl { Component_import $1 @@ ptr $symbolstartpos $endpos }
  | instance_decl { Component_instance $1 @@ ptr $symbolstartpos $endpos }
instance_decl :
  | alias { Instance_alias $1 @@ ptr $symbolstartpos $endpos }
  | type_decl { Instance_type $1 @@ ptr $symbolstartpos $endpos }
  | export_decl { Instance_export $1 @@ ptr $symbolstartpos $endpos }
import_decl :
  | LPAR IMPORT externname importdesc RPAR
    { let b, x = $4 in
      { id_name = $3; id_type = Var.bind b x; } @@ ptr $symbolstartpos $endpos }
importdesc :
  | exportdesc { $1 }
type_decl :
  | LPAR TYPE perhaps_var_E def_type RPAR
    { Var.bind $3 $4 }
export_decl :
  | LPAR EXPORT externname exportdesc RPAR
    { let b, x = $4 in
      { ed_name = $3; ed_type = Var.bind b x; } @@ ptr $symbolstartpos $endpos }
exportdesc :
  | exportdesc_FB(exportdesc_empty) { let a, b, c = $1 in a, b }
%inline exportdesc_empty :
  | { () }
%inline exportdesc_funconly_FB(fb) :
  | exportdesc_funconly_IBFB(exportdesc_empty, fb)
    { let a, b, (i, f) = $1 in a, b, f }
%inline exportdesc_funconly_IBFB(ib, fb) :
  | LPAR comp_sort perhaps_var_E ib LPAR TYPE var RPAR fb RPAR
    { $3, Export_sort_id ($2, $7) @@ ptr $symbolstartpos $endpos, ($4, $9) }
  | func_type_IBFB(ib, fb)
    { let b, x, y = $1 in b, Export_func x @@ ptr $symbolstartpos $endpos, y }
%inline exportdesc_FB(fb) :
  | exportdesc_IBFB(CORE, exportdesc_empty, fb)
    { let a, b, (i, f) = $1 in a, b, f }
exportdesc_IBFB(core_helper, ib, fb) :
  | exportdesc_funconly_IBFB(ib, fb)
    { $1 }
  | LPAR core_helper MODULE perhaps_var_E_ ib core_type_marker TYPE core_var RPAR fb RPAR
    { $4,
      Export_sort_id (CoreSort (Core_module @@ ptr $startpos($3) $endpos($3))
                      @@ ptr $startpos($2) $endpos($3)
                                                  ,$8)
      @@ ptr $symbolstartpos $endpos, ($5, $10) }
  | LPAR core_helper TYPE perhaps_var_E ib LPAR TYPE core_var RPAR fb RPAR
    { $4,
      Export_sort_id (CoreSort (Core_type @@ ptr $startpos($3) $endpos($3))
                      @@ ptr $startpos($2) $endpos($3)
                                                  ,$8)
      @@ ptr $symbolstartpos $endpos, ($5, $10) }
  | LPAR core_marker core_sort_sans_module_type perhaps_var ib LPAR TYPE core_var RPAR fb RPAR
    { $4,
      Export_sort_id (CoreSort $3 @@ ptr $startpos($2) $endpos($3), $8)
      @@ ptr $symbolstartpos $endpos, ($5, $10) }
  | LPAR core_helper MODULE perhaps_var_E_ ib core_moduledecl* fb RPAR
    { $4, Export_core_mod ({ decls = $6; } @@ ptr $startpos($6) $endpos($6))
          @@ ptr $symbolstartpos $endpos, ($5, $7) }
  | component_type_IBFB(ib, fb)
    { let b, x, y = $1 in b, Export_comp x @@ ptr $symbolstartpos $endpos, y }
  | instance_type_IBFB(ib, fb)
    { let b, x, y = $1 in b, Export_inst x @@ ptr $symbolstartpos $endpos, y }
  | LPAR VALUE perhaps_var_E ib val_type fb RPAR
    { $3, Export_val $5 @@ ptr $symbolstartpos $endpos, ($4, $6) }
  | LPAR TYPE perhaps_var_E ib type_bound fb RPAR
    { $3, Export_type $5 @@ ptr $symbolstartpos $endpos, ($4, $6) }
type_bound :
  | type_cstr { $1 }
type_cstr :
  | LPAR SUB RESOURCE RPAR
    { Tbound_subr @@ ptr $symbolstartpos $endpos }
  | LPAR EQ typeuse(def_type) RPAR
    { Tbound_eq $3 @@ ptr $symbolstartpos $endpos }

%inline canon :
  | LPAR CANON LIFT canon_lift_args(canon_func_end) RPAR
    { let x, b = $4 in Var.bind b (x @@ ptr $symbolstartpos $endpos) }
  | LPAR CANON LOWER canon_lower_args(canon_core_func_end) RPAR
    { let x, b = $4 in Var.bind b (x @@ ptr $symbolstartpos $endpos) }

  | LPAR CANON RESOURCE_NEW typeuse(def_type) canon_core_func_end RPAR
    { Var.bind $5 (Canon_resource_builtin
                     (CRB_new $4 @@ ptr $symbolstartpos $endpos)
                   @@ ptr $symbolstartpos $endpos) }
  | LPAR CANON RESOURCE_DROP val_type;; canon_core_func_end RPAR
    { Var.bind $5 (Canon_resource_builtin
                     (CRB_drop $4 @@ ptr $symbolstartpos $endpos)
                   @@ ptr $symbolstartpos $endpos) }
  | LPAR CANON RESOURCE_REP typeuse(def_type) canon_core_func_end RPAR
    { Var.bind $5 (Canon_resource_builtin
                     (CRB_rep $4 @@ ptr $symbolstartpos $endpos)
                   @@ ptr $symbolstartpos $endpos) }

  | exportdesc_funconly_FB(invert_canon_lift_right)
    { let v, e, (x, o) = $1 in
      let oo, _ = o [] in
      Var.bind v (Canon_lift (x, e, oo) @@ ptr $symbolstartpos $endpos) }

  | LPAR core_marker FUNC perhaps_var_E LPAR CANON LOWER canon_lower_args(canon_core_no_end) RPAR RPAR
    { let x, _ = $8 in Var.bind $4 (x @@ ptr $symbolstartpos $endpos) }

  | LPAR core_marker FUNC perhaps_var_E LPAR CANON RESOURCE_NEW typeuse(def_type) RPAR RPAR
    { Var.bind $4 (Canon_resource_builtin
                     (CRB_new $8 @@ ptr $symbolstartpos $endpos)
                   @@ ptr $symbolstartpos $endpos) }
  | LPAR core_marker FUNC perhaps_var_E LPAR CANON RESOURCE_DROP val_type RPAR RPAR
    { Var.bind $4 (Canon_resource_builtin
                     (CRB_drop $8 @@ ptr $symbolstartpos $endpos)
                   @@ ptr $symbolstartpos $endpos) }
  | LPAR core_marker FUNC perhaps_var_E LPAR CANON RESOURCE_REP typeuse(def_type) RPAR RPAR
    { Var.bind $4 (Canon_resource_builtin
                     (CRB_rep $8 @@ ptr $symbolstartpos $endpos)
                   @@ ptr $symbolstartpos $endpos) }
canon_lift_args(canon_end) :
  | var canon_opts(canon_end)
    { let o, (x, e) = $2 [] in (Canon_lift ($1, e, o), x) }
%inline invert_canon_lift_right :
  | LPAR CANON LIFT var canon_opts(canon_no_end) RPAR
    { ($4, $5) }
canon_lower_args(canon_end) :
  | var canon_opts(canon_end)
    { let o, e = $2 [] in Canon_lower ($1, o), e }
canon_opts(canon_end) :
  | canon_end { fun o -> List.rev o, $1 }
  | canon_opt canon_opts(canon_end) { fun o -> $2 ($1::o) }
canon_opt :
  | STRINGENCODING EQS UTF8 { String_utf8 @@ ptr $symbolstartpos $endpos }
  | STRINGENCODING EQS UTF16 { String_utf16 @@ ptr $symbolstartpos $endpos }
  | STRINGENCODING EQS LATIN1UTF16 { String_utf16 @@ ptr $symbolstartpos $endpos }
  | LPAR MEMORY core_var RPAR { Memory $3 @@ ptr $symbolstartpos $endpos }
  | LPAR REALLOC core_var RPAR { Realloc $3 @@ ptr $symbolstartpos $endpos }
  | LPAR POSTRETURN core_var RPAR { PostReturn $3 @@ ptr $symbolstartpos $endpos }
canon_func_end :
  | exportdesc { $1 }
canon_no_end :
  | { () }

canon_core_func_end :
  | LPAR CORE FUNC perhaps_var_E RPAR { $4 }
canon_core_no_end :
  | { () }

start :
  | LPAR START var startbody RPAR
    { let ps, rs = $4 [] in
      { s_func = $3
      ; s_params = ps
      ; s_result = List.map (fun r -> Var.bind r ()) rs;
      } @@ ptr $symbolstartpos $endpos}
%inline
startresults :
  | /* empty */ { fun rs vs -> List.rev vs, List.rev rs }
  | LPAR RESULT LPAR VALUE perhaps_var RPAR RPAR startresults_
    { fun rs vs -> $8 ($5::rs) vs }
startresults_ :
  | startresults { $1 }
startbody :
  | startresults { $1 [] }
  | LPAR VALUE var RPAR startbody { fun vs -> $5 ($3::vs) }

%inline import :
  | LPAR IMPORT externname importdesc RPAR
    { let b, x = $4 in
      ({ i_name = $3; i_type = Var.bind b x; } @@ ptr $symbolstartpos $endpos) }  | exportdesc_IBFB(core_marker, import_right, exportdesc_empty)
    { let b, x, (i, f) = $1 in
      ({ i_name = i; i_type = Var.bind b x; } @@ ptr $symbolstartpos $endpos) }
%inline import_right :
  | LPAR IMPORT externname RPAR { $3 }


(*** SCRIPTS ***)

string_list :
  | /* empty */ { "" }
  | string_list STRING { $1 ^ $2 }

script_component :
  | component_module
    { let x, c = $1 in x, Textual c @@ ptr $symbolstartpos $endpos }
  | LPAR COMPONENT perhaps_var BIN string_list RPAR
    { $3, Encoded ( "binary:"
                    ^ string_of_pos (position_to_pos $symbolstartpos)
                  , $5)
          @@ ptr $symbolstartpos $endpos }
  | LPAR COMPONENT perhaps_var QUOTE string_list RPAR
    { $3, Quoted ( "quoted: "
                   ^ string_of_pos (position_to_pos $symbolstartpos)
                 , $5)
          @@ ptr $symbolstartpos $endpos }

script_var_opt :
  | /* empty */ { None }
  | VAR { Some ($1 @@ ptr $symbolstartpos $endpos) }  /* Sugar */

meta :
  | LPAR INPUT script_var_opt STRING RPAR { Input ($3, $4) @@ ptr $symbolstartpos $endpos }

assertion :
  | LPAR ASSERT_INVALID script_component STRING RPAR
    { AssertInvalid (snd $3, $4) @@ ptr $symbolstartpos $endpos }
  | LPAR ASSERT_MALFORMED script_component STRING RPAR
    { AssertMalformed (snd $3, $4) @@ ptr $symbolstartpos $endpos }

cmd :
  | assertion { Assertion $1 @@ ptr $symbolstartpos $endpos }
  | script_component
    { let b, c = $1 in
      Script.Component (b, c) @@ ptr $symbolstartpos $endpos }
  | meta { Meta $1 @@ ptr $symbolstartpos $endpos }

cmd_list :
  | /* empty */ { [] }
  | cmd cmd_list { $1 :: $2 }

component_script :
  | cmd_list EOF { $1 }
