use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/lib";

use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);

use Test::More;

use PlayVideo::Test qw(repo_root capture_cmd shell_quote have_ffmpeg find_binary fixtures);

my $root      = repo_root();
my $confPath  = File::Spec->catfile($root, 'custom-convert.conf');
my $generator = File::Spec->catfile($root, 'tools', 'gen-convert-conf.pl');

my $conf = read_file($confPath);
ok(defined $conf && length $conf, 'custom-convert.conf is not empty');

# --- generator consistency and idempotency -------------------------------

my ($stdout, $stderr, $exit) = capture_cmd($^X, $generator, '--stdout');
is($exit, 0, 'generator exits successfully') or diag($stderr);
is($stdout, $conf, 'committed custom-convert.conf matches the generator output');

my $temporaryRoot = tempdir(CLEANUP => 1);
make_path(File::Spec->catdir($temporaryRoot, 'tools'));

copy_file($generator, File::Spec->catfile($temporaryRoot, 'tools', 'gen-convert-conf.pl'));

my $temporaryGenerator = File::Spec->catfile($temporaryRoot, 'tools', 'gen-convert-conf.pl');
my $temporaryConf      = File::Spec->catfile($temporaryRoot, 'custom-convert.conf');

my (undef, $runError, $runExit) = capture_cmd($^X, $temporaryGenerator);
is($runExit, 0, 'generator writes the file') or diag($runError);
ok(-f $temporaryConf, 'generated file exists');
is(read_file($temporaryConf), $conf, 'generated file has the expected content');

(undef, $runError, $runExit) = capture_cmd($^X, $temporaryGenerator);
is($runExit, 0, 'generator can run a second time') or diag($runError);
is(read_file($temporaryConf), $conf, 'generator is idempotent');

# --- profile parsing (mirrors the LMS converter config parser) ------------

my @lines = split /\n/, $conf, -1;
my @blocks;

for (my $index = 0; $index < @lines; $index++) {
	my $line = $lines[$index];

	next if $line =~ /^\s*#/;
	next if $line =~ /^\s*$/;

	unless ($line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$/) {
		fail("unexpected custom-convert.conf line: $line");
		next;
	}

	my ($input, $output, $player, $playerId) = ($1, $2, $3, $4);
	my $capabilities = $lines[ ++$index ];
	my $command      = $lines[ ++$index ];

	$capabilities =~ /^\s+#\s+(\S.*?)\s*$/
		or fail("missing capability line for $input-$output");
	my $capabilityText = $1;

	$command =~ /^\s+(\S.*?)\s*$/
		or fail("missing command line for $input-$output");
	my $commandText = $1;

	push @blocks, {
		input        => $input,
		output       => $output,
		player       => $player,
		playerId     => $playerId,
		capabilities => $capabilityText,
		command      => $commandText,
	};
}

is(scalar @blocks, 60, 'custom-convert.conf defines 60 profiles');

my %demux    = map { $_ => 1 } qw(vop vaa vvo vfl vmp);
my %fallback = map { $_ => 1 } qw(vac vae vdt vth vid);

my %seenBase;
my %modes;

for my $block (@blocks) {
	my $label = "$block->{input}->$block->{output}";

	is($block->{player}, '*', "profile $label applies to all players");
	is($block->{playerId}, '*', "profile $label applies to all player ids");

	ok($demux{$block->{input}} || $fallback{$block->{input}},
		"profile $label uses a PlayVideo content type");
	ok($block->{output} =~ /^(?:flc|mp3|pcm)$/, "profile $label output format is supported");

	like(
		$block->{capabilities},
		qr/^([A-Z](:\{[^}]+\})?)+$/,
		"profile $label capability line has valid syntax",
	);

	like($block->{capabilities}, qr/T:\{START=-ss %s\}/,
		"profile $label supports seeking (T)");
	like($block->{capabilities}, qr/U:\{END=-t %w\}/,
		"profile $label supports duration limiting (U)");

	$seenBase{"$block->{input} $block->{output}"}++;
	push @{ $modes{ substr($block->{capabilities}, 0, 1) } }, $label;

	# Every profile has the common ffmpeg prefix.  F profiles use $FILE$,
	# R profiles use $URL$.
	my $mode = substr($block->{capabilities}, 0, 1);
	is($mode =~ /^[FR]$/ ? $mode : 'invalid', $mode, "profile $label has a file or remote mode");

	like(
		$block->{command},
		qr/-hide_banner -loglevel error -nostdin \$START\$ -i \$FILE\$ \$END\$ -vn -sn -dn -map 0:a:0/,
		"profile $label has the local ffmpeg prefix",
	) if $mode eq 'F';
	like(
		$block->{command},
		qr/-hide_banner -loglevel error -nostdin \$START\$ -i \$URL\$ \$END\$ -vn -sn -dn -map 0:a:0/,
		"profile $label has the remote ffmpeg prefix",
	) if $mode eq 'R';

	unlike($block->{command}, qr/\$INPUT\$/, "profile $label has no unexpanded INPUT placeholder");

	# Capability placeholders used by the command must be declared.
	_check_placeholders($block, $label);
}

