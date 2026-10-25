#!/usr/bin/env bash
#
# Docker integration test for the PlayVideo plugin.
#
# It tests LMS 9.0.0 and 9.1.1 in dedicated containers:
#   - scan of video/audio fixtures and the large ref/*.mkv file
#   - content types, tags, chapters, cover
#   - playback through LMS's own decoders (Opus -> sox -> flac)
#   - external AC3 plugin priority and ffmpeg fallback
#   - optional combined tests with ../lms-plugin-ffmpeg
#
# The ref/ directory is local-only test media and is never copied into git.
#
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF_DIR="$ROOT/ref"
FFMPEG_PLUGIN_DIR="${FFMPEG_PLUGIN_DIR:-$ROOT/../lms-plugin-ffmpeg}"
VERSIONS="${VERSIONS:-9.0.0 9.1.1}"
TMP_BASE="${PLAYVIDEO_TEST_TMP:-/tmp/playvideo-docker}"
KEEP="${KEEP:-0}"
TEST_IMAGE_PREFIX="${TEST_IMAGE_PREFIX:-lms-playvideo-test}"

FAILS=0
CHECKS=0
CURRENT_VERSION=""
CURRENT_CONTAINER=""
CURRENT_HTTP=""
CURRENT_CLI=""
CURRENT_SLIM=""
CURRENT_CONFIG=""
CURRENT_MEDIA=""
CURRENT_MAC=""
PLAYVIDEO_STAGE="$TMP_BASE/plugin/PlayVideo"
SQ_PID=""

log()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
pass() { CHECKS=$((CHECKS+1)); printf '   PASS  %s\n' "$*"; }
fail() { FAILS=$((FAILS+1)); printf '   FAIL  %s\n' "$*"; }

cleanup_player() {
    if [ -n "${SQ_PID:-}" ] && kill -0 "$SQ_PID" 2>/dev/null; then
        kill "$SQ_PID" 2>/dev/null || true
        wait "$SQ_PID" 2>/dev/null || true
    fi
    SQ_PID=""
}

cleanup_container() {
    if [ -n "${CURRENT_CONTAINER:-}" ] && docker ps -a --format '{{.Names}}' | grep -qx "$CURRENT_CONTAINER"; then
        if [ "$KEEP" = "1" ]; then
            info "keeping container $CURRENT_CONTAINER and $CURRENT_CONFIG"
        else
            docker rm -f "$CURRENT_CONTAINER" >/dev/null 2>&1 || true
        fi
    fi
    CURRENT_CONTAINER=""
}

cleanup() {
    cleanup_player
    cleanup_container
}
trap cleanup EXIT INT TERM

image_for() {
    case "$1" in
        9.0.0) echo "${LMS_IMAGE_900:-dockerhub.fchscastle.com/lmscommunity/lyrionmusicserver:9.0.0}" ;;
        9.1.1) echo "${LMS_IMAGE_911:-lmscommunity/lyrionmusicserver:9.1.1}" ;;
        *) echo "" ;;
    esac
}

ports_for() {
    case "$1" in
        9.0.0) echo "19000 19090 13483" ;;
        9.1.1) echo "19001 19091 13484" ;;
    esac
}

mac_for() {
    case "$1" in
        9.0.0) echo "02:00:00:00:02:00" ;;
        9.1.1) echo "02:00:00:00:02:01" ;;
    esac
}

sql() {
    docker exec "$CURRENT_CONTAINER" sqlite3 /config/cache/library.db "$1" 2>/dev/null
}

sql_scalar() {
    docker exec "$CURRENT_CONTAINER" sqlite3 -noheader /config/cache/library.db "$1" 2>/dev/null | head -n 1
}

rpc() {
    local player="$1"
    local cmd="$2"
    curl -s --max-time 15 "http://127.0.0.1:$CURRENT_HTTP/jsonrpc.js" \
        -H 'Content-Type: application/json' \
        --data "{\"id\":1,\"method\":\"slim.request\",\"params\":[\"$player\",$cmd]}" 2>/dev/null
}

