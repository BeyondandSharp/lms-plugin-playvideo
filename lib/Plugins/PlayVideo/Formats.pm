package Plugins::PlayVideo::Formats;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use warnings;

use base 'Slim::Formats::Movie';

use Plugins::PlayVideo::Probe;
use Plugins::PlayVideo::Tags;
use Plugins::PlayVideo::Types;

my %MP4_EXTENSION = map { $_ => 1 } qw(mp4 m4a m4b m4p m4r);

=head2 register()

Register this class as the metadata reader for MP4 files and for all
PlayVideo content types.  The corresponding entries in
C<%Slim::Formats::loadedTagClasses> are cleared so that a previously
registered reader cannot shadow the new one.

=cut

sub register {
	my $class = shift;

	return 0 unless eval { require Slim::Formats; 1 };

	my @types = ('mp4', Plugins::PlayVideo::Types::VIDEO_TYPES);

	for my $type (@types) {
		$Slim::Formats::tagClasses{$type} = __PACKAGE__;
		delete $Slim::Formats::loadedTagClasses{$type};
	}

	return scalar @types;
}

=head2 getTag( $file, $anchor )

Fallback metadata reader for video files.  For MP4 style containers the
regular C<Slim::Formats::Movie> reader is tried first; only if that does
not return anything (i.e. the file contains a video stream) the ffprobe
based reader is used.

Returns the tag hash and the content type to use.  Files without usable
audio information are reported as C<DRM> so that the scanner skips them
without creating a database row (an empty hash would still create a
URL-only track).

=cut

sub getTag {
	my ($class, $file, $anchor) = @_;

	return _skip() unless defined $file && length $file;

	my $extension = _extension($file);

	if ($MP4_EXTENSION{$extension}) {
		my $movieTags = eval { $class->SUPER::getTag($file, $anchor) };

		if ($movieTags && ref $movieTags eq 'HASH' && scalar keys %$movieTags) {
			return ($movieTags, 'mp4');
		}

		return _video_tags($file, 1);
	}

	return _video_tags($file, 0);
}

=head2 getCoverArt( $file )

Return embedded artwork.  For MP4 style containers Audio::Scan via
C<Slim::Formats::Movie> is used first, then the attached picture stream is
extracted with ffmpeg.  Anything else is delegated to
C<Plugins::PlayVideo::Probe::cover>.

=cut

sub getCoverArt {
	my ($class, $file) = @_;

	return undef unless defined $file && length $file;

	my $extension = _extension($file);

	if ($MP4_EXTENSION{$extension}) {
		my $art = eval { $class->SUPER::getCoverArt($file) };
		return $art if defined $art && length $art;
	}

	return Plugins::PlayVideo::Probe::cover($file);
}

sub _video_tags {
	my ($file, $isMp4) = @_;

	my $probe = Plugins::PlayVideo::Probe::probe($file);

	unless ($probe) {
		_log_debug("Cannot probe [$file]: " . (Plugins::PlayVideo::Probe::last_error() // 'unknown error'));
		return _skip();
	}

	# Files without an audio stream cannot be played at all, and files with
	# no known duration are not usable for LMS.
	unless ($probe->{audio} && _has_duration($probe)) {
		_log_info("No audio or duration found in [$file], skipping");
		return _skip();
	}

	my $codec = $probe->{audio}{codec_name};
	my $ct    = Plugins::PlayVideo::Types::type_for_codec($codec);

	my ($contentType, $ctOverride);

	if ($isMp4 && !@{ $probe->{videos} || [] }) {
		# Audio only MP4 file: LMS knows "mp4" (and "alc" for ALAC) as
		# regular audio content types, so remap it to keep it in the audio
		# part of the library.
		$ctOverride  = 'mp4';
		$contentType = (defined $codec && lc($codec) eq 'alac') ? 'alc' : 'mp4';
	}
	else {
		$ctOverride  = $ct;
		$contentType = $ct;
	}

	my $tags = Plugins::PlayVideo::Tags::build(
		$probe,
		content_type  => $contentType,
		folderAsAlbum => _folder_as_album(),
		path          => $file,
	);

	return _skip() unless $tags && ref $tags eq 'HASH';

	return ($tags, $ctOverride);
}

sub _has_duration {
	my $probe = shift;

	my $seconds = $probe->{format}{duration};
	$seconds = $probe->{audio}{duration}
		unless defined $seconds && $seconds > 0;

	return defined $seconds && $seconds > 0 ? 1 : 0;
}

# Return a tag hash which makes Slim::Formats::readTags()/_newTrack() skip
# unplayable files.  Returning an empty hash or undef is not sufficient:
# runScanners adds url/urlmd5 to the attributes before the track row is
# created, so the scanner would still insert a URL-only track.  The DRM flag
# is the only early abort condition in _newTrack().
sub _skip {
	return { DRM => 1 };
}

sub _extension {
	my $file = shift;

	return '' unless defined $file && length $file;

	# Note: do not use File::Basename::fileparse() without an explicit
	# suffix list here.  Without it fileparse() does not split off the
	# extension and returns an empty suffix, which made every mp4 style
	# file take the generic video branch.
	return lc($1) if $file =~ /\.([^.\\\/]+)$/;

	return '';
}

sub _folder_as_album {
	my $prefs = eval {
		require Slim::Utils::Prefs;
		Slim::Utils::Prefs::preferences('plugin.playvideo');
	};

	return 1 unless $prefs;

	my $value = eval { $prefs->get('folderAsAlbum') };

	return defined $value ? ($value ? 1 : 0) : 1;
}


# main::DEBUGLOG / main::INFOLOG are constants created by the LMS main
# scripts; they do not exist when only parts of LMS are loaded.
sub _main_flag {
	my $name = shift;

	my $code = do {
		no strict 'refs';
		\&{"main::$name"};
	};

	return 0 unless $code;

	my $value = eval { $code->() };

	return $value ? 1 : 0;
}

my $log;

sub _logger {
	return $log if $log;
	return undef unless $INC{'Slim/Utils/Log.pm'} || eval { require Slim::Utils::Log; 1 };

	$log = eval { Slim::Utils::Log::logger('plugin.playvideo') };

	return $log;
}

sub _log_debug {
	my $message = shift;

	my $logger = _logger();
	return unless $logger && _main_flag('DEBUGLOG') && $logger->is_debug;

	$logger->debug($message);
}

sub _log_info {
	my $message = shift;

	my $logger = _logger();
	return unless $logger && _main_flag('INFOLOG') && $logger->is_info;

	$logger->info($message);
}

1;

__END__

=head1 NAME

Plugins::PlayVideo::Formats - video metadata reader for the PlayVideo plugin

=head1 DESCRIPTION

Extends L<Slim::Formats::Movie>.  MP4 style files keep using the native
Audio::Scan based reader; files with real video streams (and all other
video containers) fall back to L<Plugins::PlayVideo::Probe> and
L<Plugins::PlayVideo::Tags>.  Playback related streaming methods are
inherited from C<Slim::Formats::Movie>.

=cut
