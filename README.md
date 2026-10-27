# PlayVideo for Lyrion Music Server

![GitHub Release](https://img.shields.io/github/v/release/BeyondandSharp/lms-plugin-playvideo)

[中文说明](README.zh-CN.md)

**PlayVideo** adds the audio tracks of local video files (MP4, MKV, WebM, AVI,
MPEG-TS, ...) to your Lyrion Music Server (LMS) music library. It scans the
files, reads the container/audio metadata with `ffprobe`, exposes the files in
the normal LMS library and player menus, and lets LMS decode the audio through
its own decoders or through `ffmpeg`.

The video stream itself is **never rendered**: PlayVideo is an audio-only
bridge so that films, concert recordings, music videos and TV episodes can be
browsed, searched, added to playlists and played on any Squeezebox/Lyrion
player. There is no video output, subtitle handling or DRM support.

## Features

- Video files appear in **My Music → Videos** (up to 5000 entries per menu).
- Metadata is read with `ffprobe`; MP4-family files are still read by LMS'
  native MP4/Movie reader first, with PlayVideo's reader as fallback.
- Audio-type detection maps the audio codec to an LMS content type, so
  transcoding and the player's format capabilities work as usual.
- LMS-native decoding for Opus, AAC, Vorbis, FLAC and MP3 taken from video
  containers.
- `ffmpeg` decoding fallback for AC3, E-AC3, DTS, TrueHD and other codecs LMS
  cannot decode directly.
- Output profiles for FLAC, MP3, PCM, **AAC (ADTS)**, **Ogg Vorbis** and
  **Opus**; the AAC/Ogg/Opus targets are decoded and encoded by `ffmpeg` for
  every content type. Maximum Bitrate and downsampling are honoured.
- A pure-Perl `codec_capabilities` declaration (provider `playvideo`,
  priority `150`/`1`) that other plugins such as CodecSwitch can use to
  negotiate decoding without probing `ffmpeg`.
- **Video details** and **Chapters** in the track information menu. Chapters
  are seek shortcuts, not separate library tracks.
- Optional detection of and priority integration with
  the companion `lms-plugin-ffmpeg` plugin.
- CLI/JSON-RPC API (`playvideo status|info|chapters`) for automation and
  diagnostics.
- English and Simplified Chinese (`ZH_CN`) UI strings.

## Requirements

- Lyrion Music Server **9.0.0 or 9.1.x** (the manifest targets 9.0.0–9.*).
- `ffmpeg` **and** `ffprobe` installed on the server where LMS runs. Both must
  be executable by the LMS process. PlayVideo runs without them, but cannot
  scan video files or decode AC3/DTS/TrueHD without `ffmpeg`.
- The LMS decoder helpers used by the native profiles (`sox`, `faad`, `flac`,
  `lame`) are part of a normal LMS installation. Missing helpers only disable
  the corresponding native profile.
- No additional Perl CPAN modules are required. `JSON::XS` is used when
  present; `JSON::PP` is the fallback for parsing `ffprobe` output.

### Install ffmpeg

On Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install -y ffmpeg
```

On Alpine (the official Docker images are Alpine-based):

```sh
apk add --no-cache ffmpeg
```

On Windows/macOS install FFmpeg from your usual package manager and enter the
full paths to `ffmpeg.exe`/`ffprobe.exe` in the plugin settings.

## Building

A single version file, [VERSION](VERSION), is the only place that stores the
plugin version. Run the one-click build from the repository root:

```sh
./build.sh                 # run unit tests, build folder + archives
./build.sh --no-test       # skip unit tests
./build.sh --no-archive    # only create dist/PlayVideo/
```

The script renders `build/install.xml` from the tracked `install.xml.in`
template and creates:

```
dist/PlayVideo/                 # ready to copy into <LMS>/Plugins/
dist/PlayVideo-<VERSION>.zip    # LMS plugin-manager archive
dist/PlayVideo-<VERSION>.tar.gz # portable archive
```

`make dist` calls the same script. Never edit `install.xml` by hand; change
`VERSION` (and, if needed, `install.xml.in`) instead.

## Installation

1. Copy the plugin folder so that it is named **exactly** `PlayVideo` below
   the LMS `Plugins` directory:

   ```
   <LMS>/Plugins/PlayVideo/install.xml
   <LMS>/Plugins/PlayVideo/lib/Plugins/PlayVideo/Plugin.pm
   <LMS>/Plugins/PlayVideo/HTML/EN/plugins/PlayVideo/settings.html
   <LMS>/Plugins/PlayVideo/custom-types.conf
   <LMS>/Plugins/PlayVideo/custom-convert.conf
   <LMS>/Plugins/PlayVideo/strings.txt
   ```

   The folder name matters: LMS derives the plugin module (`Plugins::PlayVideo`)
   from it. Do not rename it (for example to `PlayVideo-<version>`).

   - **Git checkout:** run `./build.sh` in the repository and copy
     `dist/PlayVideo/` to `<LMS>/Plugins/PlayVideo`. The `ref/` test media is
     untracked and not needed.
   - **Release archive:** unpack `dist/PlayVideo-<VERSION>.zip` and copy the
     `PlayVideo` folder into `<LMS>/Plugins/`.

2. Restart Lyrion Music Server.
3. Enable **PlayVideo** under *Settings → Plugins* if it is not already
   enabled (the manifest defaults to enabled).
4. Open *Settings → PlayVideo* and check the ffmpeg/ffprobe status.
5. Add the folders containing video files to your LMS media folders and run a
   **Rescan media library**. Video files are then added to the library.

### Docker

The LMS Docker image does not include ffmpeg. Either build a small derived
image:

```dockerfile
FROM lmscommunity/lyrionmusicserver:9.1.1
USER root
RUN apk add --no-cache ffmpeg
# restore the image's default user if it is not root, e.g.:
# USER squeezeboxserver
```

or install static ffmpeg binaries and point the plugin settings at them.

The plugin itself lives in the persistent LMS configuration volume:

```sh
mkdir -p ./config/Plugins && cp -r /path/to/PlayVideo ./config/Plugins/PlayVideo
docker run -d --name lyrion \
  -p 9000:9000 -p 9090:9090 \
  -v "$PWD/config":/config \
  -v /path/to/music:/music \
  lmscommunity/lyrionmusicserver:9.1.1
```

(Adjust the image tag and paths to your setup.) Then restart the container.
Do **not** install packages with `docker exec apt-get install`: the change is
lost when the container is recreated.

## How scanning and playback work

### Scanning

`custom-types.conf` maps the known video suffixes to the `vid` content type and
adds the codec-specific audio types `vop`, `vaa`, `vvo`, `vfl`, `vmp`, `vac`,
`vae`, `vdt`, `vth`. During a scan:

1. LMS calls the registered MP4/video tag readers.
2. MP4-family files are first offered to LMS' native `Slim::Formats::Movie`
   reader. If it cannot extract usable tags, or the file is not MP4-family,
   the file is probed with `ffprobe`.
3. The normalised probe data is converted to LMS tags (title, album, artist,
   duration, sample rate, channels, bitrate, cover, ...) and stored in the
   library database.
4. The audio codec determines the content type: Opus → `vop`, AAC → `vaa`,
   Vorbis → `vvo`, FLAC → `vfl`, MP3 → `vmp`, AC3 → `vac`, E-AC3 → `vae`,
   DTS → `vdt`, TrueHD → `vth`, everything else → `vid`.

`ffprobe` is invoked directly (no shell) with a configurable timeout
(default 20 s). `folderAsAlbum` is enabled by default: when a file has no
album tag, the parent folder name is used as album. This works well for
one-movie-per-folder collections.

### Playback

PlayVideo tracks behave like normal audio tracks. LMS streams only the audio
track (`-vn -sn -dn -map 0:a:0`) to the player. The first audio stream is used.

| Audio codec in the video | Profile | Decoding path |
| --- | --- | --- |
| Opus | `vop` | ffmpeg demux → `sox -t opus` → FLAC |
| AAC (ADTS) | `vaa` | ffmpeg demux → `faad` → FLAC |
| Vorbis | `vvo` | ffmpeg demux → `sox -t ogg` → FLAC |
| FLAC | `vfl` | ffmpeg copy → LMS FLAC/MP3/PCM output |
| MP3 | `vmp` | ffmpeg copy → LMS MP3/FLAC/PCM output |
| AC3 | `vac` | external AC3 plugin if available, otherwise ffmpeg decode |
| E-AC3 | `vae` | external E-AC3/AC3 plugin if available, otherwise ffmpeg |
| DTS | `vdt` | external DTS plugin if available, otherwise ffmpeg |
| TrueHD | `vth` | external TrueHD plugin if available, otherwise ffmpeg |
| anything else | `vid` | ffmpeg decode |

Every content type has output profiles for FLAC, MP3, PCM, AAC (ADTS), Ogg
Vorbis and Opus, for both local (`F`) and remote (`R`) players (120 profiles
in total, generated by `tools/gen-convert-conf.pl`). LMS then performs the
usual player-side transcoding if the player needs a different format. Seeking
is supported: the `START`/`END` capabilities restart the conversion at the
requested position.

| Output | Profiles | Path |
| --- | --- | --- |
| FLAC (`flc`) | all types | native demux for `vop`/`vaa`/`vvo`/`vfl`/`vmp`, `ffmpeg` decode for `vac`/`vae`/`vdt`/`vth`/`vid` |
| MP3 (`mp3`) | all types | native demux for `vop`/`vaa`/`vvo`/`vfl`, `ffmpeg` decode for the rest |
| PCM (`pcm`) | all types | native demux for the five native codecs, `ffmpeg` decode for the rest |
| AAC (`aac`) | all types | `ffmpeg` decode + `-c:a aac -f adts` (default 192 kbit/s) |
| Ogg Vorbis (`ogg`) | all types | `ffmpeg` decode + `-c:a libvorbis -f ogg` (default 160 kbit/s) |
| Opus (`ops`) | all types | `ffmpeg` decode + `-c:a libopus -f ogg` (default 128 kbit/s) |

For the LMS-native profiles, `ffmpeg` is only used to demux/copy; decoding is
done by LMS' own helpers. For the fallback and AAC/Ogg/Opus profiles `ffmpeg`
does the decoding and encoding. The AAC/Ogg/Opus profiles declare downsampling
(`D`) and Maximum Bitrate (`B`, `-b:a %Bk`); the default bitrate above is used
when LMS does not request a limit.

## External decoder plugins and priority

AC3, E-AC3, DTS and TrueHD can be decoded by dedicated LMS plugins (for
example an AC3 plugin or the optional FFmpeg plugin) or by PlayVideo's own
`ffmpeg` fallback profiles. With **Prefer external decoder plugins** enabled
(the default), PlayVideo tries a dedicated decoder profile first and only then
falls back to ffmpeg. Disable it to always use the ffmpeg fallback for these
codecs.

The setting only affects the fallback content types. Opus/AAC/Vorbis/FLAC/MP3
always use the LMS-native profiles described above.

### Codec capability declaration

`Plugins::PlayVideo::Plugin->codec_capabilities()` delegates to the pure-Perl
`Plugins::PlayVideo::Types::codec_capabilities()`, which returns a static
description without touching `ffmpeg` or the preference store:

```perl
{
    provider => 'playvideo',
    priority => 150,                      # 1 when external decoders are off
    decode   => [ { from => [ ...all ten content types... ],
                    to   => [ 'pcm', 'flc' ],
                    scope => [ 'local', 'remote' ] } ],
    convert  => [ { from => [ ...all ten content types... ],
                    to   => [ 'flc', 'mp3', 'pcm', 'aac', 'ogg', 'ops' ],
                    scope => [ 'local', 'remote' ] } ],
    bitrate  => [ 'mp3', 'aac', 'ogg', 'ops' ],
}
```

`priority` follows the **Prefer external decoder plugins** setting. In the
ordering used by orchestration plugins such as CodecSwitch, lower numbers win:
`150` keeps PlayVideo behind a dedicated decoder such as the FFmpeg plugin
(`100`), while `1` lets PlayVideo's own `ffmpeg` profiles win. The declaration
is read-only; the settings page shows it as a status row.

### Optional lms-plugin-ffmpeg integration

If the companion `lms-plugin-ffmpeg` plugin is installed and enabled:

- its resolved `ffmpeg`/`ffprobe` binaries are preferred over the values in
  PlayVideo's settings (PlayVideo's own settings are used when the plugin is
  absent or cannot resolve a binary);
- its AC3/E-AC3/DTS/TrueHD conversion profiles are treated as external
  decoders by PlayVideo's priority hook, so its *fallback*/*prefer* mode also
  influences which decoder wins;
- the FFmpeg plugin's settings page is the single place to manage the shared
  binaries.

The FFmpeg plugin is optional. PlayVideo works with a system `ffmpeg` alone.

## Chapters

Chapters come from the container metadata (`ffprobe`). For local video files
the track information menu shows a **Chapters** entry. Selecting a chapter:

- if the same video is already playing, LMS seeks to the chapter start;
- otherwise the video is started, and PlayVideo waits (up to 15 seconds) until
  it is playing before seeking.

Chapters are **not** separate library tracks. They do not appear as albums,
titles or playlist entries, and they are not scanned into the database.
Files without chapters show no chapter list. Remote/streamed files are not
probed and have no chapters.

## Settings

| Setting | Default | Description |
| --- | --- | --- |
| ffmpeg executable | empty | Path to `ffmpeg`; empty = FFmpeg plugin/system PATH |
| ffprobe executable | empty | Path to `ffprobe`; empty = FFmpeg plugin/system PATH |
| Use folder name as album | on | Album fallback for untagged files |
| Probe timeout | 20 s | Maximum ffprobe runtime per file (1–120) |
| Show video details | on | Track-info entry with container/codec/resolution |
| Show chapters | on | Track-info chapter menu for local videos |
| Prefer external decoder plugins | on | Try dedicated AC3/DTS/TrueHD plugins before ffmpeg |

The status section of the settings page shows the resolved binaries, their
version and source, whether the optional FFmpeg plugin is installed, and
whether the LMS decoder helpers (`sox`, `faad`, `flac`, `lame`) are available.
A read-only **Codec capabilities** section shows the declared provider,
priority, decode targets, output formats and bitrate targets. It follows the
*Prefer external decoder plugins* setting and adds no preference of its own.

## CLI / JSON-RPC

All commands are server queries and do not need a player. `status` reports the
resolved binaries and configuration; `info` and `chapters` take the track URL
(a `file://` URL for a local file known to the library, or a library track
URL).

