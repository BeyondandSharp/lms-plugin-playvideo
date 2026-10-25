use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use File::Temp qw(tempdir);
use Time::HiRes qw(time);

use Test::More;

use PlayVideo::Test qw(have_ffmpeg find_binary);
use Plugins::PlayVideo::Probe;

my $fixtures = have_ffmpeg() ? PlayVideo::Test::fixtures() : undef;

plan skip_all => 'ffmpeg and ffprobe are required for the probe tests'
	unless $fixtures;

my $ffprobe = find_binary('ffprobe');

# --- binary resolution and status -----------------------------------------

my $status = Plugins::PlayVideo::Probe::status();
is(ref $status, 'HASH', 'status() returns a hash reference');
ok($status->{ok}, 'ffmpeg and ffprobe are available');
is($status->{ffprobe}, $ffprobe, 'ffprobe resolved from PATH');
is($status->{source}, 'system', 'binaries resolved from the system');
like($status->{version} || '', qr/\d+\.\d+/, 'ffprobe version reported');
ok(!defined $status->{error}, 'no status error');

# --- probe of a video with an audio track ---------------------------------

Plugins::PlayVideo::Probe::clear_cache();

my $probe = Plugins::PlayVideo::Probe::probe($fixtures->{video_mp4});
ok($probe, 'probe() of a video file succeeds') or diag(Plugins::PlayVideo::Probe::last_error());

is(ref $probe->{format}, 'HASH', 'format section is a hash reference');
like($probe->{format}{format_name} || '', qr/mp4/i, 'format name detected');
cmp_ok($probe->{format}{duration}, '>', 0, 'duration detected');
cmp_ok($probe->{format}{size}, '>', 0, 'format size detected');
ok(!exists $probe->{format}{filename}, 'format.filename is not requested (invalid UTF-8 safe)');
is($probe->{path}, $fixtures->{video_mp4}, 'path recorded');
cmp_ok($probe->{size}, '>', 0, 'file size recorded');
cmp_ok($probe->{mtime}, '>', 0, 'file mtime recorded');

is(ref $probe->{audio}, 'HASH', 'audio section is a hash reference');
is($probe->{audio}{codec_name}, 'aac', 'audio codec name detected');
is($probe->{audio}{sample_rate}, 48000, 'sample rate detected');
is($probe->{audio}{channels}, 1, 'channels detected');
cmp_ok($probe->{audio}{duration}, '>', 0, 'audio duration detected');

is(ref $probe->{videos}, 'ARRAY', 'videos is an array reference');
is(scalar @{ $probe->{videos} }, 1, 'one video stream detected');
is($probe->{videos}[0]{codec_name}, 'h264', 'video codec name detected');
is($probe->{videos}[0]{width}, 64, 'video width detected');
is($probe->{videos}[0]{height}, 48, 'video height detected');
is(ref $probe->{chapters}, 'ARRAY', 'chapters is an array reference');
is(scalar @{ $probe->{chapters} }, 0, 'no chapters in the simple fixture');
ok(!defined $probe->{attached_pic_index}, 'no attached picture index');

# --- probe of an audio only MP4 file --------------------------------------

my $audioProbe = Plugins::PlayVideo::Probe::probe($fixtures->{audio_mp4});
ok($audioProbe, 'probe() of an audio only MP4 succeeds');
is(scalar @{ $audioProbe->{videos} }, 0, 'no video streams in an audio only MP4');
is($audioProbe->{audio}{codec_name}, 'aac', 'audio codec of the audio only MP4');

# --- chapters -------------------------------------------------------------

my $chapters = Plugins::PlayVideo::Probe::chapters($fixtures->{chaptered_mkv});
is(ref $chapters, 'ARRAY', 'chapters() returns an array reference');
is(scalar @$chapters, 2, 'two chapters detected');
is($chapters->[0]{title}, 'Intro', 'first chapter title');
is($chapters->[1]{title}, 'Main', 'second chapter title');
cmp_ok($chapters->[0]{start}, '==', 0, 'first chapter starts at 0');
cmp_ok($chapters->[0]{end}, '>', $chapters->[0]{start}, 'first chapter has an end');
cmp_ok($chapters->[1]{start}, '>=', $chapters->[0]{end}, 'chapters do not overlap');
cmp_ok($chapters->[1]{end}, '>', $chapters->[1]{start}, 'second chapter has an end');

my $noChapters = Plugins::PlayVideo::Probe::chapters($fixtures->{opus_mkv});
is_deeply($noChapters, [], 'file without chapters returns an empty array reference');

is(Plugins::PlayVideo::Probe::chapters('/nonexistent/file.mkv'), undef,
	'chapters() returns undef for a missing file');

