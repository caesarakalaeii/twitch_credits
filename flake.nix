{
  # Keep this line accurate and one line long: `nix flake metadata` prints it,
  # and it is the first thing a cold agent learns about the repo.
  description = "twitch_credits -- deprecated TypeScript/Node Twitch EventSub bot that drives a relay, an Arduino and GPIO. Run `nix flake show` for the command map.";

  # nixpkgs is the only input, on purpose.
  #
  # flake-utils would buy exactly one thing here -- eachDefaultSystem -- which is
  # the three-line genAttrs below. In exchange it costs a second lock node in
  # every repo (flake-utils transitively pulls `systems`, so really two), a
  # second upstream that can break one repo and not the other forty, and a
  # hardcoded system list this repo cannot edit. That list is currently broken:
  # it still contains x86_64-darwin, which now throws (see `systems` below).
  #
  # nixos-unstable is the same channel the author's own NixOS config tracks, so
  # `nix develop` here and `nixos-rebuild` there resolve the same store paths and
  # share one cache.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    # `...` rather than a closed { self, nixpkgs }: adding a second input later
    # would otherwise fail with "called with unexpected argument 'self'".
    #
    # `self` is bound because the root guard below needs it: it is the only
    # handle a pure evaluation has on this flake's own source, and recognising
    # that source is what keeps a verb from running against a foreign tree.
    { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      # x86_64-darwin is deliberately absent. nixpkgs 26.11 replaced that whole
      # attribute set with `throw "Nixpkgs 26.11 has dropped support for
      # x86_64-darwin"`. genAttrs is lazy, so plain `nix develop` on Linux would
      # not notice -- it detonates later, on `nix flake check --all-systems`.
      # Add it back only against a separate nixpkgs-26.05-darwin input.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Stand-in for flake-utils.lib.eachDefaultSystem. Passes `pkgs` rather than
      # a system string, because that is what every call site below wants.
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # ======================================================================
      # PER-REPO BLOCK 1 -- the toolchain
      # ======================================================================
      # Everything the commands below need. `nix flake check` realises this
      # closure, so a typo'd attr name fails at the flake gate instead of
      # surfacing as "command not found" halfway through a task.
      #
      # Explicit `pkgs.foo`, never `with pkgs; [ ... ]`: when an attr disappears
      # in a nixpkgs bump, `with` reports a bare undefined identifier with no
      # hint of which set it came from, and the name is not greppable.
      #
      # nodejs_22 pinned by major, never bare `nodejs`: an alias that moves
      # invalidates every node_modules in the fleet on the same afternoon, and
      # here it would also change the ABI the native addons in package-lock.json
      # are compiled against.
      #
      # 22 is the FLOOR, not a preference: nodejs_20 is now
      # `throw "Node.js 20 support was removed given upstream End-of-Life on
      # 2026-04-30"` on this pin, so the node 16 era this lockfile was written
      # for is no longer expressible in nixpkgs at all. That is the direct cause
      # of the epoll limitation documented in the command map below -- do not
      # spend time looking for an older nodejs attr, there is not one.
      #
      # npm ships inside the nodejs derivation; never add it separately.
      toolchain = pkgs: [
        pkgs.nodejs_22

        # The repo pins typescript 4.7.4 in devDependencies and `dev-build`
        # deliberately uses THAT compiler out of node_modules, not this one.
        # These attrs are here for the language server and for ad-hoc
        # `tsc --noEmit` probing only; expect 5.9.3 to report diagnostics 4.7.4
        # does not. Do not "fix" `dev-build` to use it.
        pkgs.typescript
        pkgs.typescript-language-server

        # node-gyp's build environment. bcrypt has no prebuild for node 22's ABI
        # (NODE_MODULE_VERSION 127), so any install that runs scripts compiles
        # C++ here -- verified `npm rebuild bcrypt` succeeds with exactly this
        # set. python313 is node-gyp's driver, not a runtime dependency of the
        # repo, and it has to be a listed package rather than only the
        # npm_config_python value below: verified that without this line a host
        # python 3.14 leaked in as `python3` inside the shell.
        pkgs.python313
        # pkgs.gcc is listed explicitly even though mkShell already supplies a
        # stdenv compiler, because the `dev-*` wrappers get PATH from
        # `runtimeInputs` and no stdenv setup hooks at all. Without it
        # `nix run .#setup` would fail to find a compiler while the same command
        # worked inside `nix develop` -- the exact surface-dependent split this
        # template exists to prevent.
        pkgs.gcc
        pkgs.gnumake
        # For binding.gyp files that shell out to pkg-config. Nothing in this
        # lockfile does today (verified: bcrypt and @serialport/bindings-cpp both
        # build without it), so this is insurance, not a load-bearing entry.
        pkgs.pkg-config

        # ---- present in every repo in the fleet ----
        pkgs.git
        pkgs.jq
      ];

      # ======================================================================
      # PER-REPO BLOCK 2 -- libraries that get dlopened, not linked
      # ======================================================================
      # node-gyp output is never patchelf'd, so a compiled .node keeps whatever
      # DT_NEEDED the linker wrote, has no RPATH into /nix/store, and NixOS has
      # no /usr/lib to fall back on. Verified with ldd that bcrypt's
      # bcrypt_lib.node needs libstdc++.so.6 and resolves it through this path.
      #
      # Honest scope, so nobody mistakes this for a fix it is not: loading that
      # addon also succeeds with LD_LIBRARY_PATH cleared, because node is itself
      # linked against the same libstdc++ SONAME and has already loaded it. This
      # entry is what keeps that true when the addon is loaded by something other
      # than this exact node -- it is not papering over a failure you would
      # otherwise see today.
      #
      # zlib and udev are deliberately NOT here. Node bundles its own zlib, and
      # @serialport/bindings-cpp resolves to an ABI-stable NAPI prebuild
      # (prebuilds/linux-x64/node.napi.glibc.node) rather than compiling against
      # -ludev -- verified with ldd that the prebuild has no libudev DT_NEEDED,
      # and this repo never calls SerialPort.list(), which is the one code path
      # that shells out to udevadm. Add a lib here only when a specific addon
      # actually fails to dlopen it.
      nativeLibs = pkgs: [
        pkgs.stdenv.cc.cc.lib
      ];

      # ======================================================================
      # PER-REPO BLOCK 3 -- constant environment variables
      # ======================================================================
      # Only values that are constants belong here. Anything that must READ an
      # existing value (LD_LIBRARY_PATH), UNSET something (SOURCE_DATE_EPOCH) or
      # touch the work tree goes in the shellHook further down.
      #
      # This attrset is applied to BOTH surfaces -- the dev shell and every
      # `nix run` wrapper -- so a command cannot behave differently depending on
      # how it was invoked.
      envVars = pkgs: {
        # Pin node-gyp to the nix interpreter by absolute path. Left alone it
        # takes the first `python3` on PATH, which on a non-NixOS host is some
        # system python whose setuptools state we do not control -- and which
        # would make a C++ build succeed for one agent and fail for the next.
        npm_config_python = "${pkgs.python313}/bin/python";
        # npm's update notifier is a background registry request on every single
        # invocation, and its banner lands in the agent's captured output.
        npm_config_update_notifier = "false";
        npm_config_fund = "false";
        npm_config_audit = "false";
      };

      # ======================================================================
      # PER-REPO BLOCK 4 -- the command map
      # ======================================================================
      # THE single source of truth. It generates `apps` (so `nix run .#build`
      # works), the `dev-*` wrappers on PATH inside the shell, and `dev-help`.
      # Nothing is written twice, so `nix flake show` can never disagree with
      # what `dev-build` actually runs.
      #
      # Two verbs are deliberately ABSENT, and their absence is the single most
      # useful thing this file records about the repo. Read this before adding
      # either back.
      #
      # `test` -- there are no test files, and package.json's test script is
      # literally `echo "Error: no test specified" && exit 1`. A verb wired to
      # that would report failure forever and make `nix flake show` a liar.
      #
      # `run` -- THE APP CANNOT START ON ANY NODE THIS NIXPKGS SHIPS, and no
      # change to this flake fixes it. src/main.ts imports src/relais.ts
      # (main.ts:4), and src/relais.ts:1 imports `onoff` -- the only `onoff`
      # import in the tree. (An earlier revision of this comment blamed
      # src/taser.ts, which is wrong: taser.ts imports `events` and ./wait and
      # nothing native.) onoff requires `epoll` 4.0.1, epoll is a NAN 2.16.0
      # addon, and NAN of that vintage does not compile against node 22's V8
      # headers -- reproduced twice, failing at
      #   nan.h:2546  no matching function for call to
      #               v8::ObjectTemplate::SetAccessor(... v8::AccessControl& ...)
      #   v8-local-handle.h:269  static assertion failed: type check
      # and, with install scripts skipped, at runtime with
      #   Cannot find module '.../epoll/lib/binding/node-v127-linux-x64/epoll.node'
      # The fix is upstream in the repo (bump onoff/epoll, or drop the GPIO
      # dependency), not here: node 20 and 18 no longer exist as nixpkgs attrs,
      # so there is no older interpreter to fall back to. Everything that does
      # not touch GPIO is unaffected, which is why build/lint/fmt are real.
      #
      # Every command reaches the repo's own binaries through
      # "$REPO_ROOT/node_modules/.bin/..." rather than a bare name, because
      # writeShellApplication PREPENDS the nix toolchain to PATH: a bare `tsc`
      # resolves to nixpkgs' 5.9.3 instead of the 4.7.4 this lockfile pins, and
      # a bare `eslint` is not on PATH at all. The absolute path also means the
      # commands behave identically from a subdirectory and on both surfaces.
      #
      # All of which is worth exactly nothing unless $REPO_ROOT really is this
      # repo, and here is what that cost before rootGuard existed. Standing in an
      # unrelated git repo that had a node_modules of its own:
      #   nix run /path/to/twitch_credits#fmt
      # took $REPO_ROOT from the CALLER's git toplevel, ran the CALLER's
      # ./node_modules/.bin/eslint --fix over the CALLER's src/, appended to a
      # file there and exited 0 -- a mutating verb writing outside the repo, a
      # foreign binary off the caller's disk executed as if it were ours, and a
      # green exit earned by inspecting none of this repo. The flake-URL form is
      # exactly what CI and a cold agent use. rootGuard below is what stops it,
      # and `checks.anchoring` is what keeps it stopped.
      commands = pkgs: {
        setup = {
          # --ignore-scripts is load-bearing, not caution. A plain `npm ci` dies
          # building epoll (see above) and npm then ROLLS THE WHOLE TREE BACK:
          # verified node_modules was left completely empty, so a cold agent that
          # ran the obvious command would be left with no typescript, no eslint
          # and no types at all. With scripts skipped the same install finishes in
          # seconds and everything except the GPIO addon is usable.
          #
          # bcrypt is the one addon this repo actually needs compiled, and it
          # compiles fine here -- only epoll does not. Rebuild it BY NAME after
          # the install, which never visits epoll:
          #   nix run .#setup && nix develop -c npm rebuild bcrypt
          # Verified end to end: before the rebuild,
          # `nix develop -c node -e "require('bcrypt')"` dies with
          #   Cannot find module '.../bcrypt/lib/binding/napi-v3/bcrypt_lib.node'
          # and after it the addon loads and hashSync returns a $2b$ digest.
          # @serialport/bindings-cpp needs nothing: it loads straight out of a
          # skipped-scripts install because it ships a NAPI prebuild (verified),
          # so `npm rebuild` there is optional rather than a fix.
          #
          # Do NOT try to opt in with `nix run .#setup -- --ignore-scripts=false`.
          # The flag above is hardcoded, npm therefore receives --ignore-scripts
          # AND --ignore-scripts=false, obeys the second, and reproduces the exact
          # rollback described one paragraph up -- verified: it dies on epoll with
          # exit 1 and leaves node_modules with zero entries. There is no argument
          # to this verb that turns scripts back on; the rebuild above is the way.
          description = "(network) npm ci --ignore-scripts; native addons are skipped -- read the `run` note in flake.nix before changing that";
          text = ''
            npm --prefix "$REPO_ROOT" ci --ignore-scripts "$@"
          '';
        };
        build = {
          description = "tsc -> dist/ with the repo-pinned typescript 4.7.4 (needs `setup` first)";
          text = ''
            "$REPO_ROOT/node_modules/.bin/tsc" --project "$REPO_ROOT/tsconfig.json" "$@"
          '';
        };
        lint = {
          # The caveat is in the description because an agent reads
          # `nix flake show`, not this comment. .eslintrc.js is invalid twice
          # over: a top-level `global` key that eslint 8 rejects outright, and
          # then `BufferEncoding: ''` where a global's value must be 'readonly',
          # 'writable' or 'off'. Verified by applying exactly that repair
          # (`globals: { BufferEncoding: 'readonly' }`) in a scratch work tree:
          # eslint then runs normally and reports 52 ordinary style errors, 34 of
          # them --fix-able. So the toolchain here is sound and the repo's config
          # is what is broken. Left untouched on purpose: this commit adds a flake
          # and does not edit project files. (An earlier revision of this comment
          # said 55; re-measured twice on this pin, it is 52.)
          description = "eslint over src/ -- currently exits 2 on the repo's own invalid .eslintrc.js (`global` should be `globals`, and its value must be 'readonly')";
          text = ''
            if [ "$#" -eq 0 ]; then
              set -- "$REPO_ROOT/src"
            fi
            "$REPO_ROOT/node_modules/.bin/eslint" --ext .ts,.js "$@"
          '';
        };
        fmt = {
          # There is no prettier here; eslint-config-standard IS the style, so
          # --fix is the repo's only in-place rewrite. Blocked by the same
          # invalid .eslintrc.js as lint.
          description = "eslint --fix over src/ (rewrites files; blocked by the same invalid .eslintrc.js as lint)";
          text = ''
            if [ "$#" -eq 0 ]; then
              set -- "$REPO_ROOT/src"
            fi
            "$REPO_ROOT/node_modules/.bin/eslint" --ext .ts,.js --fix "$@"
          '';
        };
      };

      # ======================================================================
      # GENERIC MACHINERY -- byte-identical in all 41 repos, do not edit
      # ======================================================================

      # Prepend, never assign: a host LD_LIBRARY_PATH may be carrying something
      # the user needs, and clobbering it breaks binaries they launch from here.
      # Linux only -- on darwin the loader variable is DYLD_*, and exporting a
      # Linux-shaped value there is at best useless.
      ldPreamble =
        pkgs:
        lib.optionalString (pkgs.stdenv.hostPlatform.isLinux && nativeLibs pkgs != [ ]) ''
          export LD_LIBRARY_PATH="${lib.makeLibraryPath (nativeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        '';

      # Every command gets $REPO_ROOT. `nix run` and `nix develop` both start in
      # whatever directory they were invoked from, so a bare `node_modules`
      # silently forks a second environment as soon as an agent works from a
      # subdirectory.
      #
      # An already-exported REPO_ROOT wins over discovery, and that is the one
      # supported way to drive a verb from outside the tree -- a pure evaluation
      # cannot learn its own work-tree path, so nothing else can supply it:
      #   REPO_ROOT=/path/to/repo nix run /path/to/repo#lint
      # It is verified exactly like a discovered root, so a wrong value is
      # rejected rather than obeyed.
      rootPreamble = ''
        REPO_ROOT="''${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
        export REPO_ROOT
      '';

      # Discovery is a GUESS. `git rev-parse` answers about the CALLER's repo, and
      # `|| pwd` is the same guess with the lookup removed, so on its own the line
      # above will happily point a verb at somebody else's work tree -- see the
      # reproduction recorded in the command map above, which was not theoretical.
      # So the guess is VERIFIED here, before any verb touches a file, and a verb
      # that cannot verify it refuses instead of guessing again.
      #
      # ${self} is all a pure evaluation knows about this flake's own source: a
      # /nix/store copy of the tracked tree, never the work-tree path (checked --
      # self and self.sourceInfo carry outPath/narHash/rev and nothing else, and
      # `nix run` exports no flake reference either). That copy cannot BE the
      # answer, because the verbs must write to the work tree and the store is
      # read-only, but it is enough to RECOGNISE the tree it came from.
      #
      # flake.nix is what gets compared, whole: its description line names the
      # repo, so no other checkout in the fleet can match it, and nix already
      # copied the DIRTY work tree, so an uncommitted edit to a tracked file does
      # not trip the guard (verified: an unstaged line appended here, and the
      # verbs still ran). `$(< file)` is a bash builtin, so no PATH the caller
      # controls can subvert the check, and shellcheck is happy with it.
      #
      # Then, and only then, cd. That is what makes a verb behave identically
      # from any cwd: tools that discover their own inputs -- eslint's ignore
      # file, npm's .npmrc, node's module resolution -- resolve them from the
      # repo root instead of from wherever the caller happened to stand. The
      # consequence worth knowing: a relative path passed by hand is resolved
      # from the repo root too, so `dev-lint src/main.ts` works from anywhere,
      # while `dev-lint main.ts` from inside src/ does not.
      #
      # The one cost, stated plainly: referencing ${self} makes every wrapper
      # depend on the source, so the first `nix run` after any edit to a tracked
      # file rebuilds one tiny derivation (a copy plus shellcheck, about a
      # second). That is the price of the verbs knowing which tree they belong
      # to, and it is nothing next to a verb rewriting the wrong tree.
      #
      # Wrappers only, never the dev shell: a shellHook that cd'd would teleport
      # an interactive user out of the subdirectory they started in, and one that
      # exited would close their shell over a `nix develop /path/to/repo` that is
      # perfectly reasonable on its own.
      rootGuard = ''
        if [ ! -r "$REPO_ROOT/flake.nix" ] ||
          [ "$(< "$REPO_ROOT/flake.nix")" != "$(< ${self}/flake.nix)" ]; then
          printf '%s\n' \
            "''${0##*/}: $REPO_ROOT is not the work tree this flake came from." \
            "Refusing to read or write anything there. Run this from inside the" \
            "repo, or name the tree explicitly:" \
            "  REPO_ROOT=/path/to/repo ''${0##*/}''${*:+ $*}" >&2
          exit 1
        fi
        cd "$REPO_ROOT"
      '';

      # One derivation per command, reused by both `apps` and the dev shell, so
      # the two can never diverge. `dev-` prefixed because a bare `test` binary
      # earlier on PATH would shadow the POSIX shell builtin and quietly break
      # every script in the repo that uses it.
      wrappers =
        pkgs:
        lib.mapAttrs (
          name: cmd:
          pkgs.writeShellApplication {
            name = "dev-${name}";
            runtimeInputs = toolchain pkgs;
            runtimeEnv = envVars pkgs;
            meta.description = cmd.description;
            text = ''
              ${rootPreamble}
              ${rootGuard}
              ${ldPreamble pkgs}
              ${cmd.text}
            '';
          }
        ) (commands pkgs);

      helpFor =
        pkgs:
        let
          cmds = commands pkgs;
          names = lib.attrNames cmds;
          width = lib.foldl' (a: n: lib.max a (builtins.stringLength n)) 0 names;
          pad = n: n + lib.concatStrings (lib.genList (_: " ") (width - builtins.stringLength n));
          line = n: c: "  dev-${pad n}  ${c.description}";
        in
        pkgs.writeShellApplication {
          name = "dev-help";
          meta.description = "print this repo's command map (works offline)";
          text = ''
            cat <<'EOF'
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList line cmds)}
            EOF
          '';
        };
    in
    {
      # `nix flake show` -- the discovery entrypoint, and deliberately the whole
      # machine-facing contract: every app carries a meta.description, which
      # `nix flake show` prints inline and `nix flake show --json` exposes at
      # .apps.<system>.<name>.description. Pure evaluation, so an agent gets the
      # entire command map in one cheap call without reading a README.
      #
      # Do NOT invent a top-level output for this (`agentManifest`, `probeThing`
      # ...). Nix answers with `warning: unknown flake output '<name>'` on every
      # single `nix flake check`, forever.
      apps = forAllSystems (
        pkgs:
        lib.mapAttrs (name: cmd: {
          type = "app";
          program = "${(wrappers pkgs).${name}}/bin/dev-${name}";
          meta.description = cmd.description;
        }) (commands pkgs)
      );

      # `nix develop` -- the toolchain, plus a dev-<verb> for every app.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = toolchain pkgs ++ lib.attrValues (wrappers pkgs) ++ [ (helpFor pkgs) ];

          env = envVars pkgs;

          # Some C extensions and node-gyp addons compile at -O0, where glibc's
          # _FORTIFY_SOURCE becomes a hard error instead of a warning.
          hardeningDisable = [ "fortify" ];

          shellHook = ''
            # mkShell inherits SOURCE_DATE_EPOCH=315532800 (1980-01-01) from
            # stdenv, and any wheel or zip built in here then dies with "ZIP does
            # not support timestamps before 1980".
            unset SOURCE_DATE_EPOCH

            # Discover the root fresh instead of inheriting whatever an outer dev
            # shell exported: entering THIS shell is the statement of which tree
            # is meant, and a stale value would make every dev-* verb refuse.
            # The wrappers still honour an exported REPO_ROOT, which is how a
            # verb is driven from outside the tree.
            unset REPO_ROOT
            ${rootPreamble}
            ${ldPreamble pkgs}

            # Nothing networked, nothing stateful and nothing interactive above
            # this line, and nothing below it either. No `npm install`, no
            # `npm ci`, no `read`, no `exec $SHELL`. Bootstrapping in the hook
            # makes a cold `nix develop -c node --version` start downloading
            # before it runs anything, on EVERY invocation -- the exact failure
            # an unattended agent cannot diagnose. That is what `dev-setup` is
            # for, and its description says `(network)` so an agent knows not to
            # retry it offline.

            # The banner is interactive-only, and this guard is load-bearing:
            # shellHook output lands on the STDOUT of `nix develop -c <cmd>`, so
            # an unguarded echo corrupts anything parsing it
            # (`nix develop -c cat x.json | jq` fails to parse). $- is the only
            # reliable discriminator here -- it lacks `i` for `nix develop -c`
            # and has it at an interactive prompt. Do not test $PS1 (unset in
            # both) or $IN_NIX_SHELL (set in both). >&2 is the second layer, for
            # the case where a caller runs us on a pty.
            case $- in
              *i*) echo "twitch_credits dev shell -- 'dev-help' for the command map" >&2 ;;
            esac
          '';
        };
      });

      # `nix flake check` -- honest by construction. It realises the toolchain
      # closure (so a typo'd or currently-broken attr fails here) and builds
      # every wrapper, which runs shellcheck over every command text. Add real
      # test derivations beside it. NEVER add a check that always passes: an
      # agent reads "all checks passed!" as a signal, and a fake check makes
      # `nix flake check` a liar.
      checks = forAllSystems (pkgs: {
        toolchain =
          pkgs.runCommand "toolchain-check"
            {
              nativeBuildInputs = toolchain pkgs ++ lib.attrValues (wrappers pkgs);
            }
            ''
              for verb in ${lib.escapeShellArgs (lib.attrNames (commands pkgs))}; do
                command -v "dev-$verb" > /dev/null || {
                  echo "dev-$verb is not on PATH" >&2
                  exit 1
                }
              done
              touch "$out"
            '';

        # The regression test for rootGuard, and the reason the anchoring fix
        # cannot rot. It runs a MUTATING verb from a directory that is not this
        # repo -- the sandbox's own cwd, holding a plausible-looking src/ -- and
        # demands three things: a non-zero exit, the guard's own message (so a
        # crash for some unrelated reason cannot be mistaken for a refusal), and
        # a byte-identical decoy file afterwards.
        #
        # Nothing here can pass vacuously: drop the `cd`, drop the comparison, or
        # go back to trusting `git rev-parse`, and dev-fmt starts exiting 0 over
        # the sandbox's src/, which fails on the first assertion. Offline and
        # deterministic -- no network, no git repo, no work tree.
        anchoring =
          pkgs.runCommand "anchoring-check"
            {
              nativeBuildInputs = [ (wrappers pkgs).fmt ];
            }
            ''
              mkdir -p decoy/src
              printf 'const  x  =  1\nconsole.log( x )\n' > decoy/src/decoy.ts
              cp decoy/src/decoy.ts untouched.ts
              cd decoy
              if dev-fmt > ../out.txt 2>&1; then
                echo "dev-fmt exited 0 from $PWD, which is not the repo:" >&2
                cat ../out.txt >&2
                exit 1
              fi
              grep -q "is not the work tree this flake came from" ../out.txt || {
                echo "dev-fmt failed, but not on the root guard:" >&2
                cat ../out.txt >&2
                exit 1
              }
              cmp src/decoy.ts ../untouched.ts
              touch "$out"
            '';
      });

      # `nix fmt` -- formats the *Nix* in this repo; project code is `dev-fmt`.
      # nixfmt-tree (the treefmt wrapper) rather than bare nixfmt, because bare
      # nixfmt tries to parse every path handed to it and fails on non-Nix files.
      # This file ships already formatted, so `nix fmt` is a no-op rather than a
      # diff in 41 repos.
      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
