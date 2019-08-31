{ nixpkgs ? <nixpkgs>
, eris ? builtins.fetchGit ./.
, officialRelease ? false
}:

with builtins;
with import nixpkgs {};

let
  versionInfo = lib.splitString "\n" (lib.fileContents ./.version);
  basever = elemAt versionInfo 0;
  relname = elemAt versionInfo 1;

  vsuffix = lib.optionalString (!officialRelease)
    "pre${toString eris.revCount}_${eris.shortRev}";
  version = "${basever}${vsuffix}";
in
stdenv.mkDerivation rec {
  pname = "eris";
  inherit version relname;

  src = lib.cleanSource ./.;

  buildInputs =
    [ perl nix nix.perl-bindings glibcLocales
    ] ++ (with perlPackages;
    [ Mojolicious MojoliciousPluginStatus IOSocketSSL
      DBI DBDSQLite
    ]);

  outputs = [ "out" "man" ];

  unpackPhase = ":";
  installPhase = with perlPackages; ''
    mkdir -p \
      $out/bin $out/libexec $out/lib/systemd/system \
      $man/share/man/man8/

    # Install the man page
    substitute ${./eris.8.pod.in} ./eris.8.pod \
      --subst-var-by VERSION "${version}"
    pod2man \
      --section=8 \
      --name="ERIS" \
      --center="Eris User Manual" \
      ./eris.8.pod > $man/share/man/man8/eris.8

    # Install the systemd files
    substitute ${./conf/eris.service.in} $out/lib/systemd/system/eris.service \
      --subst-var-by NIXOUT "$out"

    # Strip the nix-shell shebang lines out of the main script
    grep -v '#!.*nix-shell' ${./eris.pl} > $out/libexec/eris.pl

    # Set up accurate version information, xz utils
    substituteInPlace $out/libexec/eris.pl \
      --replace '"0xERISVERSION"' '"${version}"' \
      --replace '"0xERISRELNAME"' '"${relname}"' \
      --replace '"xz"'        '"${xz.bin}/bin/xz"' \
      --replace '"bzip2"'     '"${bzip2.bin}/bin/bzip2"'

    # Create the binary and set permissions
    touch $out/bin/eris
    chmod +x $out/bin/eris

    # Wrapper that properly sets PERL5LIB
    cat > $out/bin/eris <<EOF
    #! ${stdenv.shell}
    set -e

    PERL5LIB=$PERL5LIB \
    LOCALE_ARCHIVE=$LOCALE_ARCHIVE \
    LIBEV_FLAGS="\''${LIBEV_FLAGS:-12}" \
      exec ${Mojolicious}/bin/hypnotoad $out/libexec/eris.pl "\$@"
    EOF
  '';

  meta = with stdenv.lib; {
    description = "A binary cache server for Nix";
    homepage    = https://github.com/thoughtpolice/eris;
    license     = licenses.gpl3Plus;
    platforms   = platforms.linux;
    maintainers = [ maintainers.thoughtpolice ];
  };
}
