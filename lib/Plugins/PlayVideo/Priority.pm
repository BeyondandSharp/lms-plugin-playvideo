package Plugins::PlayVideo::Priority;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use warnings;

use Plugins::PlayVideo::Types;

my $TRANSCODING_HELPER = 'Slim::Player::TranscodingHelper';

our $ORIGINAL;
my $INSTALLED = 0;
my $log;

=head2 install()

Wrap C<Slim::Player::TranscodingHelper::getConvertCommand2> so that video
audio types which need an external decoder (C<vac>, C<vae>, C<vdt>, C<vth>)
first try the available external decoder profiles (for example from the
generic FFmpeg plugin or from a dedicated AC3/DTS plugin) and fall back to
PlayVideo's own ffmpeg decode profiles only if no external decoder is
usable.

Does nothing in the scanner process or when the transcoding helper is not
available.  Calling it twice is a no-op.

=cut

sub install {
	return 1 if $INSTALLED && $ORIGINAL;

	return 0 if _main_flag('SCANNER');

	return 0 unless _load_transcoding_helper();

	my $current = $TRANSCODING_HELPER->can('getConvertCommand2');
	return 0 unless $current;

	# Avoid double wrapping.
	return 1 if $current == \&_getConvertCommand2;

	$ORIGINAL  = $current;
	$INSTALLED = 1;

	no warnings 'redefine';
	no strict 'refs';

	*{"${TRANSCODING_HELPER}::getConvertCommand2"} = \&_getConvertCommand2;

	_log('debug', 'Installed external decoder priority hook');

	return 1;
}

=head2 uninstall()

Restore the original C<getConvertCommand2> implementation.

=cut

sub uninstall {
	return 1 unless $INSTALLED;

	if ($ORIGINAL && _load_transcoding_helper()) {
		no warnings 'redefine';
		no strict 'refs';

		*{"${TRANSCODING_HELPER}::getConvertCommand2"} = $ORIGINAL;
	}

	undef $ORIGINAL;
	$INSTALLED = 0;

	_log('debug', 'Removed external decoder priority hook');

	return 1;
}

=head2 is_installed()

Returns true when the hook is currently installed.

=cut

sub is_installed {
	return $INSTALLED ? 1 : 0;
}

sub _getConvertCommand2 {
	my @args = @_;

	my $wantsList = wantarray;

	my $type = _effective_type(@args);

	my $candidates = defined $type
		? Plugins::PlayVideo::Types::external_candidates($type)
		: [];

	if (!@$candidates || !_prefer_external()) {
		return $wantsList ? ($ORIGINAL->(@args)) : scalar $ORIGINAL->(@args);
	}

	for my $candidate (@$candidates) {
		my @retry = @args;

		# Force the external decoder's source type and make sure the
		# original code cannot mutate the caller's capability arrays.
		$retry[1] = $candidate;
		$retry[3] = _copy_arrayref($retry[3]);
		$retry[4] = _copy_arrayref($retry[4]);

		my ($transcoder, $error) = $ORIGINAL->(@retry);

		next unless $transcoder && ref $transcoder eq 'HASH';

		my $command = $transcoder->{command};

		# A passthrough command means the format is natively supported;
		# that is not an external decoder and must not be preferred.
		next unless defined $command && $command ne '-';

		_log('debug', "Using external decoder profile '" . ($transcoder->{profile} // '?')
			. "' for content type '$type' (candidate '$candidate')");

		return $wantsList ? ($transcoder, $error) : $transcoder;
	}

	_log('debug', "No external decoder available for content type '$type', using fallback");

	return $wantsList ? ($ORIGINAL->(@args)) : scalar $ORIGINAL->(@args);
}

# Determine the content type the original implementation would use.  The
# callers usually pass it explicitly; if not, derive it from the song/track
# object like getConvertCommand2 does.
sub _effective_type {
	my ($songOrTrack, $type) = @_;

	return $type if defined $type && length $type;

	return undef unless $songOrTrack;
	return undef unless $INC{'Slim/Music/Info.pm'} || eval { require Slim::Music::Info; 1 };

	if (eval { $songOrTrack->isa('Slim::Player::Song') }) {
		my $track = eval { $songOrTrack->currentTrack() };
		return undef unless $track;
		$songOrTrack = $track;
	}

	my $contentType = eval { Slim::Music::Info::contentType($songOrTrack) };

	return (defined $contentType && $contentType ne 'unk') ? $contentType : undef;
}

sub _prefer_external {
	my $prefs = eval {
		require Slim::Utils::Prefs;
		Slim::Utils::Prefs::preferences('plugin.playvideo');
	};

	return 1 unless $prefs;

	my $value = eval { $prefs->get('preferExternalDecoders') };

	return defined $value ? ($value ? 1 : 0) : 1;
}

sub _copy_arrayref {
	my $value = shift;

	return [] unless defined $value;
	return [@$value] if ref $value eq 'ARRAY';

	return $value;
}


# main::SCANNER / main::DEBUGLOG / main::INFOLOG are constants created by
# the LMS main scripts.  They do not exist when the module is loaded in a
# unit test, so probe them defensively.
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

sub _load_transcoding_helper {
	return 1 if $INC{'Slim/Player/TranscodingHelper.pm'};

	return eval { require Slim::Player::TranscodingHelper; 1 } ? 1 : 0;
}

sub _log {
	my ($level, $message) = @_;

	return unless $INC{'Slim/Utils/Log.pm'} || eval { require Slim::Utils::Log; 1 };

	$log ||= eval { Slim::Utils::Log::logger('plugin.playvideo') };
	return unless $log;

	my $debug = _main_flag('DEBUGLOG') && $log->is_debug;
	my $info  = _main_flag('INFOLOG') && $log->is_info;

	if ($level eq 'debug') {
		$log->debug($message) if $debug;
	}
	else {
		$log->info($message) if $info || $debug;
	}

	return;
}

1;

__END__

=head1 NAME

Plugins::PlayVideo::Priority - external decoder priority for PlayVideo

=head1 DESCRIPTION

The PlayVideo content types C<vac> (AC-3), C<vae> (E-AC-3), C<vdt> (DTS)
and C<vth> (TrueHD) are PlayVideo specific fallback types: an installed
plugin providing the real codec profiles (generic FFmpeg plugin or a
dedicated decoder plugin) should win over PlayVideo's own ffmpeg decode
profiles.  This module wraps
C<Slim::Player::TranscodingHelper::getConvertCommand2> and retries the
lookup with the candidate source types from
L<Plugins::PlayVideo::Types/external_candidates> before falling back to
the original lookup.

The behaviour can be disabled with the C<preferExternalDecoders> plugin
preference.  Call L</uninstall> to restore the original method.

=cut
