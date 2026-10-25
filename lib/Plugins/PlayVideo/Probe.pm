package Plugins::PlayVideo::Probe;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use warnings;

use IO::Select;
use IPC::Open3 qw(open3);
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);
use Time::HiRes qw(time sleep);

my $DEFAULT_TIMEOUT = 20;
my $MAX_TIMEOUT     = 600;
my $MAX_JSON_BYTES  = 32 * 1024 * 1024;
my $MAX_ERR_BYTES   = 4 * 1024 * 1024;
my $CACHE_MAX       = 512;

my %CACHE;
my %VERSION_CACHE;
my $LAST_ERROR;

my %MP4_EXTENSION = map { $_ => 1 } qw(mp4 m4a m4b m4p m4r);

# ffprobe entries.  format.filename is intentionally not requested: the
# filename may contain bytes which are not valid UTF-8 for the current
# locale and would then break JSON decoding.  All paths handled by the
# plugin come from LMS, so the probe result does not need it anyway.
my $ENTRIES = join ':',
	'format=format_name,format_long_name,duration,size,bit_rate',
	'format_tags',
	'stream=index,codec_type,codec_name,profile,width,height,sample_rate,channels,channel_layout,bit_rate,bits_per_raw_sample,duration,avg_frame_rate,r_frame_rate',
	'stream_disposition=attached_pic',
	'stream_tags',
	'chapter=start_time,end_time',
	'chapter_tags';

my $ENTRIES_NO_TAGS = join ':',
	'format=format_name,format_long_name,duration,size,bit_rate',
	'stream=index,codec_type,codec_name,profile,width,height,sample_rate,channels,channel_layout,bit_rate,bits_per_raw_sample,duration,avg_frame_rate,r_frame_rate',
	'stream_disposition=attached_pic',
	'chapter=start_time,end_time';

=head2 probe( $path, %opts )

Probe a local media file and return a normalized hash reference or undef on
failure.  The result is cached in process, keyed by path, file size and
modification time.

Options:

=over 4

=item timeout

Timeout in seconds for the ffprobe call (default: plugin.playvideo
C<probeTimeout> preference, or 20).

=item cache

Set to a false value to bypass the in-process cache.

=item ffprobe / ffmpeg

Explicit binary paths, bypassing binary resolution.  Used by the unit tests.

=back

=cut

sub probe {
	my ($path, %opts) = _strip_class(@_);

	return undef unless defined $path && length $path;

	my @stat = stat($path);
	unless (@stat) {
		$LAST_ERROR = "cannot stat [$path]";
		return undef;
	}

	my $key = join "\0", $path, $stat[9], $stat[7];

	if (!exists $opts{cache} || $opts{cache}) {
		return $CACHE{$key} if $CACHE{$key};
	}

	my $res = _resolve(%opts);
	my $ffprobe = $res->{ffprobe};

	unless (_usable($ffprobe)) {
		$LAST_ERROR = 'ffprobe not found';
		return undef;
	}

	my $timeout = _timeout(%opts);

	my ($json, undef, $error) = _run_ffprobe($ffprobe, $path, $timeout, 0);

	if (!defined $json) {
		$LAST_ERROR = "ffprobe failed for [$path]: " . ($error || 'unknown error');
		return undef;
	}

	my ($data, $decodeError) = _decode_json($json);

	if (!$data) {
		# Some files contain tags with invalid encoding.  Retry without
		# requesting any tags; the technical stream information is always
		# the important part for playback.
		($json, undef, $error) = _run_ffprobe($ffprobe, $path, $timeout, 1);
		if (!defined $json) {
			$LAST_ERROR = "ffprobe failed for [$path]: " . ($error || 'unknown error');
			return undef;
		}
		($data, $decodeError) = _decode_json($json);
		unless ($data) {
			$LAST_ERROR = "cannot decode ffprobe output for [$path]: " . ($decodeError || 'unknown error');
			return undef;
		}
	}

	my $probe = _normalize($data, $path);
	$probe->{mtime} = $stat[9];
	$probe->{size}  = $stat[7];

	_store_cache($key, $probe);

	return $probe;
}

=head2 chapters( $path, %opts )

Returns an array reference with the chapters of the given file (or undef on
probe failure).  Each chapter is a hash with C<start>, C<end> and C<title>.

