use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;

use PlayVideo::Test qw(repo_root capture_cmd);
use Plugins::PlayVideo::Types;
use Plugins::PlayVideo::Tags;
use Plugins::PlayVideo::Probe;
use Plugins::PlayVideo::Priority;
use Plugins::PlayVideo::Importer;

my $root = repo_root();

# The pure modules must load without any Lyrion Music Server code.
ok(!$INC{'Slim/Formats.pm'}, 'pure modules do not load Slim::Formats');
ok(!$INC{'Slim/Player/TranscodingHelper.pm'}, 'pure modules do not load the transcoding helper');

can_ok('Plugins::PlayVideo::Types', qw(VIDEO_TYPES is_video_type type_for_codec external_candidates all_video_types_regex));
can_ok('Plugins::PlayVideo::Tags', qw(build));
can_ok('Plugins::PlayVideo::Probe', qw(probe chapters cover status clear_cache last_error));
can_ok('Plugins::PlayVideo::Priority', qw(install uninstall is_installed));
can_ok('Plugins::PlayVideo::Importer', qw(preinitPlugin initPlugin));

# The LMS dependent modules must not be forced in by the pure test run, but
# they must exist.
for my $module (qw(Formats Importer Probe Priority Tags Types)) {
	my $file = "$root/lib/Plugins/PlayVideo/$module.pm";
	ok(-f $file, "$module.pm exists");
}

for my $file (qw(custom-types.conf custom-convert.conf tools/gen-convert-conf.pl)) {
	ok(-f "$root/$file", "$file exists");
}

ok(-x "$root/tools/gen-convert-conf.pl", 'generator is executable');

my ($generatorOut, $generatorErr, $generatorExit) =
	capture_cmd($^X, '-c', "$root/tools/gen-convert-conf.pl");
is($generatorExit, 0, 'generator compiles') or diag($generatorErr);

# custom-types.conf must be parseable by Slim::Music::Info::loadTypesConfig.
my (@typeLines, %suffixes);
if (open my $handle, '<', "$root/custom-types.conf") {
	while (my $line = <$handle>) {
		$line =~ s/#.*$//;
		$line =~ s/^\s+//;
		$line =~ s/\s+$//;
		next unless length $line;

		my ($type, $suffixField, $mimeField, $serverType) = split /\s+/, $line;
		push @typeLines, $line;

		ok(defined $type && defined $suffixField && defined $mimeField && defined $serverType,
			"custom-types.conf line has four columns: $type");
		$suffixes{$_} = $type for split /,/, ($suffixField || '');
	}

	close $handle;
}
else {
	fail("cannot read custom-types.conf: $!");
}

ok(scalar @typeLines >= 10, 'custom-types.conf defines all PlayVideo types');

for my $expected (qw(vid vop vaa vvo vfl vmp vac vae vdt vth)) {
	ok(scalar(grep { $_->[0] eq $expected } map { [split /\s+/] } @typeLines),
		"content type $expected defined");
}

my @requiredSuffixes = qw(
	mp4 m4v mov qt mkv webm avi divx xvid mpg mpeg mpe m2v mp2v ts m2ts mts m2t
	vob ogv 3gp 3g2 3gp2 3gpp flv f4v wmv asf rm rmvb mjpg mjpeg
);
for my $suffix (@requiredSuffixes) {
	is($suffixes{$suffix}, 'vid', "suffix $suffix maps to vid");
}

# The suffix-less types must be declared with "-" so that only the audio
# codec detection inside the reader creates them.
for my $type (qw(vop vaa vvo vfl vmp vac vae vdt vth)) {
	my ($line) = grep { /^\Q$type\E\s/ } @typeLines;
	ok($line && $line =~ /^\Q$type\E\s+-\s+/, "$type has no suffixes");
}

done_testing();
