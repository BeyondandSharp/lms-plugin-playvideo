# Third-party notices

The PlayVideo plugin for Lyrion Music Server (LMS) is licensed under the GNU
General Public License, version 2 (see `LICENSE`). It does not bundle or link
against any third-party code. The following external programs and components
are used at runtime or are referred to by the documentation.

## Lyrion Music Server

PlayVideo is a plugin for Lyrion Music Server and is loaded by the server it is
installed into. Lyrion Music Server is distributed under the GNU General Public
License, version 2. See <https://lyrion.org/> and the `LICENSE` file of the
server installation for details.

The plugin calls LMS APIs (schema, formats, menus, transcoding helper, web
settings) but does not contain LMS source code.

## FFmpeg / ffprobe

`ffmpeg` and `ffprobe` are **external programs**, not part of this plugin.
They are not shipped, bundled, linked or embedded by PlayVideo.

- Project: <https://ffmpeg.org/>
- Licensing: FFmpeg is licensed under the LGPL v2.1 or later by default;
  optional components and build configurations may make it GPL licensed.
  Check the license and build options of the FFmpeg package installed on your
  server. See <https://ffmpeg.org/legal.html>.
- Usage: `ffprobe` is executed to read container, stream and chapter metadata;
  `ffmpeg` is executed to extract cover art and as the decoding fallback for
  audio codecs which LMS cannot decode natively (AC3, E-AC3, DTS, TrueHD and
  other video-container audio codecs).
- Both programs are invoked directly as separate processes (list-form process
  execution without a shell). They are never distributed with this plugin.

Docker images and OS packages used by the optional test harness install FFmpeg
from the distribution's package repositories; those copies are subject to the
respective distribution licenses and FFmpeg's own license.

## LMS decoder helper programs

The PlayVideo conversion profiles hand demuxed audio to the decoder helper
programs which are part of a normal Lyrion Music Server installation:

- `sox` - <https://sox.sourceforge.net/> (GPL / LGPL components)
- `faad` - <https://github.com/knik0/faad2> (GPL-2.0)
- `flac` - <https://xiph.org/flac/> (GPL / BSD-style)
- `lame` - <https://lame.sourceforge.io/> (LGPL)

These programs are not distributed with PlayVideo. When they are missing the
affected LMS-native decoder profile is unavailable; PlayVideo's ffmpeg fallback
profiles do not depend on them.

## Optional FFmpeg plugin (lms-plugin-ffmpeg)

The optional FFmpeg plugin can provide the `ffmpeg`/`ffprobe` binaries and
external decoder profiles used by PlayVideo. It is a separate plugin with its
own license and is not required.

## Test media

The `ref/` directory used for manual testing is untracked and is not part of
the plugin distribution. Do not commit media files that you are not allowed to
distribute.

## Trademarks

All product names, logos and brands are property of their respective owners.
Use of these names does not imply endorsement.
