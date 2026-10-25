package Plugins::PlayVideo::Tags;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use warnings;

use File::Basename qw(basename dirname);

use Plugins::PlayVideo::Types;

# Codecs whose audio data is (normally) lossless.
my %LOSSLESS_CODEC = map { $_ => 1 } qw(
	flac alac ape wavpack tta shorten mlp truehd
);

# Map from a normalized (lowercase, punctuation replaced by "_") ffprobe
# tag name to the tag name expected by Lyrion Music Server.  The mapping
# mirrors Slim::Formats::Movie so that the fallback reader produces the
# same database attributes as the native MP4 reader.
my %TAG_MAP = (
	title                 => 'TITLE',
	artist                => 'ARTIST',
	album                 => 'ALBUM',
	album_artist          => 'ALBUMARTIST',
	albumartist           => 'ALBUMARTIST',
	album_artist_sort     => 'ALBUMARTISTSORT',
	albumartistsort       => 'ALBUMARTISTSORT',
	artistsort            => 'ARTISTSORT',
	artist_sort           => 'ARTISTSORT',
	sort_artist           => 'ARTISTSORT',
	sortartist            => 'ARTISTSORT',
	albumsort             => 'ALBUMSORT',
	album_sort            => 'ALBUMSORT',
	sort_album            => 'ALBUMSORT',
	sortalbum             => 'ALBUMSORT',
	titlesort             => 'TITLESORT',
	title_sort            => 'TITLESORT',
	sort_title            => 'TITLESORT',
	sorttitle             => 'TITLESORT',
	composersort          => 'COMPOSERSORT',
	composer_sort         => 'COMPOSERSORT',
	sort_composer         => 'COMPOSERSORT',
	composer              => 'COMPOSER',
	conductor             => 'CONDUCTOR',
	genre                 => 'GENRE',
	date                  => 'YEAR',
	year                  => 'YEAR',
	originaldate          => 'ORIGINALYEAR',
	originalyear          => 'ORIGINALYEAR',
	comment               => 'COMMENT',
	description           => 'COMMENT',
	lyrics                => 'LYRICS',
	track                 => 'TRACKNUM',
	tracknumber           => 'TRACKNUM',
	track_number          => 'TRACKNUM',
	tracknum              => 'TRACKNUM',
	disc                  => 'DISC',
	discnumber            => 'DISC',
	disc_number           => 'DISC',
	disk                  => 'DISC',
	unsyncedlyrics        => 'LYRICS',
	unsynced_lyrics       => 'LYRICS',
	syncedlyrics          => 'LYRICS',
	bpm                   => 'BPM',
	tmpo                  => 'BPM',
	compilation           => 'COMPILATION',
	grouping              => 'GROUPING',
	work                  => 'WORK',
	'replaygain_track_gain'  => 'REPLAYGAIN_TRACK_GAIN',
	'replaygain_track_peak'  => 'REPLAYGAIN_TRACK_PEAK',
	'replaygain_album_gain'  => 'REPLAYGAIN_ALBUM_GAIN',
	'replaygain_album_peak'  => 'REPLAYGAIN_ALBUM_PEAK',
	'replaygain_gain'        => 'REPLAYGAIN_TRACK_GAIN',
	'replaygain_peak'        => 'REPLAYGAIN_TRACK_PEAK',
	'musicbrainz_album_id'          => 'MUSICBRAINZ_ALBUM_ID',
	'musicbrainz_albumid'           => 'MUSICBRAINZ_ALBUM_ID',
	'musicbrainz_artist_id'         => 'MUSICBRAINZ_ARTIST_ID',
	'musicbrainz_artistid'          => 'MUSICBRAINZ_ARTIST_ID',
	'musicbrainz_album_artist_id'   => 'MUSICBRAINZ_ALBUMARTIST_ID',
	'musicbrainz_albumartist_id'    => 'MUSICBRAINZ_ALBUMARTIST_ID',
	'musicbrainz_albumartistid'     => 'MUSICBRAINZ_ALBUMARTIST_ID',
	'musicbrainz_album_artist'      => 'ALBUMARTIST',
	'musicbrainz_album_artist_sort' => 'ALBUMARTISTSORT',
	'musicbrainz_track_id'          => 'MUSICBRAINZ_ID',
	'musicbrainz_trackid'           => 'MUSICBRAINZ_ID',
	'musicbrainz_release_track_id'  => 'MUSICBRAINZ_RELEASETRACKID',
	'musicbrainz_releasetrackid'    => 'MUSICBRAINZ_RELEASETRACKID',
	'musicbrainz_album_status'      => 'MUSICBRAINZ_ALBUM_STATUS',
	'musicbrainz_album_type'        => 'RELEASETYPE',
	'musicbrainz_albumtype'         => 'RELEASETYPE',
	'musicbrainz_sortname'          => 'ARTISTSORT',
	'musicbrainz_artist_sortname'   => 'ARTISTSORT',
);

