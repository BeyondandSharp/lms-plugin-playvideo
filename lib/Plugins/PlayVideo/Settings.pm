package Plugins::PlayVideo::Settings;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::PlayVideo::Probe;
use Plugins::PlayVideo::Types;

my $log  = logger('plugin.playvideo');
my $prefs = preferences('plugin.playvideo');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_PLAYVIDEO_SETTINGS');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/PlayVideo/settings.html');
}

sub prefs {
	return ($prefs, qw(
		ffmpeg
		ffprobe
		folderAsAlbum
		probeTimeout
		showVideoInfo
		enableChapters
		preferExternalDecoders
	));
}

sub handler {
	my ($class, $client, $params, @args) = @_;

	# HTML checkboxes only submit a value when they are checked.  Normalise
	# the boolean prefs before the base class stores them, so that unchecking
	# a default-on option really stores 0 instead of undef.
	if ($params->{saveSettings}) {
		for my $pref (qw(folderAsAlbum showVideoInfo enableChapters preferExternalDecoders)) {
			$params->{"pref_$pref"} = $params->{"pref_$pref"} ? 1 : 0;
		}
	}

	return $class->SUPER::handler($client, $params, @args);
}

sub beforeRender {
	my ($class, $params, $client) = @_;

	$params->{probe}         = _probeStatus();
	$params->{ffmpegPlugin}  = _ffmpegPluginStatus();
	$params->{decoders}      = _decoderStatus();
	$params->{capabilities}  = _capabilityStatus();

	return;
}

# Read-only summary of the declaration returned by
# Plugins::PlayVideo::Types::codec_capabilities.  It is not a preference: the
# value follows the preferExternalDecoders preference (no new setting).
sub _capabilityStatus {
	my $prefer = eval { $prefs->get('preferExternalDecoders') };
	$prefer = 1 unless defined $prefer;

	my $caps = eval { Plugins::PlayVideo::Types::codec_capabilities($prefer ? 1 : 0) };
	$caps = {} unless ref $caps eq 'HASH';

	my @outputs;
	for my $edge (@{ $caps->{convert} || [] }) {
		next unless ref $edge eq 'HASH' && ref $edge->{to} eq 'ARRAY';
		push @outputs, @{ $edge->{to} };
	}

	my @decode;
	for my $edge (@{ $caps->{decode} || [] }) {
		next unless ref $edge eq 'HASH' && ref $edge->{to} eq 'ARRAY';
		push @decode, @{ $edge->{to} };
	}

	my $bitrate = ref $caps->{bitrate} eq 'ARRAY' ? $caps->{bitrate} : [];

	@outputs = _dedupe(@outputs);
	@decode  = _dedupe(@decode);
	my @bitrateTargets = _dedupe(@$bitrate);

	return {
		provider    => defined $caps->{provider} ? "$caps->{provider}" : '',
		priority    => defined $caps->{priority} ? "$caps->{priority}" : '',
		outputs     => [@outputs],
		decode      => [@decode],
		bitrate     => [@bitrateTargets],
		outputsText => join(', ', @outputs),
		bitrateText => join(', ', @bitrateTargets),
		decodeText  => join(', ', @decode),
	};
}

sub _dedupe {
	my %seen;
	return grep { defined $_ && !$seen{$_}++ } @_;
}

sub _probeStatus {
	my $status = eval { Plugins::PlayVideo::Probe->status() };

	$status = {} unless ref $status eq 'HASH';

	return {
		ffmpeg       => defined $status->{ffmpeg}  ? "$status->{ffmpeg}"  : '',
		ffprobe      => defined $status->{ffprobe} ? "$status->{ffprobe}" : '',
		version        => defined $status->{version} ? "$status->{version}" : '',
		ffmpegVersion  => defined $status->{ffmpeg_version} ? "$status->{ffmpeg_version}" : '',
		sourceRaw    => defined $status->{source}  ? "$status->{source}"  : '',
		sourceLabel  => _sourceLabel($status->{source}),
		ok           => $status->{ok} ? 1 : 0,
		error        => defined $status->{error} ? "$status->{error}" : '',
	};
}

sub _sourceLabel {
	my $source = shift;

	return string('PLUGIN_PLAYVIDEO_SOURCE_NONE') unless defined $source && length $source;

	$source = lc $source;

	return string('PLUGIN_PLAYVIDEO_SOURCE_FFMPEG_PLUGIN') if $source =~ /plugin/;
	return string('PLUGIN_PLAYVIDEO_SOURCE_CONFIGURED')     if $source =~ /configured|pref/;
	return string('PLUGIN_PLAYVIDEO_SOURCE_SYSTEM')         if $source =~ /system|path|findbin/;
	return string('PLUGIN_PLAYVIDEO_SOURCE_NONE')           if $source =~ /none|missing/;

	return $source;
}

sub _ffmpegPluginStatus {
	my $info = {
		installed => 0,
		enabled   => 0,
		available => 0,
		ffmpeg    => '',
		ffprobe   => '',
		version   => '',
		error     => '',
	};

	return $info unless eval { require Plugins::FFmpeg::Binary; 1 };

	$info->{installed} = 1;

	$info->{enabled} = eval {
		Slim::Utils::PluginManager->isEnabled('Plugins::FFmpeg::Plugin')
	} ? 1 : 0;

	$info->{available} = eval { Plugins::FFmpeg::Binary->available() } ? 1 : 0;

	if ($info->{available}) {
		my $status = eval { Plugins::FFmpeg::Binary->status() };

		if (ref $status eq 'HASH') {
			$info->{ffmpeg}  = defined $status->{ffmpeg}  ? "$status->{ffmpeg}"  : '';
			$info->{ffprobe} = defined $status->{ffprobe} ? "$status->{ffprobe}" : '';
			$info->{version} = defined $status->{version} ? "$status->{version}" : '';
			$info->{error}   = defined $status->{error}   ? "$status->{error}"   : '';
		}
	}

	return $info;
}

sub _decoderStatus {
	my @decoders;

	for my $name (qw(sox faad flac lame)) {
		my $path = eval { Slim::Utils::Misc::findbin($name) };

		$path = '' unless defined $path;

		push @decoders, {
			name      => $name,
			path      => $path,
			available => $path ne '' ? 1 : 0,
		};
	}

	return \@decoders;
}

1;

__END__

=head1 NAME

Plugins::PlayVideo::Settings - settings page for the PlayVideo plugin

=head1 DESCRIPTION

Renders the PlayVideo settings page.  Besides the normal preferences the
page shows the resolved ffmpeg/ffprobe binaries, whether the optional FFmpeg
plugin is installed and the availability of the LMS decoder helper binaries
(sox, faad, flac, lame) used by the PlayVideo conversion profiles.

=cut
