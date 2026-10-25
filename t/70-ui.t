#!/usr/bin/perl
#
# PlayVideo plugin for Lyrion Music Server.
#
# Copyright 2025 Lyrion Music Server PlayVideo contributors.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# Static consistency checks for the PlayVideo UI, manifest and documentation.
#
# This test intentionally does not load any Lyrion Music Server module: it can
# always run on a plain Perl installation and catches missing string tokens,
# manifest mistakes, settings/prefs mismatches and missing release files.

use strict;
use warnings;

use Test::More;
use File::Spec::Functions qw(catfile catdir);
use FindBin qw($Bin);

my $root = catdir($Bin, '..');

sub slurp {
	my $file = shift;
	open my $fh, '<', $file or return undef;
	local $/;
	my $content = <$fh>;
	close $fh;
	return $content;
}

sub file {
	my $path = shift;
	return catfile($root, split m{/}, $path);
}

my @modules = qw(
	lib/Plugins/PlayVideo/Plugin.pm
	lib/Plugins/PlayVideo/Menus.pm
	lib/Plugins/PlayVideo/Chapters.pm
	lib/Plugins/PlayVideo/Settings.pm
);

my @documents = qw(
	install.xml.in
	strings.txt
	Makefile
	README.md
	README.zh-CN.md
	THIRD_PARTY_NOTICES.md
	HTML/EN/plugins/PlayVideo/settings.html
	custom-types.conf
	custom-convert.conf
	LICENSE
);

# ---------------------------------------------------------------------------
# Files which must exist in a release
# ---------------------------------------------------------------------------
for my $file (@modules, @documents, 'VERSION') {
	ok(-f file($file), "file exists: $file");
}

ok(-x file('build.sh'), 'one-click build.sh exists and is executable');

my $version = slurp(file('VERSION'));
$version = '' unless defined $version;
$version =~ s/\s+$//;

# ---------------------------------------------------------------------------
# install.xml
# ---------------------------------------------------------------------------
my $manifest = slurp(file('install.xml.in')) // '';

like($manifest, qr{<id>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}</id>}i,
	'install.xml has a UUID id');
like($manifest, qr{<name>PLUGIN_PLAYVIDEO</name>}, 'install.xml plugin name');
like($manifest, qr{<module>Plugins::PlayVideo::Plugin</module>}, 'install.xml module');
like($manifest, qr{<importmodule>Plugins::PlayVideo::Importer</importmodule>}, 'install.xml importmodule');
my $rendered = $manifest; $rendered =~ s/\@VERSION\@/$version/g;
like($manifest, qr{<version>\@VERSION\@</version>}, 'install.xml.in uses the VERSION placeholder');
like($rendered, qr{<version>\Q$version\E</version>}, 'rendered install.xml version matches VERSION');
like($manifest, qr{<description>PLUGIN_PLAYVIDEO_DESC</description>}, 'install.xml description token');
like($manifest, qr{<creator>[^<]+</creator>}, 'install.xml creator');
like($manifest, qr{<category>tools</category>}, 'install.xml category');
like($manifest, qr{<defaultState>enabled</defaultState>}, 'install.xml defaultState');
like($manifest, qr{<type>2</type>}, 'install.xml type 2 (extension)');
like($manifest, qr{<optionsURL>plugins/PlayVideo/settings\.html</optionsURL>}, 'install.xml optionsURL');
like($manifest, qr{<targetApplication>.*?<id>Lyrion Music Server</id>.*?</targetApplication>}s,
	'install.xml targets Lyrion Music Server');
like($manifest, qr{<minVersion>9\.0\.0</minVersion>}, 'install.xml minVersion 9.0.0');
like($manifest, qr{<maxVersion>9\.\*</maxVersion>}, 'install.xml maxVersion 9.*');

my ($optionsURL) = $manifest =~ m{<optionsURL>([^<]+)</optionsURL>};
ok($optionsURL, 'install.xml optionsURL is usable');

if ($optionsURL) {
	my $page = "HTML/EN/$optionsURL";
	ok(-f file($page), "settings page referenced by install.xml exists: $page");
}

# ---------------------------------------------------------------------------
# Plugin.pm contract
# ---------------------------------------------------------------------------
my $plugin = slurp(file('lib/Plugins/PlayVideo/Plugin.pm')) // '';

