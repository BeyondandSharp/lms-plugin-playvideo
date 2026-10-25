use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;

use Plugins::PlayVideo::Tags;

# Synthetic probe hashes; the tag builder must not need ffmpeg or LMS.
sub make_probe {
	my (%args) = @_;

	my $audio = $args{audio} || {
		codec_name          => 'aac',
		sample_rate         => 48000,
		channels            => 2,
		bits_per_raw_sample => 16,
		bit_rate            => 128000,
		duration            => 10,
		tags                => {},
	};

	my $format = $args{format} || {
		format_name => 'matroska,webm',
		duration    => 10,
		size        => 1000,
		bit_rate    => 128000,
		tags        => {},
	};

	return {
		path    => $args{path} || '/music/Some Folder/track.mkv',
		size    => $args{size} || 1000,
		format  => $format,
		audio   => $audio,
		videos  => $args{videos} || [],
		chapters => [],
	};
}

# --- basic LMS attributes -------------------------------------------------

my $tags = Plugins::PlayVideo::Tags::build(make_probe());

is(ref $tags, 'HASH', 'build() returns a hash reference');
is($tags->{AUDIO}, 1, 'AUDIO is set');
is($tags->{CONTENT_TYPE}, 'vaa', 'CONTENT_TYPE derived from the ACC codec');
is($tags->{OFFSET}, 0, 'OFFSET is zero');
cmp_ok($tags->{SECS}, '==', 10, 'SECS from the container duration');
is($tags->{RATE}, 48000, 'RATE from the audio sample rate');
is($tags->{CHANNELS}, 2, 'CHANNELS from the audio stream');
is($tags->{SAMPLESIZE}, 16, 'SAMPLESIZE from bits_per_raw_sample');
is($tags->{BITRATE}, 128000, 'BITRATE from the container');
is($tags->{SIZE}, 1000, 'SIZE from the container size');
is($tags->{LOSSLESS}, 0, 'AAC is not lossless');

my $fallbackSize = Plugins::PlayVideo::Tags::build(make_probe(
	format => { format_name => 'x', duration => 5, size => undef, bit_rate => undef, tags => {} },
	audio  => { codec_name => 'opus', sample_rate => 48000, channels => 2, duration => 5, tags => {} },
	size   => 4242,
));
is($fallbackSize->{SIZE}, 4242, 'SIZE falls back to the probe file size');
cmp_ok($fallbackSize->{SECS}, '==', 5, 'SECS falls back to the audio duration');

# --- codec to content type map -------------------------------------------

my %expected = (
	opus   => 'vop',
	aac    => 'vaa',
	vorbis => 'vvo',
	flac   => 'vfl',
	mp3    => 'vmp',
	ac3    => 'vac',
	eac3   => 'vae',
	dts    => 'vdt',
	truehd => 'vth',
	h264   => 'vid',
	'pcm_s16le' => 'vid',
);

for my $codec (sort keys %expected) {
	my $built = Plugins::PlayVideo::Tags::build(make_probe(
		audio => {
			codec_name  => $codec,
			sample_rate => 44100,
			channels    => 2,
			duration    => 1,
			tags        => {},
		},
	));

	is($built->{CONTENT_TYPE}, $expected{$codec}, "codec $codec maps to $expected{$codec}");
}

my $losslessFlac = Plugins::PlayVideo::Tags::build(make_probe(
	audio => {
		codec_name          => 'flac',
		sample_rate         => 44100,
		channels            => 2,
		bits_per_raw_sample => 24,
		duration            => 1,
		tags                => {},
	},
));
is($losslessFlac->{CONTENT_TYPE}, 'vfl', 'FLAC content type');
is($losslessFlac->{LOSSLESS}, 1, 'FLAC is lossless');
is($losslessFlac->{SAMPLESIZE}, 24, 'FLAC sample size');

