package PlayVideo::Test;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# Test helpers for the PlayVideo unit tests.  Keeps the media fixture
# generation in one place and provides small helpers for running external
# commands without a shell.

use strict;
use warnings;

use Exporter 'import';

use File::Basename qw(dirname fileparse);
use File::Copy ();
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

our @EXPORT_OK = qw(
	repo_root
	have_binary
	find_binary
	have_ffmpeg
	fixtures
	capture_cmd
	run_cmd
	shell_quote
);

my $ROOT;

my $FIXTURE_DIR;
my $FIXTURES;

my @FIXTURE_NAMES = qw(
	video_mp4
	audio_m4a
	audio_mp4
	alac_m4a
	opus_mkv
	aac_mkv
	ac3_mkv
	dts_mkv
	flac_mkv
	mp3_mkv
	vorbis_mkv
	chaptered_mkv
	cover_mp4
	noaudio_mp4
	bad_utf8_mp4
);

sub repo_root {
	return $ROOT if $ROOT;

	my $here = dirname(__FILE__);
	$ROOT = File::Spec->rel2abs(File::Spec->catdir($here, '..', '..', '..'));

	return $ROOT;
}

sub find_binary {
	my $name = shift;

	return undef unless defined $name && length $name;

	my @names = ($name);
	push @names, "$name.exe" if $^O eq 'MSWin32' && $name !~ /\.\w+$/;

	for my $directory (split /[:;]/, $ENV{PATH} || '') {
		next unless length $directory;
		for my $candidate (@names) {
			my $path = File::Spec->catfile($directory, $candidate);
			return $path if -f $path && -x $path;
		}
	}

	return undef;
}

sub have_binary {
	my $name = shift;
	return defined find_binary($name) ? 1 : 0;
}

sub have_ffmpeg {
	return have_binary('ffmpeg') && have_binary('ffprobe') ? 1 : 0;
}

sub shell_quote {
	my $value = shift;

	return "''" unless defined $value && length $value;

	$value =~ s/'/'"'"'/g;

	return "'$value'";
}

# Run a command (list form, no shell) and capture stdout/stderr/exit code.
sub capture_cmd {
	my @cmd = @_;

	my ($in, $out);
	my $err = gensym();

	my $pid = eval { open3($in, $out, $err, @cmd) };
	unless ($pid) {
		return (undef, undef, undef, "cannot execute: $@");
	}

	close $in;

	local $/;
	my $stdout = <$out>;
	my $stderr = <$err>;

	waitpid($pid, 0);
	my $status = $?;

	$stdout = '' unless defined $stdout;
	$stderr = '' unless defined $stderr;

	return ($stdout, $stderr, $status >> 8, undef);
}

