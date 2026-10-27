# Lyrion Music Server 的 PlayVideo 插件

[English README](README.md)

**PlayVideo** 将本地视频文件（MP4、MKV、WebM、AVI、MPEG-TS 等）中的音轨加入
Lyrion Music Server（LMS）音乐库。插件会扫描这些文件，使用 `ffprobe` 读取容器
与音频元数据，使视频文件可以像普通曲目一样浏览、搜索、加入播放列表，并由 LMS
自带的解码器或 `ffmpeg` 解码播放。

**视频画面不会被渲染**。PlayVideo 只负责音频：影片、演唱会录像、音乐视频和剧集
可以在任意 Squeezebox/Lyrion 播放器上播放，但没有视频输出、字幕或 DRM 支持。

## 功能

- 视频文件出现在 **我的音乐 → 视频（Videos）** 菜单中（每个菜单最多 5000 条）。
- 使用 `ffprobe` 读取元数据；MP4 系列文件仍优先使用 LMS 原生的 MP4/Movie
  读取器，失败时才使用 PlayVideo 的探测结果。
- 根据音频编码映射为 LMS 内容类型，使转码和播放器格式能力判断保持正常。
- 视频容器中的 Opus、AAC、Vorbis、FLAC、MP3 使用 LMS 原生解码。
- AC3、E-AC3、DTS、TrueHD 等 LMS 无法直接解码的编码使用 `ffmpeg` 回退解码。
- 提供 FLAC、MP3、PCM、**AAC（ADTS）**、**Ogg Vorbis** 与 **Opus** 输出配置；
  其中 AAC/Ogg/Opus 对所有内容类型都由 `ffmpeg` 解码并编码，支持最大码率与降采样。
- 纯 Perl 的 `codec_capabilities` 能力声明（提供方 `playvideo`，优先级
  `150`/`1`），CodecSwitch 等插件可在不探测 `ffmpeg` 的情况下协商解码能力。
- 曲目信息菜单中提供 **视频详情** 与 **章节**。章节是跳转快捷方式，不是独立曲目。
- 可选检测并与伴随项目 `lms-plugin-ffmpeg` 集成。
- 提供 CLI/JSON-RPC 接口（`playvideo status|info|chapters`）用于诊断和自动化。
- 界面提供英文与简体中文（`ZH_CN`）字符串。

## 系统要求

- Lyrion Music Server **9.0.0 或 9.1.x**（插件清单目标为 9.0.0–9.*）。
- 运行 LMS 的服务器上安装 `ffmpeg` **和** `ffprobe`，且 LMS 进程有执行权限。
  缺少它们时插件仍可加载，但无法扫描视频文件，也无法解码 AC3/DTS/TrueHD。
- LMS 原生的解码辅助程序 `sox`、`faad`、`flac`、`lame` 通常随 LMS 一起安装。
  缺少某个程序只会影响对应的原生解码配置。
- 不需要额外的 Perl CPAN 模块。优先使用 `JSON::XS`，否则回退到 `JSON::PP`
  解析 `ffprobe` 输出。

### 安装 ffmpeg

Debian/Ubuntu：

```sh
sudo apt-get update
sudo apt-get install -y ffmpeg
```

Alpine（官方 Docker 镜像基于 Alpine）：

```sh
apk add --no-cache ffmpeg
```

Windows/macOS 请通过常用包管理器安装 FFmpeg，并在插件设置中填写
`ffmpeg.exe`/`ffprobe.exe` 的完整路径。

## 构建

插件版本只存放在 [VERSION](VERSION) 这一个文件里。在仓库根目录执行一键构建：

```sh
./build.sh                 # 运行单元测试，生成目录和压缩包
./build.sh --no-test       # 跳过单元测试
./build.sh --no-archive    # 只生成 dist/PlayVideo/
```

脚本会从受版本控制的 `install.xml.in` 模板渲染 `build/install.xml`，并生成：

```
dist/PlayVideo/                 # 可直接复制到 <LMS>/Plugins/
dist/PlayVideo-<VERSION>.zip    # LMS 插件管理器压缩包
dist/PlayVideo-<VERSION>.tar.gz # 通用压缩包
```

