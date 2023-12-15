(* Yoann Padioleau
 *
 * Copyright (C) 2023 Semgrep Inc.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * version 2.1 as published by the Free Software Foundation, with the
 * special exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the file
 * LICENSE for more details.
 *)
open Common
module Arg = Cmdliner.Arg
module Cmd = Cmdliner.Cmd
module Term = Cmdliner.Term

(*****************************************************************************)
(* Prelude *)
(*****************************************************************************)
(* Jsonnet interpreter written in OCaml.
 *
 * For more information see libs/ojsonnet/
 *)

(*****************************************************************************)
(* Types *)
(*****************************************************************************)

type format = JSON | YAML [@@deriving show]
type dump_action = DumpAST | DumpCore | DumpValue | DumpJSON [@@deriving show]

(* Substitution is far slower, but correct. We get too many regressions
 * with Environment, including for our jsonnet GHA workflows
 * in .github/workflows/
 *)
let default_eval_strategy = Conf_ojsonnet.EvalSubst

type conf = {
  target : Fpath.t;
  format : format;
  dump : dump_action option;
  eval_strategy : Conf_ojsonnet.eval_strategy;
  common : CLI_common.conf;
}
[@@deriving show]

(*****************************************************************************)
(* CLI flags *)
(*****************************************************************************)
let o_target : string Term.t =
  let info = Arg.info [] ~docv:"TARGET" ~doc:"File to interpret" in
  Arg.value (Arg.pos 0 Arg.string "default.jsonnet" info)

let o_yaml : bool Term.t =
  let info = Arg.info [ "yaml" ] ~doc:"Generate YAML instead of JSON" in
  Arg.value (Arg.flag info)

let o_subst : bool Term.t =
  let info = Arg.info [ "subst" ] ~doc:"Evaluate using substitution model" in
  Arg.value (Arg.flag info)

let o_envir : bool Term.t =
  let info = Arg.info [ "envir" ] ~doc:"Evaluate using environment model" in
  Arg.value (Arg.flag info)

let o_strict : bool Term.t =
  let info = Arg.info [ "strict" ] ~doc:"Evaluate using strict model" in
  Arg.value (Arg.flag info)

(* alt: use subcommands in ojsonnet but not worth the complexity *)
let o_dump : string option Term.t =
  let info = Arg.info [ "dump" ] ~doc:"<internal>" in
  Arg.value (Arg.opt Arg.(some string) None info)

(* this used to be autogenerated by ppx_deriving_cmdliner *)
let term : conf Term.t =
  let combine common dump envir strict subst target yaml =
    let dump =
      dump
      |> Option.map (function
           | "AST" -> DumpAST
           | "core" -> DumpCore
           | "value" -> DumpValue
           | "JSON" -> DumpJSON
           | s -> failwith (spf "dump '%s' is not supported." s))
    in
    {
      common;
      target = Fpath.v target;
      format = (if yaml then YAML else JSON);
      dump;
      eval_strategy =
        (match (envir, subst, strict) with
        | false, false, false -> default_eval_strategy
        | true, false, false -> Conf_ojsonnet.EvalEnvir
        | false, true, false -> Conf_ojsonnet.EvalSubst
        | false, false, true -> Conf_ojsonnet.EvalStrict
        | _else_ ->
            failwith "option mutually exclusive --envir/--strict/--subst");
    }
  in
  Term.(
    const combine $ CLI_common.o_common $ o_dump $ o_envir $ o_strict $ o_subst
    $ o_target $ o_yaml)

(*****************************************************************************)
(* Actions *)
(*****************************************************************************)

let dump (action : dump_action) (strategy : Conf_ojsonnet.eval_strategy)
    (target : Fpath.t) : unit =
  Conf_ojsonnet.eval_strategy := strategy;
  match action with
  | DumpAST -> Test_ojsonnet.dump_jsonnet_ast target
  | DumpCore -> Test_ojsonnet.dump_jsonnet_core target
  | DumpValue -> Test_ojsonnet.dump_jsonnet_value target
  | DumpJSON -> Test_ojsonnet.dump_jsonnet_json target

(* TODO
    ( "-perf_test_jsonnet",
      " <file>",
      Arg_helpers.mk_action_1_conv Fpath.v Test_ojsonnet.perf_test_jsonnet );
*)

(*****************************************************************************)
(* Entry point *)
(*****************************************************************************)

let interpret eval_strategy (file : Fpath.t) : JSON.t =
  Conf_ojsonnet.eval_strategy := eval_strategy;
  let ast = Parse_jsonnet.parse_program file in
  let core = Desugar_jsonnet.desugar_program file ast in
  let v = Eval_jsonnet.eval_program core in
  let json = Eval_jsonnet.manifest_value v in
  json

let run (conf : conf) : unit =
  CLI_common.setup_logging ~force_color:true ~level:conf.common.logging_level;
  Logs.debug (fun m -> m "conf =\n%s" (show_conf conf));

  match conf.dump with
  | Some action -> dump action conf.eval_strategy conf.target
  | None -> (
      let json = interpret conf.eval_strategy conf.target in
      match conf.format with
      | JSON ->
          let str = JSON.string_of_json json in
          print_string str;
          flush stdout
      | YAML ->
          let y = JSON.to_yojson json in
          let v = JSON.yojson_to_ezjsonm y in
          let str = Yaml.to_string_exn v in
          print_string str;
          flush stdout)

(*****************************************************************************)
(* Cmdliner boilerplate *)
(*****************************************************************************)

let main () =
  Parse_jsonnet.jsonnet_parser_ref := Parse_jsonnet_tree_sitter.parse;
  let info = Cmd.info Sys.argv.(0) in
  let term = Term.(const run $ term) in
  let cmd = Cmd.v info term in
  exit (Cmd.eval cmd)

let () = main ()