sub run_cmd {
	my @cmd = @_;

	my ($stdout, $stderr, $exit) = capture_cmd(@cmd);

	unless (defined $exit && $exit == 0) {
		die "Command failed (@cmd): exit=" . ($exit // 'undef') . " stderr=$stderr";
	}

	return $stdout;
}

sub fixtures {
	return $FIXTURES if $FIXTURES;
	return undef unless have_ffmpeg();

	my $directory = $ENV{PLAYVIDEO_TEST_MEDIA}
		|| File::Spec->catdir(File::Spec->tmpdir(), 'playvideo-test-fixtures-v1');

	make_path($directory);

	$FIXTURE_DIR = $directory;

	my $ffmpeg = find_binary('ffmpeg');

	my %paths = map { $_ => File::Spec->catfile($directory, _file_name($_)) } @FIXTURE_NAMES;

	$FIXTURES = \%paths;

	my @builders = (
		video_mp4     => sub { my ($out) = @_; _build_av($ffmpeg, $out, 'aac') },
		audio_m4a     => sub { my ($out) = @_; _build_audio($ffmpeg, $out, 'aac') },
		audio_mp4     => sub { my ($out) = @_; _build_audio($ffmpeg, $out, 'aac') },
		alac_m4a      => sub { my ($out) = @_; _build_audio($ffmpeg, $out, 'alac') },
		opus_mkv      => sub { my ($out) = @_; _build_av($ffmpeg, $out, 'libopus') },
		aac_mkv       => sub { my ($out) = @_; _build_av($ffmpeg, $out, 'aac') },
		ac3_mkv       => sub { my ($out) = @_; _build_av($ffmpeg, $out, 'ac3') },
		dts_mkv       => sub { my ($out) = @_; _build_av($ffmpeg, $out, 'dca', '-strict', '-2') },
		flac_mkv      => sub { my ($out) = @_; _build_av($ffmpeg, $out, 'flac') },
		mp3_mkv       => sub { my ($out) = @_; _build_av($ffmpeg, $out, 'libmp3lame') },
		vorbis_mkv    => sub { my ($out) = @_; _build_av($ffmpeg, $out, 'libvorbis', '-ac', '2', '-strict', '-2') },
		chaptered_mkv => sub { my ($out, $p) = @_; _build_chaptered($ffmpeg, $out, $p->{video_mp4}, $directory) },
		cover_mp4     => sub { my ($out, $p) = @_; _build_cover($ffmpeg, $out, $p->{audio_m4a}, $directory) },
		noaudio_mp4   => sub { my ($out) = @_; _build_noaudio($ffmpeg, $out) },
		bad_utf8_mp4  => sub { my ($out, $p) = @_; _build_bad_utf8($p->{video_mp4}, $out) },
	);

	while (@builders) {
		my ($name, $builder) = splice @builders, 0, 2;
		_ensure($paths{$name}, $builder, \%paths);
	}

	return $FIXTURES;
}

sub _file_name {
	my $name = shift;

	return 'video.mp4'          if $name eq 'video_mp4';
	return 'audio.m4a'          if $name eq 'audio_m4a';
	return 'audio.mp4'          if $name eq 'audio_mp4';
	return 'audio_alac.m4a'     if $name eq 'alac_m4a';
	return 'opus.mkv'           if $name eq 'opus_mkv';
	return 'aac.mkv'            if $name eq 'aac_mkv';
	return 'ac3.mkv'            if $name eq 'ac3_mkv';
	return 'dts.mkv'            if $name eq 'dts_mkv';
	return 'flac.mkv'           if $name eq 'flac_mkv';
	return 'mp3.mkv'            if $name eq 'mp3_mkv';
	return 'vorbis.mkv'         if $name eq 'vorbis_mkv';
	return 'chaptered.mkv'      if $name eq 'chaptered_mkv';
	return 'cover.mp4'          if $name eq 'cover_mp4';
	return 'noaudio.mp4'        if $name eq 'noaudio_mp4';
	return "bad\xff\xfe.mp4"    if $name eq 'bad_utf8_mp4';
	return $name;
}

sub _ensure {
	my ($path, $builder, $paths) = @_;

	return if -s $path;

	my ($base, $directory, $extension) = fileparse($path, qr/\.[^.]*$/);
	my $temporary = File::Spec->catfile($directory, $base . ".$$" . $extension);

	$builder->($temporary, $paths);

	unless (-s $temporary) {
		die "Fixture generation produced no data for $path";
	}

	rename $temporary, $path or die "Cannot rename $temporary to $path: $!";

	return;
}

sub _build_av {
	my ($ffmpeg, $path, $codec, @extra) = @_;

	my @cmd = (
		$ffmpeg, '-y', '-v', 'error',
		'-f', 'lavfi', '-i', 'testsrc=size=64x48:rate=5:duration=1',
		'-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=1',
		'-map', '0:v', '-map', '1:a',
		'-t', '1',
		'-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
		'-c:a', $codec,
		@extra,
		'-metadata', 'title=Test Video',
		'-metadata', 'artist=Test Artist',
		'-metadata', 'album=Test Album',
		'-metadata', 'date=2011-05-01',
		'-metadata', 'genre=Rock',
		'-metadata', 'composer=Test Composer',
		'-metadata', 'comment=Test Comment',
		$path,
	);

	run_cmd(@cmd);

	return;
}

sub _build_audio {
	my ($ffmpeg, $path, $codec) = @_;

	my @cmd = (
		$ffmpeg, '-y', '-v', 'error',
		'-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=1',
		'-t', '1',
		'-c:a', $codec,
		'-metadata', 'title=Audio Title',
		'-metadata', 'artist=Audio Artist',
		$path,
	);

	run_cmd(@cmd);

	return;
}

sub _build_chaptered {
	my ($ffmpeg, $path, $source, $directory) = @_;

	my $meta = File::Spec->catfile($directory, 'chapters.ffmetadata');

	unless (-s $meta) {
		open my $handle, '>', $meta or die "Cannot write $meta: $!";
		print $handle <<'META';
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=600
title=Intro
[CHAPTER]
TIMEBASE=1/1000
START=600
END=1200
title=Main
META
		close $handle;
	}

	run_cmd(
		$ffmpeg, '-y', '-v', 'error',
		'-i', $source,
		'-i', $meta,
		'-map', '0',
		'-map_metadata', '1',
		'-map_chapters', '1',
		'-c', 'copy',
		$path,
	);

	return;
}

sub _build_cover {
	my ($ffmpeg, $path, $audio, $directory) = @_;

	my $png = File::Spec->catfile($directory, 'cover.png');

	unless (-s $png) {
		run_cmd(
			$ffmpeg, '-y', '-v', 'error',
			'-f', 'lavfi', '-i', 'color=c=red:s=32x32:d=1',
			'-frames:v', '1',
			$png,
		);
	}

	run_cmd(
		$ffmpeg, '-y', '-v', 'error',
		'-i', $audio,
		'-i', $png,
		'-map', '0:a',
		'-map', '1:v',
		'-c', 'copy',
		'-disposition:v', 'attached_pic',
		$path,
	);

	return;
}

sub _build_noaudio {
	my ($ffmpeg, $path) = @_;

	run_cmd(
		$ffmpeg, '-y', '-v', 'error',
		'-f', 'lavfi', '-i', 'testsrc=size=64x48:rate=5:duration=1',
		'-t', '1',
		'-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
		'-an',
		$path,
	);

	return;
}

sub _build_bad_utf8 {
	my ($source, $path) = @_;

	File::Copy::copy($source, $path) or die "Cannot copy $source to $path: $!";

	return;
}

1;

__END__

=head1 NAME

PlayVideo::Test - test helpers for the PlayVideo plugin

=head1 DESCRIPTION

Generates small video/audio fixtures with ffmpeg and provides helpers to
run external commands without a shell.  Fixtures are cached in a temporary
directory so that the individual test files do not regenerate them.

=cut