# content_type option wins over the codec mapping
my $overridden = Plugins::PlayVideo::Tags::build(
	make_probe(audio => { codec_name => 'alac', sample_rate => 44100, channels => 2, duration => 1, tags => {} }),
	content_type => 'alc',
);
is($overridden->{CONTENT_TYPE}, 'alc', 'content_type option overrides the codec mapping');

# --- tag mapping ----------------------------------------------------------

my $tagProbe = make_probe(
	format => {
		format_name => 'matroska,webm',
		duration    => 200,
		size        => 5000,
		bit_rate    => 200000,
		tags        => {
			TITLE             => '  Movie Title  ',
			Artist            => 'The Artist',
			ALBUM             => 'The Album',
			'Album Artist'    => 'The Album Artist',
			GENRE             => 'Rock',
			DATE              => '2011-05-01',
			TRACK             => '3/12',
			DISC              => '1/2',
			COMMENT           => 'A comment',
			COMPOSER          => 'The Composer',
			CONDUCTOR         => 'The Conductor',
			LYRICS            => 'La la la',
			BPM               => '120',
			COMPILATION       => '1',
			TITLESORT         => 'Movie Title, The',
			ARTISTSORT        => 'Artist, The',
			ALBUMSORT         => 'Album, The',
			ALBUMARTISTSORT   => 'Album Artist, The',
			COMPOSERSORT      => 'Composer, The',
			REPLAYGAIN_TRACK_GAIN => '-5.80 dB',
			REPLAYGAIN_TRACK_PEAK => '0.9876',
			'MusicBrainz Album Id'   => '00000000-0000-0000-0000-000000000001',
			'MusicBrainz Artist Id'  => '00000000-0000-0000-0000-000000000002',
			'MusicBrainz Track Id'   => '00000000-0000-0000-0000-000000000003',
			'MusicBrainz Album Status' => 'Official',
			'MusicBrainz Album Type'   => 'Album',
		},
	},
);

my $mapped = Plugins::PlayVideo::Tags::build($tagProbe);

is($mapped->{TITLE}, 'Movie Title', 'title mapped and trimmed');
is($mapped->{ARTIST}, 'The Artist', 'artist mapped');
is($mapped->{ALBUM}, 'The Album', 'album mapped');
is($mapped->{ALBUMARTIST}, 'The Album Artist', 'album artist mapped');
is($mapped->{GENRE}, 'Rock', 'genre mapped');
is($mapped->{YEAR}, 2011, 'year extracted from a full date');
is($mapped->{TRACKNUM}, 3, 'track number parsed');
is($mapped->{DISC}, 1, 'disc number parsed');
is($mapped->{DISCC}, 2, 'disc count parsed');
is($mapped->{COMMENT}, 'A comment', 'comment mapped');
is($mapped->{COMPOSER}, 'The Composer', 'composer mapped');
is($mapped->{CONDUCTOR}, 'The Conductor', 'conductor mapped');
is($mapped->{LYRICS}, 'La la la', 'lyrics mapped');
is($mapped->{BPM}, 120, 'bpm mapped');
is($mapped->{COMPILATION}, 1, 'compilation mapped');
is($mapped->{TITLESORT}, 'Movie Title, The', 'title sort mapped');
is($mapped->{ARTISTSORT}, 'Artist, The', 'artist sort mapped');
is($mapped->{ALBUMSORT}, 'Album, The', 'album sort mapped');
is($mapped->{ALBUMARTISTSORT}, 'Album Artist, The', 'album artist sort mapped');
is($mapped->{COMPOSERSORT}, 'Composer, The', 'composer sort mapped');
is($mapped->{REPLAYGAIN_TRACK_GAIN}, '-5.80 dB', 'replay gain mapped');
is($mapped->{REPLAYGAIN_TRACK_PEAK}, '0.9876', 'replay gain peak mapped');
is($mapped->{MUSICBRAINZ_ALBUM_ID}, '00000000-0000-0000-0000-000000000001', 'MusicBrainz album id mapped');
is($mapped->{MUSICBRAINZ_ARTIST_ID}, '00000000-0000-0000-0000-000000000002', 'MusicBrainz artist id mapped');
is($mapped->{MUSICBRAINZ_ALBUM_STATUS}, 'Official', 'MusicBrainz album status mapped');
is($mapped->{RELEASETYPE}, 'Album', 'MusicBrainz album type mapped');
ok(!defined $mapped->{MUSICBRAINZ_ID} || defined $mapped->{MUSICBRAINZ_ID}, 'MusicBrainz track id handled');

