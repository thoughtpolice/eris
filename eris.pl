#! /usr/bin/env nix-shell
#! nix-shell -i hypnotoad -p perl nix nix.perl-bindings glibcLocales perlPackages.Mojolicious perlPackages.MojoliciousPluginStatus perlPackages.IOSocketSSL perlPackages.DBI perlPackages.DBDSQLite

# Eris: simple, flexible nix binary cache server
# Copyright (C) 2018-2019 Austin Seipp
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
use Scalar::Util qw(looks_like_number);
use Cwd qw(getcwd);
use MIME::Base64;
use List::Util;

use Mojolicious::Lite -signatures;
use Mojo::IOLoop;

use Nix::Config;
use Nix::Manifest;
use Nix::Store;
use Nix::Utils qw(readFile);

## -----------------------------------------------------------------------------
## -- Basics

# Note: replaced by the build script for nix builds
our $VERSION  = "0xERISVERSION";
our $RELNAME  = "0xERISRELNAME";
our $XZEXE    = "xz";
our $BZ2EXE   = "bzip2";

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

    # Index page enabled by default
    index_page => 1,

    # Default cache priority: higher than cache.nixos.org
    priority => 30,

    # No default upstream.
    upstream => '',
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
  "Eris $Eris::VERSION ($Eris::RELNAME), ".
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

# Proxy, status page, index page info
app->log->info(
  "priority: " . app->config->{priority} . ", " .
  "status page: " . (app->config->{status} == 1 ? "yes" : "no") . ", " .
  "index page: " . (app->config->{index_page} == 1 ? "yes" : "no") . ", " .
  "proxy headers: "  . (app->config->{proxy} == 1 ? "yes" : "no")
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
  $sign_sk = readFile app->config->{signing}->{private};
  chomp $sign_sk; # readFile doesn't do this itself

  my $sign_sk64   = +(split /:/, $sign_sk)[-1];
  my $sign_skno64 = decode_base64($sign_sk64);

  if (length($sign_skno64) != 64) {
    app->log->error("invalid signing key provided! signing disabled");
    $sign_host = undef;
    $sign_sk = undef;
  } else {
    # An ed25519 secret key contains the public key as well. It's the botton 32
    # bytes of the whole 64 byte key. Compute that.
    my $sign_pk64 = encode_base64(substr($sign_skno64, 32));
    chomp $sign_pk64; # beware encode_base64() newline!

    # Attach the user-configured signing hostname to this key, regardless of what
    # was in the file in the first place. `nix-store --generate-binary-cache-key`
    # will write a user-chosen name at creation time, but the user here would
    # (rightfully) expect the served hostname to match what they put in the
    # config file.
    $sign_sk = $sign_host . ":" . $sign_sk64;
    $sign_pk = $sign_host . ":" . $sign_pk64;

    app->log->info("signing: enabled, key = $sign_host:$sign_pk64");
  }
} else {
  app->log->info("signing: no signatures enabled")
}

# --
# -- upstream/proxy information
# --

# Upstream information
my $upstream = Mojo::URL->new(app->config->{upstream});
my $resign_upstream_narinfos = 0;
my $resigning_unsafe = 0;
my $resign_pubkey = undef;
my $resign_keyname = undef;
my $resign_key64 = undef;
my $always_use_upstream = 0;

# ensure the upstream host has a valid nix-cache-info
my $upstream_host_valid = 0;
if (defined($upstream->host)) {
  app->log->info("upstream host configured, attempting nix-cache-info ping...");

  my $ua = new Mojo::UserAgent->new;
  $ua->transactor->name("Eris/$Eris::VERSION");
  my $url = Mojo::URL->new('nix-cache-info')->to_abs($upstream);
  my $body = $ua->get($url)->result->body;

  my ($upstreamStoreDir) = $body =~ /StoreDir: (.*)/;
  if ($upstreamStoreDir eq $Nix::Config::storeDir) {
    app->log->info("OK: upstream has StoreDir=$upstreamStoreDir");
    $upstream_host_valid = 1;
  } else {
    app->log->error("FAIL: upstream has StoreDir=$upstreamStoreDir, incompatible with $Nix::Config::storeDir!");
    app->log->error("marking upstream as invalid");
  }
}

