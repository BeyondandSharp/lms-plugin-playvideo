package Plugins::PlayVideo::Types;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
	VIDEO_TYPES
	is_video_type
	type_for_codec
	external_candidates
	all_video_types_regex
	codec_capabilities
);

# Content types used by PlayVideo.  The four trailing types are the
# "fallback only" audio codecs that need an external decoder or the
# ffmpeg decode fallback; the leading types are demuxed from the video
# container and handed to LMS' own decoders.
my @VIDEO_TYPES = qw(vid vop vaa vvo vfl vmp vac vae vdt vth);

my %IS_VIDEO_TYPE = map { $_ => 1 } @VIDEO_TYPES;

# ffprobe codec_name -> PlayVideo content type.  Anything unknown (h264,
# pcm variants, ...) is treated as a plain video audio track ("vid").
my %CODEC_TYPE = (
	opus   => 'vop',
	aac    => 'vaa',
	vorbis => 'vvo',
	flac   => 'vfl',
	mp3    => 'vmp',
	ac3    => 'vac',
	eac3   => 'vae',
	dts    => 'vdt',
	truehd => 'vth',
);

# Types for which Priority may retry with an external decoder plugin.
# The candidates are ordered from most to least preferred.
my %EXTERNAL_CANDIDATES = (
	vac => [qw(ac3 a52)],
	vae => [qw(eac3 ec3 ac3)],
	vdt => [qw(dts dca)],
	vth => [qw(truehd mlp dts)],
);

sub VIDEO_TYPES {
	return wantarray ? @VIDEO_TYPES : [@VIDEO_TYPES];
}

sub is_video_type {
	my ($ct) = _strip_class(@_);

	return 0 unless defined $ct;
	return $IS_VIDEO_TYPE{ lc $ct } ? 1 : 0;
}

sub type_for_codec {
	my ($codec) = _strip_class(@_);

	return 'vid' unless defined $codec;

	$codec = lc $codec;
	$codec =~ s/^\s+//;
	$codec =~ s/\s+$//;

	return 'vid' unless length $codec;

	return $CODEC_TYPE{$codec} || 'vid';
}

sub external_candidates {
	my ($ct) = _strip_class(@_);

	return [] unless defined $ct;

	my $candidates = $EXTERNAL_CANDIDATES{ lc $ct };
	return [] unless $candidates;

	return [@$candidates];
}

# Allow the helpers to be called as class methods as well.
sub _strip_class {
	return @_ unless @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;

	my @copy = @_;
	shift @copy;

	return @copy;
}

sub all_video_types_regex {
	my $alternation = join '|', @VIDEO_TYPES;
	return qr/^(?:$alternation)$/;
}

# Output formats produced from every PlayVideo content type.  FLAC, MP3 and
# PCM are produced either by the native demux profiles or by the ffmpeg
# fallback; AAC (ADTS), Ogg Vorbis and Opus are always encoded by ffmpeg.
my @CONVERT_TARGETS = qw(flc mp3 pcm aac ogg ops);

# Targets which honour LMS' Maximum Bitrate setting (B capability).
my @BITRATE_TARGETS = qw(mp3 aac ogg ops);

# Side effect free conversion declaration, see the POD at the end of the
# file.  Called without an argument it assumes external decoders are
# preferred, which matches the preferExternalDecoders plugin default.
sub codec_capabilities {
	my @args = @_;

	# Accept both codec_capabilities( $prefer ) and the class method form
	# codec_capabilities( $class, $prefer ).
	my $prefer;
	if (@args && defined $args[0] && !ref $args[0] && $args[0] eq __PACKAGE__) {
		$prefer = $args[1];
	}
	else {
		$prefer = $args[0];
	}

	$prefer = 1 unless defined $prefer;

	my $priority = $prefer ? 150 : 1;

	return {
		provider => 'playvideo',
		priority => $priority,

		# ffmpeg decodes every PlayVideo content type into PCM or FLAC.
		decode => [
			{
				from  => [@VIDEO_TYPES],
				to    => [qw(pcm flc)],
				scope => [qw(local remote)],
			},
		],

		# Every content type can be converted into the output formats of
		# custom-convert.conf: FLAC, MP3, PCM, AAC (ADTS), Ogg Vorbis and
		# Opus.
		convert => [
			{
				from  => [@VIDEO_TYPES],
				to    => [@CONVERT_TARGETS],
				scope => [qw(local remote)],
			},
		],

		# These convert targets honour LMS' Maximum Bitrate setting (B).
		bitrate => [@BITRATE_TARGETS],
	};
}

1;

__END__

=head1 NAME

Plugins::PlayVideo::Types - content type helpers for the PlayVideo plugin

=head1 DESCRIPTION

Pure Perl helpers mapping ffprobe codec names to the PlayVideo content types
and describing which content types may be served by an external decoder
plugin.  This module has no Lyrion Music Server runtime dependency.

=head2 VIDEO_TYPES

Returns the list of all PlayVideo content types in list context, an array
reference in scalar context.

=head2 is_video_type( $contentType )

Returns true if the given content type is a PlayVideo video content type.

=head2 type_for_codec( $codecName )

Maps an ffprobe codec name to a PlayVideo content type.  Unknown codecs are
mapped to C<vid>.

=head2 external_candidates( $contentType )

Returns an array reference with the content types that may be used as an
external decoder for the given type (empty for types without candidates).

=head2 all_video_types_regex()

Returns a compiled regular expression matching any PlayVideo content type.

=head2 codec_capabilities( $preferExternalDecoders )

Returns a side effect free hash reference describing the conversions the
plugin provides:

  {
    provider => 'playvideo',
    priority => 150,                       # 1 when external decoders are off
    decode   => [ { from => [...10 types...], to => ['pcm', 'flc'],
                    scope => ['local', 'remote'] } ],
    convert  => [ { from => [...10 types...],
                    to => ['flc', 'mp3', 'pcm', 'aac', 'ogg', 'ops'],
                    scope => ['local', 'remote'] } ],
    bitrate  => ['mp3', 'aac', 'ogg', 'ops'],
  }

C<priority> is the preference passed to orchestration layers such as
CodecSwitch (smaller values win).  It is 150 when external decoders are
preferred and 1 when they are not.  C<bitrate> lists the convert targets
which honour LMS' Maximum Bitrate setting (B capability).

This function has no Lyrion Music Server runtime dependency.

=cut