json_value() {
    # $1 = result key, stdin = JSON-RPC response
    python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit(0)
r=d.get("result") or {}
v=r.get(sys.argv[1],"")
print("" if v is None else v)' "$1" 2>/dev/null
}

json_int() {
    # $1 = result key, stdin = JSON-RPC response
    python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print(0); raise SystemExit(0)
r=d.get("result") or {}
try:
    print(int(r.get(sys.argv[1],0) or 0))
except Exception:
    print(0)' "$1" 2>/dev/null
}

build_image() {
    local version="$1" base tag
    base="$(image_for "$version")"
    tag="$TEST_IMAGE_PREFIX:$version"
    if docker image inspect "$tag" >/dev/null 2>&1; then
        info "using existing test image $tag"
        return 0
    fi
    if ! docker image inspect "$base" >/dev/null 2>&1; then
        info "pulling base image $base"
        docker pull "$base" >/dev/null || { fail "cannot pull $base"; return 1; }
    fi
    info "building $tag from $base"
    docker build -q -t "$tag" --build-arg BASE_IMAGE="$base" -f "$ROOT/script/Dockerfile.test" "$ROOT" \
        || { fail "docker build failed for $version"; return 1; }
}

make_fixtures() {
    local dir="$1"
    mkdir -p "$dir" "$dir/raw"
    local ref
    ref="$(find "$REF_DIR" -maxdepth 1 -type f -name '*.mkv' -print0 2>/dev/null | head -z -n 1 | tr -d '\0')"
    if [ -n "$ref" ] && [ -f "$ref" ]; then
        cp --reflink=auto "$ref" "$dir/concert_ref.mkv" 2>/dev/null || cp "$ref" "$dir/concert_ref.mkv"
        info "large ref file staged: $(du -h "$dir/concert_ref.mkv" | cut -f1)"
    else
        info "WARNING: no ref/*.mkv found; large-file checks will be skipped"
    fi

    local vf='-f lavfi -i testsrc=size=160x120:rate=10'
    local af='-f lavfi -i sine=frequency=440:sample_rate=48000'
    local common='-shortest -y -v error'

    # shellcheck disable=SC2086
    ffmpeg $vf $af -t 4 -c:v libx264 -preset ultrafast -c:a aac $common "$dir/mp4_aac.mp4" || fail "fixture mp4_aac"
    # shellcheck disable=SC2086
    ffmpeg $vf $af -t 4 -c:v libx264 -preset ultrafast -c:a libopus $common "$dir/mkv_opus.mkv" || fail "fixture mkv_opus"
    # shellcheck disable=SC2086
    ffmpeg $vf $af -t 4 -c:v libx264 -preset ultrafast -c:a aac $common "$dir/mkv_aac.mkv" || fail "fixture mkv_aac"
    # shellcheck disable=SC2086
    ffmpeg $vf $af -t 20 -c:v libx264 -preset ultrafast -c:a ac3 $common "$dir/mkv_ac3.mkv" || fail "fixture mkv_ac3"
    # shellcheck disable=SC2086
    ffmpeg $vf $af -t 4 -c:v libx264 -preset ultrafast -c:a flac $common "$dir/mkv_flac.mkv" || fail "fixture mkv_flac"
    # shellcheck disable=SC2086
    ffmpeg $vf $af -t 4 -c:v libx264 -preset ultrafast -c:a libmp3lame -q:a 5 $common "$dir/mkv_mp3.mkv" || fail "fixture mkv_mp3"
    # shellcheck disable=SC2086
    ffmpeg $vf $af -t 4 -c:v libx264 -preset ultrafast -c:a libvorbis $common "$dir/mkv_vorbis.mkv" || fail "fixture mkv_vorbis"
    # shellcheck disable=SC2086
    ffmpeg $vf -t 3 -c:v libx264 -preset ultrafast -an -y -v error "$dir/noaudio.mp4" || fail "fixture noaudio"
    # shellcheck disable=SC2086
    ffmpeg $af -t 4 -c:a aac -y -v error "$dir/audio_aac.m4a" || fail "fixture audio_aac"
    # shellcheck disable=SC2086
    ffmpeg $af -t 4 -c:a alac -y -v error "$dir/audio_alac.m4a" || fail "fixture audio_alac"
    # shellcheck disable=SC2086
    ffmpeg $af -t 4 -c:a aac -y -v error "$dir/audio_aac.mp4" || fail "fixture audio_aac_mp4"
}