# --- cover art ------------------------------------------------------------

my $cover = Plugins::PlayVideo::Probe::cover($fixtures->{cover_mp4});
ok(defined $cover && length $cover > 8, 'cover() extracts the attached picture');
is(unpack('H*', substr($cover, 0, 8)), '89504e470d0a1a0a', 'extracted cover is a PNG');

is(Plugins::PlayVideo::Probe::cover($fixtures->{audio_mp4}), undef,
	'cover() returns undef without embedded artwork');

# --- caching --------------------------------------------------------------

my $cachedA = Plugins::PlayVideo::Probe::probe($fixtures->{video_mp4});
my $cachedB = Plugins::PlayVideo::Probe::probe($fixtures->{video_mp4});
is($cachedA, $cachedB, 'probe() result is cached in process');

my $uncached = Plugins::PlayVideo::Probe::probe($fixtures->{video_mp4}, cache => 0);
isnt($cachedA, $uncached, 'cache => 0 bypasses the cache');

Plugins::PlayVideo::Probe::clear_cache();
my $afterClear = Plugins::PlayVideo::Probe::probe($fixtures->{video_mp4});
isnt($cachedA, $afterClear, 'clear_cache() empties the cache');

# --- attribute based (method) call style ----------------------------------

my $methodProbe = Plugins::PlayVideo::Probe->probe($fixtures->{audio_m4a});
ok($methodProbe && ref $methodProbe eq 'HASH', 'probe can be called as a class method');
my $methodStatus = Plugins::PlayVideo::Probe->status();
ok($methodStatus && ref $methodStatus eq 'HASH', 'status can be called as a class method');
my $methodChapters = Plugins::PlayVideo::Probe->chapters($fixtures->{chaptered_mkv});
is(scalar @$methodChapters, 2, 'chapters can be called as a class method');

# --- invalid UTF-8 filename ----------------------------------------------

my $badProbe = Plugins::PlayVideo::Probe::probe($fixtures->{bad_utf8_mp4});
ok($badProbe, 'probe() handles a filename with invalid UTF-8 bytes')
	or diag(Plugins::PlayVideo::Probe::last_error());
is($badProbe->{audio}{codec_name}, 'aac', 'audio detected for the invalid UTF-8 filename');
ok(!exists $badProbe->{format}{filename}, 'no filename in the probe result');

# --- missing file ---------------------------------------------------------

is(Plugins::PlayVideo::Probe::probe('/nonexistent/file.mkv'), undef,
	'probe() returns undef for a missing file');
like(Plugins::PlayVideo::Probe::last_error() || '', qr/stat/i, 'last_error() explains the failure');

# --- timeout --------------------------------------------------------------

SKIP: {
	my $directory = tempdir(CLEANUP => 1);
	my $slow = "$directory/slow-ffprobe";

	open my $handle, '>', $slow or skip 'cannot create the fake ffprobe script', 3;
	print $handle "#!/bin/sh\nexec sleep 30\n";
	close $handle;
	chmod 0755, $slow or skip 'cannot make the fake ffprobe executable', 3;

	my $started = time;
	my $timedOut = Plugins::PlayVideo::Probe::probe(
		$fixtures->{video_mp4},
		cache   => 0,
		ffprobe => $slow,
		timeout => 1,
	);
	my $elapsed = time - $started;

	ok(!defined $timedOut, 'probe() returns undef on timeout');
	cmp_ok($elapsed, '<', 10, 'the ffprobe call is killed after the timeout');
	like(Plugins::PlayVideo::Probe::last_error() || '', qr/timeout/i, 'last_error() reports the timeout');
}

# --- optional large reference file ---------------------------------------

SKIP: {
	my $reference = $ENV{PLAYVIDEO_REF};

	skip 'set PLAYVIDEO_REF to test the large reference file', 8
		unless defined $reference && length $reference;

	my $refProbe = Plugins::PlayVideo::Probe::probe($reference);
	ok($refProbe, 'probe() of the reference file succeeds')
		or diag(Plugins::PlayVideo::Probe::last_error());

	is($refProbe->{audio}{codec_name}, 'opus', 'reference audio codec is opus');
	is($refProbe->{audio}{sample_rate}, 48000, 'reference sample rate');
	is($refProbe->{audio}{channels}, 2, 'reference channels');
	cmp_ok($refProbe->{format}{duration}, '>', 800, 'reference duration');
	is(scalar @{ $refProbe->{chapters} }, 2, 'reference chapters');
	ok(defined $refProbe->{chapters}[0]{title}, 'reference chapter has a title');
	is($refProbe->{videos}[0]{width}, 1280, 'reference video width');
}

done_testing();