=cut

sub chapters {
	my ($path, %opts) = _strip_class(@_);

	my $probe = probe($path, %opts);
	return undef unless $probe;

	return $probe->{chapters} || [];
}

=head2 cover( $path, %opts )

Extract the embedded cover art of a local file.  For MP4 style containers
C<Slim::Formats::Movie> (Audio::Scan) is tried first when available, then
the attached picture stream is extracted with ffmpeg (without decoding
video).  Returns the raw image bytes or undef.

=cut

sub cover {
	my ($path, %opts) = _strip_class(@_);

	return undef unless defined $path && length $path;
	return undef unless -e $path;

	my $suffix = _extension($path);

	if ($MP4_EXTENSION{$suffix}) {
		my $art = eval {
			require Slim::Formats::Movie;
			Slim::Formats::Movie->getCoverArt($path);
		};
		return $art if defined $art && length $art;
	}

	my $probe = probe($path, %opts);
	return undef unless $probe;

	my $index = $probe->{attached_pic_index};
	return undef unless defined $index;

	my $res = _resolve(%opts);
	my $ffmpeg = $res->{ffmpeg};
	return undef unless _usable($ffmpeg);

	my @args = (
		'-hide_banner',
		'-loglevel', 'error',
		'-nostdin',
		'-i', $path,
		'-map', "0:$index",
		'-c', 'copy',
		'-f', 'image2pipe',
		'-',
	);

	my ($out, undef, $error) = _run($ffmpeg, \@args, _timeout(%opts));

	unless (defined $out && length $out) {
		$LAST_ERROR = "cover extraction failed for [$path]: " . ($error || 'no output');
		return undef;
	}

	return $out;
}

=head2 status()

Returns information about the resolved ffmpeg/ffprobe binaries:

	{ ffmpeg, ffprobe, source, version, ffmpeg_version, ok, error }

=cut

sub status {
	my %opts = _strip_class(@_);

	my $res = _resolve(%opts);

	my @missing = grep { !_usable($res->{$_}) } qw(ffmpeg ffprobe);

	my $version       = _usable($res->{ffprobe}) ? _version($res->{ffprobe}) : undef;
	my $ffmpegVersion = _usable($res->{ffmpeg})  ? _version($res->{ffmpeg})  : undef;

	return {
		ffmpeg         => $res->{ffmpeg},
		ffprobe        => $res->{ffprobe},
		source         => $res->{source},
		version        => $version,
		ffmpeg_version => $ffmpegVersion,
		ok             => @missing ? 0 : 1,
		error          => @missing ? 'missing binary: ' . join(', ', @missing) : undef,
	};
}

=head2 clear_cache()

Drop the in-process probe cache (and cached binary versions).

=cut

sub clear_cache {
	%CACHE         = ();
	%VERSION_CACHE = ();
	$LAST_ERROR    = undef;
	return 1;
}

=head2 last_error()

Last error message recorded by probe/cover/status, or undef.

=cut

sub last_error {
	return $LAST_ERROR;
}


# Accept both function calls (probe($path)) and method calls
# (Plugins::PlayVideo::Probe->probe($path)) for the public API.
sub _strip_class {
	return @_ unless @_ && defined $_[0] && !ref $_[0] && $_[0] eq __PACKAGE__;

	my @copy = @_;
	shift @copy;

	return @copy;
}

sub _store_cache {
	my ($key, $probe) = @_;

	$CACHE{$key} = $probe;

	if (scalar keys %CACHE > $CACHE_MAX) {
		%CACHE = ();
		$CACHE{$key} = $probe;
	}

	return;
}

sub _extension {
	my $path = shift;

	return '' unless defined $path && length $path;

	# Do not use File::Basename::fileparse() without a suffix list: without
	# it the extension is not split off.
	return lc($1) if $path =~ /\.([^.\\\/]+)$/;

	return '';
}

