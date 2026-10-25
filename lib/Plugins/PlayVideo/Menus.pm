package Plugins::PlayVideo::Menus;

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
use Time::HiRes qw(time);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring string);

use Plugins::PlayVideo::Chapters;
use Plugins::PlayVideo::Probe;
use Plugins::PlayVideo::Types;

my $log = logger('plugin.playvideo');
my $prefs = preferences('plugin.playvideo');

# Keep menus responsive.  Scanning can produce large libraries; the OPML
# menu only ever shows the first entries and logs when it has to truncate.
my $MAX_FEED_ITEMS = 5000;

my $SEEK_TIMEOUT       = 15;
my $SEEK_POLL_INTERVAL = 0.25;

my $initialized = 0;

sub init {
	return 1 if $initialized;

	$initialized = 1;

	_registerInfoProviders();
	_registerCommands();

	return 1;
}

sub feed {
	my ($client, $cb, $args) = @_;

	my $items = eval { _feedItems($client) };

	if (!$items || ref $items ne 'ARRAY') {
		$log->error('Unable to build the PlayVideo feed: ' . ($@ || 'unknown error'));
		$items = [];
	}

	if (!scalar @$items) {
		$items = [{
			type => 'text',
			name => cstring($client, 'PLUGIN_PLAYVIDEO_NO_VIDEOS'),
		}];
	}

	my $title = cstring($client, 'PLUGIN_PLAYVIDEO');

	$cb->({
		type  => 'opml',
		title => $title,
		name  => $title,
		items => $items,
	}) if $cb;

	return $items;
}

sub _feedItems {
	my $client = shift;

	my @types = _videoTypes();

	return [] unless scalar @types;

	my $rs = eval {
		Slim::Schema->rs('Track')->search(
			{
				'me.content_type' => { -in => \@types },
			},
			{
				order_by => 'me.titlesort',
				rows     => $MAX_FEED_ITEMS + 1,
			},
		);
	};

	if (!$rs) {
		$log->error('Unable to query video tracks: ' . ($@ || 'unknown error'));
		return [];
	}

	my @tracks = eval { $rs->all };

	if ($@) {
		$log->error('Unable to read video tracks: ' . $@);
		return [];
	}

	if (scalar @tracks > $MAX_FEED_ITEMS) {
		$log->warn(sprintf(
			'PlayVideo library contains more than %d video tracks, showing only the first %d in the menu',
			$MAX_FEED_ITEMS,
			$MAX_FEED_ITEMS,
		));

		splice @tracks, $MAX_FEED_ITEMS;
	}

	my @items;

	for my $track (@tracks) {
		my $url = eval { $track->url };

		next unless defined $url && length $url;

		my $title = eval { $track->title };
		$title = eval { $track->name } if !defined $title || $title eq '';
		$title = eval { Slim::Utils::Misc::unescape($url) } if !defined $title || $title eq '';
		$title = $url if !defined $title || $title eq '';

		my $secs  = eval { $track->secs };
		my $cover = _coverForTrack($track);

		push @items, {
			name     => "$title",
			type     => 'audio',
			play     => $url,
			url      => $url,
			cover    => $cover,
			# The Web UI renders "image", the OPML/Jive path uses "cover".
			image    => $cover,
			duration => $secs,
			on_select => 'play',
		};
	}

	return \@items;
}

sub _coverForTrack {
	my $track = shift;

	my $remote = eval { $track->coverurl };

	return $remote if defined $remote && $remote =~ /^https?:/;

	my $id = eval { $track->id };

	return undef unless defined $id && $id;

	return "/music/$id/cover.jpg";
}

sub _registerInfoProviders {
	eval { require Slim::Menu::TrackInfo; 1 }
		or do {
			$log->warn('Slim::Menu::TrackInfo not available, video details menu disabled');
			return;
		};

	eval {
		Slim::Menu::TrackInfo->registerInfoProvider(
			playvideoDetails => (
				after => 'moreinfo',
				func  => \&trackInfoVideoDetails,
			),
		);

		Slim::Menu::TrackInfo->registerInfoProvider(
			playvideoChapters => (
				after => 'moreinfo',
				func  => \&trackInfoChapters,
			),
		);
		1;
	} or $log->error('Unable to register PlayVideo TrackInfo providers: ' . ($@ || 'unknown error'));

	return 1;
}