like($plugin, qr/use\s+base\s+qw\(Slim::Plugin::OPMLBased\)/, 'Plugin.pm inherits from Slim::Plugin::OPMLBased');
like($plugin, qr/SUPER::initPlugin/, 'Plugin.pm calls SUPER::initPlugin');
like($plugin, qr/tag\s*=>\s*'playvideo'/, 'Plugin.pm registers tag playvideo');
like($plugin, qr/menu\s*=>\s*'browse'/, 'Plugin.pm registers browse menu');
like($plugin, qr/node\s*=>\s*'myMusic'/, 'Plugin.pm registers myMusic node');
like($plugin, qr/weight\s*=>\s*40/, 'Plugin.pm weight 40');
like($plugin, qr/Plugins::PlayVideo::Menus::feed/, 'Plugin.pm uses Menus::feed');
like($plugin, qr/Plugins::PlayVideo::Formats::register/, 'Plugin.pm registers formats');
like($plugin, qr/Plugins::PlayVideo::Priority::install/, 'Plugin.pm installs Priority hook');
like($plugin, qr/Plugins::PlayVideo::Priority::uninstall/, 'Plugin.pm uninstalls Priority hook');
like($plugin, qr/Plugins::FFmpeg::Binary/, 'Plugin.pm prefers the FFmpeg plugin binary');
like($plugin, qr/TranscodingHelper::binaries\{ffmpeg\}/, 'Plugin.pm publishes ffmpeg binary');
like($plugin, qr/PLUGIN_PLAYVIDEO/, 'Plugin.pm has a display name token');
like($plugin, qr/sub shutdownPlugin/, 'Plugin.pm implements shutdownPlugin');

my @prefs = qw(
	ffmpeg
	ffprobe
	folderAsAlbum
	probeTimeout
	showVideoInfo
	enableChapters
	preferExternalDecoders
);

for my $pref (@prefs) {
	like($plugin, qr/\b\Q$pref\E\b\s*=>/, "Plugin.pm initializes pref $pref");
}

# ---------------------------------------------------------------------------
# Settings.pm / settings.html
# ---------------------------------------------------------------------------
my $settings = slurp(file('lib/Plugins/PlayVideo/Settings.pm')) // '';
my $html     = slurp(file('HTML/EN/plugins/PlayVideo/settings.html')) // '';

like($settings, qr/<Slim::Web::Settings>|Slim::Web::Settings/, 'Settings.pm extends Slim::Web::Settings');
like($settings, qr/plugins\/PlayVideo\/settings\.html/, 'Settings.pm points at the settings page');
like($settings, qr/Plugins::PlayVideo::Probe->status/, 'Settings.pm reports probe status');
like($settings, qr/Plugins::FFmpeg::Binary/, 'Settings.pm detects the FFmpeg plugin');
like($settings, qr/sox/, 'Settings.pm checks sox');
like($settings, qr/faad/, 'Settings.pm checks faad');
like($settings, qr/flac/, 'Settings.pm checks flac');
like($settings, qr/lame/, 'Settings.pm checks lame');

my ($prefsSub) = $settings =~ /sub\s+prefs\s*\{(.*?)^\}/ms;
my ($prefsBlock) = defined $prefsSub ? $prefsSub =~ /qw\((.*?)\)/s : ();
my @settingsPrefs = $prefsBlock ? ($prefsBlock =~ /\b([a-z][A-Za-z0-9_]*)\b/g) : ();

is_deeply(
	[ sort @settingsPrefs ],
	[ sort @prefs ],
	'Settings.pm exposes exactly the documented prefs',
);

like($html, qr/PROCESS settings\/header\.html/, 'settings.html includes the settings header');
like($html, qr/PROCESS settings\/footer\.html/, 'settings.html includes the settings footer');
like($html, qr/WRAPPER settingSection/, 'settings.html uses settingSection (LMS 9 layout)');
like($html, qr/WRAPPER settingGroup/, 'settings.html uses settingGroup (LMS 9 layout)');
like($html, qr/class="prefTable"/, 'status/decoder tables use prefTable');
unlike($html, qr/WRAPPER setting\s/, 'settings.html does not use the legacy setting wrapper');

for my $pref (@prefs) {
	like($html, qr/name="pref_\Q$pref\E"/, "settings.html renders pref $pref");
}

# ---------------------------------------------------------------------------
# Menus.pm contract
# ---------------------------------------------------------------------------
my $menus = slurp(file('lib/Plugins/PlayVideo/Menus.pm')) // '';

