#!/usr/bin/perl

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# Generator for custom-convert.conf.
#
# The file is generated so that the (large) set of conversion profiles
# stays consistent.  Run this script from anywhere:
#
#     perl tools/gen-convert-conf.pl            # update in place
#     perl tools/gen-convert-conf.pl --stdout   # print to stdout
#
# The script only writes the file if its content changed, i.e. it is
# idempotent.  The test suite checks that the committed file matches the
# generator output.

use strict;
use warnings;

use File::Basename qw(dirname);
use File::Spec;
use FindBin qw($RealBin);

my $ROOT = File::Spec->rel2abs(dirname($RealBin));
my $OUTPUT = File::Spec->catfile($ROOT, 'custom-convert.conf');

my $STDOUT = (@ARGV && $ARGV[0] eq '--stdout');

# Prefix used by every profile.  $START$/$END$ are substituted by LMS'
# transcoding helper for time based seeking; $FILE$/$URL$ are replaced
# with the quoted local path or the remote URL.
my $FFMPEG_PREFIX = '[ffmpeg] -hide_banner -loglevel error -nostdin $START$ -i $INPUT$ $END$ -vn -sn -dn -map 0:a:0';

my %CAP = (
	T       => 'T:{START=-ss %s}',
	U       => 'U:{END=-t %w}',
	D_SOX   => 'D:{RESAMPLE=-r %d}',
	D_LAME  => 'D:{RESAMPLE=--resample %D}',
	D_FFMPEG => 'D:{RESAMPLE=-ar %d}',
	B_LAME  => 'B:{BITRATE=--abr %B}',
	B_FFMPEG => 'B:{BITRATE=-b:a %Bk}',
);

my @PROFILES;

# ---------------------------------------------------------------------------
# Profiles using LMS' own decoders: ffmpeg demuxes (stream copy, no decode)
# the audio track from the video container and pipes it into the same
# decoder chain LMS uses for the corresponding audio format.
# ---------------------------------------------------------------------------

my @DEMUX = (
	{
		ct       => 'vop',
		container => 'ogg',
		outputs  => {
			flc => {
				pipe => '[sox] -q -t opus - -t flac -C 0 $RESAMPLE$ -',
				caps => [qw(T U D_SOX)],
			},
			mp3 => {
				pipe => '[sox] -q -t opus - -t wav - | [lame] --silent -q $QUALITY$ $RESAMPLE$ $BITRATE$ - -',
				caps => [qw(T U D_LAME B_LAME)],
			},
			pcm => {
				pipe => '[sox] -q -t opus - -t raw -r 44100 -c 2 -2 -s -',
				caps => [qw(T U)],
			},
		},
	},
	{
		ct       => 'vaa',
		container => 'adts',
		outputs  => {
			flc => {
				pipe => '[faad] -q -w -f 1 - | [flac] -cs --totally-silent --compression-level-0 --ignore-chunk-sizes -',
				caps => [qw(T U)],
			},
			mp3 => {
				pipe => '[faad] -q -w -f 1 - | [lame] --silent -q $QUALITY$ $RESAMPLE$ $BITRATE$ - -',
				caps => [qw(T U D_LAME B_LAME)],
			},
			pcm => {
				pipe => '[faad] -q -w -f 2 -b 1 -',
				caps => [qw(T U)],
			},
		},
	},
	{
		ct       => 'vvo',
		container => 'ogg',
		outputs  => {
			flc => {
				pipe => '[sox] -q -t ogg - -t flac -C 0 $RESAMPLE$ -',
				caps => [qw(T U D_SOX)],
			},
			mp3 => {
				pipe => '[sox] -q -t ogg - -t wav - | [lame] --silent -q $QUALITY$ $RESAMPLE$ $BITRATE$ - -',
				caps => [qw(T U D_LAME B_LAME)],
			},
			pcm => {
				pipe => '[sox] -q -t ogg - -t raw -r 44100 -c 2 -2 -s -',
				caps => [qw(T U)],
			},
		},
	},
	{
		ct       => 'vfl',
		container => 'flac',
		outputs  => {
			flc => {
				pipe => undef,
				caps => [qw(T U)],
			},
			mp3 => {
				pipe => '[flac] -dc --totally-silent --force-raw-format --endian=little --sign=signed -- - | [sox] -q -t raw --endian little --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ - -t raw -c 2 - | [lame] --silent -r --little-endian --signed --bitwidth $SAMPLESIZE$ -s $SAMPLERATE$ -q $QUALITY$ $RESAMPLE$ $BITRATE$ - -',
				caps => [qw(T U D_LAME B_LAME)],
			},
			pcm => {
				pipe => '[flac] -dcs --force-raw-format --endian=little --sign=signed -- -',
				caps => [qw(T U)],
			},
		},
	},
	{
		ct       => 'vmp',
		container => 'mp3',
		outputs  => {
			flc => {
				pipe => '[sox] -q -t mp3 - -t flac -C 0 $RESAMPLE$ -',
				caps => [qw(T U D_SOX)],
			},
			mp3 => {
				pipe => undef,
				caps => [qw(T U)],
			},
			pcm => {
				pipe => '[sox] -q -t mp3 - -t raw -r 44100 -c 2 -2 -s -',
				caps => [qw(T U)],
			},
		},
	},
);

