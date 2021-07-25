{ stdenv
, lib
, perl
, nix
, glibcLocales
, Mojolicious
, MojoliciousPluginStatus
, IOSocketSSL
, DBI
, DBDSQLite
, xz
, bzip2
}:

stdenv.mkDerivation rec {
  pname = "eris";
  version = "0.1";

  src = lib.cleanSource ./.;

  buildInputs = [
    perl nix nix.perl-bindings glibcLocales
    Mojolicious MojoliciousPluginStatus IOSocketSSL
    DBI DBDSQLite
  ];

  outputs = [ "out" "man" ];

  unpackPhase = ":";
  installPhase = ''
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
      --replace '"0xERISRELNAME"' '"Developer edition"' \
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

  meta = with lib; {
    description = "A binary cache server for Nix";
    homepage    = "https://github.com/thoughtpolice/eris";
    license     = licenses.gpl3Plus;
    platforms   = platforms.linux;
    maintainers = [ maintainers.thoughtpolice ];
  };
}
