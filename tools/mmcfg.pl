#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Nigel Shearman
# ---------------------------------------------------------------------------
# mmcfg.pl - read / modify a MiSTer Minimig config file (config/minimig*.cfg)
#
# The file is a raw dump of Main_MiSTer's `mm_configTYPE`
# (support/minimig/minimig_config.h). Layout of the parts we touch:
#
#   off 0    char           id[8]        = "MNMGCFG0"
#   off 8    uint16 (LE)    version
#   off 10   uint16 (LE)    ext_cfg2     <- OSD O[48..63]  (bit n = O[48+n])
#   off 12   char           kickstart[992]
#   off 1004 char           label[32]
#   off 1036 uint16 (LE)    ext_cfg      <- OSD O[32..47]  (bit n = O[32+n])
#   ...
#
# Minimig routes O[0..31] as always-0 and O[32..63] as ext_cfg / ext_cfg2
# (minimig_set_extcfg). Any ext_cfg bit auto-persists across Save/Load config.
#
# Examples:
#   mmcfg.pl --show minimig.cfg
#   mmcfg.pl --o 57 --set  minimig.cfg          # enable A4091 (O[57])
#   mmcfg.pl --o 58 --clear minimig.cfg         # disable PiStorm (O[58])
#   mmcfg.pl --o 57 --set --out new.cfg minimig.cfg
#   mmcfg.pl --a4091 minimig.cfg                # shorthand for --o 57 --set
# ---------------------------------------------------------------------------
use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case bundling);

my $ID       = "MNMGCFG0";
my $OFF_EC2  = 10;      # ext_cfg2  (O[48..63])
my $OFF_EC1  = 1036;    # ext_cfg   (O[32..47])

my ($show, $set, $clear, $a4091, $o, $out, $nobak, $help);
GetOptions(
    "show|s"      => \$show,
    "set"         => \$set,
    "clear|c"     => \$clear,
    "a4091"       => \$a4091,
    "o|O=i"       => \$o,
    "out=s"       => \$out,
    "no-backup"   => \$nobak,
    "help|h"      => \$help,
) or usage();
usage() if $help;

my $file = shift or usage("no config file given");
$a4091 and do { $o = 57; $set = 1 };

open(my $fh, "<:raw", $file) or die "open $file: $!\n";
local $/;
my $buf = <$fh>;
close $fh;

die "not a Minimig config (bad id): $file\n"
    unless substr($buf, 0, 8) eq $ID;
die "config too short (", length($buf), " bytes)\n"
    if length($buf) < $OFF_EC1 + 2;

my $ec1 = unpack("v", substr($buf, $OFF_EC1, 2));
my $ec2 = unpack("v", substr($buf, $OFF_EC2, 2));

if ($show || !defined $o) {
    printf "%-18s %s\n", "file:", $file;
    printf "%-18s %d bytes\n", "size:", length($buf);
    printf "%-18s 0x%04x\n", "version:", unpack("v", substr($buf, 8, 2));
    printf "%-18s 0x%04x   %s\n", "ext_cfg  O[32..47]:", $ec1, bits(32, $ec1);
    printf "%-18s 0x%04x   %s\n", "ext_cfg2 O[48..63]:", $ec2, bits(48, $ec2);
    printf "%-18s %s\n", "  O[57] A4091:",   ($ec2 & (1 << 9))  ? "ON" : "off";
    printf "%-18s %s\n", "  O[58] PiStorm:", ($ec2 & (1 << 10)) ? "ON" : "off";
    exit 0 unless defined $o;
}

die "--o must be 32..63\n" if $o < 32 || $o > 63;
die "give exactly one of --set / --clear (or --a4091)\n"
    if ($set && $clear) || (!$set && !$clear);

my ($off, $word, $bit, $name) = $o >= 48
    ? ($OFF_EC2, $ec2, $o - 48, "ext_cfg2")
    : ($OFF_EC1, $ec1, $o - 32, "ext_cfg");

my $old = $word;
$word = $set ? ($word |  (1 << $bit))
             : ($word & ~(1 << $bit));

if ($word == $old) {
    printf "O[%d] already %s in %s (0x%04x) - no change\n",
        $o, ($set ? "set" : "clear"), $name, $old;
    exit 0;
}

substr($buf, $off, 2) = pack("v", $word);

my $dst = $out // $file;
if (!$out && !$nobak) {
    my $bak = "$file.bak";
    open(my $b, ">:raw", $bak) or die "backup $bak: $!\n";
    print $b $_ for slurp($file);
    close $b;
    print "backup -> $bak\n";
}
open(my $w, ">:raw", $dst) or die "write $dst: $!\n";
print $w $buf;
close $w;

printf "O[%d]: %s bit %d in %s  0x%04x -> 0x%04x   wrote %s\n",
    $o, ($set ? "set" : "clear"), $bit, $name, $old, $word, $dst;

# --------------------------------------------------------------------------
sub bits {
    my ($base, $w) = @_;
    my @on = map { "O[" . ($base + $_) . "]" } grep { $w & (1 << $_) } 0 .. 15;
    @on ? join(" ", @on) : "-";
}
sub slurp { open(my $f, "<:raw", $_[0]) or die $!; local $/; my $d = <$f>; close $f; $d }
sub usage {
    my $msg = shift;
    print STDERR "error: $msg\n\n" if $msg;
    print STDERR <<'EOF';
usage: mmcfg.pl [options] <minimig.cfg>

  -s, --show          print id / version / ext_cfg / ext_cfg2 and exit
      --o N            target OSD bit O[N], N = 32..63
      --set            set the bit
  -c, --clear          clear the bit
      --a4091          shorthand: --o 57 --set  (enable the A4091 board)
      --out FILE       write to FILE instead of in-place
      --no-backup      do not write <file>.bak (in-place edits only)
  -h, --help
EOF
    exit($msg ? 2 : 0);
}