wait_http() {
    local i
    for i in $(seq 1 120); do
        if curl -sf --max-time 2 "http://127.0.0.1:$CURRENT_HTTP/" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_player() {
    local i out
    for i in $(seq 1 90); do
        out="$(rpc "" '["players",0,100]')"
        if printf '%s' "$out" | grep -q "$CURRENT_MAC"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

start_player() {
    cleanup_player
    SQ_PID=""
    squeezelite -s "127.0.0.1:$CURRENT_SLIM" -o - -a 16 -c flac,pcm,mp3 \
        -m "$CURRENT_MAC" -n "playvideo-test" \
        -f "$CURRENT_CONFIG/squeezelite.log" 2>/dev/null \
        | perl "$ROOT/script/fixtures/pace-audio.pl" --rate 48000 --channels 2 --bytes 2 >/dev/null 2>&1 &
    SQ_PID=$!
    wait_player
}

ensure_player() {
    if [ -z "${SQ_PID:-}" ] || ! kill -0 "$SQ_PID" 2>/dev/null; then
        info "squeezelite is gone, restarting test player"
        start_player || { fail "could not restart squeezelite"; return 1; }
    fi
    return 0
}

stage_playvideo() {
    rm -rf "$PLAYVIDEO_STAGE"
    mkdir -p "$PLAYVIDEO_STAGE"
    local f
    for f in install.xml lib HTML custom-types.conf custom-convert.conf strings.txt VERSION \
             README.md README.zh-CN.md LICENSE THIRD_PARTY_NOTICES.md Makefile; do
        [ -e "$ROOT/$f" ] && cp -a "$ROOT/$f" "$PLAYVIDEO_STAGE/"
    done
    find "$PLAYVIDEO_STAGE" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$PLAYVIDEO_STAGE" -type f -exec chmod 644 {} + 2>/dev/null || true
}

start_container() {
    local version="$1" image="$2"
    stage_playvideo
    rm -rf "$CURRENT_CONFIG"
    mkdir -p "$CURRENT_CONFIG"
    docker rm -f "$CURRENT_CONTAINER" >/dev/null 2>&1 || true
    docker run -d --name "$CURRENT_CONTAINER" \
        -p "127.0.0.1:${CURRENT_HTTP}:${CURRENT_HTTP}" \
        -p "127.0.0.1:${CURRENT_CLI}:9090" \
        -p "${CURRENT_SLIM}:3483" \
        -v "$PLAYVIDEO_STAGE:/config/cache/Plugins/PlayVideo:ro" \
        -v "$REF_DIR:/music/ref:ro" \
        -v "$CURRENT_MEDIA:/music/fixtures:ro" \
        -v "$CURRENT_CONFIG:/config" \
        -e "HTTP_PORT=${CURRENT_HTTP}" \
        -e "EXTRA_ARGS=--logging=player.source=DEBUG,plugin.playvideo=DEBUG" \
        "$image" >/dev/null || { fail "docker run failed"; return 1; }

    wait_http || { fail "LMS HTTP did not start"; docker exec "$CURRENT_CONTAINER" tail -80 /config/logs/server.log 2>/dev/null; return 1; }
    info "LMS is up on http://127.0.0.1:$CURRENT_HTTP"

    start_player || { fail "squeezelite player not seen by LMS"; return 1; }
    info "squeezelite player connected"

    # Trigger a full scan; fresh config may already have started one.
    rpc "" '["rescan"]' >/dev/null
    return 0
}

wait_scan() {
    local i rows proc
    for i in $(seq 1 180); do
        rows="$(sql_scalar "select count(*) from tracks where content_type in ('vop','vaa','vvo','vfl','vmp','vac','vae','vdt','vth','vid');")"
        proc="$(docker exec "$CURRENT_CONTAINER" sh -c 'pgrep -f "[s]canner.pl" >/dev/null 2>&1 && echo 1 || echo 0' 2>/dev/null)"
        if [ "${rows:-0}" -ge 9 ] && [ "${proc:-0}" = "0" ]; then
            info "scan done, ${rows} video tracks"
            return 0
        fi
        sleep 1
    done
    docker exec "$CURRENT_CONTAINER" tail -60 /config/logs/scanner.log 2>/dev/null
    return 1
}

restart_lms() {
    cleanup_player
    # Stop first: LMS writes its plugin cache again during graceful shutdown,
    # which would otherwise resurrect a stale manifest list (seen on 9.0.0).
    docker stop "$CURRENT_CONTAINER" >/dev/null 2>&1 || { fail "docker stop failed"; return 1; }
    rm -f "$CURRENT_CONFIG/cache/plugin-data.yaml"
    docker start "$CURRENT_CONTAINER" >/dev/null 2>&1 || { fail "docker start failed"; return 1; }
    wait_http || { fail "LMS HTTP did not restart"; return 1; }
    start_player || { fail "player not reconnected"; return 1; }
    sleep 1
    return 0
}

install_plugin() {
    local src="$1" name="$2"
    rm -rf "$CURRENT_CONFIG/cache/Plugins/$name"
    cp -a "$src" "$CURRENT_CONFIG/cache/Plugins/$name" || { fail "cannot install $name"; return 1; }
    # never let nested test fixtures appear as plugins to LMS
    rm -rf "$CURRENT_CONFIG/cache/Plugins/$name/.git" \
           "$CURRENT_CONFIG/cache/Plugins/$name/script" \
           "$CURRENT_CONFIG/cache/Plugins/$name/t" \
           "$CURRENT_CONFIG/cache/Plugins/$name/dist" \
           "$CURRENT_CONFIG/cache/Plugins/$name/build" \
           "$CURRENT_CONFIG/cache/Plugins/$name/ref"
    find "$CURRENT_CONFIG/cache/Plugins/$name" -type d -exec chmod 755 {} + 2>/dev/null || true
    find "$CURRENT_CONFIG/cache/Plugins/$name" -type f -exec chmod 644 {} + 2>/dev/null || true
    rm -f "$CURRENT_CONFIG/cache/plugin-data.yaml"
}

remove_plugin() {
    local name="$1"
    rm -rf "$CURRENT_CONFIG/cache/Plugins/$name"
    rm -f "$CURRENT_CONFIG/cache/plugin-data.yaml"
}

track_id() {
    sql_scalar "select id from tracks where url like '%fixtures/$1' limit 1"
}

play_fixture() {
    local name="$1" id attempt i mode t
    id="$(track_id "$name")"
    if [ -z "$id" ]; then fail "no track for $name"; return 1; fi
    for attempt in 1 2; do
        ensure_player || return 1
        rpc "$CURRENT_MAC" "[\"playlistcontrol\",\"cmd:load\",\"track_id:$id\"]" >/dev/null
        rpc "$CURRENT_MAC" '["play"]' >/dev/null
        for i in $(seq 1 25); do
            sleep 1
            mode="$(json_value mode <<<"$(rpc "$CURRENT_MAC" '["status","-",1,"tags:mode,time,duration"]')")"
            t="$(json_int time <<<"$(rpc "$CURRENT_MAC" '["status","-",1,"tags:mode,time,duration"]')")"
            if [ "$t" -gt 0 ] 2>/dev/null; then
                info "$name playing (mode=$mode time=${t}s)"
                return 0
            fi
        done
        stop_playback
    done
    fail "$name did not start playing"
    docker exec "$CURRENT_CONTAINER" tail -40 /config/logs/server.log 2>/dev/null
    return 1
}

stop_playback() {
    rpc "$CURRENT_MAC" '["stop"]' >/dev/null 2>&1 || true
    sleep 1
}

log_lines() { docker exec "$CURRENT_CONTAINER" sh -c 'wc -l < /config/logs/server.log' 2>/dev/null | tr -d ' '; }

log_has_since() {
    local from="$1" pattern="$2"
    docker exec "$CURRENT_CONTAINER" sh -c "tail -n +$((from+1)) /config/logs/server.log 2>/dev/null | grep -qF -- '$pattern'"
}

assert_db() {
    local desc="$1" sqlq="$2" expected="$3" got
    got="$(sql_scalar "$sqlq")"
    if [ "$got" = "$expected" ]; then pass "$desc"; else fail "$desc (expected '$expected', got '$got')"; fi
}

assert_db_nonempty() {
    local desc="$1" sqlq="$2" got
    got="$(sql_scalar "$sqlq")"
    if [ -n "$got" ] && [ "$got" != "0" ]; then pass "$desc"; else fail "$desc (got '$got')"; fi
}

assert_log_since() {
    local desc="$1" from="$2" pattern="$3"
    if log_has_since "$from" "$pattern"; then pass "$desc"; else fail "$desc (missing '$pattern')"; fi
}

check_playvideo_cli() {
    local out chapters info_json
    out="$(rpc "" '["playvideo","status"]')"
    if printf '%s' "$out" | grep -q '"ffmpeg"'; then pass "playvideo status"; else fail "playvideo status: $out"; fi

    info_json="$(rpc "" '["playvideo","info","file:///music/fixtures/concert_ref.mkv"]')"
    if printf '%s' "$info_json" | grep -q '1280'; then pass "playvideo info (1280x720)"; else fail "playvideo info: $info_json"; fi

    chapters="$(rpc "" '["playvideo","chapters","file:///music/fixtures/concert_ref.mkv"]')"
    if printf '%s' "$chapters" | grep -q '不会说话的爱情' && printf '%s' "$chapters" | grep -q '中国孩子'; then
        pass "playvideo chapters (2 chapter titles)"
    else
        fail "playvideo chapters: $chapters"
    fi

    out="$(rpc "$CURRENT_MAC" '["playvideo","items",0,10]')"
    if printf '%s' "$out" | grep -q 'loop_loop' && printf '%s' "$out" | grep -q '巴黎消夏'; then
        pass "playvideo feed lists video tracks"
    else
        fail "playvideo feed: $out"
    fi
}

assert_scan() {
    local ct
    assert_db "ref track type is vop" "select content_type from tracks where url like '%/fixtures/concert_ref.mkv' limit 1" "vop"
    assert_db "ref track is audio" "select audio from tracks where url like '%/fixtures/concert_ref.mkv' limit 1" "1"
    assert_db_nonempty "ref duration" "select secs > 800 from tracks where url like '%/fixtures/concert_ref.mkv' limit 1"
    assert_db "ref sample rate" "select samplerate from tracks where url like '%/fixtures/concert_ref.mkv' limit 1" "48000"
    assert_db "ref channels" "select channels from tracks where url like '%/fixtures/concert_ref.mkv' limit 1" "2"
    assert_db_nonempty "ref title" "select title like '%巴黎%' from tracks where url like '%/fixtures/concert_ref.mkv' limit 1"
    assert_db_nonempty "ref artist" "select count(*) > 0 from contributor_track ct join contributors c on c.id = ct.contributor join tracks t on t.id = ct.track where t.url like '%/fixtures/concert_ref.mkv' and length(c.name) > 0"
    assert_db_nonempty "ref genre" "select count(*) > 0 from genre_track gt join genres g on g.id = gt.genre join tracks t on t.id = gt.track where t.url like '%/fixtures/concert_ref.mkv' and length(g.name) > 0"
    assert_db "ref year" "select year from tracks where url like '%/fixtures/concert_ref.mkv' limit 1" "2011"
    assert_db_nonempty "GBK filename ref row exists" "select count(*) > 0 from tracks where url like '%music/ref/%'"

    for pair in "mp4_aac.mp4:vaa" "mkv_opus.mkv:vop" "mkv_aac.mkv:vaa" "mkv_ac3.mkv:vac" "mkv_flac.mkv:vfl" "mkv_mp3.mkv:vmp" "mkv_vorbis.mkv:vvo"; do
        f="${pair%%:*}"; want="${pair##*:}"
        ct="$(sql_scalar "select content_type from tracks where url like '%fixtures/$f' limit 1")"
        if [ "$ct" = "$want" ]; then pass "fixture $f -> $want"; else fail "fixture $f expected $want got '$ct'"; fi
    done

    assert_db "audio m4a stays mp4/mp4x" "select content_type in ('mp4','mp4x') from tracks where url like '%fixtures/audio_aac.m4a' limit 1" "1"
    assert_db "audio alac stays alc/alcx" "select content_type in ('alc','alcx') from tracks where url like '%fixtures/audio_alac.m4a' limit 1" "1"
    assert_db "audio-only mp4 stays mp4/mp4x" "select content_type in ('mp4','mp4x') from tracks where url like '%fixtures/audio_aac.mp4' limit 1" "1"
    assert_db "no-audio video not scanned" "select count(*) from tracks where url like '%fixtures/noaudio.mp4'" "0"
}

assert_playback() {
    local from status t
    from="$(log_lines)"
    play_fixture concert_ref.mkv || return 1
    assert_log_since "ref uses vop->flc" "$from" "vop->flc"
    assert_log_since "ref decoded by LMS sox" "$from" "-t opus"
    pass "ref playback started"
    local attempt
    for attempt in 1 2; do
        ensure_player || break
        rpc "$CURRENT_MAC" '["time","400"]' >/dev/null
        sleep 3
        t="$(json_int time <<<"$(rpc "$CURRENT_MAC" '["status","-",1,"tags:mode,time,duration"]')")"
        if [ "${t:-0}" -ge 395 ] 2>/dev/null; then
            pass "ref seek to 400s"
            break
        fi
        if [ "$attempt" = "2" ]; then fail "ref seek (time=$t)"; fi
    done
    stop_playback

    from="$(log_lines)"
    play_fixture mkv_ac3.mkv || return 1
    assert_log_since "AC3 without external plugin uses vac fallback" "$from" "vac->flc"
    stop_playback
}

test_version() {
    local version="$1"
    CURRENT_VERSION="$version"
    CURRENT_CONTAINER="playvideo-test-${version//./-}"
    read -r CURRENT_HTTP CURRENT_CLI CURRENT_SLIM <<<"$(ports_for "$version")"
    CURRENT_MAC="$(mac_for "$version")"
    CURRENT_CONFIG="$TMP_BASE/$version/config"
    CURRENT_MEDIA="$TMP_BASE/$version/media"

    log "LMS $version (container $CURRENT_CONTAINER)"
    build_image "$version" || return 1
    make_fixtures "$CURRENT_MEDIA" || return 1
    start_container "$version" "$TEST_IMAGE_PREFIX:$version" || return 1
    wait_scan || { fail "scan did not complete"; return 1; }

    assert_scan
    check_playvideo_cli
    assert_playback

    # --- external dedicated AC3 plugin (no FFmpeg plugin installed) ---
    install_plugin "$ROOT/script/fixtures/TestAc3" TestAc3 || return 1
    restart_lms || return 1
    docker exec "$CURRENT_CONTAINER" rm -f /tmp/playvideo-fake-ac3-used
    from="$(log_lines)"
    if play_fixture mkv_ac3.mkv; then
        if docker exec "$CURRENT_CONTAINER" test -f /tmp/playvideo-fake-ac3-used; then
            pass "dedicated AC3 plugin profile selected"
        else
            fail "dedicated AC3 marker missing"
        fi
        assert_log_since "dedicated AC3 logs ac3->flc" "$from" "ac3->flc"
    fi
    stop_playback

    remove_plugin TestAc3
    install_plugin "$ROOT/script/fixtures/TestAc3Broken" TestAc3Broken || return 1
    restart_lms || return 1
    docker exec "$CURRENT_CONTAINER" rm -f /tmp/playvideo-fake-ac3-used
    from="$(log_lines)"
    if play_fixture mkv_ac3.mkv; then
        assert_log_since "broken external plugin falls back to vac" "$from" "vac->flc"
        if docker exec "$CURRENT_CONTAINER" test -f /tmp/playvideo-fake-ac3-used; then
            fail "broken external plugin unexpectedly used marker"
        else
            pass "broken external plugin not used"
        fi
    fi
    stop_playback
    remove_plugin TestAc3Broken

    # --- optional combined test with lms-plugin-ffmpeg ---
    if [ -f "$FFMPEG_PLUGIN_DIR/install.xml" ]; then
        log "LMS $version + lms-plugin-ffmpeg"
        install_plugin "$FFMPEG_PLUGIN_DIR" FFmpeg || return 1
        restart_lms || return 1
        from="$(log_lines)"
        if play_fixture mkv_ac3.mkv; then
            assert_log_since "FFmpeg plugin ac3 profile selected" "$from" "ac3->flc"
            if docker exec "$CURRENT_CONTAINER" grep -q "libmp3lame\|-c:a flac" /config/logs/server.log 2>/dev/null; then
                pass "FFmpeg plugin command observed"
            else
                fail "FFmpeg plugin command not observed"
            fi
        fi
        stop_playback

        # dedicated AC3 plugin must win in FFmpeg plugin fallback mode
        install_plugin "$ROOT/script/fixtures/TestAc3" TestAc3 || return 1
        restart_lms || return 1
        docker exec "$CURRENT_CONTAINER" rm -f /tmp/playvideo-fake-ac3-used
        from="$(log_lines)"
        if play_fixture mkv_ac3.mkv; then
            if docker exec "$CURRENT_CONTAINER" test -f /tmp/playvideo-fake-ac3-used; then
                pass "dedicated AC3 wins over ffmpeg fallback"
            else
                fail "dedicated AC3 did not win over ffmpeg fallback"
            fi
        fi
        stop_playback

        # prefer mode: FFmpeg plugin should win over dedicated plugin
        rpc "" '["pref","plugin.ffmpeg:mode","prefer"]' >/dev/null
        restart_lms || return 1
        docker exec "$CURRENT_CONTAINER" rm -f /tmp/playvideo-fake-ac3-used
        from="$(log_lines)"
        if play_fixture mkv_ac3.mkv; then
            if docker exec "$CURRENT_CONTAINER" test -f /tmp/playvideo-fake-ac3-used; then
                fail "prefer mode still selected dedicated AC3 plugin"
            else
                pass "prefer mode selected FFmpeg plugin over dedicated AC3"
            fi
        fi
        stop_playback
        remove_plugin TestAc3

        # ref still must use LMS sox, not ffmpeg
        from="$(log_lines)"
        if play_fixture concert_ref.mkv; then
            assert_log_since "ref still uses vop + sox with FFmpeg plugin installed" "$from" "-t opus"
        fi
        stop_playback
        remove_plugin FFmpeg
    else
        info "skip combined FFmpeg plugin test (no install.xml at $FFMPEG_PLUGIN_DIR)"
    fi

    cleanup_player
    cleanup_container
    return 0
}

main() {
    mkdir -p "$TMP_BASE"
    if [ ! -x "$(command -v docker)" ]; then
        echo "docker is required" >&2
        exit 2
    fi
    if [ ! -x "$(command -v squeezelite)" ]; then
        echo "squeezelite is required for playback tests" >&2
        exit 2
    fi
    if [ ! -x "$(command -v ffmpeg)" ]; then
        echo "host ffmpeg is required to create fixtures" >&2
        exit 2
    fi

    for version in $VERSIONS; do
        test_version "$version"
        if [ "$FAILS" -gt 0 ] && [ "${STOP_ON_FAIL:-0}" = "1" ]; then
            break
        fi
    done

    log "RESULT: $CHECKS checks, $FAILS failures"
    if [ "$FAILS" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