Classic CLI (port 9090):

```text
playvideo status ?
playvideo info file:///music/Videos/Concert.mkv ?
playvideo chapters file:///music/Videos/Concert.mkv ?
```

The URL may also be passed with the CLI tag prefix (`playvideo info url:file:///music/Videos/Concert.mkv ?`); both forms are accepted.

JSON-RPC (port 9000):

```sh
curl -s http://localhost:9000/jsonrpc.js \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["",["playvideo","status"]]}'

curl -s http://localhost:9000/jsonrpc.js \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["",["playvideo","chapters","file:///music/Videos/Concert.mkv"]]}'
```

`playvideo chapters` returns `count` plus a `chapters_loop` array with
`start`, `end` (when known), `start_text` and `title` per chapter.

## Testing

The repository contains unit tests and a Docker harness:

```sh
make test                 # prove -l t
make lint                 # static UI checks; add LMS_HOME=/lms for perl -c
make docker-test          # LMS 9.0.0/9.1.1 containers (needs Docker)
make dist                 # build dist/PlayVideo/
make install PLUGINS_DIR=/var/lib/squeezeboxserver/Plugins
```

- `make test` runs on the host. Tests which need a full LMS installation skip
  themselves when `LMS_HOME` is not set. `t/40-conf.t` checks the 120
  generated profiles (including real `ffmpeg` signatures for ADTS/Ogg),
  `t/55-capabilities.t` checks the pure capability declaration and its
  consistency with `custom-convert.conf`.
