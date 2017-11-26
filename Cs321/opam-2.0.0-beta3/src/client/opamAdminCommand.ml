(**************************************************************************)
(*                                                                        *)
(*    Copyright 2012-2017 OCamlPro                                        *)
(*    Copyright 2012 INRIA                                                *)
(*                                                                        *)
(*  All rights reserved. This file is distributed under the terms of the  *)
(*  GNU Lesser General Public License version 2.1, with the special       *)
(*  exception on linking described in the file LICENSE.                   *)
(*                                                                        *)
(**************************************************************************)

open OpamTypes
open OpamProcess.Job.Op
open OpamStateTypes
open Cmdliner

let admin_command_doc =
  "Tools for repository administrators"

let admin_command_man = [
  `S "DESCRIPTION";
  `P "This command can perform various actions on repositories in the opam \
      format. It is expected to be run from the root of a repository, i.e. a \
      directory containing a 'repo' file and a subdirectory 'packages/' \
      holding package definition within subdirectories. A 'compilers/' \
      subdirectory (opam repository format version < 2) will also be used by \
      the $(b,upgrade-format) subcommand."
]

let index_command_doc =
  "Generate an inclusive index file for serving over HTTP."
let index_command =
  let command = "index" in
  let doc = index_command_doc in
  let man = [
    `S "DESCRIPTION";
    `P "An opam repository can be served over HTTP or HTTPS using any web \
        server. To that purpose, an inclusive index needs to be generated \
        first: this command generates the files the opam client will expect \
        when fetching from an HTTP remote, and should be run after any changes \
        are done to the contents of the repository."
  ]
  in
  let urls_txt_arg =
    Arg.(value & vflag `minimal_urls_txt [
        `no_urls_txt, info ["no-urls-txt"] ~doc:
          "Don't generate a 'urls.txt' file. That index file is no longer \
           needed from opam 2.0 on, but is still used by older versions.";
        `full_urls_txt, info ["full-urls-txt"] ~doc:
          "Generate an inclusive 'urls.txt', for a repository that will be \
           used by opam versions earlier than 2.0.";
        `minimal_urls_txt, info ["minimal-urls-txt"] ~doc:
          "Generate a minimal 'urls.txt' file, that only includes the 'repo' \
           file. This allows opam versions earlier than 2.0 to read that file, \
           and be properly redirected to a repository dedicated to their \
           version, assuming a suitable 'redirect:' field is defined, instead \
           of failing. This is the default.";
      ])
  in
  let cmd global_options urls_txt =
    OpamArg.apply_global_options global_options;
    let repo_root = OpamFilename.cwd () in
    if not (OpamFilename.exists_dir OpamFilename.Op.(repo_root / "packages"))
    then
      OpamConsole.error_and_exit
        "No repository found in current directory.\n\
         Please make sure there is a \"packages/\" directory";
    let repo_file =
      OpamFile.Repo.read_opt (OpamRepositoryPath.repo repo_root)
    in
    if repo_file = None then
      OpamConsole.warning "No \"repo\" file found.";
    if urls_txt <> `no_urls_txt then
      (OpamConsole.msg "Generating urls.txt...\n";
       OpamFilename.of_string "repo" ::
       (if urls_txt = `full_urls_txt then
          OpamFilename.rec_files OpamFilename.Op.(repo_root / "compilers") @
          OpamFilename.rec_files (OpamRepositoryPath.packages_dir repo_root)
        else []) |>
       List.fold_left (fun set f ->
           if not (OpamFilename.exists f) then set else
           let attr = OpamFilename.to_attribute repo_root f in
           OpamFilename.Attribute.Set.add attr set
         ) OpamFilename.Attribute.Set.empty |>
       OpamFile.File_attributes.write
         (OpamFile.make (OpamFilename.of_string "urls.txt")));
    OpamConsole.msg "Generating index.tar.gz...\n";
    OpamHTTP.make_index_tar_gz repo_root;
    OpamConsole.msg "Done.\n";
  in
  Term.(pure cmd $ OpamArg.global_options $ urls_txt_arg),
  OpamArg.term_info command ~doc ~man


