#! /usr/bin/env nix-shell
#! nix-shell -i hypnotoad -p perl nix nix.perl-bindings glibcLocales perlPackages.Mojolicious perlPackages.MojoliciousPluginStatus perlPackages.IOSocketSSL perlPackages.DBI perlPackages.DBDSQLite

# Eris: simple, flexible nix binary cache server
# Copyright (C) 2018 Austin Seipp
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

package Eris;

## -----------------------------------------------------------------------------

use File::Basename qw(basename);

use Mojolicious::Lite -signatures;
use Mojo::IOLoop;

use Nix::Config;
use Nix::Manifest;
use Nix::Store;
use Nix::Utils qw(readFile);

use Cwd qw(getcwd);
use MIME::Base64;
use List::Util;

## -----------------------------------------------------------------------------
## -- Basics

# Note: replaced by the build script for nix builds
our $VERSION  = "0xDEADBEEF";
our $XZEXE    = "xz";

my $eris_conf_file = $ENV{ERIS_CONFIG};
$eris_conf_file ||= getcwd . '/eris.conf';

# Configuration values may be set through the Perl config file
plugin 'Config' => {
  file => $eris_conf_file,

  default => {
    # By default, access is unrestricted
    users => [],

    # By default, no signing keys are generated or used
    signing => 'none',

    # Default access is localhost only
    listen => [ 'http://127.0.0.1:8080' ],

    # Assumed to not be behind a proxy
    proxy => 0,

    # Defaults for workers and clients
    workers => 4,
    clients => 1000,

    # No status page by default
    status => 0,
  },
};

## -----------------------------------------------------------------------------
## -- Sanity checks

# It seems to be extremely important that HOME is set properly before any
# communication with the Nix daemon; this is because it uses a temporary
# location under $HOME/.cache or $XDG_CACHE_DIR for temporary storage in some
# operations, but it throws an exception /earlier than that/ if $HOME isn't set
# (regardless of whether it will be used or not), making the server throw
# unhandled 500 errors when functions like queryPathFromHashPart are called. In
# a strange twist of fate however, this also seems to be racy somehow -- I was
# able to successfully use the daemon *sometimes* if $HOME was unset, but not
# other times. But when you run with multiple workers, this basically leads to
# non-deterministic failure for clients (some worker processes may open
# successful connections, and others may not.) This probably doesn't impact
# nix-serve since it has a UID assigned in Nixpkgs, while Eris tries to use
# DynamicUser=true in systemd
#
# In the end, just die if we don't have $HOME set, since there's nothing we can
# do to stop this.
die "HOME is not set (nix-store requires this); immediately exiting!"
  unless defined($ENV{HOME});

## -----------------------------------------------------------------------------
## -- Custom Mojo Initialization

# Ensure Hypnotoad writes the .pid file into the CWD of the running app by
# default; otherwise, it tries to write it next to the script, but that fails
# because the script might be inside /nix/store. However, systemd also needs
# to track the right PID file for termination, so we allow it to be overridden
# in the environment (see module.nix)
my $pid_file = $ENV{ERIS_PID_FILE};
$pid_file ||= getcwd . "/eris.pid";

app->config(hypnotoad => {
  pid_file => $pid_file,

  # Make sure Hypnotoad listens on the specified addresses
  listen => app->config->{listen},

  # Configure proxy-mode for X-Forwarded-For, etc, if asked
  proxy => app->config->{proxy},

  # Workers, clients
  workers => app->config->{workers},
  clients => app->config->{clients},
});

# Add some custom content types we can use with 'render'
app->types->type(narinfo  => 'text/x-nix-narinfo');

## -----------------------------------------------------------------------------
## -- Global startup logic

# Output a nice startup message
my $mode = app->mode;
my $ev_mode = $ENV{LIBEV_FLAGS} || 1;

# The libev backend is chosen at startup time, long before we can control
# it here. Best to just tell the user what they chose.
#
# LIBEV_FLAGS is a mix of the bitwise flags from libev's API; in particular,
# there are 4 options:
#
#  - 1 (0b0001)  select(2)      everything
#  - 2 (0b0010)  poll(2)        everything
#  - 4 (0b0100)  epoll(2)       linux
#  - 8 (0b1000)  kqueue(2)      mac/bsd
#
# the default we set in the Nix package is 12, which is a mix of epoll and
# kqueue. these asynchronous interfaces are vital for real usage, so we set them
# by default.
my @ev_backends = ();
for ($ev_mode) {
  if ($_ & 0b1)    { push @ev_backends, "select" }
  if ($_ & 0b10)   { push @ev_backends, "poll" }
  if ($_ & 0b100)  { push @ev_backends, "epoll" }
  if ($_ & 0b1000) { push @ev_backends, "kqueue" }
}
my $libev_info = join "/", @ev_backends;