`make dist` 调用同一个脚本。不要手工修改 `install.xml`；需要改版本时只修改
`VERSION`（必要时再改 `install.xml.in`）。

## 安装插件

1. 将插件文件夹复制到 LMS 的 `Plugins` 目录下，文件夹名必须**正好**是
   `PlayVideo`：

   ```
   <LMS>/Plugins/PlayVideo/install.xml
   <LMS>/Plugins/PlayVideo/lib/Plugins/PlayVideo/Plugin.pm
   <LMS>/Plugins/PlayVideo/HTML/EN/plugins/PlayVideo/settings.html
   <LMS>/Plugins/PlayVideo/custom-types.conf
   <LMS>/Plugins/PlayVideo/custom-convert.conf
   <LMS>/Plugins/PlayVideo/strings.txt
   ```

   文件夹名决定模块名（`Plugins::PlayVideo`），不要改名（例如改成
   `PlayVideo-<版本>`）。

   - **Git 检出：** 在仓库中运行 `./build.sh`，把 `dist/PlayVideo/` 复制到
     `<LMS>/Plugins/PlayVideo`。`ref/` 只是未跟踪的测试媒体，不需要复制。
   - **发布包：** 解压 `dist/PlayVideo-<VERSION>.zip`，把其中的 `PlayVideo`
     文件夹复制到 `<LMS>/Plugins/`。

2. 重启 Lyrion Music Server。
3. 在 *设置 → 插件* 中确认 PlayVideo 已启用（插件清单默认启用）。
4. 打开 *设置 → PlayVideo*，检查 ffmpeg/ffprobe 状态。
5. 将视频所在文件夹加入 LMS 媒体文件夹，并执行 **重新扫描媒体库**。

### Docker

LMS 官方 Docker 镜像默认不包含 ffmpeg。可以构建一个小的派生镜像：

```dockerfile
FROM lmscommunity/lyrionmusicserver:9.1.1
USER root
RUN apk add --no-cache ffmpeg
# 如果镜像默认使用非 root 用户，请恢复原来的 USER，例如：
# USER squeezeboxserver
```

也可以挂载静态编译的 ffmpeg 二进制，并在插件设置中指定路径。

插件本身应放在持久的 LMS 配置卷中：

```sh
mkdir -p ./config/Plugins
cp -r /path/to/PlayVideo ./config/Plugins/PlayVideo
docker run -d --name lyrion \
  -p 9000:9000 -p 9090:9090 \
  -v "$PWD/config":/config \
  -v /path/to/music:/music \
  lmscommunity/lyrionmusicserver:9.1.1
```

（请按实际情况调整镜像标签和路径。）然后重启容器。不要用
`docker exec apt-get install` 安装软件包，因为容器重建后改动会丢失。

## 扫描与播放原理

### 扫描

`custom-types.conf` 将常见视频后缀映射到 `vid` 内容类型，并增加按编码区分的
音频类型 `vop`、`vaa`、`vvo`、`vfl`、`vmp`、`vac`、`vae`、`vdt`、`vth`。
扫描过程：

1. LMS 调用注册的 MP4/视频标签读取器。
2. MP4 系列文件先交给 LMS 原生 `Slim::Formats::Movie` 读取；若无法得到可用
   标签，或文件不是 MP4 系列，则使用 `ffprobe` 探测。
3. 规范化后的探测结果转换为 LMS 标签（标题、专辑、艺术家、时长、采样率、
   声道数、码率、封面等）并写入媒体库数据库。
4. 音频编码决定内容类型：Opus → `vop`，AAC → `vaa`，Vorbis → `vvo`，
   FLAC → `vfl`，MP3 → `vmp`，AC3 → `vac`，E-AC3 → `vae`，DTS → `vdt`，
   TrueHD → `vth`，其他 → `vid`。

`ffprobe` 以列表方式直接调用（不经过 shell），超时可配置（默认 20 秒）。
`folderAsAlbum` 默认开启：文件没有专辑标签时，使用所在文件夹名作为专辑名，
适合“一个文件夹一部影片”的收藏方式。

### 播放

PlayVideo 曲目与普通音频曲目一致。LMS 只把音频流（`-vn -sn -dn -map 0:a:0`）
送给播放器，并使用第一条音轨。