(* Downloads all urls of the given package to the given cache_dir *)
let package_files_to_cache repo_root cache_dir ?link (nv, prefix) =
  match
    OpamFileTools.read_opam
      (OpamRepositoryPath.packages repo_root prefix nv)
  with
  | None -> Done (OpamPackage.Map.empty)
  | Some opam ->
    let add_to_cache ?name urlf errors =
      let label =
        OpamPackage.to_string nv ^
        OpamStd.Option.to_string ((^) "/") name
      in
      match OpamFile.URL.checksum urlf with
      | [] ->
        OpamConsole.warning "[%s] no checksum, not caching"
          (OpamConsole.colorise `green label);
        Done errors
      | (first_checksum :: _) as checksums ->
        OpamRepository.pull_file_to_cache label
          ~cache_dir
          checksums
          (OpamFile.URL.url urlf :: OpamFile.URL.mirrors urlf)
        @@| function
        | Not_available m ->
          OpamPackage.Map.update nv (fun l -> m::l) [] errors
        | Up_to_date () | Result () ->
          OpamStd.Option.iter (fun link_dir ->
              let target =
                OpamFilename.create cache_dir
                  (OpamFilename.Base.of_string
                     (String.concat "/" (OpamHash.to_path first_checksum)))
              in
              let name =
                OpamStd.Option.default
                  (OpamUrl.basename (OpamFile.URL.url urlf))
                  name
              in
              let link =
                OpamFilename.Op.(link_dir / OpamPackage.to_string nv // name)
              in
              OpamFilename.link ~relative:true ~target ~link)
            link;
          errors
    in
    let urls =
      (match OpamFile.OPAM.url opam with
       | None -> []
       | Some urlf -> [add_to_cache urlf]) @
      (List.map (fun (name,urlf) ->
           add_to_cache ~name:(OpamFilename.Base.to_string name) urlf)
          (OpamFile.OPAM.extra_sources opam))
    in
    OpamProcess.Job.seq urls OpamPackage.Map.empty

let cache_command_doc = "Fills a local cache of package archives"
let cache_command =
  let command = "cache" in
  let doc = cache_command_doc in
  let man = [
    `S "DESCRIPTION";
    `P "Downloads the archives for all packages to fill a local cache, that \
        can be used when serving the repository."
  ]
  in
  let cache_dir_arg =
    Arg.(value & pos 0 OpamArg.dirname (OpamFilename.Dir.of_string "./cache") &
         info [] ~docv:"DIR" ~doc:
           "Name of the cache directory to use.")
  in
  let no_repo_update_arg =
    Arg.(value & flag & info ["no-repo-update";"n"] ~doc:
           "Don't check, create or update the 'repo' file to point to the \
            generated cache ('archive-mirrors:' field).")
  in
  let link_arg =
    Arg.(value & opt (some OpamArg.dirname) None &
         info ["link"] ~docv:"DIR" ~doc:
           "Create reverse symbolic links to the archives within $(i,DIR), in \
            the form $(b,DIR/PKG.VERSION/FILENAME).")
  in
  let jobs_arg =
    Arg.(value & opt OpamArg.positive_integer 8 &
         info ["jobs"; "j"] ~docv:"JOBS" ~doc:
           "Number of parallel downloads")
  in
  let cmd global_options cache_dir no_repo_update link jobs =
    OpamArg.apply_global_options global_options;
    let repo_root = OpamFilename.cwd () in
    if not (OpamFilename.exists_dir OpamFilename.Op.(repo_root / "packages"))
    then
        OpamConsole.error_and_exit
          "No repository found in current directory.\n\
           Please make sure there is a \"packages\" directory";
    let repo_file = OpamRepositoryPath.repo repo_root in
    let repo_def = OpamFile.Repo.safe_read repo_file in

    let repo = OpamRepositoryBackend.local repo_root in
    let pkg_prefixes = OpamRepository.packages_with_prefixes repo in

    let errors =
      OpamParallel.reduce ~jobs
        ~nil:OpamPackage.Map.empty
        ~merge:(OpamPackage.Map.union (fun a _ -> a))
        ~command:(package_files_to_cache repo_root cache_dir ?link)
        (List.sort (fun (nv1,_) (nv2,_) ->
             (* Some pseudo-randomisation to avoid downloading all files from
                the same host simultaneously *)
             match compare (Hashtbl.hash nv1) (Hashtbl.hash nv2) with
             | 0 -> compare nv1 nv2
             | n -> n)
            (OpamPackage.Map.bindings pkg_prefixes))
    in

    if not no_repo_update then
      let cache_dir_url = OpamFilename.remove_prefix_dir repo_root cache_dir in
      if not (List.mem cache_dir_url (OpamFile.Repo.dl_cache repo_def)) then
        (OpamConsole.msg "Adding %s to %s...\n"
           cache_dir_url (OpamFile.to_string repo_file);
         OpamFile.Repo.write repo_file
           (OpamFile.Repo.with_dl_cache
              (cache_dir_url :: OpamFile.Repo.dl_cache repo_def)
              repo_def));

      if not (OpamPackage.Map.is_empty errors) then (
        OpamConsole.error "Got some errors while processing: %s"
          (OpamStd.List.concat_map ", " OpamPackage.to_string
             (OpamPackage.Map.keys errors));
        OpamConsole.errmsg "%s"
          (OpamStd.Format.itemize (fun (nv,el) ->
               Printf.sprintf "[%s] %s" (OpamPackage.to_string nv)
                 (String.concat "\n" el))
              (OpamPackage.Map.bindings errors))
      );

      OpamConsole.msg "Done.\n";
  in
  Term.(pure cmd $ OpamArg.global_options $
        cache_dir_arg $ no_repo_update_arg $ link_arg $ jobs_arg),
  OpamArg.term_info command ~doc ~man


let upgrade_command_doc =
  "Upgrades repository from earlier opam versions."
let upgrade_command =
  let command = "upgrade" in
  let doc = upgrade_command_doc in
  let man = [
    `S "DESCRIPTION";
    `P "This command reads repositories from earlier opam versions, and \
        converts them to repositories suitable for the current opam version. \
        Packages might be created or renamed, and any compilers defined in the \
        old format ('compilers/' directory) will be turned into packages, \
        using a pre-defined hierarchy that assumes OCaml compilers."
  ]
  in
  let clear_cache_arg =
    let doc =
      "Instead of running the upgrade, clear the cache of archive hashes (held \
       in ~/.cache), that is used to avoid re-downloading files to obtain \
       their hashes at every run."
    in
    Arg.(value & flag & info ["clear-cache"] ~doc)
  in
  let create_mirror_arg =
    let doc =
      "Don't overwrite the current repository, but put an upgraded mirror in \
       place in a subdirectory, with proper redirections. Needs the URL the \
       repository will be served from to put in the redirects (older versions \
       of opam don't understand relative redirects)."
    in
    Arg.(value & opt (some OpamArg.url) None &
         info ~docv:"URL" ["m"; "mirror"] ~doc)
  in
  let cmd global_options clear_cache create_mirror =
    OpamArg.apply_global_options global_options;
    if clear_cache then OpamAdminRepoUpgrade.clear_cache ()
    else match create_mirror with
      | None ->
        OpamAdminRepoUpgrade.do_upgrade (OpamFilename.cwd ());
        if OpamFilename.exists (OpamFilename.of_string "index.tar.gz") ||
           OpamFilename.exists (OpamFilename.of_string "urls.txt")
        then
          OpamConsole.note
            "Indexes need updating: you should now run:\n\
             \n\
            \  opam admin index"
      | Some m -> OpamAdminRepoUpgrade.do_upgrade_mirror (OpamFilename.cwd ()) m
  in
  Term.(pure cmd $ OpamArg.global_options $
        clear_cache_arg $ create_mirror_arg),
  OpamArg.term_info command ~doc ~man

let lint_command_doc =
  "Runs 'opam lint' and reports on a whole repository"
let lint_command =
  let command = "lint" in
  let doc = lint_command_doc in
  let man = [
    `S "DESCRIPTION";
    `P "This command gathers linting results on all files in a repository. The \
        warnings and errors to show or hide can be selected"
  ]
  in
  let short_arg =
    OpamArg.mk_flag ["s";"short"]
      "Print only packages and warning/error numbers, without explanations"
  in
  let list_arg =
    OpamArg.mk_flag ["list";"l"]
      "Only list package names, without warning details"
  in
  let include_arg =
    OpamArg.arg_list "INT" "Show only these warnings"
      OpamArg.positive_integer
  in
  let exclude_arg =
    OpamArg.mk_opt_all ["exclude";"x"] "INT"
      "Exclude the given warnings or errors"
      OpamArg.positive_integer
  in
  let ignore_arg =
    OpamArg.mk_opt_all ["ignore-packages";"i"] "INT"
      "Ignore any packages having one of these warnings or errors"
      OpamArg.positive_integer
  in
  let warn_error_arg =
    OpamArg.mk_flag ["warn-error";"W"]
      "Return failure on any warnings, not only on errors"
  in
  let cmd global_options short list incl excl ign warn_error =
    OpamArg.apply_global_options global_options;
    let repo_root = OpamFilename.cwd () in
    if not (OpamFilename.exists_dir OpamFilename.Op.(repo_root / "packages"))
    then
        OpamConsole.error_and_exit
          "No repository found in current directory.\n\
           Please make sure there is a \"packages\" directory";
    let repo = OpamRepositoryBackend.local repo_root in
    let pkg_prefixes = OpamRepository.packages_with_prefixes repo in
    let ret =
      OpamPackage.Map.fold (fun nv prefix ret ->
          let opam_file = OpamRepositoryPath.opam repo_root prefix nv in
          let w, _ = OpamFileTools.lint_file opam_file in
          if List.exists (fun (n,_,_) -> List.mem n ign) w then ret else
          let w =
            List.filter (fun (n,_,_) ->
                (incl = [] || List.mem n incl) && not (List.mem n excl))
              w
          in
          if w <> [] then
            if list then
              print_endline (OpamPackage.to_string nv)
            else if short then
              OpamConsole.msg "%s %s\n" (OpamPackage.to_string nv)
                (OpamStd.List.concat_map " " (fun (n,k,_) ->
                     OpamConsole.colorise
                       (match k with `Warning -> `yellow | `Error -> `red)
                       (string_of_int n))
                    w)
            else
              OpamConsole.msg "\r\027[KIn %s:\n%s\n"
                (OpamPackage.to_string nv)
                (OpamFileTools.warns_to_string w);
          ret && not (warn_error && w <> [] ||
                      List.exists (fun (_,k,_) -> k = `Error) w))
        pkg_prefixes
        true
    in
    OpamStd.Sys.exit (if ret then 0 else 1)
  in
  Term.(pure cmd $ OpamArg.global_options $
        short_arg $ list_arg $ include_arg $ exclude_arg $ ignore_arg $
        warn_error_arg),
  OpamArg.term_info command ~doc ~man