sub _normalize {
	my ($data, $path) = @_;

	my $format = $data->{format} || {};

	my $probe = {
		path => $path,
		format => {
			format_name => _scalar($format->{format_name}),
			format_long_name => _scalar($format->{format_long_name}),
			duration    => _number($format->{duration}),
			size        => _integer($format->{size}),
			bit_rate    => _integer($format->{bit_rate}),
			tags        => _normalize_tags($format->{tags}),
		},
		videos   => [],
		chapters => [],
		attached_pic_index => undef,
	};

	my $audio;

	for my $stream (@{ $data->{streams} || [] }) {
		my $type = $stream->{codec_type} || '';

		if ($type eq 'audio') {
			# Use the first audio stream, like LMS does for its own
			# metadata readers.
			$audio ||= _normalize_audio($stream);
		}
		elsif ($type eq 'video') {
			my $attached = $stream->{disposition} && $stream->{disposition}{attached_pic};

			if ($attached) {
				$probe->{attached_pic_index} = $stream->{index}
					unless defined $probe->{attached_pic_index};
			}
			else {
				push @{ $probe->{videos} }, _normalize_video($stream);
			}
		}
	}

	$probe->{audio} = $audio if $audio;

	for my $chapter (@{ $data->{chapters} || [] }) {
		my $start = _number($chapter->{start_time});
		my $end   = _number($chapter->{end_time});

		push @{ $probe->{chapters} }, {
			start => $start,
			end   => $end,
			title => _chapter_title($chapter->{tags}),
		};
	}

	return $probe;
}

sub _normalize_audio {
	my $stream = shift;

	return {
		index               => _integer($stream->{index}),
		codec_name          => _scalar($stream->{codec_name}),
		profile             => _scalar($stream->{profile}),
		sample_rate         => _integer($stream->{sample_rate}),
		channels            => _integer($stream->{channels}),
		channel_layout      => _scalar($stream->{channel_layout}),
		bit_rate            => _integer($stream->{bit_rate}),
		bits_per_raw_sample => _integer($stream->{bits_per_raw_sample}),
		duration            => _number($stream->{duration}),
		tags                => _normalize_tags($stream->{tags}),
	};
}

sub _normalize_video {
	my $stream = shift;

	return {
		index         => _integer($stream->{index}),
		codec_name    => _scalar($stream->{codec_name}),
		profile       => _scalar($stream->{profile}),
		width         => _integer($stream->{width}),
		height        => _integer($stream->{height}),
		avg_frame_rate => _scalar($stream->{avg_frame_rate}),
		r_frame_rate   => _scalar($stream->{r_frame_rate}),
		duration      => _number($stream->{duration}),
		tags          => _normalize_tags($stream->{tags}),
	};
}

sub _normalize_tags {
	my $tags = shift;

	return {} unless $tags && ref $tags eq 'HASH';

	my %result;
	for my $key (keys %$tags) {
		my $value = $tags->{$key};
		next unless defined $value;
		next if ref $value;
		$result{$key} = $value;
	}

	return \%result;
}

sub _chapter_title {
	my $tags = shift;

	return undef unless $tags && ref $tags eq 'HASH';

	for my $key (keys %$tags) {
		next unless $key =~ /^title$/i;
		my $value = $tags->{$key};
		return $value if defined $value && !ref $value && length $value;
	}

	return undef;
}

sub _run_ffprobe {
	my ($ffprobe, $path, $timeout, $noTags) = @_;

	my @args = (
		'-v', 'error',
		'-hide_banner',
		'-print_format', 'json',
		'-show_entries', $noTags ? $ENTRIES_NO_TAGS : $ENTRIES,
		'-i', $path,
	);

	return _run($ffprobe, \@args, $timeout);
}

sub _decode_json {
	my $buffer = shift;

	my ($data, $error);

	if (eval { require JSON::XS; 1 }) {
		$data = eval { JSON::XS->new->utf8->decode($buffer) };
		$error = $@;
	}

	if (!$data) {
		unless (eval { require JSON::PP; 1 }) {
			return (undef, $error || 'no JSON decoder available');
		}
		$data  = eval { JSON::PP->new->utf8->decode($buffer) };
		$error = $@;
	}

	return (undef, $error) unless $data && ref $data eq 'HASH';

	return ($data, undef);
}

sub _timeout {
	my %opts = @_;

	if (defined $opts{timeout} && $opts{timeout} =~ /^\d+(?:\.\d+)?$/) {
		my $timeout = $opts{timeout} + 0;
		return $timeout if $timeout > 0;
	}

	my $prefs = _plugin_prefs();
	if ($prefs) {
		my $timeout = eval { $prefs->get('probeTimeout') };
		if (defined $timeout && $timeout =~ /^\d+(?:\.\d+)?$/ && $timeout > 0) {
			return $timeout > $MAX_TIMEOUT ? $MAX_TIMEOUT : $timeout;
		}
	}

	return $DEFAULT_TIMEOUT;
}