- `make lint` always checks the manifest, strings, settings template and
  required files. With `LMS_HOME` pointing to an LMS checkout/installation it
  also runs `perl -c` against every plugin module.
- `make docker-test` uses `script/docker-test.sh` to boot LMS 9.0.0 and 9.1.1
  images, install ffmpeg inside the image and exercise scanning, probing and
  the decoder priority. Playback assertions use a host `squeezelite` player.
- `ref/` contains untracked test media and is not committed; do not commit
  copyrighted media. Tests should generate or use their own fixtures.

Last verified with the Docker harness in this repository: **LMS 9.0.0 and
9.1.1, all checks pass**, covering scanning/metadata, the `vop -> flc`
demux + LMS `sox` path, seeking, video-only skip, the external AC3 priority
matrix (dedicated plugin wins in `fallback`, FFmpeg plugin wins in `prefer`)
and the optional `lms-plugin-ffmpeg` integration.

## Limitations

- **No video rendering.** Only the audio track is played. There is no video
  window, subtitles, multiple audio track selection or menu navigation.
- **No DRM.** Encrypted/protected files cannot be probed or played.
- **Remote files are best effort.** Online libraries, UPnP and internet
  streams are not probed for video chapters; only local files are supported
  for detailed metadata and chapters.
- **One audio stream.** The first audio stream is used; other audio tracks in
  a container are not selectable.