let pattern_list_arg =
  OpamArg.arg_list "PATTERNS"
    "Package patterns with globs. matching againsta $(b,NAME) or \
     $(b,NAME.VERSION)"
    Arg.string

let env_arg =
  Arg.(value & opt (list string) [] & info ["environment"] ~doc:
         "Use the given opam environment, in the form of a list \
          comma-separated 'var=value' bindings, when resolving variables. \
          This is used e.g. when computing available packages: if undefined, \
          availability of packages is not taken into account. Note that, \
          unless overriden, variables like 'root' or 'opam-version' may be \
          taken from the current opam installation. What is defined in \
          $(i,~/.opam/config) is always ignored.")

let state_selection_arg =
  let docs = OpamArg.package_selection_section in
  Arg.(value & vflag OpamListCommand.Available [
      OpamListCommand.Any, info ~docs ["A";"all"]
        ~doc:"Include all, even uninstalled or unavailable packages";
      OpamListCommand.Available, info ~docs ["a";"available"]
        ~doc:"List only packages that are available according to the defined \
              $(b,environment). Without $(b,--environment), equivalent to \
              $(b,--all).";
      OpamListCommand.Installable, info ~docs ["installable"]
        ~doc:"List only packages that are installable according to the \
              defined $(b,environment) (this calls the solver and may be \
              more costly; a package depending on an unavailable may be \
              available, but is never installable)";
    ])