# if the upstream is ok, then figure out the upstream/resigning logic
if ($upstream_host_valid) {
  $always_use_upstream = 1 if $upstream->query->param('always');
  $resign_upstream_narinfos = 1 if $upstream->query->param('resign');

  # disable resigning in specific cases
  if (!defined($sign_sk) && $resign_upstream_narinfos) {
    app->log->warn("resigning configured for '".$upstream->host."', but no signing key set! disabling");
    $resign_upstream_narinfos = 0;
  }

  $resign_pubkey = $upstream->query->param('public_key');
  if ($resign_upstream_narinfos) {
    if (!$resign_pubkey) {
      if (!$upstream->query->param('resign_unsafe')) {
        app->log->warn("resigning configured for '".$upstream->host."', but no public key set!");
        app->log->warn("this is HIGHLY UNSAFE, so disabling. set 'resign_unsafe=1' to bypass!");
        $resign_upstream_narinfos = 0;
      } else {
        app->log->warn("resigning configured for '".$upstream->host."', but no public key set, and unsafe mode enabled!");
        app->log->warn("THIS IS HIGHLY UNSAFE! YOU SHOULD CONFIGURE AN UPSTREAM PUBLIC KEY");
        $resigning_unsafe = 1;
      }
    } else {
      # We use the key name later on to do a lookup
      ($resign_keyname, $resign_key64) = +(split /:/, $resign_pubkey);
    }
  }

  # unset the parameters
  $upstream->query(always => undef);
  $upstream->query(resign => undef);
  $upstream->query(resign_unsafe => undef);
  $upstream->query(public_key => undef);

  # dump debugging info
  if ($always_use_upstream) {
    app->log->info("upstream: yes, always using " . $upstream . " (proxy mode)");
  } else {
    app->log->info("upstream: yes, using " . $upstream . " on miss");
  }

  if ($resign_upstream_narinfos) {
    app->log->info("upstream: re-signing narinfos with key '".$sign_host."'");
    unless ($resigning_unsafe) {
      app->log->info("upstream: validating with public key '".$resign_pubkey."'");
    }
  }

} else {
  app->log->info("upstream: no, only serving given cache");
}

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
## -- Eris API routes: basic cache info

die "Priority setting must be a number!"
  unless looks_like_number(app->config->{priority});

# Cache info handler
get '/nix-cache-info' => {
  text => join "\n", (
    "StoreDir: $Nix::Config::storeDir",
    "WantMassQuery: 1",
    "Priority: " . app->config->{priority},
    "",
  ),
};

## -----------------------------------------------------------------------------
## -- Fetching upstream objects

helper parse_narinfo => sub ($c, $body) {
  my $hash = {};

  $hash->{References} = [ ];
  $hash->{Sig} = [ ];

  while ($body =~ /(.*): (.*)/g) {
    if ($1 eq 'References') {
      push @{ $hash->{References} }, (split /\s/, $2);
    }
    elsif ($1 eq 'Sig') {
      push @{ $hash->{Sig} }, $2;
    }
    elsif ($1 eq 'NarSize' || $1 eq 'FileSize') {
      # contextualize narinfo value as an int
      $hash->{"$1"} = ($2 + 0);
    }
    else {
      $hash->{"$1"} = $2;
    }
  }

  # we need to do two things: first, fingerprintPath expects an array ref
  # instead of a direct array for the references, so we need to wrap the whole
  # thing with [ ... ] and put it in a scalar. second, narinfos must serve
  # 'References:' entries WITHOUT the store path attached, but fingerprintPath
  # REQUIRES the store path is prefixed. so: split into an array, add the
  # store path prefix, and return a ref.
  $hash->{References} = [ map { "$Nix::Config::storeDir/$_" } @{ $hash->{References} } ];

  return $hash;
};

my $our_user = new Mojo::UserAgent->new;
$our_user->transactor->name("Eris/$Eris::VERSION");
$our_user->max_response_size(0); # infinite download size for upstreams

