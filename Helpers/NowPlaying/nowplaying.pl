#!/usr/bin/perl
# Loads libnowplaying.dylib into Apple's /usr/bin/perl, which macOS allows to read now-playing information.
# Usage: /usr/bin/perl nowplaying.pl /path/to/libnowplaying.dylib
use strict;
use warnings;
require DynaLoader;

my $path = shift @ARGV or die "usage: nowplaying.pl <dylib>\n";
my $lib = DynaLoader::dl_load_file($path, 0) or die DynaLoader::dl_error();
my $symbol = DynaLoader::dl_find_symbol($lib, "macdeck_nowplaying_run") or die "symbol not found\n";
DynaLoader::dl_install_xsub("main::run", $symbol);
run();