- **Non-UTF-8 paths.** `ffprobe` is asked for metadata only and not for the
  filename, and fallback handling avoids invalid UTF-8. Very old filesystems
  or locally-encoded file names may still cause missing tags or mismatched
  paths; convert your file names to UTF-8 if possible.
- **Large libraries.** The menu is capped at 5000 video tracks (the log
  reports truncation). Use search or the normal library queries for larger
  collections.
- **Chapter support depends on the container.** MP4, MKV and some other
  containers support chapters; others do not.
- **Scanning cost.** Each video file is probed once with ffprobe; large
  libraries and slow network shares make scans slower. Increase the probe
  timeout for very slow storage.
- **Seeking** restarts the transcode at the new position; it is not gapless
  and may take a moment on slow machines.

## Security

- PlayVideo executes `ffprobe` and `ffmpeg` as child processes using list-form
  process execution (`IPC::Open3`). User-supplied paths and file names are
  never passed through a shell, and `ffprobe` output is parsed as JSON rather
  than evaluated.
- The executable-path settings reject control characters and overly long
  values, but they are still administrator-controlled input: only set paths
  to binaries you trust.
- Media files are untrusted input. Keep `ffmpeg`/`ffprobe` up to date, run LMS
  as an unprivileged user where possible, and only add media folders you
  control. A malicious media file may trigger bugs in the decoders.
- Metadata read from media files is shown in the web UI and player menus;
  the web UI escapes it, but do not assume media tags are trustworthy.
- The plugin does not open network ports on its own. The CLI/JSON-RPC
  endpoints are the normal LMS ones; secure them with LMS' access control if
  the server is reachable from untrusted networks.

## License

PlayVideo is free software, licensed under the GNU General Public License,
version 2. See [LICENSE](LICENSE). Third-party components and their licenses
are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Lyrion Music Server itself is licensed under the GNU General Public License,
version 2.