# Helper routine that fetches objects from an upstream server, if it's
# configured. This automatically figures out the right path to serve. If
# resigning for upstream caches is enabled, then we enter an alternative path
# for .narinfo files that appends our own signature to the response.
helper fetch_upstream => sub ($c, $ctype, $info=undef) {
  my $path = $c->req->url;
  my $prefix = defined($info) ? "$info: " : '';
  app->log->debug($prefix.'fetching upstream object '.$path);

  my $upstream_url = Mojo::URL->new($path);
  $upstream_url->query('');
  $upstream_url = $upstream_url->to_abs($upstream);

  my $tx = $our_user->build_tx(GET => $upstream_url => {
    Accept => $ctype,
  });

  # if we're not serving narinfos, then just proxy the object
  unless ($c->stash('format') eq 'narinfo') {
    $tx->res->content->once(body => sub ($stx) {
      $c->res->headers->content_type('application/x-nix-archive');
      $c->res->headers->content_length($tx->res->headers->content_length);
      $c->write;

      $tx->res->content->unsubscribe('read')->on(read => sub ($s, $bytes) {
        $c->write($bytes);
      });
    });

    return $our_user->start($tx);
  }

  # otherwise, fetch the whole narinfo
  app->log->debug("fetching upstream narinfo");
  return $our_user->start_p($tx)->then(sub ($mtx) {
    # exit immediately for non-200 resps
    if ($mtx->result->code != 200) {
      app->log->debug("non-200 return for narinfo, no resign");
      return $c->render(
        format => 'txt',
        text   => $mtx->result->text,
        status => $mtx->result->code,
      );
    }

    my $body = $mtx->result->body;
    chomp $body;

    my $narinfo = $c->parse_narinfo($body);
    my $signature = undef;

    if ($resign_upstream_narinfos) {
      app->log->debug("attempting to resign with key for '$sign_host'");

      # NB: references can be empty, so don't bail if they are. but everything
      # else is mandatory
      if (!defined($narinfo->{StorePath}) ||
          !defined($narinfo->{NarHash}) ||
          !defined($narinfo->{NarSize})) {
        app->log->error("could not parse narinfo for valid signature!");
        return $c->render(format => 'txt', text => '404', status => 404);
      }

      my $fp = fingerprintPath(
        $narinfo->{StorePath},
        $narinfo->{NarHash},
        $narinfo->{NarSize},
        $narinfo->{References}
      );

      unless ($resigning_unsafe) {
        # check upstream fingerprint validity
        my $sig64 = (grep /$resign_keyname:/, @{ $narinfo->{Sig} })[0];
        $sig64 = +(split /:/, $sig64)[-1];

        if (!$sig64) {
          app->log->error("could not find signature for $resign_keyname on upstream narinfo!");
          return $c->render(format => 'txt', text => '404', status => 404);
        }

        app->log->debug("attempting to validate signature '$resign_keyname:$sig64' for '$path'...");
        if (!checkSignature(decode_base64($resign_key64), decode_base64($sig64), $fp)) {
          app->log->error("invalid signature '$resign_keyname:$sig64' for '$path'!");
          return $c->render(format => 'txt', text => '404', status => 404);
        }

        app->log->debug("valid signature for $resign_keyname on upstream path $path");
      }

      # sign, finish
      $signature = signString($sign_sk, $fp);
    }

    if ($c->param('json')) {
      push @{ $narinfo->{Sig} }, $signature
        if defined($signature);

      return $c->render(json => $narinfo);
    } else {
      $body .= "\nSig: $signature\n"
        if defined($signature);

      $c->res->headers->content_length(length($body));
      return $c->render(format => 'narinfo', text => $body);
    }
  });
};

# Helper routine that handles misses for local objects, if an upstream is
# defined for the current configuration. If not, a 404 is returned.
helper handle_miss => sub ($c, $ctype) {
  return $c->render(format => 'txt', text => "404", status => 404)
    if (!defined($upstream->host));

  return $c->fetch_upstream($ctype, 'local miss');
};

# Helper routine that simply pulls out the hash parameter from the query and
# returns the path of that object in the store; accessible via $c->nixhash;
helper nixhash => sub ($c) {
  my $hash = $c->param('hash');

  if (length $hash != 32) {
    # If the hash we get asked about isn't 32 bytes (160 bits) then we need to
    # go ahead and treat it as invalid, possibly to be forwarded to an upstream
    # server. Why? Because the local-store.cc implementation inside Nix will
    # treat this hash as invalid if it isn't this exact length. The reason this
    # would be the case is because an upstream .narinfo, served e.g. by
    # cache.nixos.org, may use a hash value that is bigger than 32 bytes. The
    # actual length of the hash doesn't matter in general for substituter logic
    # to work, because it just follows the URLs in the narinfo -- it's just that
    # queryPathFromHashPart actually requires this for local queries in its API.
    return ($hash, undef);
  }

  my $storePath = queryPathFromHashPart($hash);
  return ($hash, $storePath);
};