let get_virtual_switch_state repo_root env =
  let env =
    List.map (fun s ->
        match OpamStd.String.cut_at s '=' with
        | Some (var,value) -> OpamVariable.of_string var, S value
        | None -> OpamVariable.of_string s, B true)
      env
  in
  let repo = OpamRepositoryBackend.local repo_root in
  let repo_file = OpamRepositoryPath.repo repo_root in
  let repo_def = OpamFile.Repo.safe_read repo_file in
  let opams = OpamRepositoryState.load_repo_opams repo in
  let gt = {
    global_lock = OpamSystem.lock_none;
    root = OpamStateConfig.(!r.root_dir);
    config = OpamStd.Option.Op.(OpamStateConfig.(load !r.root_dir) +!
                                OpamFile.Config.empty);
    global_variables = OpamVariable.Map.empty;
  } in
  let singl x = OpamRepositoryName.Map.singleton repo.repo_name x in
  let rt = {
    repos_global = gt;
    repos_lock = OpamSystem.lock_none;
    repositories = singl repo;
    repos_definitions = singl repo_def;
    repo_opams = singl opams;
  } in
  let st = OpamSwitchState.load_virtual ~repos_list:[repo.repo_name] gt rt in
  if env = [] then st else
  let gt =
    {gt with global_variables =
               OpamVariable.Map.of_list @@
               List.map (fun (var, value) ->
                   var, (lazy (Some value), "Manually defined"))
                 env }
  in
  {st with
   switch_global = gt;
   available_packages = lazy (
     OpamPackage.keys @@
     OpamPackage.Map.filter (fun package opam ->
         OpamFilter.eval_to_bool ~default:false
           (OpamPackageVar.resolve_switch_raw ~package gt
              OpamSwitch.unset OpamFile.Switch_config.empty)
           (OpamFile.OPAM.available opam))
       st.opams
   )}