like($menus, qr/Slim::Schema->rs\('Track'\)/, 'Menus.pm queries tracks');
like($menus, qr/content_type/, 'Menus.pm filters by content type');
like($menus, qr/5000/, 'Menus.pm caps the menu at 5000 entries');
like($menus, qr/PlayVideo::Types::VIDEO_TYPES/, 'Menus.pm uses Types::VIDEO_TYPES');
like($menus, qr/PlayVideo::Chapters::get_for_url/, 'Menus.pm uses Chapters::get_for_url');
like($menus, qr/PlayVideo::Probe->probe/, 'Menus.pm uses Probe->probe');
like($menus, qr/Slim::Player::Source::gototime/, 'Menus.pm seeks via gototime');
like($menus, qr/Slim::Utils::Timers::setTimer/, 'Menus.pm polls chapter playback with a timer');
like($menus, qr/registerInfoProvider/, 'Menus.pm registers TrackInfo providers');
like($menus, qr/'playvideo', 'status'/, 'Menus.pm registers playvideo status command');
like($menus, qr/'playvideo', 'info'/, 'Menus.pm registers playvideo info command');
like($menus, qr/'playvideo', 'chapters'/, 'Menus.pm registers playvideo chapters command');
like($menus, qr/sub _cliUrl\b/, 'Menus.pm normalizes CLI URLs');
like($menus, qr/url\\s\*:\\s\*/, 'Menus.pm strips a leading url: tag');
my $cliUrlCalls = () = $menus =~ /_cliUrl\(\$request\)/g;
cmp_ok($cliUrlCalls, '>=', 2, 'both CLI info and chapters use _cliUrl');

like($menus, qr/addResultLoop/, 'Menus.pm returns chapter loops');
like($menus, qr/sub _videoTypes\b.*?wantarray/s, 'Menus.pm _videoTypes returns a list in list context');
like($menus, qr/type\s*=>\s*'audio'/, 'Menus.pm feed items are audio type');
like($menus, qr/play\s*=>\s*\$url/, 'Menus.pm feed items set the play url');
like($menus, qr/duration\s*=>\s*\$secs/, 'Menus.pm feed items set duration in seconds');

# ---------------------------------------------------------------------------
# Chapters.pm contract
# ---------------------------------------------------------------------------
my $chapters = slurp(file('lib/Plugins/PlayVideo/Chapters.pm')) // '';

like($chapters, qr/sub get\b/, 'Chapters.pm implements get()');
like($chapters, qr/sub get_for_url\b/, 'Chapters.pm implements get_for_url()');
like($chapters, qr/Plugins::PlayVideo::Probe->chapters/, 'Chapters.pm uses Probe->chapters');
like($chapters, qr/Plugins::PlayVideo::Types::is_video_type/, 'Chapters.pm checks the content type');
like($chapters, qr/%chapterCache/, 'Chapters.pm has an in-memory cache');
like($chapters, qr/remote/, 'Chapters.pm rejects remote tracks');

# ---------------------------------------------------------------------------
# strings.txt
# ---------------------------------------------------------------------------
my $strings = slurp(file('strings.txt')) // '';

my (%defined, %seenToken, %en, %zh_cn);

my $current;
for my $line (split /\r?\n/, $strings) {
	next if $line =~ /^\s*#/;

	if ($line =~ /^([A-Z][A-Z0-9_]*)\s*$/) {
		$current = $1;
		$seenToken{$current}++;
		$defined{$current} ||= 0;
		next;
	}

	if (defined $current && $line =~ /^\t([A-Z_]+)\t(.*)$/) {
		$en{$current} = 1 if $1 eq 'EN';
		$zh_cn{$current} = 1 if $1 eq 'ZH_CN';
		$defined{$current} = 1;
		next;
	}

	$current = undef if $line =~ /^\s*$/;
}

my @tokenSources = @modules;
push @tokenSources, 'HTML/EN/plugins/PlayVideo/settings.html';
push @tokenSources, 'install.xml.in';

my %used;

for my $source (@tokenSources) {
	my $text = slurp(file($source)) // '';

	while ($text =~ /\b(PLUGIN_PLAYVIDEO(?:_[A-Z0-9_]+)?)\b/g) {
		$used{$1} = 1;
	}
}

my @missing = sort grep { !$defined{$_} } keys %used;