# Basics: version, mode settings, nix configuration
app->log->info(
  "Eris: version $Eris::VERSION, ".
  "mode = $mode (mojo $Mojolicious::VERSION)"
);
app->log->info(
  "libev: mode $ev_mode ($libev_info), ".
  "nix: ver $Nix::Config::version, ".
  "local store: $Nix::Config::storeDir"
);

# Config info
my $conf_info = (-e "$eris_conf_file")
    ? "using file '$eris_conf_file'"
    : "no config file, using default settings";
app->log->info("config: " . $conf_info);

# Proxy, status page info
app->log->info(
  "status page: " . (app->config->{status} == 1 ? "enabled" : "disabled") . ", " .
  "proxy mode: "  . (app->config->{proxy} == 1 ? "enabled" : "disabled")
);

# User info
{
  my $users    = app->config->{users};
  my $numusers = scalar @$users;
  my $authinfo = $numusers != 0
      ? "enabled, $numusers users"
      : "none (publicly available)";

  app->log->info("authentication: " . $authinfo);
}

# --
# -- Signing logic
# --

my ($sign_host, $sign_pk, $sign_sk) = (undef, undef, undef);

## Case 1: user-specified keys
if (ref(app->config->{signing}) eq 'HASH') {
  $sign_host = app->config->{signing}->{host};
  $sign_pk = readFile app->config->{signing}->{public};
  $sign_sk = readFile app->config->{signing}->{private};

  # readFile doesn't do this itself
  chomp $sign_pk; chomp $sign_sk;

  app->log->info("signing: user-specified, hostname = $sign_host");
}

## Case 2: no keys
app->log->info("signing: no signatures enabled")
  if (!defined($sign_sk));

## OK, done
app->log->info("public key: $sign_pk")
  if (defined($sign_pk));

## -----------------------------------------------------------------------------
## -- Warnings, further info

if ($ev_mode == 1) {
  # this is the only case where select(2) would be the only option
  app->log->warn("NOTE: using select(2) backend only! This will not scale well");
  app->log->warn("NOTE: try setting the environment variable LIBEV_FLAGS=15");
  app->log->warn("NOTE: see 'man eris' for more info");
}

## -----------------------------------------------------------------------------
## -- Global authentication logic

under sub {
  my $c = shift;
  my $users = app->config->{users};
  my $info = $c->req->url->to_abs->userinfo;

  # No authentication configured, so all attempts succeed
  return 1 if !@$users;

  # Attempted authentication
  if (defined($info)) {
    # Succeed if the user information in the HTTP header matches the list
    # of users specified in the config
    return 1 if List::Util::any { $_ eq $info } @$users;
  }

  # Otherwise (e.g. auth was wrong, no auth provided), throw up the http
  # authentication banner
  $c->res->headers->www_authenticate('Basic');
  $c->render(text => "Authentication required.\n", status => 401);
  return undef;
};

## -----------------------------------------------------------------------------
## -- Eris API routes: not used by Nix

# The following group defines all of the 'v1' API endpoints
group {
  under '/v1';

  # Version handler; probably useful one day!
  get '/version' => { text => "$Eris::VERSION\n" };

  # Public key handler; Nix won't use this, but it's useful for clients if they
  # quickly want to automatically fetch/import keys
  get '/public-key' => sub ($c) {
    return $c->render(format => 'txt', text => "No public key configured\n", status => 404)
        unless $sign_pk;

    $c->render(format => 'txt', text => "$sign_pk\n");
  };
};

## -----------------------------------------------------------------------------
## -- Eris API routes: these are Nix-required routes for an HTTP cache

# Cache info handler
get '/nix-cache-info' => {
  text => join "\n", (
    "StoreDir: $Nix::Config::storeDir",
    "WantMassQuery: 1",
    "Priority: 30",
    "",
  ),
};

# Helper routine that simply pulls out the hash parameter from
# the query and returns the path of that object in the store;
# accessible via $c->nixhash;
helper nixhash => sub ($c) {
  my $hash = $c->param('hash');
  my $storePath = queryPathFromHashPart($hash);
  return ($hash, $storePath);
};

## -----------------------------------------------------------------------------
## -- .narinfo handler