sub _resolve {
	my %opts = @_;

	my ($ffmpeg, $ffprobe, $source);

	if (defined $opts{ffmpeg} || defined $opts{ffprobe}) {
		$ffmpeg  = $opts{ffmpeg};
		$ffprobe = $opts{ffprobe};
		$source  = 'option' if _usable($ffmpeg) || _usable($ffprobe);
	}

	# 1. The optional generic FFmpeg plugin provides shared binaries.
	if (!_usable($ffmpeg) || !_usable($ffprobe)) {
		if (eval { require Plugins::FFmpeg::Binary; 1 }) {
			my $available = eval {
				Plugins::FFmpeg::Binary->can('available')
					&& Plugins::FFmpeg::Binary->available();
			};

			if ($available) {
				my $pluginFfmpeg  = eval { Plugins::FFmpeg::Binary->ffmpeg() };
				my $pluginFfprobe = eval { Plugins::FFmpeg::Binary->ffprobe() };

				if (_usable($pluginFfmpeg) || _usable($pluginFfprobe)) {
					$ffmpeg  = $pluginFfmpeg  unless _usable($ffmpeg);
					$ffprobe = $pluginFfprobe unless _usable($ffprobe);
					$source  = 'ffmpeg-plugin';
				}
			}
		}
	}

	# 2. PlayVideo's own preferences.
	if (!_usable($ffmpeg) || !_usable($ffprobe)) {
		if (my $prefs = _plugin_prefs()) {
			my $prefFfmpeg  = eval { $prefs->get('ffmpeg') };
			my $prefFfprobe = eval { $prefs->get('ffprobe') };

			if (_usable($prefFfmpeg) || _usable($prefFfprobe)) {
				$ffmpeg  = $prefFfmpeg  if !_usable($ffmpeg)  && _usable($prefFfmpeg);
				$ffprobe = $prefFfprobe if !_usable($ffprobe) && _usable($prefFfprobe);
				$source = 'configured';
			}
		}
	}

	# 3. System binaries (LMS' findbin search path, then PATH).
	if (!_usable($ffmpeg) || !_usable($ffprobe)) {
		$ffmpeg  = _system_binary('ffmpeg')  unless _usable($ffmpeg);
		$ffprobe = _system_binary('ffprobe') unless _usable($ffprobe);
		$source  = 'system' if _usable($ffmpeg) || _usable($ffprobe);
	}

	return {
		ffmpeg  => _usable($ffmpeg)  ? $ffmpeg  : undef,
		ffprobe => _usable($ffprobe) ? $ffprobe : undef,
		source  => $source || 'none',
	};
}

sub _system_binary {
	my $name = shift;

	if ($INC{'Slim/Utils/Misc.pm'} || eval { require Slim::Utils::Misc; 1 }) {
		my $path = eval { Slim::Utils::Misc::findbin($name) };
		return $path if _usable($path);
	}

	return _find_in_path($name);
}

sub _find_in_path {
	my $name = shift;

	my $path = $ENV{PATH};
	return undef unless defined $path && length $path;

	my @names = ($name);
	push @names, "$name.exe" if $^O eq 'MSWin32' && $name !~ /\.\w+$/;

	for my $directory (split /[:;]/, $path) {
		next unless length $directory;
		for my $candidate (@names) {
			my $binary = "$directory/$candidate";
			return $binary if _usable($binary);
		}
	}

	return undef;
}

sub _usable {
	my $binary = shift;

	return 0 unless defined $binary && !ref $binary && length $binary;
	return 0 unless -f $binary;
	return 0 unless -x $binary;

	return 1;
}

sub _version {
	my $binary = shift;

	return undef unless _usable($binary);

	my @stat = stat($binary);
	my $key  = join "\0", $binary, $stat[9] // 0, $stat[7] // 0;

	return $VERSION_CACHE{$key} if exists $VERSION_CACHE{$key};

	my ($out) = _run($binary, ['-version'], 5);

	my $version;
	if (defined $out) {
		if ($out =~ /version\s+(\S+)/i) {
			$version = $1;
		}
		elsif ($out =~ /^(\S+)/) {
			$version = $1;
		}
	}

	$VERSION_CACHE{$key} = $version;

	return $version;
}

