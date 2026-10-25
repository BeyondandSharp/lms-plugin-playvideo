#!/usr/bin/env perl

# Reader for squeezelite's raw stdout output ("-o -").  It consumes the
# interleaved PCM at (roughly) real time so that LMS/player playback time
# advances instead of finishing instantly like the ALSA "null" device does.
#
# Usage: squeezelite ... -o - -a 16 | pace-audio.pl [--rate 44100] [--channels 2] [--bytes 2]
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Time::HiRes qw(sleep time);

my %opt = (
	rate     => 44100,
	channels => 2,
	bytes    => 2,
	chunk    => 8192,
);

GetOptions(
	'rate=i'     => \$opt{rate},
	'channels=i' => \$opt{channels},
	'bytes=i'    => \$opt{bytes},
	'chunk=i'    => \$opt{chunk},
) or die "usage: $0 [--rate N] [--channels N] [--bytes N] [--chunk N]\n";

my $bytes_per_second = $opt{rate} * $opt{channels} * $opt{bytes};
die "invalid rate/channels/bytes\n" unless $bytes_per_second > 0;

my $delay_per_chunk = $opt{chunk} / $bytes_per_second;
my $deadline        = time;

binmode(STDIN);
binmode(STDOUT);

# read/discard in small chunks; the sleeping throttles squeezelite's stdout
# pipe, which in turn throttles its playback thread
while (1) {
	my $read = read(STDIN, my $buffer, $opt{chunk});
	last unless $read;

	$deadline += $read / $bytes_per_second;

	my $now = time;
	# if we are falling behind by more than a second, resync instead of
	# accumulating an ever growing backlog
	$deadline = $now if $deadline < $now - 1;

	my $sleep = $deadline - time;
	sleep($sleep) if $sleep > 0;
}

exit 0;
