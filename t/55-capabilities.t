use strict;
use warnings;

# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

# Verify the pure codec capability declaration of
# Plugins::PlayVideo::Types::codec_capabilities and its thin Plugin.pm
# delegation.  This test deliberately loads no Lyrion Music Server module:
# the declaration must be cheap, static and usable standalone.

use FindBin;
use lib "$FindBin::Bin/../lib";

use File::Basename qw(dirname);
use File::Spec;
use Test::More;

use Plugins::PlayVideo::Types qw(VIDEO_TYPES codec_capabilities);

my $root = File::Spec->rel2abs(File::Spec->catdir($FindBin::Bin, '..'));

sub slurp {
	my $file = shift;

	open my $handle, '<', $file or return undef;
	local $/;
	my $content = <$handle>;
	close $handle;

	return $content;
}

my @expectedTypes = qw(vid vop vaa vvo vfl vmp vac vae vdt vth);

# ---------------------------------------------------------------------------
# pure Perl: the capability declaration must not drag in LMS
# ---------------------------------------------------------------------------
is_deeply([VIDEO_TYPES()], \@expectedTypes, 'VIDEO_TYPES returns the ten content types');

ok(!$INC{'Slim/Utils/Prefs.pm'}, 'loading Types does not load Slim::Utils::Prefs');
ok(!$INC{'Slim/Player/TranscodingHelper.pm'}, 'loading Types does not load the transcoding helper');
ok(!$INC{'Slim/Utils/Log.pm'}, 'loading Types does not load the LMS logger');

# ---------------------------------------------------------------------------
# provider and priority
# ---------------------------------------------------------------------------
can_ok('Plugins::PlayVideo::Types', 'codec_capabilities');

my $preferred = codec_capabilities(1);
my $fallback  = codec_capabilities(0);

is(ref $preferred, 'HASH', 'codec_capabilities returns a hash reference');
is($preferred->{provider}, 'playvideo', 'provider is playvideo');
is($preferred->{priority}, 150, 'priority is 150 when external decoders are preferred');
is($fallback->{provider}, 'playvideo', 'provider is playvideo with external decoders off');
is($fallback->{priority}, 1, 'priority is 1 when external decoders are not preferred');

is(codec_capabilities()->{priority}, 150,
	'the default (no argument) assumes external decoders are preferred');
is(Plugins::PlayVideo::Types::codec_capabilities(0)->{priority}, 1,
	'function form accepts the preference argument');
is(Plugins::PlayVideo::Types->codec_capabilities(0)->{priority}, 1,
	'class method form accepts the preference argument');

# Lower numbers win in the competing providers' ordering (CodecSwitch):
# with external decoders preferred PlayVideo declares 150, i.e. after the
# FFmpeg plugin (100); with the preference off it declares 1 and wins.
cmp_ok($fallback->{priority}, '<', $preferred->{priority},
	'external decoder preference lowers the declared priority');

# ---------------------------------------------------------------------------
# decode edge: every content type can be decoded to PCM or FLAC
# ---------------------------------------------------------------------------
is(ref $preferred->{decode}, 'ARRAY', 'decode is an array reference');
is(scalar @{ $preferred->{decode} }, 1, 'exactly one decode edge');

my $decode = $preferred->{decode}[0];

is(ref $decode, 'HASH', 'decode edge is a hash reference');
is_deeply($decode->{from}, \@expectedTypes, 'decode sources are all ten content types');
is_deeply($decode->{to}, [qw(pcm flc)], 'decode targets are pcm and flc');
is_deeply($decode->{scope}, [qw(local remote)], 'decode scope is local and remote');

# ---------------------------------------------------------------------------
# convert edge: every content type can be converted to all output formats
# ---------------------------------------------------------------------------
is(ref $preferred->{convert}, 'ARRAY', 'convert is an array reference');
is(scalar @{ $preferred->{convert} }, 1, 'exactly one convert edge');

my $convert = $preferred->{convert}[0];

is(ref $convert, 'HASH', 'convert edge is a hash reference');
is_deeply($convert->{from}, \@expectedTypes, 'convert sources are all ten content types');
is_deeply($convert->{to}, [qw(flc mp3 pcm aac ogg ops)],
	'convert targets are flc, mp3, pcm, aac, ogg and ops');