is_deeply(\@missing, [], 'all PLUGIN_PLAYVIDEO_* tokens used by the UI are defined')
	or diag('Undefined tokens: ' . join(', ', @missing));

my @noEnglish = sort grep { $defined{$_} && !$en{$_} } keys %used;

is_deeply(\@noEnglish, [], 'all used tokens have an EN translation')
	or diag('Tokens without EN: ' . join(', ', @noEnglish));

my @noChinese = sort grep { !$zh_cn{$_} } keys %used;

is_deeply(\@noChinese, [], 'all used tokens have a ZH_CN translation')
	or diag('Tokens without ZH_CN: ' . join(', ', @noChinese));

my @duplicates = sort grep { $seenToken{$_} > 1 } keys %seenToken;

is_deeply(\@duplicates, [], 'no duplicate token definitions in strings.txt')
	or diag('Duplicated tokens: ' . join(', ', @duplicates));

# Format strings must contain a placeholder if they are used with arguments.
my %formatTokens = map { $_ => 1 } qw(
	PLUGIN_PLAYVIDEO_VIDEO_STREAM
	PLUGIN_PLAYVIDEO_RESOLUTION
	PLUGIN_PLAYVIDEO_SAMPLE_RATE_FMT
	PLUGIN_PLAYVIDEO_CHANNELS_FORMAT
	PLUGIN_PLAYVIDEO_BITRATE_FORMAT
	PLUGIN_PLAYVIDEO_CHAPTER_TITLE
	PLUGIN_PLAYVIDEO_CHAPTER_NUMBER
	PLUGIN_PLAYVIDEO_SEEK_STARTING
	PLUGIN_PLAYVIDEO_SEEK_DONE
	PLUGIN_PLAYVIDEO_SEEK_TIMEOUT
);

for my $token (sort keys %formatTokens) {
	my ($line) = $strings =~ /^\Q$token\E\s*\n\tEN\t(.*)$/m;
	ok(defined $line && $line =~ /%s/, "format token $token has an EN format placeholder")
		or diag("missing or malformed EN line for $token");
}

# ---------------------------------------------------------------------------
# Makefile
# ---------------------------------------------------------------------------
my $makefile = slurp(file('Makefile')) // '';

for my $target (qw(test lint docker-test dist install clean)) {
	like($makefile, qr/^\Q$target\E\s*:/m, "Makefile has a $target target");
}

like($makefile, qr/prove/, 'Makefile test target uses prove');
like($makefile, qr/script\/docker-test\.sh/, 'Makefile docker-test uses script/docker-test.sh');
like($makefile, qr/dist\/PlayVideo/, 'Makefile dist creates dist/PlayVideo');
like($makefile, qr/PLUGINS_DIR/, 'Makefile install honours PLUGINS_DIR');

# ---------------------------------------------------------------------------
# Documentation
# ---------------------------------------------------------------------------
my $readme = slurp(file('README.md')) // '';
my $readmeZh = slurp(file('README.zh-CN.md')) // '';

for my $term (qw(ffmpeg ffprobe Plugins/PlayVideo chapters Docker security limitations)) {
	like($readme, qr/\Q$term\E/i, "README.md mentions $term");
}

for my $term ('ffmpeg', 'ffprobe', 'Plugins/PlayVideo', '章节', 'Docker', '安全', '限制') {
	like($readmeZh, qr/\Q$term\E/i, "README.zh-CN.md mentions $term");
}

like($readme, qr/external decoder/i, 'README.md explains external decoder priority');
like($readme, qr/separate library tracks/i, 'README.md explains chapters are not library tracks');
like($readme, qr/make test/, 'README.md documents make test');
like($readme, qr/make docker-test/, 'README.md documents make docker-test');
like($readme, qr/ref\//, 'README.md documents that ref/ is not committed');
like($readme, qr/non-UTF-8/i, 'README.md documents the non-UTF-8 path caveat');

my $notices = slurp(file('THIRD_PARTY_NOTICES.md')) // '';

like($notices, qr/ffmpeg/i, 'THIRD_PARTY_NOTICES mentions ffmpeg');
like($notices, qr/(?:LGPL|GPL)/, 'THIRD_PARTY_NOTICES mentions FFmpeg licensing');
like($notices, qr/Lyrion Music Server/, 'THIRD_PARTY_NOTICES mentions LMS');
like($notices, qr/GNU\s+General\s+Public\s+License/i, 'THIRD_PARTY_NOTICES mentions the GPL');

done_testing();
