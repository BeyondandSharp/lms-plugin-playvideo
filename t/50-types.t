use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;

use Plugins::PlayVideo::Types;

my @videoTypes = Plugins::PlayVideo::Types::VIDEO_TYPES();
is_deeply(
	[@videoTypes],
	[qw(vid vop vaa vvo vfl vmp vac vae vdt vth)],
	'VIDEO_TYPES returns all content types in the documented order',
);

my $videoTypesRef = Plugins::PlayVideo::Types::VIDEO_TYPES();
is(ref $videoTypesRef, 'ARRAY', 'VIDEO_TYPES returns an array reference in scalar context');
is_deeply($videoTypesRef, [@videoTypes], 'scalar and list forms agree');

for my $type (@videoTypes) {
	ok(Plugins::PlayVideo::Types::is_video_type($type), "$type is a video content type");
	ok(Plugins::PlayVideo::Types::is_video_type(uc $type), "$type is recognised case insensitively");
	ok(Plugins::PlayVideo::Types::is_video_type($type) == 1, "$type predicate is a boolean");
}

for my $type (qw(mp3 ogg flac aac mp4 aif wav unk '')) {
	ok(!Plugins::PlayVideo::Types::is_video_type($type), "$type is not a video content type");
}

ok(!Plugins::PlayVideo::Types::is_video_type(undef), 'undef is not a video content type');

my %codecMap = (
	opus   => 'vop',
	aac    => 'vaa',
	vorbis => 'vvo',
	flac   => 'vfl',
	mp3    => 'vmp',
	ac3    => 'vac',
	eac3   => 'vae',
	dts    => 'vdt',
	truehd => 'vth',
);

for my $codec (sort keys %codecMap) {
	is(
		Plugins::PlayVideo::Types::type_for_codec($codec),
		$codecMap{$codec},
		"codec $codec maps to $codecMap{$codec}",
	);
}

for my $codec (qw(h264 hevc vc1 mpeg4 pcm_s16le pcm_s24le wmap a52 alac dca mlp)) {
	is(Plugins::PlayVideo::Types::type_for_codec($codec), 'vid',
		"unknown codec $codec maps to vid");
}

is(Plugins::PlayVideo::Types::type_for_codec('OPUS'), 'vop', 'codec names are case insensitive');
is(Plugins::PlayVideo::Types::type_for_codec('  opus  '), 'vop', 'codec names are trimmed');
is(Plugins::PlayVideo::Types::type_for_codec(undef), 'vid', 'undef codec maps to vid');
is(Plugins::PlayVideo::Types::type_for_codec(''), 'vid', 'empty codec maps to vid');

my %candidates = (
	vac => [qw(ac3 a52)],
	vae => [qw(eac3 ec3 ac3)],
	vdt => [qw(dts dca)],
	vth => [qw(truehd mlp dts)],
);

for my $type (sort keys %candidates) {
	is_deeply(
		Plugins::PlayVideo::Types::external_candidates($type),
		$candidates{$type},
		"external candidates for $type",
	);
}

for my $type (qw(vid vop vaa vvo vfl vmp mp3 ac3 dts truehd unk)) {
	is_deeply(
		Plugins::PlayVideo::Types::external_candidates($type),
		[],
		"no external candidates for $type",
	);
}

is_deeply(Plugins::PlayVideo::Types::external_candidates(undef), [],
	'external_candidates(undef) returns an empty array reference');

# A fresh array reference is returned, so callers cannot corrupt the map.
my $first = Plugins::PlayVideo::Types::external_candidates('vac');
push @$first, 'mutated';
is_deeply(
	Plugins::PlayVideo::Types::external_candidates('vac'),
	[qw(ac3 a52)],
	'external_candidates returns a copy',
);

my $regex = Plugins::PlayVideo::Types::all_video_types_regex();
for my $type (@videoTypes) {
	like($type, $regex, "regex matches $type");
}
ok('mp3' !~ $regex, 'regex does not match audio types');

# Class method call style must be tolerated as well.
is(Plugins::PlayVideo::Types->type_for_codec('opus'), 'vop', 'type_for_codec works as a class method');
ok(Plugins::PlayVideo::Types->is_video_type('vid'), 'is_video_type works as a class method');

done_testing();