is_deeply($convert->{scope}, [qw(local remote)], 'convert scope is local and remote');

# ---------------------------------------------------------------------------
# bitrate targets: the targets honouring the B (Maximum Bitrate) capability
# ---------------------------------------------------------------------------
is(ref $preferred->{bitrate}, 'ARRAY', 'bitrate is an array reference');
is_deeply($preferred->{bitrate}, [qw(mp3 aac ogg ops)],
	'bitrate targets are mp3, aac, ogg and ops');
is_deeply($fallback->{bitrate}, [qw(mp3 aac ogg ops)],
	'bitrate targets do not depend on the provider priority');
ok(!grep({ $_ eq 'flc' } @{ $preferred->{bitrate} }), 'the lossless FLAC target is not a bitrate target');
ok(!grep({ $_ eq 'pcm' } @{ $preferred->{bitrate} }), 'the PCM target is not a bitrate target');

# ---------------------------------------------------------------------------
# consistency with the generated custom-convert.conf
# ---------------------------------------------------------------------------
my $conf = slurp(File::Spec->catfile($root, 'custom-convert.conf'));
ok(defined $conf && length $conf, 'custom-convert.conf is readable');

my (%confSources, %confOutputs, %pairs);
my $profileCount = 0;

for my $line (split /\n/, defined $conf ? $conf : '') {
	next if $line =~ /^\s*#/;
	next if $line =~ /^\s*$/;
	next unless $line =~ /^(\S+)\s+(\S+)\s+\*\s+\*\s*$/;

	my ($source, $output) = ($1, $2);
	$confSources{$source} = 1;
	$confOutputs{$output} = 1;
	$pairs{"$source $output"}++;
	$profileCount++;
}
$profileCount = int($profileCount / 2);

is_deeply([sort keys %confSources], [sort @expectedTypes],
	'the profiles use exactly the ten declared content types');
is_deeply([sort keys %confOutputs], [sort @{ $convert->{to} }],
	'the profile output formats match the declared convert targets');
is(scalar keys %pairs, 60, 'the profiles define 60 source/output pairs');
is($profileCount, 60, 'the profiles form 60 file/remote pairs');

for my $input (@expectedTypes) {
	for my $output (@{ $convert->{to} }) {
		ok($pairs{"$input $output"}, "profile pair $input->$output is declared and present");
		is($pairs{"$input $output"}, 2, "profile pair $input->$output has F and R profiles");
	}
}

# The decode declaration targets must also correspond to real profiles.
for my $target (@{ $decode->{to} }) {
	ok($confOutputs{$target}, "decode target $target has conversion profiles");
}

# ---------------------------------------------------------------------------
# independent copies: callers cannot corrupt the declaration
# ---------------------------------------------------------------------------
push @{ $preferred->{convert}[0]{to} }, 'bogus';
push @{ $preferred->{decode}[0]{from} }, 'bogus';
push @{ $preferred->{bitrate} }, 'bogus';

my $again = codec_capabilities(1);

is_deeply($again->{convert}[0]{to}, [qw(flc mp3 pcm aac ogg ops)],
	'each call returns an independent convert target list');
is_deeply($again->{decode}[0]{from}, \@expectedTypes,
	'each call returns an independent decode source list');
is_deeply($again->{bitrate}, [qw(mp3 aac ogg ops)],
	'each call returns an independent bitrate target list');

# ---------------------------------------------------------------------------
# Plugin.pm delegation: thin wrapper reading the preference
# ---------------------------------------------------------------------------
my $plugin = slurp(File::Spec->catfile($root, 'lib', 'Plugins', 'PlayVideo', 'Plugin.pm')) // '';

like($plugin, qr/sub\s+codec_capabilities\b/, 'Plugin.pm implements codec_capabilities');
like($plugin, qr/Plugins::PlayVideo::Types::codec_capabilities/,
	'Plugin.pm delegates to Types::codec_capabilities');
like($plugin, qr/\$prefs->get\('preferExternalDecoders'\)/,
	'Plugin.pm reads the preferExternalDecoders preference');
like($plugin, qr/use\s+Plugins::PlayVideo::Types/,
	'Plugin.pm loads the pure Types module');

done_testing();