# ffprobe reports some dates as "DATE_RELEASED"/"DATE_RECORDED" style tags.
# They are folded into YEAR (in this priority order) unless a "date"/"year"
# tag was present already.
my @DATE_FALLBACK_TAGS = qw(date_released date_recorded datecreated date_created);

sub build {
	my @args = @_;

	# Accept both build($probe, ...) and Tags->build($probe, ...).
	shift @args if @args && defined $args[0] && !ref $args[0] && $args[0] eq __PACKAGE__;

	my ($probe, %opts) = @args;

	return {} unless $probe && ref $probe eq 'HASH';

	my $format = $probe->{format} || {};
	my $audio  = $probe->{audio}  || {};

	my $codec = $audio->{codec_name};
	my $ct    = $opts{content_type};

	if (!defined $ct || !length $ct) {
		$ct = Plugins::PlayVideo::Types::type_for_codec($codec);
	}

	my $tags = {};

	$tags->{CONTENT_TYPE} = $ct;
	$tags->{AUDIO}        = 1;
	$tags->{OFFSET}       = 0;

	my $secs = _number($format->{duration});
	$secs = _number($audio->{duration}) unless defined $secs;
	$tags->{SECS} = $secs if defined $secs;

	if (defined(my $rate = _integer($audio->{sample_rate}))) {
		$tags->{RATE} = $rate;
	}
	if (defined(my $channels = _integer($audio->{channels}))) {
		$tags->{CHANNELS} = $channels;
	}
	if (defined(my $sampleSize = _integer($audio->{bits_per_raw_sample} // $audio->{bits_per_sample}))) {
		$tags->{SAMPLESIZE} = $sampleSize;
	}
	if (defined(my $bitrate = _integer($format->{bit_rate} // $audio->{bit_rate}))) {
		$tags->{BITRATE} = $bitrate;
	}
	if (defined(my $size = _integer($format->{size} // $probe->{size}))) {
		$tags->{SIZE} = $size;
	}

	$tags->{LOSSLESS} = (defined $codec && $LOSSLESS_CODEC{ lc $codec }) ? 1 : 0;

	# Merge container level tags with the tags of the first audio stream.
	# Stream tags win, they are the more specific ones.
	my %merged;
	for my $source ($format->{tags}, $audio->{tags}) {
		next unless $source && ref $source eq 'HASH';
		for my $key (keys %$source) {
			my $value = $source->{$key};
			next unless defined $value;
			next if ref $value;
			$merged{$key} = $value;
		}
	}

	# Normalize keys and map them.  Sorted iteration keeps the result
	# deterministic when several source tags map to the same LMS tag.
	for my $key (sort keys %merged) {
		my $normalized = _normalize_tag_name($key);
		my $mapped     = $TAG_MAP{$normalized} or next;

		next if defined $tags->{$mapped};

		my $value = _clean_value($merged{$key});
		next unless defined $value && length $value;

		$tags->{$mapped} = $value;
	}

	# Fold the remaining date variants into YEAR.
	if (!defined $tags->{YEAR}) {
		for my $key (@DATE_FALLBACK_TAGS) {
			my $value;
			for my $source ($format->{tags}, $audio->{tags}) {
				next unless $source && ref $source eq 'HASH';
				for my $tag (keys %$source) {
					next unless _normalize_tag_name($tag) eq $key;
					$value = _clean_value($source->{$tag});
					last if defined $value;
				}
				last if defined $value;
			}
			if (defined $value && length $value) {
				$tags->{YEAR} = $value;
				last;
			}
		}
	}

	# Same handling as Slim::Formats::Movie for date, track and disc.
	if (defined $tags->{YEAR}) {
		$tags->{YEAR} = sanitize_year($tags->{YEAR});
	}

	_parse_number_pair($tags, 'TRACKNUM', undef, 'track');
	_parse_number_pair($tags, 'DISC', 'DISCC', 'disc');

	# Optionally use the folder name as album name.  This is useful for
	# video folders which very often contain one movie per directory.
	if ($opts{folderAsAlbum} && !defined $tags->{ALBUM}) {
		my $path = $probe->{path} // $opts{path};
		if (defined $path && length $path) {
			my $album = basename(dirname($path));
			$album =~ s/^\s+//;
			$album =~ s/\s+$//;
			$tags->{ALBUM} = $album if length $album && $album ne '.' && $album ne '/';
		}
	}

	return $tags;
}

sub sanitize_year {
	my $year = shift;

	return $year unless defined $year;

	if ($year =~ /^\s*(\d{4})/) {
		return int($1);
	}
	if ($year =~ /^\s*(\d+)\s*$/) {
		return int($1);
	}

	return _clean_value($year);
}

# Parse "#" or "#/#" style values into an LMS track/disc number (and the
# optional count in the second tag, following Slim::Formats::Movie).
sub _parse_number_pair {
	my ($tags, $numberTag, $countTag, $sourceTag) = @_;

	my $value = $tags->{$numberTag};
	return unless defined $value;

	if ($value =~ /^\s*(\d+)\s*(?:\/\s*(\d+))?/) {
		my ($number, $count) = ($1, $2);

		$tags->{$numberTag} = int($number);
		$tags->{$countTag}  = int($count)
			if defined $countTag && defined $count && $count =~ /^\d+$/;
	}
	else {
		delete $tags->{$numberTag};
	}
}

sub _normalize_tag_name {
	my $name = shift;
	return '' unless defined $name;

	$name = lc $name;
	$name =~ tr/ /_/;
	$name =~ tr/-/_/;
	$name =~ s/[^a-z0-9_]//g;
	$name =~ s/_+/_/g;

	return $name;
}

sub _clean_value {
	my $value = shift;

	return undef unless defined $value;
	return undef if ref $value;

	$value = "$value";
	$value =~ s/^\s+//;
	$value =~ s/\s+$//;
	$value =~ s/\x00//g;

	return $value;
}

sub _number {
	my $value = shift;

	return undef unless defined $value;
	return undef unless $value =~ /^\s*-?\d+(?:\.\d+)?\s*$/;

	return 0 + $value;
}

sub _integer {
	my $value = shift;

	return undef unless defined $value;
	return undef unless $value =~ /^\s*-?\d+\s*$/;

	return int($value);
}

1;

__END__

=head1 NAME

Plugins::PlayVideo::Tags - pure tag building for the PlayVideo plugin

=head1 SYNOPSIS

	my $tags = Plugins::PlayVideo::Tags::build(
		$probe,
		content_type   => 'vop',
		folderAsAlbum  => 1,
	);

=head1 DESCRIPTION

Transforms the normalized probe hash returned by
L<Plugins::PlayVideo::Probe> into the tag hash expected by
C<Slim::Formats-E<gt>readTags>.  The module is pure Perl and does not require
a running Lyrion Music Server (and therefore can be unit tested standalone).

Supported options:

=over 4

=item content_type

Overrides the content type derived from the audio codec.

=item folderAsAlbum

When true and no ALBUM tag is present, the name of the directory containing
the file is used as album name.

=item path

Fallback path used for C<folderAsAlbum> when the probe hash does not contain
one.

=back

=cut