| 视频中的音频编码 | 配置 | 解码路径 |
| --- | --- | --- |
| Opus | `vop` | ffmpeg 解复用 → `sox -t opus` → FLAC |
| AAC (ADTS) | `vaa` | ffmpeg 解复用 → `faad` → FLAC |
| Vorbis | `vvo` | ffmpeg 解复用 → `sox -t ogg` → FLAC |
| FLAC | `vfl` | ffmpeg 复制 → LMS FLAC/MP3/PCM 输出 |
| MP3 | `vmp` | ffmpeg 复制 → LMS MP3/FLAC/PCM 输出 |
| AC3 | `vac` | 有外部 AC3 插件时优先使用，否则 ffmpeg 解码 |
| E-AC3 | `vae` | 有外部 E-AC3/AC3 插件时优先，否则 ffmpeg |
| DTS | `vdt` | 有外部 DTS 插件时优先，否则 ffmpeg |
| TrueHD | `vth` | 有外部 TrueHD 插件时优先，否则 ffmpeg |
| 其他 | `vid` | ffmpeg 解码 |

每种内容类型都有 FLAC、MP3、PCM、AAC（ADTS）、Ogg Vorbis 与 Opus 输出配置，
同时覆盖本地（`F`）和远程（`R`）播放器（共 120 个配置，由
`tools/gen-convert-conf.pl` 生成）。若播放器需要其他格式，LMS 会继续做常规的
播放器端转码。支持跳转：`START`/`END` 能力会让转换从指定位置重新开始。

| 输出 | 配置 | 路径 |
| --- | --- | --- |
| FLAC（`flc`） | 全部类型 | `vop`/`vaa`/`vvo`/`vfl`/`vmp` 原生解复用，其余由 `ffmpeg` 解码 |
| MP3（`mp3`） | 全部类型 | `vop`/`vaa`/`vvo`/`vfl` 原生解复用，其余由 `ffmpeg` 解码 |
| PCM（`pcm`） | 全部类型 | 五种原生编码解复用，其余由 `ffmpeg` 解码 |
| AAC（`aac`） | 全部类型 | `ffmpeg` 解码 + `-c:a aac -f adts`（默认 192 kbit/s） |
| Ogg Vorbis（`ogg`） | 全部类型 | `ffmpeg` 解码 + `-c:a libvorbis -f ogg`（默认 160 kbit/s） |
| Opus（`ops`） | 全部类型 | `ffmpeg` 解码 + `-c:a libopus -f ogg`（默认 128 kbit/s） |

对于 LMS 原生配置，`ffmpeg` 只负责解复用/复制，解码由 LMS 自带程序完成；
对于回退配置与 AAC/Ogg/Opus 配置，解码和编码由 `ffmpeg` 完成。AAC/Ogg/Opus
配置声明降采样（`D`）与最大码率（`B`，`-b:a %Bk`）；LMS 未指定码率上限时使用
上表的默认码率。

## 外部解码插件与优先级

AC3、E-AC3、DTS、TrueHD 可以由专用 LMS 插件（例如 AC3 插件或可选的 FFmpeg
插件）解码，也可以使用 PlayVideo 自带的 `ffmpeg` 回退配置。默认开启
**优先使用外部解码插件**：先尝试专用解码配置，再回退到 ffmpeg。关闭后，
这些编码始终使用 ffmpeg 回退配置。

该设置只影响上述回退类型。Opus/AAC/Vorbis/FLAC/MP3 始终使用前面介绍的原生
解码配置。

### 编解码能力声明

`Plugins::PlayVideo::Plugin->codec_capabilities()` 委托给纯 Perl 的
`Plugins::PlayVideo::Types::codec_capabilities()`，返回静态描述，不探测
`ffmpeg`，也不读取偏好设置：

```perl
{
    provider => 'playvideo',
    priority => 150,                      # 关闭外部解码器优先时为 1
    decode   => [ { from => [ ...全部十种内容类型... ],
                    to   => [ 'pcm', 'flc' ],
                    scope => [ 'local', 'remote' ] } ],
    convert  => [ { from => [ ...全部十种内容类型... ],
                    to   => [ 'flc', 'mp3', 'pcm', 'aac', 'ogg', 'ops' ],
                    scope => [ 'local', 'remote' ] } ],
    bitrate  => [ 'mp3', 'aac', 'ogg', 'ops' ],
}
```

