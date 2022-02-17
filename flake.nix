{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
    flake-compat = {
      url = github:edolstra/flake-compat;
      flake = false;
    };
  };
  outputs = { self, flake-utils, nixpkgs, ... }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          defaultPackage = with pkgs; stdenv.mkDerivation {
            name = "emacs";
            src = self;

            NATIVE_FULL_AOT = "1";
            LIBRARY_PATH = "${lib.getLib stdenv.cc.libc}/lib";

            enableParallelBuilding = true;

            postPatch = lib.concatStringsSep "\n" [
              # Add the name of the wrapped gvfsd
              # This used to be carried as a patch but it often got out of sync with upstream
              # and was hard to maintain for emacs-overlay.
              (lib.concatStrings (map
                (fn: ''
                  sed -i 's#(${fn} "gvfs-fuse-daemon")#(${fn} "gvfs-fuse-daemon") (${fn} ".gvfsd-fuse-wrapped")#' lisp/net/tramp-gvfs.el
                '') [
                "tramp-compat-process-running-p"
                "tramp-process-running-p"
              ]))

              # Reduce closure size by cleaning the environment of the emacs dumper
              ''
                substituteInPlace src/Makefile.in \
                  --replace 'RUN_TEMACS = ./temacs' 'RUN_TEMACS = env -i ./temacs'
              ''

              ''
                substituteInPlace lisp/international/mule-cmds.el \
                  --replace /usr/share/locale ${gettext}/share/locale

                for makefile_in in $(find . -name Makefile.in -print); do
                  substituteInPlace $makefile_in --replace /bin/pwd pwd
                done
              ''

              # Make native compilation work both inside and outside of nix build
              (
                let
                  backendPath = (lib.concatStringsSep " "
                    (builtins.map (x: ''\"-B${x}\"'') [
                      # Paths necessary so the JIT compiler finds its libraries:
                      "${lib.getLib libgccjit}/lib"
                      "${lib.getLib libgccjit}/lib/gcc"
                      "${lib.getLib stdenv.cc.libc}/lib"

                      # Executable paths necessary for compilation (ld, as):
                      "${lib.getBin stdenv.cc.cc}/bin"
                      "${lib.getBin stdenv.cc.bintools}/bin"
                      "${lib.getBin stdenv.cc.bintools.bintools}/bin"
                    ]));
                in
                ''
                  substituteInPlace lisp/emacs-lisp/comp.el --replace \
                    "(defcustom native-comp-driver-options nil" \
                    "(defcustom native-comp-driver-options '(${backendPath})"
                ''
              )
              ""
            ];

            nativeBuildInputs = [ pkg-config makeWrapper autoreconfHook texinfo ];

            buildInputs = [
              ncurses
              gnome2.GConf
              libxml2
              gnutls
              alsa-lib
              acl
              gpm
              gettext
              jansson
              harfbuzz.dev
              dbus
              libselinux
              systemd
              xlibsWrapper
              xorg.libXaw
              Xaw3d
              xorg.libXpm
              libpng
              libjpeg
              giflib
              libtiff
              xorg.libXft
              cairo
              librsvg
              imagemagick
              m17n_lib
              libotf
              gtk3-x11
              gsettings-desktop-schemas
              libgccjit
            ];

            hardeningDisable = [ "format" ];

            configureFlags = [
              "--disable-build-details" # for a (more) reproducible build
              "--with-modules"
              "--with-native-compilation"
              "--with-imagemagick"
              "--with-pgtk"
            ];
            installTargets = [ "tags" "install" ];

            postInstall = ''
              mkdir -p $out/share/emacs/site-lisp
              cp ${./site-start.el} $out/share/emacs/site-lisp/site-start.el

              $out/bin/emacs --batch -f batch-byte-compile $out/share/emacs/site-lisp/site-start.el

              siteVersionDir=`ls $out/share/emacs | grep -v site-lisp | head -n 1`

              rm -r $out/share/emacs/$siteVersionDir/site-lisp
              for srcdir in src lisp lwlib ; do
                dstdir=$out/share/emacs/$siteVersionDir/$srcdir
                mkdir -p $dstdir
                find $srcdir -name "*.[chm]" -exec cp {} $dstdir \;
                cp $srcdir/TAGS $dstdir
                echo '((nil . ((tags-file-name . "TAGS"))))' > $dstdir/.dir-locals.el
              done

              echo "Generating native-compiled trampolines..."
              # precompile trampolines in parallel, but avoid spawning one process per trampoline.
              # 1000 is a rough lower bound on the number of trampolines compiled.
              $out/bin/emacs --batch --eval "(mapatoms (lambda (s) \
                (when (subr-primitive-p (symbol-function s)) (print s))))" \
                | xargs -n $((1000/NIX_BUILD_CORES + 1)) -P $NIX_BUILD_CORES \
                  $out/bin/emacs --batch -l comp --eval "(while argv \
                    (comp-trampoline-compile (intern (pop argv))))"
              mkdir -p $out/share/emacs/native-lisp
              $out/bin/emacs --batch \
                --eval "(add-to-list 'native-comp-eln-load-path \"$out/share/emacs/native-lisp\")" \
                -f batch-native-compile $out/share/emacs/site-lisp/site-start.el
            '';
          };
        });
}