sub trackInfoVideoDetails {
	my ($client, $url, $track) = @_;

	return undef unless $prefs->get('showVideoInfo');

	return undef unless blessed($track);

	return undef if $track->can('remote') && eval { $track->remote };

	return undef unless _trackIsVideo($track);

	return {
		name         => cstring($client, 'PLUGIN_PLAYVIDEO_VIDEO_DETAILS'),
		url          => \&videoDetailsMenu,
		passthrough  => [ $track->url ],
		isContextMenu => 1,
	};
}

sub trackInfoChapters {
	my ($client, $url, $track) = @_;

	return undef unless $prefs->get('enableChapters');

	return undef unless blessed($track);

	return undef if $track->can('remote') && eval { $track->remote };

	return undef unless _trackIsVideo($track);

	return {
		name         => cstring($client, 'PLUGIN_PLAYVIDEO_CHAPTERS'),
		url          => \&chaptersMenu,
		passthrough  => [ $track->url ],
		isContextMenu => 1,
	};
}

sub videoDetailsMenu {
	my ($client, $cb, $params, $url) = @_;

	$url ||= $params->{url} if ref $params eq 'HASH';

	my $items = [];

	my $path  = _pathForUrl($url);
	my $probe = (defined $path && length $path) ? eval { Plugins::PlayVideo::Probe->probe($path) } : undef;

	if (!$probe || ref $probe ne 'HASH') {
		push @$items, {
			type => 'text',
			name => cstring($client, 'PLUGIN_PLAYVIDEO_PROBE_FAILED'),
		};

		$cb->({ type => 'opml', items => $items }) if $cb;

		return $items;
	}

	my $format = ref $probe->{format} eq 'HASH' ? $probe->{format} : {};

	my $container = _clean($format->{format_long_name});
	$container = _clean($format->{format_name}) if !defined $container || $container eq '';

	push @$items, {
		type  => 'text',
		label => 'PLUGIN_PLAYVIDEO_CONTAINER',
		name  => $container || cstring($client, 'PLUGIN_PLAYVIDEO_UNKNOWN'),
	};

	my $duration = _seconds($format->{duration});
	$duration = _seconds($probe->{audio}->{duration}) if !defined $duration && ref $probe->{audio} eq 'HASH';

	push @$items, {
		type  => 'text',
		label => 'PLUGIN_PLAYVIDEO_DURATION',
		name  => defined $duration ? _formatTime($duration) : cstring($client, 'PLUGIN_PLAYVIDEO_UNKNOWN'),
	} if defined $duration;

	my $videos = _videoStreams($probe);

	if (scalar @$videos) {
		push @$items, {
			type  => 'text',
			label => 'PLUGIN_PLAYVIDEO_VIDEO',
			name  => _videoSummary($client, $videos->[0]),
		};
	}

	my $audio = ref $probe->{audio} eq 'HASH' ? $probe->{audio} : undef;

	if ($audio) {
		push @$items, {
			type  => 'text',
			label => 'PLUGIN_PLAYVIDEO_AUDIO',
			name  => _audioSummary($client, $audio),
		};
	}

	my $size = _bytes($format->{size});
	$size = _bytes($probe->{size}) if !defined $size;

	push @$items, {
		type  => 'text',
		label => 'PLUGIN_PLAYVIDEO_SIZE',
		name  => defined $size ? _formatBytes($size) : cstring($client, 'PLUGIN_PLAYVIDEO_UNKNOWN'),
	} if defined $size;

	if ($prefs->get('enableChapters')) {
		my $count = ref $probe->{chapters} eq 'ARRAY' ? scalar @{ $probe->{chapters} } : 0;

		push @$items, {
			type  => 'text',
			label => 'PLUGIN_PLAYVIDEO_CHAPTERS',
			name  => $count,
		} if $count;
	}

	$cb->({ type => 'opml', items => $items }) if $cb;

	return $items;
}

sub chaptersMenu {
	my ($client, $cb, $params, $url) = @_;

	$url ||= $params->{url} if ref $params eq 'HASH';

	my $chapters = eval { Plugins::PlayVideo::Chapters::get_for_url($url) };

	$chapters = [] unless ref $chapters eq 'ARRAY';

	my @items;

	my $index = 0;

	for my $chapter (@$chapters) {
		next unless ref $chapter eq 'HASH';
		next unless defined $chapter->{start};

		$index++;

		my $label = _chapterLabel($client, $chapter, $index);

		push @items, {
			name         => $label,
			url          => \&seekChapter,
			passthrough  => [ $url, 0 + $chapter->{start}, $label ],
			nextWindow   => 'parent',
		};
	}

	if (!scalar @items) {
		@items = ({
			type => 'text',
			name => cstring($client, 'PLUGIN_PLAYVIDEO_NO_CHAPTERS'),
		});
	}

	$cb->({ type => 'opml', items => \@items }) if $cb;

	return \@items;
}

