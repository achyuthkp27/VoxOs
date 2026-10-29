#!/usr/bin/perl
# VoxOS's Now Playing helper. macOS answers MediaRemote's queue only to processes Apple signed, and
# /usr/bin/perl is one, so VoxOS runs this script in it and the script calls into VoxOSNowPlaying's
# library: now-playing.pl <library> <queue|play-item>. Options come in the environment; the answer
# is one line of JSON on standard output.
use strict;
use warnings;
use DynaLoader;

my ($library, $command) = @ARGV;
die "usage: now-playing.pl <library> <queue|play-item>\n" unless defined $command;

my %functions = (
    'queue'     => 'voxos_now_playing_queue',
    'play-item' => 'voxos_now_playing_play_item',
);
my $function = $functions{$command} or die "unknown command: $command\n";

my $handle = DynaLoader::dl_load_file($library, 0) or die "cannot load $library: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, $function) || DynaLoader::dl_find_symbol($handle, "_$function")
    or die "missing $function: " . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub('main::run', $symbol);
run();
