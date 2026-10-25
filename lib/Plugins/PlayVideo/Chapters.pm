package Plugins::PlayVideo::Chapters;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use warnings;

use Scalar::Util qw(blessed);

use Slim::Utils::Log;

use Plugins::PlayVideo::Probe;
use Plugins::PlayVideo::Types;

my $log = logger('plugin.playvideo');

# A small process local cache.  Probe has its own cache, but it is keyed by
# path and may be disabled; this one also keeps the last state of the track
# so frequent TrackInfo menu rendering does not run ffprobe again.
my %chapterCache;

my $MAX_CACHE_ENTRIES = 100;

sub get {
	my $track = shift;

	return [] unless $track;

	# get_for_url() passes a plain URL; make both entry points forgiving.
	unless (blessed($track)) {
		return get_for_url($track);
	}

	my $url = eval { $track->url };

	return [] unless defined $url && length $url;

	return [] if $track->can('remote') && eval { $track->remote };

	return [] unless _track_is_video($track);

	my $path = eval { $track->path };

	$path = _path_from_url($url) unless defined $path && length $path;

	return [] unless defined $path && length $path;

	return _chapters_for_path($path);
}

sub get_for_url {
	my $url = shift;

	return [] unless defined $url && length $url;

	# Allow callers to hand in a track object by mistake.
	return get($url) if blessed($url);

	unless (eval { Slim::Music::Info::isFileURL($url) }) {
		return [];
	}

	my $track = eval { Slim::Schema->objectForUrl({ url => $url }) };

	if (blessed($track)) {
		# Covers the case where the track exists but is marked remote.
		return [] if $track->can('remote') && eval { $track->remote };

		my $path = eval { $track->path };
		return _chapters_for_path($path) if defined $path && length $path;
	}

	my $path = _path_from_url($url);

	return [] unless defined $path && length $path;

	# Not in the library (yet).  Only trust the file suffix, the content
	# type is unknown at this point.
	return [] unless _path_is_video($path);

	return _chapters_for_path($path);
}

sub clear_cache {
	%chapterCache = ();

	return 1;
}

sub _chapters_for_path {
	my $path = shift;

	return [] unless defined $path && length $path && -e $path;

	my $mtime = (stat _)[9];

	if (my $cached = $chapterCache{$path}) {
		if (!defined $mtime || $cached->{mtime} == $mtime) {
			return [ map { { %$_ } } @{ $cached->{chapters} || [] } ];
		}
	}

	my $chapters = eval { Plugins::PlayVideo::Probe->chapters($path) };

	if (!defined $chapters || ref $chapters ne 'ARRAY') {
		$log->warn('Unable to read chapters for ' . $path . ': ' . ($@ || 'no chapters returned'));
		$chapters = [];
	}

	my @normalized;

	for my $chapter (@$chapters) {
		next unless ref $chapter eq 'HASH';

		my $start = $chapter->{start};

		next unless defined $start && $start =~ /^\s*\d+(?:\.\d+)?\s*$/;

		push @normalized, {
			start => 0 + $start,
			end   => (defined $chapter->{end} && $chapter->{end} =~ /^\s*\d+(?:\.\d+)?\s*$/)
				? 0 + $chapter->{end}
				: undef,
			title => defined $chapter->{title} ? "$chapter->{title}" : undef,
		};
	}

	_remember($path, $mtime, \@normalized);

	return [ map { { %$_ } } @normalized ];
}

sub _remember {
	my ($path, $mtime, $chapters) = @_;

	if (scalar keys %chapterCache >= $MAX_CACHE_ENTRIES) {
		# Drop the oldest entry (insertion order is good enough here).
		my ($oldest) = sort { ($chapterCache{$a}->{seen} || 0) <=> ($chapterCache{$b}->{seen} || 0) } keys %chapterCache;
		delete $chapterCache{$oldest} if defined $oldest;
	}

	$chapterCache{$path} = {
		mtime    => $mtime,
		chapters => $chapters,
		seen     => time(),
	};

	return 1;
}

sub _track_is_video {
	my $track = shift;

	my $contentType = eval { $track->content_type };

	if (!defined $contentType || $contentType eq '') {
		$contentType = eval { Slim::Schema->contentType($track) };
	}

	return Plugins::PlayVideo::Types::is_video_type($contentType) ? 1 : 0;
}

sub _path_from_url {
	my $url = shift;

	return undef unless defined $url && length $url;

	return eval { Slim::Utils::Misc::pathFromFileURL($url) };
}

sub _path_is_video {
	my $path = shift;

	return 0 unless defined $path && length $path;

	my $type = eval { Slim::Music::Info::typeFromPath($path) };

	return Plugins::PlayVideo::Types::is_video_type($type) ? 1 : 0;
}

1;

__END__

=head1 NAME

Plugins::PlayVideo::Chapters - chapter access for PlayVideo video tracks

=head1 SYNOPSIS

	my $chapters = Plugins::PlayVideo::Chapters::get($track);
	my $chapters = Plugins::PlayVideo::Chapters::get_for_url($url);

=head1 DESCRIPTION

Returns the chapter list of a local video file, using
L<Plugins::PlayVideo::Probe>.  Each entry is a hash reference with the keys
C<start>, C<end> and C<title>.

Remote tracks and files which are not one of the PlayVideo content types are
rejected and an empty array reference is returned.  Results are cached in
memory and invalidated when the file modification time changes.

=cut