sub seekChapter {
	my ($client, $cb, $params, $url, $start, $label) = @_;

	my $notice = cstring($client, 'PLUGIN_PLAYVIDEO_SEEK_STARTING', $label || '');

	if (!blessed($client) || !defined $url || !defined $start) {
		$cb->({ type => 'opml', items => [{ name => $notice, showBriefly => 1 }] }) if $cb;
		return;
	}

	$start = 0 + $start;

	if (_isPlayingUrl($client, $url)) {
		eval { Slim::Player::Source::gototime($client, $start) };

		_briefly($client, cstring($client, 'PLUGIN_PLAYVIDEO_SEEK_DONE', $label || ''));

		$cb->({
			type  => 'opml',
			items => [{ name => $notice, showBriefly => 1, nowPlaying => 1 }],
		}) if $cb;

		return;
	}

	eval { $client->execute([ 'playlist', 'play', $url ]) };

	_briefly($client, $notice);

	_pollForSeek($client, $url, $start, $label, time() + $SEEK_TIMEOUT);

	$cb->({
		type  => 'opml',
		items => [{ name => $notice, showBriefly => 1, nowPlaying => 1 }],
	}) if $cb;

	return;
}

sub _pollForSeek {
	my ($client, $url, $start, $label, $deadline) = @_;

	eval {
		Slim::Utils::Timers::setTimer(
			$client,
			time() + $SEEK_POLL_INTERVAL,
			\&_checkSeek,
			$url,
			$start,
			$label,
			$deadline,
		);
		1;
	} or $log->warn('Unable to schedule the PlayVideo chapter seek: ' . ($@ || 'unknown error'));

	return 1;
}

sub _checkSeek {
	my ($client, $url, $start, $label, $deadline) = @_;

	return unless blessed($client);

	if (_isPlayingUrl($client, $url)) {
		eval { Slim::Player::Source::gototime($client, $start) };

		_briefly($client, cstring($client, 'PLUGIN_PLAYVIDEO_SEEK_DONE', $label || ''));

		return;
	}

	if (time() >= $deadline) {
		_briefly($client, cstring($client, 'PLUGIN_PLAYVIDEO_SEEK_TIMEOUT', $label || ''));

		return;
	}

	_pollForSeek($client, $url, $start, $label, $deadline);

	return;
}

sub _isPlayingUrl {
	my ($client, $url) = @_;

	return 0 unless blessed($client) && defined $url;

	my $song = eval { Slim::Player::Source::playingSong($client) };

	return 0 unless $song;

	my $track = eval { $song->currentTrack };

	return 0 unless $track;

	my $current = eval { $track->url };

	return 0 unless defined $current;

	return _urlsMatch($current, $url) ? 1 : 0;
}

sub _urlsMatch {
	my ($left, $right) = @_;

	return 0 unless defined $left && defined $right;

	my $a = _normalizeUrl($left);
	my $b = _normalizeUrl($right);

	return $a eq $b ? 1 : 0;
}

sub _normalizeUrl {
	my $url = shift;

	$url =~ s/#.*$//;

	if (eval { require Slim::Utils::Misc; 1 }) {
		$url = eval { Slim::Utils::Misc::unescape($url) } || $url;
	}

	return $url;
}

sub _briefly {
	my ($client, $message) = @_;

	return unless blessed($client) && defined $message && length $message;

	eval {
		$client->showBriefly(
			{
				line => [ undef, $message ],
				jive => {
					type     => 'popupplay',
					text     => [ $message ],
					duration => 3000,
				},
			},
			{
				firstline => 0,
				duration  => 3,
				scroll    => 1,
			},
		);
		1;
	} or $log->debug('Unable to show PlayVideo feedback: ' . ($@ || 'unknown error'));

	return 1;
}

sub _chapterLabel {
	my ($client, $chapter, $index) = @_;

	my $time  = _formatTime(defined $chapter->{start} ? $chapter->{start} : 0);
	my $title = _clean($chapter->{title});

	if (defined $title && length $title) {
		return cstring($client, 'PLUGIN_PLAYVIDEO_CHAPTER_TITLE', $title, $time);
	}

	return cstring($client, 'PLUGIN_PLAYVIDEO_CHAPTER_NUMBER', $index, $time);
}

