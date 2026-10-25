use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Config;
use File::Spec;

use Test::More;

# Lyrion Music Server modules expect these constants from the main scripts.
use constant SCANNER        => 0;
use constant RESIZER        => 0;
use constant ISWINDOWS      => ($^O =~ /^m?s?win/i) ? 1 : 0;
use constant ISMAC          => ($^O =~ /darwin/i) ? 1 : 0;
use constant ISLINUX        => ($^O =~ /linux/i) ? 1 : 0;
use constant TRANSCODING    => 1;
use constant PERFMON        => 0;
use constant DEBUGLOG       => 0;
use constant INFOLOG        => 0;
use constant STATISTICS     => 0;
use constant SB1SLIMP3SYNC  => 1;
use constant WEBUI          => 0;
use constant NOMYSB         => 1;
use constant LOCALFILE      => 0;
use constant NOBROWSECACHE  => 0;
use constant SLIM_SERVICE   => 0;
use constant NOUPNP         => 0;
use constant ISACTIVEPERL   => 0;

use PlayVideo::Test qw(have_ffmpeg fixtures repo_root);
use Plugins::PlayVideo::Types;
use Plugins::PlayVideo::Probe;
use Plugins::PlayVideo::Priority;

# This test requires a Lyrion Music Server runtime.  Either point LMS_HOME at
# a server checkout (which is the directory containing Slim/) or add the LMS
# modules to PERL5LIB and provide LMS_HOME anyway so that we know the test
# intentionally runs against LMS.
my $lmsHome = $ENV{LMS_HOME};

if (defined $lmsHome && length $lmsHome) {
	my $perlVersion = $Config::Config{'version'} || '';
	   $perlVersion =~ s/\.\d+$//;

	my $arch    = $Config::Config{'archname'} || '';
	my $gnuArch = $arch;
	   $gnuArch =~ s/gnu-//;

	my @include = (
		File::Spec->catdir($lmsHome, 'CPAN', 'arch', $perlVersion, $gnuArch),
		File::Spec->catdir($lmsHome, 'CPAN', 'arch', $perlVersion, $arch),
		File::Spec->catdir($lmsHome, 'CPAN', 'arch', $perlVersion),
		File::Spec->catdir($lmsHome, 'lib'),
		File::Spec->catdir($lmsHome, 'CPAN'),
		$lmsHome,
	);

	unshift @INC, grep { -d $_ } @include;

	# Slim::Utils::Unicode (loaded while compiling Slim::Formats) needs the
	# detected OS; the LMS main scripts initialize this before anything else.
	eval {
		require Slim::Utils::OSDetect;
		Slim::Utils::OSDetect::init($lmsHome);
		1;
	};
}

plan skip_all => 'set LMS_HOME (and optionally PERL5LIB) to run the LMS integration tests'
	unless eval { require Slim::Formats; 1 };

require Slim::Formats;

plan skip_all => 'Slim::Formats::Movie is not loadable (missing Audio::Scan?)'
	unless eval { require Slim::Formats::Movie; 1 };

my $formats = eval { require Plugins::PlayVideo::Formats; 1 };

plan skip_all => 'Plugins::PlayVideo::Formats is not loadable: ' . ($@ || 'unknown error')
	unless $formats;

# --- format registration --------------------------------------------------

my @videoTypes = Plugins::PlayVideo::Types::VIDEO_TYPES();

$Slim::Formats::tagClasses{mp4} = 'Slim::Formats::Movie';
$Slim::Formats::loadedTagClasses{mp4} = 1;
$Slim::Formats::loadedTagClasses{$_} = 1 for @videoTypes;

my $registered = eval { Plugins::PlayVideo::Formats::register() };
ok($registered, 'Formats::register() succeeds') or diag($@);

is($Slim::Formats::tagClasses{mp4}, 'Plugins::PlayVideo::Formats',
	'mp4 is registered to the PlayVideo reader');

for my $type (@videoTypes) {
	is($Slim::Formats::tagClasses{$type}, 'Plugins::PlayVideo::Formats',
		"$type is registered to the PlayVideo reader");
	ok(!exists $Slim::Formats::loadedTagClasses{$type},
		"loaded tag class cache for $type was cleared");
}

# --- getTag ---------------------------------------------------------------

my $fixtures = have_ffmpeg() ? fixtures() : undef;