for my $source (@DEMUX) {
	for my $output (qw(flc mp3 pcm)) {
		my $spec = $source->{outputs}{$output};

		my $command = $FFMPEG_PREFIX
			. ' -c:a copy'
			. " -f $source->{container} -"
			. (defined $spec->{pipe} ? " | $spec->{pipe}" : '');

		_add_profiles($source->{ct}, $output, $command, $spec->{caps});
	}
}

# ---------------------------------------------------------------------------
# Fallback profiles: ffmpeg decodes the audio directly.  These are used for
# the codecs which need an external decoder (AC-3, E-AC-3, DTS, TrueHD) and
# for unknown audio codecs in video containers.
# ---------------------------------------------------------------------------

my @FALLBACK = (
	{
		output => 'flc',
		decode => '-ac $OCHANNELS$ $RESAMPLE$ -c:a flac -f flac -',
		caps   => [qw(T U D_FFMPEG)],
	},
	{
		output => 'mp3',
		decode => '-ac $OCHANNELS$ $RESAMPLE$ -c:a libmp3lame -q:a $QUALITY$ $BITRATE$ -f mp3 -',
		caps   => [qw(T U D_FFMPEG B_FFMPEG)],
	},
	{
		output => 'pcm',
		decode => '-ac $OCHANNELS$ $RESAMPLE$ -c:a pcm_s16le -f s16le -',
		caps   => [qw(T U D_FFMPEG)],
	},
);

for my $ct (qw(vac vae vdt vth vid)) {
	for my $spec (@FALLBACK) {
		my $command = $FFMPEG_PREFIX . ' ' . $spec->{decode};

		_add_profiles($ct, $spec->{output}, $command, $spec->{caps});
	}
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

my $content = _generate();

if ($STDOUT) {
	print $content;
	exit 0;
}

my $previous = '';
if (open my $read, '<', $OUTPUT) {
	local $/;
	$previous = <$read>;
	close $read;
}

if ($previous eq $content) {
	exit 0;
}

open my $write, '>', $OUTPUT or die "Cannot write $OUTPUT: $!\n";
print $write $content;
close $write or die "Cannot close $OUTPUT: $!\n";

exit 0;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub _add_profiles {
	my ($input, $output, $command, $caps) = @_;

	for my $mode (qw(F R)) {
		my $inputVariable = $mode eq 'F' ? '$FILE$' : '$URL$';

		my $profileCommand = $command;
		$profileCommand =~ s/\$INPUT\$/$inputVariable/g;

		my $capabilityLine = $mode . join('', map { $CAP{$_} } @$caps);

		push @PROFILES, {
			input     => $input,
			output    => $output,
			capability => $capabilityLine,
			command   => $profileCommand,
		};
	}

	return;
}

sub _generate {
	my $out = '';

	$out .= "# PlayVideo conversion profiles.\n";
	$out .= "#\n";
	$out .= "# GENERATED FILE - DO NOT EDIT.  Edit tools/gen-convert-conf.pl and\n";
	$out .= "# regenerate with: perl tools/gen-convert-conf.pl\n";
	$out .= "#\n";
	$out .= "# First line: <source type> <output format> <player type> <player id>.\n";
	$out .= "# Second line: capabilities (T/U seeking with ffmpeg, D downsample,\n";
	$out .= "# B bitrate limit).  Third line: the conversion command.\n";
	$out .= "\n";

	for my $profile (@PROFILES) {
		$out .= sprintf "%s %s * *\n", $profile->{input}, $profile->{output};
		$out .= "\t# $profile->{capability}\n";
		$out .= "\t$profile->{command}\n";
		$out .= "\n";
	}

	return $out;
}