sub _registerCommands {
	eval { require Slim::Control::Request; 1 }
		or do {
			$log->warn('Slim::Control::Request not available, PlayVideo CLI commands disabled');
			return;
		};

	eval {
		# JSON-RPC and CLI calls without the CLI query marker.
		Slim::Control::Request::addDispatch([ 'playvideo', 'status' ], [ 0, 1, 0, \&cliStatus ]);
		Slim::Control::Request::addDispatch([ 'playvideo', 'info', '_url' ], [ 0, 1, 0, \&cliInfo ]);
		Slim::Control::Request::addDispatch([ 'playvideo', 'chapters', '_url' ], [ 0, 1, 0, \&cliChapters ]);

		# Classic CLI query form ("playvideo status ?").
		Slim::Control::Request::addDispatch([ 'playvideo', 'status', '?' ], [ 0, 1, 0, \&cliStatus ]);
		Slim::Control::Request::addDispatch([ 'playvideo', 'info', '_url', '?' ], [ 0, 1, 0, \&cliInfo ]);
		Slim::Control::Request::addDispatch([ 'playvideo', 'chapters', '_url', '?' ], [ 0, 1, 0, \&cliChapters ]);
		1;
	} or $log->error('Unable to register PlayVideo CLI commands: ' . ($@ || 'unknown error'));

	return 1;
}

sub cliStatus {
	my $request = shift;

	my $status = eval { Plugins::PlayVideo::Probe->status() };

	$status = {} unless ref $status eq 'HASH';

	my %result = (
		ffmpeg                  => defined $status->{ffmpeg} ? "$status->{ffmpeg}" : '',
		ffprobe                 => defined $status->{ffprobe} ? "$status->{ffprobe}" : '',
		source                  => defined $status->{source} ? "$status->{source}" : '',
		version                 => defined $status->{version} ? "$status->{version}" : '',
		ok                      => $status->{ok} ? 1 : 0,
		error                   => defined $status->{error} ? "$status->{error}" : '',
		chapters_enabled        => $prefs->get('enableChapters') ? 1 : 0,
		show_video_info         => $prefs->get('showVideoInfo') ? 1 : 0,
		prefer_external_decoders => $prefs->get('preferExternalDecoders') ? 1 : 0,
		ffmpeg_plugin           => _ffmpegPluginLoaded() ? 1 : 0,
	);

	my $videoTypes = _videoTypes();

	if (scalar @$videoTypes) {
		my $count = eval {
			Slim::Schema->rs('Track')->search({
				'me.content_type' => { -in => $videoTypes },
			})->count;
		};

		$result{video_count} = defined $count ? 0 + $count : 0;
	}

	$request->addResult($_, $result{$_}) for sort keys %result;

	$request->setStatusDone();

	return;
}

# Accept both positional URLs and the tagged CLI form which arrives as
# "url:<url>" in the positional slot (LMS CLI/JSON-RPC do not strip the tag
# when no tagged parameter is declared for the request).
sub _cliUrl {
	my $request = shift;

	my $url = $request->getParam('_url');
	$url = $request->getParam('url') if !defined $url || $url eq '';

	return undef unless defined $url;

	$url = "$url";
	$url =~ s/^\s+//;
	$url =~ s/\s+$//;
	$url =~ s/^url\s*:\s*//i;

	return length $url ? $url : undef;
}