let list_command_doc = "Lists packages from a repository"
let list_command =
  let command = "list" in
  let doc = list_command_doc in
  let man = [
    `S "DESCRIPTION";
    `P "This command is similar to 'opam list', but allows listing packages \
        directly from a repository instead of what is available in a given \
        opam installation.";
  ]
  in
  let cmd
      global_options package_selection state_selection package_listing env
      packages =
    OpamArg.apply_global_options global_options;
    let format =
      let force_all_versions =
        match packages with
        | [single] ->
          let nameglob =
            match OpamStd.String.cut_at single '.' with
            | None -> single
            | Some (n, _v) -> n
          in
          (try ignore (OpamPackage.Name.of_string nameglob); true
           with Failure _ -> false)
        | _ -> false
      in
      package_listing ~force_all_versions
    in
    let pattern_selector = OpamListCommand.pattern_selector packages in
    let filter =
      OpamFormula.ands
        [package_selection; Atom state_selection; pattern_selector]
    in
    let st = get_virtual_switch_state (OpamFilename.cwd ()) env in
    if not format.OpamListCommand.short && filter <> OpamFormula.Empty then
      OpamConsole.msg "# Packages matching: %s\n"
        (OpamListCommand.string_of_formula filter);
    let results =
      OpamListCommand.filter ~base:st.packages st filter
    in
    OpamListCommand.display st format results
  in
  Term.(pure cmd $ OpamArg.global_options $ OpamArg.package_selection $
        state_selection_arg $ OpamArg.package_listing $ env_arg $
        pattern_list_arg),
  OpamArg.term_info command ~doc ~man