sub _plugin_prefs {
	return undef unless $INC{'Slim/Utils/Prefs.pm'} || eval { require Slim::Utils::Prefs; 1 };

	return eval { Slim::Utils::Prefs::preferences('plugin.playvideo') };
}

# Run a program with a timeout, without a shell (list form open3).  Returns
# ($stdout, $stderr, $error).  On timeout or failure stdout is undef.
sub _run {
	my ($binary, $args, $timeout) = @_;

	$timeout = $DEFAULT_TIMEOUT unless defined $timeout && $timeout > 0;

	my ($in, $out);
	my $err = gensym();
	my $pid = eval { open3($in, $out, $err, $binary, @$args) };

	unless ($pid) {
		return (undef, undef, 'cannot execute [' . ($binary // '') . ']: ' . ($@ || 'unknown error'));
	}

	# ffprobe does not read stdin.
	close $in;

	my $selector = IO::Select->new($out, $err);
	my ($stdout, $stderr) = ('', '');

	my $deadline = time + $timeout;
	my $timedout = 0;
	my $reaped   = 0;

	while (1) {
		my $remaining = $deadline - time;

		if ($remaining <= 0) {
			$timedout = 1;
			last;
		}

		my @ready = $selector->can_read($remaining > 0.25 ? 0.25 : $remaining);

		for my $handle (@ready) {
			my $bytes = sysread($handle, my $buffer, 65536);

			if (!defined $bytes) {
				next if $!{EINTR};
				$selector->remove($handle);
				next;
			}

			if ($bytes == 0) {
				$selector->remove($handle);
				next;
			}

			if ($handle == $out) {
				$stdout .= $buffer if length($stdout) < $MAX_JSON_BYTES;
			}
			else {
				$stderr .= $buffer if length($stderr) < $MAX_ERR_BYTES;
			}
		}

		last unless $selector->count;
	}

	if ($timedout) {
		kill 'TERM', $pid;
		for (1 .. 50) {
			if (waitpid($pid, WNOHANG) == $pid) {
				$reaped = 1;
				last;
			}
			sleep 0.01;
		}
		if (!$reaped) {
			kill 'KILL', $pid;
			waitpid($pid, 0);
		}
		close $out;
		close $err;
		return (undef, $stderr, "timeout after $timeout seconds");
	}

	waitpid($pid, 0);
	my $status = $?;
	close $out;
	close $err;

	if ($status == -1) {
		return (undef, $stderr, 'cannot wait for child process');
	}

	my $exitCode = $status >> 8;
	my $signal   = $status & 127;

	if ($signal) {
		return (undef, $stderr, "terminated by signal $signal");
	}

	if ($exitCode) {
		return (undef, $stderr, "exited with code $exitCode");
	}

	return ($stdout, $stderr, undef);
}

sub _scalar {
	my $value = shift;

	return undef unless defined $value && !ref $value;

	$value = "$value";
	$value =~ s/\s+$//;

	return length $value ? $value : undef;
}

sub _number {
	my $value = shift;

	return undef unless defined $value && !ref $value;
	return undef unless $value =~ /^\s*-?\d+(?:\.\d+)?\s*$/;

	return 0 + $value;
}

sub _integer {
	my $value = shift;

	return undef unless defined $value && !ref $value;
	return undef unless $value =~ /^\s*-?\d+\s*$/;

	return int($value);
}

1;

__END__

=head1 NAME

Plugins::PlayVideo::Probe - ffprobe based metadata reader for PlayVideo

=head1 DESCRIPTION

Wraps C<ffprobe> using a list form C<IPC::Open3> call with a timeout and
without a shell, so that any filename (including non UTF-8 ones) is passed
through unchanged.  Only container and stream headers are read, video data
is never decoded.

Binary resolution order:

=over 4

=item 1. C<Plugins::FFmpeg::Binary> when that module is loadable and has
binaries available

=item 2. the C<plugin.playvideo> preferences C<ffmpeg>/C<ffprobe>

=item 3. system binaries found via C<Slim::Utils::Misc::findbin>, then PATH

=back

=cut
