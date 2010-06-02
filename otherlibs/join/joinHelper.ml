(***********************************************************************)
(*                                                                     *)
(*                           Objective Caml                            *)
(*                                                                     *)
(*            Luc Maranget, projet Moscova, INRIA Rocquencourt         *)
(*                                                                     *)
(*  Copyright 2004 Institut National de Recherche en Informatique et   *)
(*  en Automatique.  All rights reserved.  This file is distributed    *)
(*  under the terms of the Q Public License version 1.0.               *)
(*                                                                     *)
(***********************************************************************)

(* $Id$ *)


(* Fork utilities *)

type fork_args =
| No_argument
| Same_arguments of string array
| Argument_generator of (unit -> string array)

let prepend s a =
  let len = Array.length a in
  Array.init
    (succ len)
    (function
      | 0 -> String.copy s
      | i -> a.(pred i))

let get_args = function
  | No_argument -> [| |]
  | Same_arguments a -> a
  | Argument_generator f -> f ()

let filter_clients a =
  let a' = Array.copy a in
  let len = Array.length a in
  let i = ref 0 in
  let i' = ref 0 in
  while (!i < len) do
    if a.(!i) = "-clients" then begin
      i := !i + 2
    end else begin
      a'.(!i') <- a.(!i);
      incr i;
      incr i'
    end
  done;
  Array.sub a' 0 !i'

let do_forks name args n =
  let rec df = function
    | 0 -> []
    | n ->
        match Unix.fork () with
        | 0 ->
            let args = prepend name (get_args args) in
            Unix.handle_unix_error
              (fun () -> Unix.execv name args) ()
        | pid -> pid :: (df (pred n)) in
  df (max 0 n)


(* Configuration *)

type configuration = {
    mutable host : string;
    mutable port : int;
    mutable clients : int;
    mutable forked_program : string;
    mutable fork_args : fork_args;
    mutable magic_id : string;
    mutable magic_value : string;
}

let default_host = "localhost"

let default_port = 12345

let default_clients = 0

let default_forked_program =
  if Array.length Sys.argv > 0 then
    String.copy Sys.argv.(0)
  else
    ""

let default_fork_args =
  let len = Array.length Sys.argv in
  Same_arguments (filter_clients (Array.sub Sys.argv 1 (pred len)))

let default_magic_id = "magic-number"

let default_magic_value = "magic-value"

let default_configuration () = {
  host = String.copy default_host;
  port = default_port;
  clients = default_clients;
  forked_program = String.copy default_forked_program;
  fork_args = default_fork_args;
  magic_id = String.copy default_magic_id;
  magic_value = String.copy default_magic_value;
}

let split_addr s =
  try
    let idx = String.index s ':' in
    let host = String.sub s 0 idx in
    let port = String.sub s (succ idx) (String.length s - idx - 1) in
    (if host = "" then String.copy default_host else host),
    (try int_of_string port with _ -> raise (Arg.Bad ("invalid port: " ^ port)))
  with
  | Not_found -> String.copy s, default_port

let make_configuration () =
  let cfg = default_configuration () in
  cfg, [ "-host",
         Arg.String
           (fun s ->
             let h, p = split_addr s in
             cfg.host <- h;
             cfg.port <- p),
         "<name:port>  Set host name and port" ;

         "-clients",
         Arg.Int (fun i -> cfg.clients <- i),
         "<n>  Set number of clients to launch";

         "-forked-program",
         Arg.String (fun s -> cfg.forked_program <- String.copy s),
         "<name>  Set executable for clients" ]


(* Client-related functions *)

type 'a lookup_function = Join.Ns.t -> string -> 'a

let lookup_once = Join.Ns.lookup

let rec lookup_times n w ns k =
  try
    lookup_once ns k
  with
  | Not_found ->
      if n = 1 then
        raise Not_found
      else begin
        Thread.delay w;
        let n' = if n = min_int then min_int else pred n in
        lookup_times n' w ns k
      end

type at_fail_chan = unit Join.chan

let do_at_fail f =
  def ch () = (try f () with _ -> ()); 0 in
  ch

def do_nothing_at_fail () = 0

let exit_at_fail_with_code c =
  def exit_at_fail () = exit c; 0 in
  exit_at_fail

let exit_at_fail = exit_at_fail_with_code 0

exception Invalid_magic of string * string

let rec get_site n addr =
  try Join.Site.there addr with
  | Join.Exit -> raise Join.Exit
  | Failure _ as e ->
      if n > 1 then begin
	Thread.delay 0.5 ; get_site (n-1) addr
      end else raise e

let connect cfg =
  let inet_addr = (Unix.gethostbyname cfg.host).Unix.h_addr_list.(0) in
  let server_addr = Unix.ADDR_INET (inet_addr, cfg.port) in
  get_site 128 server_addr
  
let init_client ?(at_fail=do_nothing_at_fail) cfg =
  let server_site = connect cfg in
  let ns = Join.Ns.of_site server_site in
  Join.Site.at_fail server_site at_fail;
  let lookup_magic = lookup_times ~-1 1.0 in
  let magic : string = lookup_magic ns cfg.magic_id in
  if magic <> cfg.magic_value then
    raise (Invalid_magic (cfg.magic_value, magic));
  let pids = do_forks cfg.forked_program cfg.fork_args cfg.clients in
  ns,pids

let init_client_with_lookup ?(at_fail=do_nothing_at_fail) ?(lookup=(lookup_times ~-1 1.0)) cfg id =
  let ns,pids = init_client ~at_fail:at_fail cfg in
  let v = lookup ns id in
  ns, pids,v


(* Server-related functions *)

let init_server cfg =
  let inet_addr = (Unix.gethostbyname cfg.host).Unix.h_addr_list.(0) in
  let server_addr = Unix.ADDR_INET (inet_addr, cfg.port) in
  Join.Ns.register Join.Ns.here cfg.magic_id cfg.magic_value;
  Join.Site.listen server_addr;
  let pids = do_forks cfg.forked_program cfg.fork_args (max 0 cfg.clients) in
  Join.Ns.here, pids

let init_server_with_register cfg id v =
  let ns, pids = init_server cfg in
  Join.Ns.register ns id v;
  ns, pids


(* Miscellaneous functions *)

let wait_forever () =
  def wait() & never_sent() = reply to wait in
  wait ();
  exit 0 (* never reached *)