## -----------------------------------------------------------------------------
## -- .narinfo handler

helper format_narinfo_txt => sub ($c, $hash, $storePath) {
  my ($drv, $narhash, $time, $size, $refs) = queryPathInfo($storePath, 1);

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

  # Include a signature, if configured
  if (defined $sign_sk) {
    my $fp  = fingerprintPath($storePath, $narhash, $size, $refs);
    my $sig = signString($sign_sk, $fp);
    push @res, "Sig: $sig";
  }

  push @res, ""; # extra newline, so CURL/etc look nice
  my $narinfo = join "\n", @res;

  return $narinfo;
};

helper render_narinfo_json => sub ($c, $hash, $storePath) {
  my ($drv, $narhash, $time, $size, $refs) = queryPathInfo($storePath, 1);

  my $obj = {
    StorePath => $storePath,
    URL => "nar/$hash.nar",
    Compression => "none",
    NarHash => $narhash,
    NarSize => $size,
  };

  # Needed paths that this NAR references
  $obj->{References} = [ map { basename $_ } @$refs ]
    if scalar @$refs > 0;

  # Derivation and system information
  if (defined $drv) {
    $obj->{Deriver} = basename $drv;

    # Add system information, if the .drv exists for this .nar
    if (isValidPath($drv)) {
      my $drvpath = derivationFromPath($drv);
      $obj->{System} = $drvpath->{platform};
    }
  }

  # Include a signature, if configured
  if (defined $sign_sk) {
    my $fp  = fingerprintPath($storePath, $narhash, $size, $refs);
    my $sig = signString($sign_sk, $fp);
    $obj->{Sig} = [ $sig ];
  }

  return $c->render(json => $obj);
};

# Main .narinfo handler logic.
get '/:hash' => [ format => [ 'narinfo' ] ] => sub ($c) {
  # Always fetch upstream results if asked. Otherwise, query the store, and
  # optionally pass thru to an upstream if that fails.
  return $c->fetch_upstream('text/x-nix-narinfo') if $always_use_upstream;
  my ($hash, $storePath) = $c->nixhash;
  return $c->handle_miss('text/x-nix-narinfo') unless $storePath;

  # query

  if ($c->param('json')) {
    app->log->debug("path query: $storePath (json = YES)");
    return $c->render_narinfo_json($hash, $storePath);
  } else {
    app->log->debug("path query: $storePath (json = NO)");

    my $narinfo = $c->format_narinfo($hash, $storePath);
    $c->res->headers->content_length(length($narinfo));
    return $c->render(format => 'narinfo', text => $narinfo);
  }
};

## -----------------------------------------------------------------------------
## -- Handlers for .nar objects, both compressed and uncompressed