sub cliInfo {
	my $request = shift;

	my $url = _cliUrl($request);

	if (!defined $url) {
		$request->setStatusBadParams();
		return;
	}

	my $path  = _pathForUrl($url);

	if (!defined $path || !length $path || !-e $path) {
		$request->addResult('error', string('PLUGIN_PLAYVIDEO_NOT_LOCAL_FILE'));
		$request->addResult('url', $url);
		$request->setStatusDone();
		return;
	}

	my $probe = eval { Plugins::PlayVideo::Probe->probe($path) };

	if (!$probe || ref $probe ne 'HASH') {
		$request->addResult('error', string('PLUGIN_PLAYVIDEO_PROBE_FAILED'));
		$request->addResult('url', $url);
		$request->setStatusDone();
		return;
	}

	my $format = ref $probe->{format} eq 'HASH' ? $probe->{format} : {};
	my $audio  = ref $probe->{audio} eq 'HASH' ? $probe->{audio} : {};
	my $videos = _videoStreams($probe);

	my %result = (
		url       => _clean($url),
		container => _clean($format->{format_name}),
	);

	my $duration = _seconds($format->{duration});
	$duration = _seconds($audio->{duration}) if !defined $duration;

	if (defined $duration) {
		$result{duration}      = 0 + $duration;
		$result{duration_text} = _formatTime($duration);
	}

	my $size = _bytes($format->{size});
	$size = _bytes($probe->{size}) if !defined $size;

	if (defined $size) {
		$result{size}      = 0 + $size;
		$result{size_text} = _formatBytes($size);
	}

	if (my $video = $videos->[0]) {
		$result{video_codec} = _clean($video->{codec_name});
		$result{width}       = _number($video->{width});
		$result{height}      = _number($video->{height});
		$result{video_text}  = _videoSummary(undef, $video);
	}

	if (scalar keys %$audio) {
		$result{audio_codec}  = _clean($audio->{codec_name});
		$result{sample_rate}  = _number($audio->{sample_rate});
		$result{channels}     = _number($audio->{channels});
		$result{audio_bitrate} = _number($audio->{bit_rate});

		$result{audio_text} = _audioSummary(undef, $audio);
	}

	$result{chapters} = ref $probe->{chapters} eq 'ARRAY' ? scalar @{ $probe->{chapters} } : 0;

	for my $key (sort keys %result) {
		next unless defined $result{$key};

		$request->addResult($key, $result{$key});
	}

	$request->setStatusDone();

	return;
}

sub cliChapters {
	my $request = shift;

	my $url = _cliUrl($request);

	if (!defined $url) {
		$request->setStatusBadParams();
		return;
	}

	my $chapters = eval { Plugins::PlayVideo::Chapters::get_for_url($url) };

	$chapters = [] unless ref $chapters eq 'ARRAY';

	my $count = 0;

	for my $chapter (@$chapters) {
		next unless ref $chapter eq 'HASH';
		next unless defined $chapter->{start};

		my $title = _clean($chapter->{title});

		$request->addResultLoop('chapters_loop', $count, 'start', 0 + $chapter->{start});
		$request->addResultLoop('chapters_loop', $count, 'start_text', _formatTime($chapter->{start}));
		$request->addResultLoop('chapters_loop', $count, 'end', 0 + $chapter->{end})
			if defined $chapter->{end};
		$request->addResultLoop('chapters_loop', $count, 'title', $title)
			if defined $title && length $title;

		$count++;
	}

	$request->addResult('count', $count);
	$request->addResult('url', _clean($url));

	$request->setStatusDone();

	return;
}

sub _ffmpegPluginLoaded {
	return eval { require Plugins::FFmpeg::Binary; 1 } ? 1 : 0;
}

sub _videoTypes {
	my @types = eval { Plugins::PlayVideo::Types::VIDEO_TYPES() };

	return wantarray ? () : [] unless scalar @types;

	@types = @{ $types[0] } if scalar @types == 1 && ref $types[0] eq 'ARRAY';

	@types = grep { defined $_ && length $_ } @types;

	# Callers use both styles: list context (feed query) and scalar
	# context (status count, regex construction).
	return wantarray ? @types : \@types;
}

sub _videoStreams {
	my $probe = shift;

	my $videos = ref $probe->{videos} eq 'ARRAY' ? $probe->{videos} : [];

	my @streams = grep { ref $_ eq 'HASH' } @$videos;

	# ffprobe reports attached pictures (cover art) as video streams.  Drop
	# the one marked as attached picture, if the probe gave us its index.
	if (defined $probe->{attached_pic_index}) {
		my $attached = $probe->{attached_pic_index};

		@streams = grep {
			!defined $_->{index} || $_->{index} != $attached
		} @streams;
	}

	return \@streams;
}

sub _videoSummary {
	my ($client, $video) = @_;

	return cstring($client, 'PLUGIN_PLAYVIDEO_UNKNOWN') unless ref $video eq 'HASH';

	my $codec = _clean($video->{codec_name});
	my $width = _number($video->{width});
	my $height = _number($video->{height});

	if (defined $codec && defined $width && defined $height) {
		return cstring($client, 'PLUGIN_PLAYVIDEO_VIDEO_STREAM', $codec, $width, $height);
	}

	if (defined $codec) {
		return $codec;
	}

	if (defined $width && defined $height) {
		return cstring($client, 'PLUGIN_PLAYVIDEO_RESOLUTION', $width, $height);
	}

	return cstring($client, 'PLUGIN_PLAYVIDEO_UNKNOWN');
}