is(scalar @{ $modes{F} || [] }, 30, '30 file (F) profiles');
is(scalar @{ $modes{R} || [] }, 30, '30 remote (R) profiles');

for my $base (sort keys %seenBase) {
	is($seenBase{$base}, 2, "profile pair $base has exactly one F and one R profile");
}

for my $input (keys %demux, keys %fallback) {
	for my $output (qw(flc mp3 pcm)) {
		ok($seenBase{"$input $output"}, "profile $input $output is defined");
	}
}

# --- expected piped decoders ---------------------------------------------

my %expectedFragments = (
	'vop flc' => ['-c:a copy', '-f ogg', '[sox] -q -t opus', '-t flac'],
	'vop mp3' => ['-c:a copy', '-f ogg', '[sox] -q -t opus', '[lame]'],
	'vop pcm' => ['-c:a copy', '-f ogg', '[sox] -q -t opus', '-t raw'],
	'vaa flc' => ['-c:a copy', '-f adts', '[faad]', '[flac]'],
	'vaa mp3' => ['-c:a copy', '-f adts', '[faad]', '[lame]'],
	'vaa pcm' => ['-c:a copy', '-f adts', '[faad]', '-f 2'],
	'vvo flc' => ['-c:a copy', '-f ogg', '[sox] -q -t ogg', '-t flac'],
	'vvo mp3' => ['-c:a copy', '-f ogg', '[sox] -q -t ogg', '[lame]'],
	'vvo pcm' => ['-c:a copy', '-f ogg', '[sox] -q -t ogg', '-t raw'],
	'vfl flc' => ['-c:a copy', '-f flac'],
	'vfl mp3' => ['-c:a copy', '-f flac', '[flac] -dc', '[lame]'],
	'vfl pcm' => ['-c:a copy', '-f flac', '[flac] -dcs'],
	'vmp flc' => ['-c:a copy', '-f mp3', '[sox] -q -t mp3', '-t flac'],
	'vmp mp3' => ['-c:a copy', '-f mp3'],
	'vmp pcm' => ['-c:a copy', '-f mp3', '[sox] -q -t mp3', '-t raw'],
);

for my $block (@blocks) {
	my $base = "$block->{input} $block->{output}";
	my $fragmentList = $expectedFragments{$base} or next;

	for my $fragment (@$fragmentList) {
		like($block->{command}, qr/\Q$fragment\E/, "profile $base command contains '$fragment'");
	}
}

# --- fallback decoder profiles -------------------------------------------

my %expectedDecode = (
	flc => '-c:a flac -f flac -',
	mp3 => '-c:a libmp3lame',
	pcm => '-c:a pcm_s16le -f s16le -',
);

for my $block (@blocks) {
	my $base = "$block->{input} $block->{output}";
	next unless $fallback{$block->{input}};

	unlike($block->{command}, qr/-c:a copy/, "fallback profile $base does not copy audio");
	like($block->{command}, qr/-ac \$OCHANNELS\$/, "fallback profile $base uses the output channel count");
	like($block->{command}, qr/\Q$expectedDecode{$block->{output}}\E/,
		"fallback profile $base uses the expected encoder");
}

# --- D and B capabilities ------------------------------------------------