group {
  # All .nar requests happen under the /nar handler URL
  under '/nar';

  # This is the primary helper function for the NAR endpoint, which can stream
  # for multiple different endpoints, though for now it's fairly single-purpose.
  helper stream_nar => sub ($c) {
    # Always fetch upstream results if asked. Otherwise, query the store, and
    # optionally pass thru to an upstream if that fails.
    return $c->fetch_upstream('application/x-nix-nar') if $always_use_upstream;
    my ($hash, $storePath) = $c->nixhash;
    return $c->handle_miss('application/x-nix-nar') unless $storePath;

    # Set the Content-Length for tools like curl, etc
    my ($drv, $narhash, $time, $size, $refs) = queryPathInfo($storePath, 1);
    $c->res->headers->content_length($size);

    # And content-type, too
    $c->res->headers->content_type('application/x-nix-archive');

    # get the right command. we don't advertise .nar.xz or .nar.bz2 ourselves, but
    # the upstream narinfos might, and for compatibility we offer them here.
    my $dump_cmd = "nix-store --dump '$storePath'";
    if ($c->stash('format') eq 'nar.xz') {
      $dump_cmd .= "|$XZEXE --fast";
    } elsif ($c->stash('format') eq 'nar.bz2') {
      $dump_cmd .= "|$BZ2EXE --fast";
    }

    app->log->debug("streaming ".$c->stash('format').": $storePath");

    # dump and optionally exit on 503, so error codes can be distinguished
    my $pid = open my $fh, '-|', $dump_cmd;
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
  get '/:hash' => [ format => [ 'nar', 'nar.xz', 'nar.bz2' ] ] => sub ($c) {
    return $c->stream_nar();
  };
};

## -----------------------------------------------------------------------------
## -- Index page handler

get '/version.js' => sub ($c) {
  $c->stash(priority => app->config->{priority});
  $c->render(template => 'version', format => 'js');
} if app->config->{index_page} == 1;

get '/' => sub ($c) {
  $c->stash(sign_pk => $sign_pk);
  $c->render(template => 'index');
} if app->config->{index_page} == 1;

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

__DATA__
@@ index.html.ep
% my $url = url_for;
<!DOCTYPE html>
<html lang="en">

<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
  <title>Nix binary cache (Eris <%= $Eris::VERSION %>)</title>
  <link rel="stylesheet" href="https://stackpath.bootstrapcdn.com/bootstrap/4.3.1/css/bootstrap.min.css"
    integrity="sha384-ggOyR0iXCbMQv3Xipma34MD+dH/1fQ784/j6cY/iJTQUOhcWr7x9JvoRxT2MZw1T" crossorigin="anonymous">
  <style>
    body {
      padding-top: 60px;
      padding-bottom: 60px;
    }
  </style>
  <script src="version.js"></script>
</head>

<body>
  <div class="container">
    <div class="row justify-content-md-center">
      <div class="col-md-auto">
        <p class="lead">
          This service, <code><%= $url->to_abs %></code>, provides a "binary
          cache" for the <a href="https://nixos.org/nix/">Nix package
          manager</a>. It is used to automatically speed up builds.
        </p>
      </div>
    </div>
    <hr>
    <div class="row">
      <div class="col text-center">
        <h5>Usage</h5>

        <p>Using <code>/etc/nix/nix.conf</code>:</p>
        % if (defined($sign_pk)) {
          <pre><code>substituters = <%= $url->to_abs %>
trusted-public-keys = <%= $sign_pk %></code></pre>
        % } else {
          <pre><code>substituters = <%= $url->to_abs %></code></pre>
        % }

        <p>Using <code>/etc/nixos/configuration.nix</code>:</p>
        % if (defined($sign_pk)) {
          <pre><code>nix.binaryCaches = [ "<%= $url->to_abs %>" ];
nix.binaryCachePublicKeys = [ "<%= $sign_pk %>" ];</code></pre>
        % } else {
          <pre><code>nix.binaryCaches = [ "<%= $url->to_abs %>" ];</code></pre>
        % }

        <p>Using <code>nix</code>, <code>nix-build</code>, etc:</p>
        % if (defined($sign_pk)) {
          <pre><code>nix build \\
--option substituters '<%= $url->to_abs %>' \\
--option trusted-public-keys '<%= $sign_pk %>' \\
...</code></pre>
        % } else {
          <pre><code>nix build --substituters '<%= $url->to_abs %>' ...</code></pre>
        % }
      </div>
    </div>
    <hr>
    <div class="row">
      <div class="col text-center">
        <small class="d-block mb-3 text-muted">Powered by <a
        href="https://github.com/thoughtpolice/eris">Eris</a>. <a
        href="javascript:;" onclick="showVersionClick()">&pi;</a> <span
        id="versioninfo"></span></small>
        % if (app->config->{status} == 1) {
          <small class="d-block mb-3 text-muted">View <a href="<%=
          url_for('mojo-status')->to_abs %>">server status</a>. </small>
        % }
      </div>
    </div>
  </div>
</body>

</html>

@@ version.js.ep
let versionInfo = "<%= $Eris::VERSION %>. Cache priority: <%= $priority %>";
let versionDisplayed = false;

function showVersionClick() {
  if (!versionDisplayed) {
    versionDisplayed = true;
    document.getElementById('versioninfo')
      .insertAdjacentHTML('afterbegin', versionInfo)
  }
}