`priority` 跟随 **优先使用外部解码插件** 设置。在 CodecSwitch 等编排插件使用的
排序中数字越小越优先：`150` 让 PlayVideo 排在专用解码器（如 FFmpeg 插件
`100`）之后，`1` 则让 PlayVideo 自己的 `ffmpeg` 配置优先。该声明是只读的，
设置页会以状态行显示。

### 可选的 lms-plugin-ffmpeg 集成

如果安装并启用了伴随项目 `lms-plugin-ffmpeg`：

- 优先使用该插件解析出的 `ffmpeg`/`ffprobe`；插件不存在或无法解析时才使用
  PlayVideo 设置中的路径或系统 PATH；
- 它的 AC3/E-AC3/DTS/TrueHD 转换配置会被 PlayVideo 的优先级钩子视为外部
  解码器，因此它的 *fallback*/*prefer* 模式也会影响最终使用哪个解码器；
- 可以在 FFmpeg 插件设置页统一管理共享的二进制路径。

FFmpeg 插件是可选的。只使用系统 `ffmpeg` 也能正常工作。

## 章节

章节来自容器元数据（`ffprobe`）。本地视频文件的曲目信息菜单会显示
**章节** 条目。选择章节时：

- 如果同一个视频正在播放，则直接跳转到章节起点；
- 否则先开始播放视频，PlayVideo 最多等待 15 秒，确认开始播放后再跳转。

章节**不是**独立曲目：不会作为专辑、标题或播放列表条目出现，也不会写入
媒体库数据库。没有章节的文件不显示章节列表。远程/流媒体文件不进行探测，
因此没有章节。

## 设置项

| 设置 | 默认值 | 说明 |
| --- | --- | --- |
| ffmpeg 可执行文件 | 空 | `ffmpeg` 路径；留空表示 FFmpeg 插件/系统 PATH |
| ffprobe 可执行文件 | 空 | `ffprobe` 路径；留空表示 FFmpeg 插件/系统 PATH |
| 使用文件夹名作为专辑 | 开 | 无专辑标签时的回退方案 |
| 探测超时（秒） | 20 | 单个文件 ffprobe 的最长运行时间（1–120） |
| 显示视频详情 | 开 | 曲目信息中的容器/编码/分辨率条目 |
| 显示章节 | 开 | 本地视频的章节菜单 |
| 优先使用外部解码插件 | 开 | AC3/DTS/TrueHD 先尝试专用插件再回退 ffmpeg |

设置页面的状态区域会显示解析到的二进制路径、版本和来源，是否安装了可选的
FFmpeg 插件，以及 LMS 解码辅助程序（`sox`、`faad`、`flac`、`lame`）是否可用。
只读的 **编解码能力** 区域会显示声明中的提供方、优先级、解码目标、输出格式与
码率目标。它跟随 *优先使用外部解码插件* 设置，不新增任何偏好项。

## CLI / JSON-RPC

以下命令都是服务器查询，不需要指定播放器。`status` 报告解析到的二进制与配置；
`info` 和 `chapters` 接收曲目 URL（本地文件可用 `file://` URL，或媒体库中的
曲目 URL）。

经典 CLI（端口 9090）：

```text
playvideo status ?
playvideo info file:///music/Videos/Concert.mkv ?
playvideo chapters file:///music/Videos/Concert.mkv ?
```

也可以使用 CLI 标签前缀形式（`playvideo info url:file:///music/Videos/Concert.mkv ?`），两种形式都支持。

JSON-RPC（端口 9000）：

```sh
curl -s http://localhost:9000/jsonrpc.js \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["",["playvideo","status"]]}'

curl -s http://localhost:9000/jsonrpc.js \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"method":"slim.request","params":["",["playvideo","chapters","file:///music/Videos/Concert.mkv"]]}'
```

`playvideo chapters` 返回 `count` 以及 `chapters_loop` 数组，每项包含
`start`、`end`（如果有）、`start_text`、`title`。

## 测试

仓库包含单元测试和 Docker 测试脚本：

```sh
make test                 # prove -l t
make lint                 # 静态 UI 检查；设置 LMS_HOME=/lms 后还会执行 perl -c
make docker-test          # LMS 9.0.0/9.1.1 容器（需要 Docker）
make dist                 # 生成 dist/PlayVideo/
make install PLUGINS_DIR=/var/lib/squeezeboxserver/Plugins
```

- `make test` 可在主机上运行；需要完整 LMS 的测试在未设置 `LMS_HOME` 时会跳过。
  `t/40-conf.t` 检查 120 个生成的配置（包括 ADTS/Ogg 的真实 `ffmpeg` 签名），
  `t/55-capabilities.t` 检查纯 Perl 能力声明与 `custom-convert.conf` 的一致性。
- `make lint` 始终检查清单、字符串、设置模板和必需文件；设置 `LMS_HOME`
  指向 LMS 目录时还会对每个插件模块执行 `perl -c`。
- `make docker-test` 调用 `script/docker-test.sh`，启动 LMS 9.0.0 与 9.1.1
  镜像，在镜像中安装 ffmpeg，并验证扫描、探测和解码优先级。播放断言使用
  主机上的 `squeezelite`。
- `ref/` 是未跟踪的测试媒体，不要提交受版权保护的媒体文件；测试应自行生成
  或使用自己的固定样本。

最近一次使用本仓库 Docker 测试脚本的验证结果：**LMS 9.0.0 与 9.1.1 全部检查
通过**，覆盖扫描/元数据、`vop -> flc` 解封装 + LMS `sox` 解码、跳转、
纯视频文件跳过、外部 AC3 优先级矩阵（fallback 下专用插件优先，prefer 下
FFmpeg 插件优先）以及可选的 `lms-plugin-ffmpeg` 集成。

## 限制

- **不渲染视频。** 只播放音轨，没有视频窗口、字幕、多音轨选择或菜单导航。
- **不支持 DRM。** 加密/受保护的文件无法探测或播放。
- **远程文件仅尽力支持。** 在线音乐库、UPnP 和网络流不会进行视频章节探测；
  详细元数据和章节只支持本地文件。
- **只使用一条音轨。** 使用第一条音频流，无法在多个音轨之间切换。
- **非 UTF-8 路径。** 不会向 `ffprobe` 请求文件名，并尽量避免无效 UTF-8；
  但旧文件系统或本地编码的文件名仍可能导致标签缺失或路径不匹配。建议将文件
  名转换为 UTF-8。
- **大型媒体库。** 菜单最多显示 5000 个视频曲目（超出时日志会提示截断）。
  更大的收藏请使用搜索或普通媒体库查询。
- **章节依赖容器。** MP4、MKV 等部分容器支持章节，其他容器不支持。
- **扫描开销。** 每个视频文件都会用 ffprobe 探测一次；媒体库很大或网络存储
  较慢时扫描会更久，可适当增大探测超时。
- **跳转** 会在新位置重新启动转码，不是无缝播放，在低性能机器上可能需要
  一点时间。

## 安全性

- PlayVideo 使用列表方式（`IPC::Open3`）启动 `ffprobe`/`ffmpeg` 子进程，
  用户提供的路径和文件名不会经过 shell；`ffprobe` 输出按 JSON 解析，不会被
  当作代码执行。
- 可执行文件路径设置会拒绝控制字符和超长值，但这些仍是管理员提供的输入：
  只应指向可信的二进制文件。
- 媒体文件是不可信输入。请保持 `ffmpeg`/`ffprobe` 更新，尽量以非特权用户
  运行 LMS，并且只添加自己控制的媒体文件夹。恶意媒体文件可能触发解码器漏洞。
- 媒体元数据会显示在 Web UI 和播放器菜单中；Web UI 会进行转义，但不要把
  媒体标签当作可信内容。
- 插件本身不额外开放网络端口；CLI/JSON-RPC 使用 LMS 自带端点，若服务器可从
  不可信网络访问，请配置 LMS 的访问控制。

## 许可证

PlayVideo 是自由软件，采用 GNU General Public License 第 2 版许可，
参见 [LICENSE](LICENSE)。第三方组件及其许可证见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

Lyrion Music Server 本身同样采用 GNU General Public License 第 2 版许可。