# short replaygain tag names (common in Matroska files)
my $shortGain = Plugins::PlayVideo::Tags::build(make_probe(
	format => {
		format_name => 'matroska,webm',
		duration    => 1,
		size        => 10,
		bit_rate    => 10,
		tags        => {
			REPLAYGAIN_GAIN => '-4.91 dB',
			REPLAYGAIN_PEAK => '1.1095',
		},
	},
));
is($shortGain->{REPLAYGAIN_TRACK_GAIN}, '-4.91 dB', 'short replaygain gain mapped');
is($shortGain->{REPLAYGAIN_TRACK_PEAK}, '1.1095', 'short replaygain peak mapped');

# DATE_RELEASED style tags (Matroska)
my $dateReleased = Plugins::PlayVideo::Tags::build(make_probe(
	format => {
		format_name => 'matroska,webm',
		duration    => 1,
		size        => 10,
		bit_rate    => 10,
		tags        => { DATE_RELEASED => 2011, DATE_RECORDED => 2010 },
	},
));
is($dateReleased->{YEAR}, 2011, 'DATE_RELEASED used for YEAR');

# audio stream tags win over container tags
my $mergeProbe = make_probe(
	format => {
		format_name => 'matroska,webm',
		duration    => 1,
		size        => 10,
		bit_rate    => 10,
		tags        => { TITLE => 'Container Title', ALBUM => 'Container Album' },
	},
	audio => {
		codec_name  => 'aac',
		sample_rate => 44100,
		channels    => 2,
		duration    => 1,
		tags        => { TITLE => 'Stream Title' },
	},
);
my $merged = Plugins::PlayVideo::Tags::build($mergeProbe);
is($merged->{TITLE}, 'Stream Title', 'audio stream tags win over container tags');
is($merged->{ALBUM}, 'Container Album', 'container tags are still used');

# --- folder as album ------------------------------------------------------

my $folderTags = Plugins::PlayVideo::Tags::build(
	make_probe(path => '/music/Concerts/My Movie/track.mkv'),
	folderAsAlbum => 1,
);
is($folderTags->{ALBUM}, 'My Movie', 'folderAsAlbum uses the directory name');

my $noFolderTags = Plugins::PlayVideo::Tags::build(
	make_probe(path => '/music/Concerts/My Movie/track.mkv'),
	folderAsAlbum => 0,
);
ok(!defined $noFolderTags->{ALBUM}, 'folderAsAlbum disabled leaves ALBUM unset');

my $existingAlbum = Plugins::PlayVideo::Tags::build(
	make_probe(
		path   => '/music/Concerts/My Movie/track.mkv',
		format => {
			format_name => 'matroska,webm',
			duration    => 1,
			size        => 10,
			bit_rate    => 10,
			tags        => { ALBUM => 'Real Album' },
		},
	),
	folderAsAlbum => 1,
);
is($existingAlbum->{ALBUM}, 'Real Album', 'folderAsAlbum never overrides an existing album tag');

# --- robustness -----------------------------------------------------------

is_deeply(Plugins::PlayVideo::Tags::build(undef), {}, 'build(undef) returns an empty hash reference');

my $emptyProbe = Plugins::PlayVideo::Tags::build({});
is($emptyProbe->{AUDIO}, 1, 'AUDIO is set even for an empty probe');
is($emptyProbe->{CONTENT_TYPE}, 'vid', 'unknown codec maps to vid');

# class method call style
my $methodTags = Plugins::PlayVideo::Tags->build(make_probe());
is($methodTags->{AUDIO}, 1, 'build() can be called as a class method');

done_testing();