# Main .narinfo handler logic.
get '/:hash' => [ format => [ 'narinfo' ] ] => sub ($c) {
  $c->timing->begin('narinfo');

  # 404 when no hash is found
  my ($hash, $storePath) = $c->nixhash;
  return $c->render(format => 'txt', text => "No such path.\n", status => 404)
      unless $storePath;

  # query
  $c->timing->begin('nar_query');
  app->log->debug("path query: $storePath");
  my ($drv, $narhash, $time, $size, $refs) = queryPathInfo($storePath, 1);
  my $elapsed_query = $c->timing->elapsed('nar_query');
  $c->timing->server_timing('nar_query_time', "Path Query", $elapsed_query);

  $c->timing->begin('nar_info');
  my @res = (
    "StorePath: $storePath",
    "URL: nar/$hash.nar",
    "Compression: none",
    "NarHash: $narhash",
    "NarSize: $size",
  );

  # Needed paths that this NAR references
  push(@res, "References: " . join(" ", map { basename $_ } @$refs))
      if scalar @$refs > 0;

  # Derivation and system information
  if (defined $drv) {
    push(@res, "Deriver: " . basename $drv);

    # Add system information, if the .drv exists for this .nar
    if (isValidPath($drv)) {
      my $drvpath = derivationFromPath($drv);
      push(@res, "System: $drvpath->{platform}");
    }
  }
  my $elapsed_info = $c->timing->elapsed('nar_info');
  $c->timing->server_timing('nar_info_time', "Build information", $elapsed_info);

  # Include a signature, if configured
  if (defined $sign_sk) {
    $c->timing->begin('signing');

    my $fp  = fingerprintPath($storePath, $narhash, $size, $refs);
    my $sig = signString($sign_sk, $fp);
    push @res, "Sig: $sig";

    my $elapsed_sign = $c->timing->elapsed('signing');
    $c->timing->server_timing('signing', "Ed25519 signing", $elapsed_sign);
  }

  push @res, ""; # extra newline, so CURL/etc look nice
  my $narinfo = join "\n", @res;

  my $elapsed_total = $c->timing->elapsed('narinfo');
  my $rps = $c->timing->rps($elapsed_total);
  app->log->debug("Elapsed query time for $hash.narinfo: ${elapsed_total}s (~ $rps/s)");
  $c->timing->server_timing('total', "Total request time", $elapsed_total);

  $c->res->headers->content_length(length($narinfo));
  $c->render(format => 'narinfo', text => $narinfo);
};

## -----------------------------------------------------------------------------
## -- Handlers for .nar objects, both compressed and uncompressed

group {
  # All .nar requests happen under the /nar handler URL
  under '/nar';

  # This is the primary helper function for the NAR endpoint, which can stream
  # for multiple different endpoints, though for now it's fairly single-purpose.
  helper stream_nar => sub {
    my $c = shift;
    my ($hash, $storePath) = $c->nixhash;
    return $c->render(format => 'txt', text => "No such path.\n", status => 404)
        unless $storePath;

    # Set the Content-Length for tools like curl, etc
    app->log->debug("streaming nar: $storePath");
    my ($drv, $narhash, $time, $size, $refs) = queryPathInfo($storePath, 1);
    $c->res->headers->content_length($size);

    # And content-type, too
    $c->res->headers->content_type('application/x-nix-archive');

    # dump and optionally exit on 503, so error codes can be distinguished
    my $pid = open my $fh, '-|', "nix-store --dump '$storePath'";
    return $c->render(format => 'txt', text => 'nix-store --dump failed', status => 503)
        unless defined($pid);

    my $stream = Mojo::IOLoop::Stream->new($fh);
    my $sid = Mojo::IOLoop->stream($stream);
    $c->timing->begin('nar_stream');

    $stream->on(read => sub ($s, $bytes) {
      return $c->write_chunk($bytes);
    });

    # record timing info when the stream is finished and close the connection
    $stream->on(close => sub {
      my $elapsed = $c->timing->elapsed('nar_stream');
      my $rps     = $c->timing->rps($elapsed);
      app->log->debug("NAR streaming ($size bytes) took ${elapsed}s (~ $rps/s)");

      $c->timing->server_timing('nar_stream', $hash, $elapsed);
      return $c->finish;
    });

    # the pid and handle will be removed by the GC later
    $c->on(finish => sub {
      return Mojo::IOLoop->remove($sid);
    });
  };

  # Primary route handler for /nar/:hash.nar requests
  get '/:hash' => [ format => [ 'nar' ] ] => sub ($c) {
    return $c->stream_nar();
  };
};

## -----------------------------------------------------------------------------
## -- El fin

# Extra: Mojolicious Server Status UX, available at /mojo-status
plugin 'Status' if app->config->{status} == 1;

# Go-go gadget Mojo!
app->start;

# Local Variables:
# mode: perl
# fill-column: 80
# indent-tabs-mode: nil
# buffer-file-coding-system: utf-8-unix
# End:
