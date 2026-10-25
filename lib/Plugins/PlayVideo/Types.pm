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

=cut