sub _audioSummary {
	my ($client, $audio) = @_;

	return cstring($client, 'PLUGIN_PLAYVIDEO_UNKNOWN') unless ref $audio eq 'HASH';

	my @parts;

	my $codec = _clean($audio->{codec_name});
	push @parts, $codec if defined $codec && length $codec;

	my $rate = _number($audio->{sample_rate});
	push @parts, cstring($client, 'PLUGIN_PLAYVIDEO_SAMPLE_RATE_FMT', $rate) if defined $rate;

	my $channels = _number($audio->{channels});
	push @parts, cstring($client, 'PLUGIN_PLAYVIDEO_CHANNELS_FORMAT', $channels) if defined $channels;

	my $bitRate = _number($audio->{bit_rate});
	push @parts, cstring($client, 'PLUGIN_PLAYVIDEO_BITRATE_FORMAT', int($bitRate / 1000)) if defined $bitRate && $bitRate > 0;

	return cstring($client, 'PLUGIN_PLAYVIDEO_UNKNOWN') unless scalar @parts;

	return join(', ', @parts);
}

sub _trackIsVideo {
	my $track = shift;

	my $contentType = eval { $track->content_type };

	if (!defined $contentType || $contentType eq '') {
		$contentType = eval { Slim::Schema->contentType($track) };
	}

	return Plugins::PlayVideo::Types::is_video_type($contentType) ? 1 : 0;
}

sub _pathForUrl {
	my $url = shift;

	return undef unless defined $url && length $url;

	if (blessed($url)) {
		return eval { $url->path };
	}

	my $track = eval { Slim::Schema->objectForUrl({ url => $url }) };

	if (blessed($track) && !( $track->can('remote') && $track->remote )) {
		my $path = eval { $track->path };

		return $path if defined $path && length $path;
	}

	return undef unless eval { Slim::Music::Info::isFileURL($url) };

	return eval { Slim::Utils::Misc::pathFromFileURL($url) };
}

sub _formatTime {
	my $seconds = shift;

	return '' unless defined $seconds && $seconds =~ /^\s*\d+(?:\.\d+)?\s*$/;

	my $total = int($seconds + 0.5);

	my $hours   = int($total / 3600);
	my $minutes = int(($total % 3600) / 60);
	my $secs    = $total % 60;

	return $hours
		? sprintf('%d:%02d:%02d', $hours, $minutes, $secs)
		: sprintf('%d:%02d', $minutes, $secs);
}

sub _formatBytes {
	my $bytes = shift;

	return '' unless defined $bytes && $bytes =~ /^\s*\d+(?:\.\d+)?\s*$/;

	$bytes = 0 + $bytes;

	return sprintf('%.1f GB', $bytes / (1024 ** 3)) if $bytes >= 1024 ** 3;
	return sprintf('%.1f MB', $bytes / (1024 ** 2)) if $bytes >= 1024 ** 2;
	return sprintf('%.1f KB', $bytes / 1024)        if $bytes >= 1024;

	return sprintf('%d B', $bytes);
}

sub _seconds {
	my $value = shift;

	return undef unless defined $value && $value =~ /^\s*-?\d+(?:\.\d+)?\s*$/;

	return 0 + $value;
}

sub _number {
	my $value = shift;

	return undef unless defined $value;

	if (ref $value) {
		return undef;
	}

	return undef unless $value =~ /^\s*-?\d+(?:\.\d+)?\s*$/;

	return 0 + $value;
}

sub _bytes {
	my $value = shift;

	return undef unless defined $value && !ref $value && $value =~ /^\s*\d+\s*$/;

	return 0 + $value;
}

sub _clean {
	my $value = shift;

	return undef unless defined $value;
	return undef if ref $value;

	$value = "$value";
	$value =~ s/[\x00-\x1f\x7f]//g;
	$value =~ s/^\s+//;
	$value =~ s/\s+$//;

	$value = substr($value, 0, 512) if length($value) > 512;

	return $value;
}

1;

__END__

=head1 NAME

Plugins::PlayVideo::Menus - menus, TrackInfo and CLI for the PlayVideo plugin

=head1 DESCRIPTION

Provides the I<Videos> node below I<My Music>, the I<Video details> and
I<Chapters> entries in the track information menu and the following
CLI/JSON-RPC commands:

	playvideo status ?
	playvideo info <url> ?
	playvideo chapters <url> ?

Chapters are exposed as seek targets.  Selecting a chapter seeks in the
currently playing video, or starts the video and seeks once it is playing.

=cut
