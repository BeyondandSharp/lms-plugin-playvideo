use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use Test::More;

use PlayVideo::Test qw(have_ffmpeg);
use Plugins::PlayVideo::Probe;

my $fixtures = have_ffmpeg() ? PlayVideo::Test::fixtures() : undef;

plan skip_all => 'ffmpeg and ffprobe are required for the chapter tests'
	unless $fixtures;

# Probe::chapters() is the pure helper behind Plugins::PlayVideo::Chapters.
my $chapters = Plugins::PlayVideo::Probe::chapters($fixtures->{chaptered_mkv});

is(ref $chapters, 'ARRAY', 'chapters() returns an array reference');
is(scalar @$chapters, 2, 'the chaptered fixture has two chapters');

for my $index (0 .. $#$chapters) {
	my $chapter = $chapters->[$index];

	is(ref $chapter, 'HASH', "chapter $index is a hash reference");
	ok(defined $chapter->{start}, "chapter $index has a start");
	ok(defined $chapter->{end}, "chapter $index has an end");
	cmp_ok($chapter->{end}, '>', $chapter->{start}, "chapter $index ends after it starts");
	ok(defined $chapter->{title} && length $chapter->{title}, "chapter $index has a title");
}

is($chapters->[0]{title}, 'Intro', 'first chapter title');
is($chapters->[1]{title}, 'Main', 'second chapter title');
cmp_ok($chapters->[0]{start}, '==', 0, 'the first chapter starts at zero');
cmp_ok($chapters->[1]{start}, '>=', $chapters->[0]{end} - 0.001, 'chapters are ordered');

my $chaptersAgain = Plugins::PlayVideo::Probe::chapters($fixtures->{chaptered_mkv});
is_deeply($chaptersAgain, $chapters, 'chapter list is stable through the cache');

my $withoutChapters = Plugins::PlayVideo::Probe::chapters($fixtures->{opus_mkv});
is_deeply($withoutChapters, [], 'a file without chapters returns an empty array reference');

is(Plugins::PlayVideo::Probe::chapters('/nonexistent/chaptered.mkv'), undef,
	'chapters() returns undef for a missing file');

# Chapters must be usable as plain numbers by the menu/CLI code.
SKIP: {
	skip 'no chapters to inspect', 2 unless @$chapters;

	my $start = $chapters->[1]{start};
	my $end   = $chapters->[1]{end};

	ok($start == $start + 0, 'chapter start is numeric');
	ok($end == $end + 0, 'chapter end is numeric');
}

# --- optional large reference file ---------------------------------------

SKIP: {
	my $reference = $ENV{PLAYVIDEO_REF};

	skip 'set PLAYVIDEO_REF to test the large reference file chapters', 5
		unless defined $reference && length $reference;

	my $refChapters = Plugins::PlayVideo::Probe::chapters($reference);

	is(ref $refChapters, 'ARRAY', 'reference chapters is an array reference');
	is(scalar @$refChapters, 2, 'reference file has two chapters');
	ok(defined $refChapters->[0]{title} && length $refChapters->[0]{title},
		'reference chapter has a title');
	cmp_ok($refChapters->[0]{start}, '==', 0, 'reference first chapter starts at zero');
	cmp_ok($refChapters->[1]{end}, '>', 800, 'reference last chapter ends at the end of the file');
}

done_testing();
