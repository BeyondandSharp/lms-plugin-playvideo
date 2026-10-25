package Plugins::PlayVideo::Plugin;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use warnings;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use base qw(Slim::Plugin::OPMLBased);

use Plugins::PlayVideo::Formats;
use Plugins::PlayVideo::Menus;
use Plugins::PlayVideo::Priority;

my $log = logger('plugin.playvideo');

my $prefs = preferences('plugin.playvideo');

# Guard against preinitPlugin/initPlugin being called more than once and
# remember the ffmpeg binary we put into TranscodingHelper ourselves.  We
# must never overwrite a binary resolved by somebody else (for example the
# optional FFmpeg plugin).
my $prefsInitialized = 0;
my $ownFfmpegBinary;

sub getDisplayName {
	return 'PLUGIN_PLAYVIDEO';
}

# Register the prefs and the custom format readers as early as possible.
# PluginManager calls preinitPlugin before initPlugin for every plugin.
sub preinitPlugin {
	my $class = shift;

	$class->_initPreferences;
	$class->_registerFormats;
}

sub initPlugin {
	my $class = shift;

	$class->_initPreferences;
	$class->_registerFormats;
	$class->_installPriority;
	$class->_initMenus;

	if (main::WEBUI) {
		eval {
			require Plugins::PlayVideo::Settings;
			Plugins::PlayVideo::Settings->new;
			1;
		} or $log->error('Unable to initialize the PlayVideo settings page: ' . ($@ || 'unknown error'));
	}

	$class->_setupBinaries;

	$class->SUPER::initPlugin(
		feed   => \&Plugins::PlayVideo::Menus::feed,
		tag    => 'playvideo',
		menu   => 'browse',
		node   => 'myMusic',
		weight => 40,
	);
}

sub shutdownPlugin {
	my $class = shift;

	eval {
		require Plugins::PlayVideo::Priority;
		Plugins::PlayVideo::Priority::uninstall();
		1;
	} or $log->warn('Unable to uninstall the PlayVideo transcoding hook: ' . ($@ || 'unknown error'));

	return 1;
}

sub _initPreferences {
	my $class = shift;

	return if $prefsInitialized;

	$prefs->init({
		ffmpeg                 => '',
		ffprobe                => '',
		folderAsAlbum          => 1,
		probeTimeout           => 20,
		showVideoInfo          => 1,
		enableChapters         => 1,
		preferExternalDecoders => 1,
	});

	# Settings are plain executable paths.  Probe runs them in list form
	# (never through a shell), but LMS' transcoding helper builds a command
	# string from the binary path.  Reject control characters, quotes and
	# shell metacharacters, as well as absurdly long values.
	$prefs->setValidate(sub {
		my (undef, $value) = @_;

		return 1 if !defined $value || $value eq '';
		return 0 if ref $value;
		return 0 if $value =~ /[\x00-\x1f\x7f]/;
		return 0 if $value =~ /["'`$;|&<>]/;
		return 0 if length($value) > 4096;
		return 1;
	}, qw(ffmpeg ffprobe));

	$prefs->setValidate({ validator => 'intlimit', low => 1, high => 120 }, 'probeTimeout');

	$prefs->setChange(sub { __PACKAGE__->_pathPreferenceChanged(@_) }, qw(ffmpeg ffprobe));

	$prefsInitialized = 1;

	return 1;
}

sub _pathPreferenceChanged {
	my ($class, $pref, $value) = @_;

	# The probe module caches resolved binaries, so make sure it resolves
	# again after the paths have been edited.
	eval {
		require Plugins::PlayVideo::Probe;
		Plugins::PlayVideo::Probe->clear_cache() if Plugins::PlayVideo::Probe->can('clear_cache');
		1;
	} or $log->warn('Unable to clear the PlayVideo probe cache: ' . ($@ || 'unknown error'));

	$class->_setupBinaries;

	return 1;
}

sub _registerFormats {
	my $class = shift;

	eval {
		Plugins::PlayVideo::Formats::register();
		1;
	} or $log->error('Unable to register the PlayVideo format readers: ' . ($@ || 'unknown error'));

	return 1;
}

sub _installPriority {
	my $class = shift;

	eval {
		Plugins::PlayVideo::Priority::install();
		1;
	} or $log->error('Unable to install the PlayVideo decoder priority hook: ' . ($@ || 'unknown error'));

	return 1;
}

sub _initMenus {
	my $class = shift;

	eval {
		Plugins::PlayVideo::Menus::init();
		1;
	} or $log->error('Unable to initialize the PlayVideo menus: ' . ($@ || 'unknown error'));

	return 1;
}

# Pick the ffmpeg binary in this order:
#   1. the optional FFmpeg plugin (when loaded and able to resolve a binary)
#   2. our own configured path
#   3. the system PATH
#
# The result is only published through TranscodingHelper if nobody has set a
# binary yet, or if the current value is the one we set ourselves before.
sub _setupBinaries {
	my $class = shift;

	my $ffmpeg = $class->_resolveFfmpeg;
	return unless $ffmpeg;

	my $current = $Slim::Player::TranscodingHelper::binaries{ffmpeg};

	if (!$current || (defined $ownFfmpegBinary && $current eq $ownFfmpegBinary)) {
		$Slim::Player::TranscodingHelper::binaries{ffmpeg} = $ffmpeg;
		$ownFfmpegBinary = $ffmpeg;
	}

	return $ffmpeg;
}

sub _resolveFfmpeg {
	my $class = shift;

	my $ffmpeg;

	if (eval { require Plugins::FFmpeg::Binary; 1 }) {
		my $available = eval { Plugins::FFmpeg::Binary->available() };

		if ($available) {
			$ffmpeg = eval { Plugins::FFmpeg::Binary->ffmpeg() };
		}
	}

	if (!$ffmpeg) {
		my $configured = $prefs->get('ffmpeg');
		$ffmpeg = $configured if defined $configured && $configured ne '';

		if (!$ffmpeg) {
			$ffmpeg = eval { Slim::Utils::Misc::findbin('ffmpeg') };
		}
	}

	return $ffmpeg;
}

1;

__END__

=head1 NAME

Plugins::PlayVideo::Plugin - Lyrion Music Server PlayVideo plugin

=head1 DESCRIPTION

Makes the audio tracks of local video files (MP4, MKV, WebM, AVI, ...)
available in the Lyrion Music Server library and player menus.

The plugin registers the fallback tag readers, installs the external
decoder priority hook, registers the TrackInfo/CLI additions and adds a
I<Videos> node below I<My Music>.

ffmpeg/ffprobe are used for scanning and as the decoding fallback for
codecs which LMS cannot decode natively (AC3, E-AC3, DTS, TrueHD, ...).

=cut