my %expectD = (
	'vop flc' => 1, 'vop mp3' => 1, 'vop pcm' => 0,
	'vaa flc' => 0, 'vaa mp3' => 1, 'vaa pcm' => 0,
	'vvo flc' => 1, 'vvo mp3' => 1, 'vvo pcm' => 0,
	'vfl flc' => 0, 'vfl mp3' => 1, 'vfl pcm' => 0,
	'vmp flc' => 1, 'vmp mp3' => 0, 'vmp pcm' => 0,
);
$expectD{$_} = 1 for map { ("$_ flc", "$_ mp3", "$_ pcm") } keys %fallback;

my %expectB;
$expectB{'vop mp3'} = 1;
$expectB{'vaa mp3'} = 1;
$expectB{'vvo mp3'} = 1;
$expectB{'vfl mp3'} = 1;
$expectB{'vmp mp3'} = 0;
$expectB{"$_ mp3"} = 1 for keys %fallback;

for my $block (@blocks) {
	my $base = "$block->{input} $block->{output}";

	my $hasD = $block->{capabilities} =~ /D:\{RESAMPLE=/ ? 1 : 0;
	my $hasB = $block->{capabilities} =~ /B:\{BITRATE=/ ? 1 : 0;

	if ($expectD{$base}) {
		ok($hasD, "profile $base declares the downsampling capability");
	}
	else {
		ok(!$hasD, "profile $base does not declare the downsampling capability");
	}

	if ($expectB{$base}) {
		ok($hasB, "profile $base declares the bitrate capability");
	}
	else {
		ok(!$hasB, "profile $base does not declare the bitrate capability");
	}

	if ($block->{output} eq 'mp3') {
		like($block->{command}, qr/\[lame\]|libmp3lame|-c:a copy/,
			"mp3 profile $base uses a supported mp3 encoder/passthrough");
	}
}

# --- execute the ffmpeg parts against the fixtures -----------------------

my $fixtures = have_ffmpeg() ? PlayVideo::Test::fixtures() : undef;
my $ffmpeg   = find_binary('ffmpeg');

SKIP: {
	skip 'ffmpeg is required for the conversion smoke tests', 1 unless $fixtures && $ffmpeg;

	my $shellDirectory = tempdir(CLEANUP => 1);

	my %commandFor;
	for my $block (@blocks) {
		$commandFor{"$block->{input} $block->{output}"} = $block if substr($block->{capabilities}, 0, 1) eq 'F';
	}

	# Each demux profile: the ffmpeg part must produce a valid elementary
	# stream for the LMS decoder.
	my %demuxFixture = (
		vop => 'opus_mkv',
		vaa => 'aac_mkv',
		vvo => 'vorbis_mkv',
		vfl => 'flac_mkv',
		vmp => 'mp3_mkv',
	);

	my %signature = (
		vop => qr/^OggS/,
		vaa => qr/^\xff/,
		vvo => qr/^OggS/,
		vfl => qr/^fLaC/,
		vmp => qr/^(?:\xff|ID3)/,
	);

	for my $input (qw(vop vaa vvo vfl vmp)) {
		my $block   = $commandFor{"$input flc"} or next;
		my $command = $block->{command};

		$command = (split /\s+\|\s+/, $command)[0];

		my $output = File::Spec->catfile($shellDirectory, "$input.bin");
		my ($exit, $error) = _run_shell(
			$command,
			$shellDirectory,
			file => $fixtures->{$demuxFixture{$input}},
			output => $output,
		);

		is($exit, 0, "demux command for $input executes") or diag($error);
		ok(-s $output, "demux command for $input produces data");

		if (-s $output) {
			open my $handle, '<:raw', $output;
			my $header = '';
			read($handle, $header, 4);
			close $handle;

			like($header // '', $signature{$input}, "demux command for $input produces the right container");
		}
	}

	# Fallback profiles: full ffmpeg decode.
	my %decodeSignature = (
		flc => qr/^fLaC/,
		mp3 => qr/^(?:\xff|ID3)/,
		pcm => qr/./s,
	);

	for my $input (qw(vac vae vdt vth vid)) {
		my $fixture = $input eq 'vac' ? $fixtures->{ac3_mkv}
			: $input eq 'vdt' ? $fixtures->{dts_mkv}
			: $fixtures->{video_mp4};

		for my $output (qw(flc mp3 pcm)) {
			my $block = $commandFor{"$input $output"} or next;

			my $file = File::Spec->catfile($shellDirectory, "fallback-$input-$output.bin");
			my ($exit, $error) = _run_shell(
				$block->{command},
				$shellDirectory,
				file => $fixture,
				output => $file,
			);

			is($exit, 0, "fallback command $input->$output executes") or diag($error);
			ok(-s $file, "fallback command $input->$output produces data");

			if (-s $file) {
				open my $handle, '<:raw', $file;
				my $header = '';
				read($handle, $header, 4);
				close $handle;
				like($header // '', $decodeSignature{$output},
					"fallback command $input->$output produces $output data");
			}
		}
	}

	# Seeking placeholders must be positioned correctly for ffmpeg.
	SKIP: {
		my $block = $commandFor{'vop flc'} or skip 'no vop flc profile', 4;

		my $command = (split /\s+\|\s+/, $block->{command})[0];
		my $output  = File::Spec->catfile($shellDirectory, 'seek.bin');

		my ($exit, $error) = _run_shell(
			$command,
			$shellDirectory,
			file  => $fixtures->{opus_mkv},
			output => $output,
			START => '-ss 0.2',
			END   => '-t 0.3',
		);

		is($exit, 0, 'demux command with T/U placeholders executes') or diag($error);
		ok(-s $output, 'demux command with T/U placeholders produces data');
	}
}

done_testing();

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub read_file {
	my $path = shift;

	open my $handle, '<', $path or return undef;
	local $/;
	my $content = <$handle>;
	close $handle;

	return $content;
}

sub copy_file {
	my ($source, $destination) = @_;

	open my $in, '<:raw', $source or die "Cannot read $source: $!";
	open my $out, '>:raw', $destination or die "Cannot write $destination: $!";
	local $/;
	my $content = <$in>;
	print {$out} $content;
	close $in;
	close $out;

	return;
}

sub _check_placeholders {
	my ($block, $label) = @_;

	my %declared = (
		FILE       => 1,
		URL        => 1,
		QUALITY    => 1,
		CHANNELS   => 1,
		SAMPLESIZE => 1,
		SAMPLERATE => 1,
		OCHANNELS  => 1,
	);

	$declared{START}    = 1 if $block->{capabilities} =~ /T:\{START=/;
	$declared{END}      = 1 if $block->{capabilities} =~ /U:\{END=/;
	$declared{RESAMPLE} = 1 if $block->{capabilities} =~ /D:\{RESAMPLE=/;
	$declared{BITRATE}  = 1 if $block->{capabilities} =~ /B:\{BITRATE=/;

	my %used;
	$used{$1} = 1 while $block->{command} =~ /\$(\w+)\$/g;

	for my $name (sort keys %used) {
		ok($declared{$name}, "profile $label declares placeholder \$$name\$");
	}

	return;
}

sub _run_shell {
	my ($command, $directory, %values) = @_;

	my $ffmpeg = find_binary('ffmpeg');

	my $file = shell_quote($values{file});
	my %substitutions = (
		START     => $values{START} // '',
		END       => $values{END} // '',
		FILE      => $file,
		URL       => $file,
		QUALITY   => '5',
		CHANNELS  => '2',
		SAMPLESIZE => '16',
		SAMPLERATE => '48000',
		OCHANNELS => '2',
		RESAMPLE  => '',
		BITRATE   => '',
	);

	for my $name (sort keys %substitutions) {
		my $value = $substitutions{$name};
		$command =~ s/\$$name\$/$value/ge;
	}

	$command =~ s/\[ffmpeg\]/shell_quote($ffmpeg)/ge;

	my $output = $values{output};
	my $errorFile = "$output.err";

	unlink $output;
	unlink $errorFile;

	my $shellCommand = "$command > " . shell_quote($output) . " 2> " . shell_quote($errorFile);
	my $status = system('sh', '-c', $shellCommand);

	my $error = '';
	if (open my $handle, '<', $errorFile) {
		local $/;
		$error = <$handle>;
		close $handle;
	}

	return ($status >> 8, $error);
}