let filter_command_doc = "Filters a repository to only keep selected packages"
let filter_command =
  let command = "filter" in
  let doc = filter_command_doc in
  let man = [
    `S "DESCRIPTION";
    `P "This command removes all package definitions that don't match the \
        search criteria (specified similarly to 'opam admin list') from a \
        repository."
  ]
  in
  let remove_arg =
    OpamArg.mk_flag ["remove"]
      "Invert the behaviour and remove the matching packages, keeping the ones \
       that don't match."
  in
  let dryrun_arg =
    OpamArg.mk_flag ["dry-run"]
      "List the removal commands, without actually performing them"
  in
  let cmd
      global_options package_selection state_selection env remove dryrun
      packages =
    OpamArg.apply_global_options global_options;
    let repo_root = OpamFilename.cwd () in
    let pattern_selector = OpamListCommand.pattern_selector packages in
    let filter =
      OpamFormula.ands
        [package_selection; Atom state_selection; pattern_selector]
    in
    let st = get_virtual_switch_state repo_root env in
    let packages = OpamListCommand.filter ~base:st.packages st filter in
    if remove then
      OpamConsole.formatted_msg
        "The following packages will be REMOVED from the repository (%d \
         packages will be kept):\n%s\n"
        OpamPackage.Set.(cardinal Op.(st.packages -- packages))
        (OpamStd.List.concat_map " " OpamPackage.to_string
           (OpamPackage.Set.elements packages))
    else
      OpamConsole.formatted_msg
        "The following packages will be kept in the repository (%d packages \
         will be REMOVED):\n%s\n"
        OpamPackage.Set.(cardinal Op.(st.packages -- packages))
        (OpamStd.List.concat_map " " OpamPackage.to_string
           (OpamPackage.Set.elements packages));
    let packages =
      if remove then packages else OpamPackage.Set.Op.(st.packages -- packages)
    in
    if not (dryrun || OpamConsole.confirm "Confirm ?") then
      OpamStd.Sys.exit 2
    else
    let repo = OpamRepositoryBackend.local repo_root in
    let pkg_prefixes = OpamRepository.packages_with_prefixes repo in
    OpamPackage.Map.iter (fun nv prefix ->
        if OpamPackage.Set.mem nv packages then
          let d = OpamRepositoryPath.packages repo_root prefix nv in
          if dryrun then
            OpamConsole.msg "rm -rf %s\n" (OpamFilename.Dir.to_string d)
          else
            OpamFilename.rmdir_cleanup d)
      pkg_prefixes
  in
  Term.(pure cmd $ OpamArg.global_options $ OpamArg.package_selection $
        state_selection_arg $ env_arg $ remove_arg $ dryrun_arg $
        pattern_list_arg),
  OpamArg.term_info command ~doc ~man

let admin_subcommands = [
  index_command; OpamArg.make_command_alias index_command "make";
  cache_command;
  upgrade_command;
  lint_command;
  list_command;
  filter_command;
]

let default_subcommand =
  let man =
    admin_command_man @ [
      `S "COMMANDS";
      `S "COMMAND ALIASES";
    ] @ OpamArg.help_sections
  in
  let usage global_options =
    OpamArg.apply_global_options global_options;
    OpamConsole.formatted_msg
      "usage: opam admin [--version]\n\
      \                  [--help]\n\
      \                  <command> [<args>]\n\
       \n\
       The most commonly used opam commands are:\n\
      \    index          %s\n\
      \    cache          %s\n\
      \    upgrade-format %s\n\
       \n\
       See 'opam admin <command> --help' for more information on a specific \
       command.\n"
      index_command_doc
      cache_command_doc
      upgrade_command_doc
  in
  Term.(pure usage $ OpamArg.global_options),
  Term.info "opam admin"
    ~version:(OpamVersion.to_string OpamVersion.current)
    ~sdocs:OpamArg.global_option_section
    ~doc:admin_command_doc
    ~man
