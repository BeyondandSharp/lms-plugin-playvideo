#!/usr/bin/env bash
#
# PlayVideo one-click build.
#
# Reads the plugin version exclusively from ./VERSION, renders
# build/install.xml from install.xml.in, assembles dist/PlayVideo/ and
# creates dist/PlayVideo-<VERSION>.zip (and .tar.gz when available).
#
#   ./build.sh              run unit tests, build folder + archives
#   ./build.sh --no-test    skip the unit tests
#   ./build.sh --no-archive only create dist/PlayVideo/
#   ./build.sh --help
#
# This file is part of the PlayVideo plugin and licensed under GPL-2.0.

set -euo pipefail

PLUGIN='PlayVideo'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

BUILD_DIR="$ROOT/build"
DIST_ROOT="$ROOT/dist"
DIST_DIR="$DIST_ROOT/$PLUGIN"
RUN_TESTS=1
MAKE_ARCHIVES=1

die()  { printf 'build.sh: error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

usage() {
	sed -n '2,13p' "$ROOT/build.sh" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--no-test)    RUN_TESTS=0 ;;
		--no-archive) MAKE_ARCHIVES=0 ;;
		-h|--help)    usage; exit 0 ;;
		*)            die "unknown option: $1 (use --help)" ;;
	esac
	shift
done

[ -f VERSION ] || die 'VERSION file is missing'
[ -f install.xml.in ] || die 'install.xml.in template is missing'

# VERSION is the single source of truth.  Accept 1.2.3 and common
# pre-release suffixes such as 1.2.3-rc1 or 1.2.3+build.4.
VERSION=$(tr -d '[:space:]' < VERSION)
[ -n "$VERSION" ] || die 'VERSION is empty'
case "$VERSION" in
	[0-9]*.[0-9]*.[0-9]*) ;;
	*) die "VERSION must look like MAJOR.MINOR.PATCH (got '$VERSION')" ;;
esac
case "$VERSION" in
	*[!0-9A-Za-z.+-]*) die "VERSION contains unsupported characters: '$VERSION'" ;;
esac

if [ "$RUN_TESTS" -eq 1 ]; then
	command -v prove >/dev/null 2>&1 || die 'prove is required to run the unit tests (or use --no-test)'
	note "==> Running unit tests"
	prove -l t
fi

note "==> Building $PLUGIN $VERSION"
rm -rf "$BUILD_DIR" "$DIST_DIR"
rm -f "$DIST_ROOT/$PLUGIN-$VERSION.zip" "$DIST_ROOT/$PLUGIN-$VERSION.tar.gz"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# Render the only versioned metadata file.  The template is the tracked
# source; build/install.xml and the copy in dist/ are generated.
perl -0777 -e '
	my ($template, $version, $output) = @ARGV;
	open my $in, "<", $template or die "$template: $!\n";
	local $/;
	my $text = <$in>;
	close $in;
	my $count = ($text =~ s/\@VERSION\@/$version/g);
	die "$template: \@VERSION\@ placeholder not found\n" unless $count;
	open my $out, ">", $output or die "$output: $!\n";
	print {$out} $text;
	close $out;
' install.xml.in "$VERSION" "$BUILD_DIR/install.xml"

grep -qF "<version>$VERSION</version>" "$BUILD_DIR/install.xml" \
	|| die 'rendered install.xml does not contain the VERSION value'

for file in \
	lib \
	HTML \
	custom-types.conf \
	custom-convert.conf \
	strings.txt \
	README.md \
	README.zh-CN.md \
	THIRD_PARTY_NOTICES.md \
	LICENSE
do
	[ -e "$file" ] || die "required file is missing: $file"
	cp -a "$file" "$DIST_DIR/"
done
cp -p "$BUILD_DIR/install.xml" "$DIST_DIR/install.xml"

find "$DIST_DIR" -type d -exec chmod 755 {} +
find "$DIST_DIR" -type f -exec chmod 644 {} +

if [ "$MAKE_ARCHIVES" -eq 1 ]; then
	note "==> Creating archives"
	have_archive=0
	if command -v zip >/dev/null 2>&1; then
		(cd "$DIST_ROOT" && zip -qr "$PLUGIN-$VERSION.zip" "$PLUGIN")
		note "    $DIST_ROOT/$PLUGIN-$VERSION.zip"
		have_archive=1
	fi
	if command -v tar >/dev/null 2>&1; then
		tar -czf "$DIST_ROOT/$PLUGIN-$VERSION.tar.gz" -C "$DIST_ROOT" "$PLUGIN"
		note "    $DIST_ROOT/$PLUGIN-$VERSION.tar.gz"
		have_archive=1
	fi
	[ "$have_archive" -eq 1 ] || die 'neither zip nor tar is available; use --no-archive'
fi

note
note "Release folder: $DIST_DIR"
note "Copy it to <LMS>/Plugins/$PLUGIN and restart LMS."