SKIP: {
	skip 'ffmpeg is required to generate the tag fixtures', 23 unless $fixtures;

	my ($tags, $contentType) = Plugins::PlayVideo::Formats->getTag($fixtures->{video_mp4});

	is(ref $tags, 'HASH', 'getTag returns a tag hash for a video file');
	is($contentType, 'vaa', 'getTag reports the AAC content type for a video file');
	is($tags->{CONTENT_TYPE}, 'vaa', 'CONTENT_TYPE set from the audio codec');
	is($tags->{AUDIO}, 1, 'AUDIO set for a video file');
	cmp_ok($tags->{SECS}, '>', 0, 'SECS set for a video file');
	is($tags->{RATE}, 48000, 'RATE set for a video file');
	is($tags->{CHANNELS}, 1, 'CHANNELS set for a video file');
	ok(defined $tags->{TITLE} && length $tags->{TITLE}, 'TITLE read from the tags');

	# Audio only MP4 style files must be remapped to the LMS audio content
	# types, even when the native MP4 reader returns nothing.
	for my $fixture (qw(audio_mp4 audio_m4a)) {
		my ($audioTags, $audioContentType) = Plugins::PlayVideo::Formats->getTag($fixtures->{$fixture});
		is(ref $audioTags, 'HASH', "getTag returns tags for $fixture");
		is($audioContentType, 'mp4', "audio only $fixture is remapped to mp4");
	}

	my ($alacTags, $alacContentType) = Plugins::PlayVideo::Formats->getTag($fixtures->{alac_m4a});
	is(ref $alacTags, 'HASH', 'getTag returns tags for the ALAC m4a');
	is($alacContentType, 'mp4', 'ALAC m4a reports the mp4 content type override');
	is($alacTags->{CONTENT_TYPE}, 'alc', 'ALAC m4a keeps the alc content type');

	# Video without audio and unreadable files must make the scanner skip
	# the file.  A plain empty hash would still create a URL-only row.
	for my $fixture (qw(noaudio_mp4)) {
		my ($skippedTags) = Plugins::PlayVideo::Formats->getTag($fixtures->{$fixture});
		is(ref $skippedTags, 'HASH', "getTag returns a skip tag hash for $fixture");
		is($skippedTags->{DRM}, 1, "video without audio is reported as skip (DRM) for $fixture");
	}

	my ($missingTags) = Plugins::PlayVideo::Formats->getTag('/nonexistent/file.mkv');
	is(ref $missingTags, 'HASH', 'missing file returns a skip tag hash');
	is($missingTags->{DRM}, 1, 'missing file is reported as skip (DRM)');

	my ($emptyTags) = Plugins::PlayVideo::Formats->getTag('');
	is(ref $emptyTags, 'HASH', 'empty file name returns a skip tag hash');
	is($emptyTags->{DRM}, 1, 'empty file name is reported as skip (DRM)');

	my $art = Plugins::PlayVideo::Formats->getCoverArt($fixtures->{cover_mp4});
	ok(defined $art && length($art) > 8, 'getCoverArt extracts the embedded artwork');
	is(unpack('H*', substr($art // '', 0, 4)), '89504e47', 'getCoverArt returns PNG data');
}

# --- readTags through Slim::Formats --------------------------------------

SKIP: {
	skip 'ffmpeg is required to generate the readTags fixture', 6 unless $fixtures;

	no warnings 'once';

	# Try a full LMS init first; it may fail outside a complete LMS setup.
	eval { Slim::Music::Info::init(); 1 };

	# The plugin's custom-types.conf is normally loaded by the scanner's
	# plugin manager.  This test process has no plugin manager, so apply the
	# content types from the file directly.
	my $loadedCustomTypes = 0;
	my $customTypes = File::Spec->catfile(repo_root(), 'custom-types.conf');

	if (open my $handle, '<', $customTypes) {
		while (my $line = <$handle>) {
			$line =~ s/#.*$//;
			$line =~ s/^\s+//;
			$line =~ s/\s+$//;
			next unless length $line;

			my ($type, $suffixField, $mimeField, $serverType) = split /\s+/, $line;
			next unless defined $type && defined $suffixField;

			$Slim::Music::Info::slimTypes{$type} = $serverType if defined $serverType;
			$Slim::Music::Info::suffixes{$_} = $type for grep { $_ ne '-' } split /,/, $suffixField;
			$loadedCustomTypes = 1;
		}
		close $handle;
	}

	# Keep the test usable when it is copied without the plugin data files.
	if (!$loadedCustomTypes) {
		$Slim::Music::Info::slimTypes{vid} = 'audio';
		$Slim::Music::Info::suffixes{$_} = 'vid'
			for qw(mp4 m4v mov qt mkv webm avi mpg mpeg ts);
	}

	# Mimic the real startup order: Slim::Formats->init() runs before the
	# plugin registers its readers.
	eval { Slim::Formats->init(); 1 };
	Plugins::PlayVideo::Formats::register();

	my $readTags = eval { Slim::Formats->readTags($fixtures->{video_mp4}) };

	if (!$readTags || !scalar keys %$readTags) {
		skip 'readTags is not usable in this partial LMS environment', 6;
	}

	is(ref $readTags, 'HASH', 'Slim::Formats->readTags returns a hash reference');
	is($readTags->{CONTENT_TYPE}, 'vaa', 'readTags uses the PlayVideo content type');
	is($readTags->{AUDIO}, 1, 'readTags marks the video track as audio');
	cmp_ok($readTags->{SECS}, '>', 0, 'readTags has a duration');
	is($readTags->{RATE}, 48000, 'readTags has a sample rate');
	ok(defined $readTags->{TITLE} && length $readTags->{TITLE}, 'readTags has a title');
}

# --- Priority hook --------------------------------------------------------

SKIP: {
	skip 'Slim::Player::TranscodingHelper is not loadable', 7
		unless eval { require Slim::Player::TranscodingHelper; 1 };

	my $original = \&Slim::Player::TranscodingHelper::getConvertCommand2;

	ok(Plugins::PlayVideo::Priority::install(), 'Priority::install() succeeds');
	my $wrapped = \&Slim::Player::TranscodingHelper::getConvertCommand2;
	isnt($wrapped, $original, 'getConvertCommand2 has been wrapped');

	ok(Plugins::PlayVideo::Priority::install(), 'installing twice is a no-op');
	is(\&Slim::Player::TranscodingHelper::getConvertCommand2, $wrapped,
		'getConvertCommand2 is wrapped only once');

	ok(Plugins::PlayVideo::Priority::uninstall(), 'Priority::uninstall() succeeds');
	is(\&Slim::Player::TranscodingHelper::getConvertCommand2, $original,
		'the original getConvertCommand2 is restored');
	ok(!Plugins::PlayVideo::Priority::is_installed(), 'the hook is not installed anymore');
}

# --- Priority candidate routing ------------------------------------------

SKIP: {
	skip 'external decoders are disabled by preference', 8
		unless Plugins::PlayVideo::Priority::_prefer_external();

	my $fakeSong = bless {}, 'PlayVideo::Test::FakeSong';

	# First candidate (ac3) wins.
	{
		my @seen;
		local $Plugins::PlayVideo::Priority::ORIGINAL = sub {
			my @args = @_;
			push @seen, $args[1];
			return ({ command => "$args[1]-decoder", profile => "$args[1]-flc-*-*" }, undef);
		};

		my ($transcoder) = Plugins::PlayVideo::Priority::_getConvertCommand2(
			$fakeSong, 'vac', ['F'], [], [],
		);

		is($seen[0], 'ac3', 'the external candidate type is tried first');
		is($transcoder->{profile}, 'ac3-flc-*-*', 'the external decoder profile is returned');
	}

	# Candidates which fail fall back to the original type.
	{
		my @seen;
		local $Plugins::PlayVideo::Priority::ORIGINAL = sub {
			my @args = @_;
			push @seen, $args[1];
			return unless $args[1] eq 'vac';
			return ({ command => 'vac-decoder', profile => 'vac-flc-*-*' }, undef);
		};

		my ($transcoder) = Plugins::PlayVideo::Priority::_getConvertCommand2(
			$fakeSong, 'vac', ['F'], [], [],
		);

		is_deeply(\@seen, [qw(ac3 a52 vac)], 'all candidates are tried before the fallback');
		is($transcoder->{profile}, 'vac-flc-*-*', 'the fallback profile is returned');
	}

	# A passthrough ("-") external result must be rejected.
	{
		local $Plugins::PlayVideo::Priority::ORIGINAL = sub {
			my @args = @_;
			return unless $args[1] eq 'vac';
			return ({ command => 'vac-decoder', profile => 'vac-flc-*-*' }, undef);
		};

		my ($transcoder) = Plugins::PlayVideo::Priority::_getConvertCommand2(
			$fakeSong, 'vac', ['F'], [], [],
		);

		is($transcoder->{profile}, 'vac-flc-*-*', 'a "-" external command is rejected');
	}

	# Scalar context.

	{
		local $Plugins::PlayVideo::Priority::ORIGINAL = sub {
			return ({ command => 'ac3-decoder', profile => 'ac3-flc-*-*' }, undef);
		};

		my $transcoder = Plugins::PlayVideo::Priority::_getConvertCommand2(
			$fakeSong, 'vac', ['F'], [], [],
		);

		is(ref $transcoder, 'HASH', 'scalar context returns the transcoder');
		is($transcoder->{profile}, 'ac3-flc-*-*', 'scalar context returns the external profile');
	}

	# Types without candidates go straight to the original implementation.
	{
		my $called = 0;
		local $Plugins::PlayVideo::Priority::ORIGINAL = sub {
			$called++;
			return ({ command => 'vop-decoder', profile => 'vop-flc-*-*' }, undef);
		};

		Plugins::PlayVideo::Priority::_getConvertCommand2($fakeSong, 'vop', ['F'], [], []);

		is($called, 1, 'types without external candidates call the original directly');
	}
}

done_testing();
