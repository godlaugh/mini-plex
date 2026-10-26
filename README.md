# DLNA Drop

把视频或文件夹拖进窗口，家里的电视就能通过 DLNA 浏览并播放。只做一件事：Plex Media Server 里的 DLNA 共享。

## 使用

1. 打开 `build/DLNA Drop.app`（可拖到「应用程序」）。首次运行若弹出「允许查找本地网络设备」或防火墙提示，请选「允许」。
2. 把视频文件或文件夹拖进窗口，或点左下角 `+`。
3. 电视上打开「媒体播放器 / DLNA / 媒体服务器」，选择「<Mac 名> 的视频」即可浏览播放。

- 关闭窗口后仍在后台共享；⌘Q 退出才会停止。右上角开关可暂停共享。
- 文件夹按实时内容浏览，新增视频无需重新拖入。
- 与视频同名的字幕（`.srt/.ass/.ssa/.smi/.vtt`，如 `电影.srt`、`电影.zh.srt`）会一并提供给支持外挂字幕的电视（三星等）。
- 播放期间 Mac 不会因闲置而睡眠。

## 构建

```bash
./scripts/build-app.sh
```

需要 Xcode 命令行工具（Swift 6），产物为通用二进制（Apple 芯片 + Intel），ad-hoc 签名。

## 实现说明

参考对象是 `/Applications/Plex Media Server.app/Contents/MacOS/Plex DLNA Server`，用 REA 检查其 Mach-O 依赖与字符串，并对正在运行的 Plex DLNA（端口 32469）做了实际请求比对：

| 方面 | Plex 的做法（观测） | DLNA Drop |
| --- | --- | --- |
| 协议栈 | Platinum UPnP SDK，`MediaServer:1` | 自研，Swift + Network.framework |
| 服务 | ContentDirectory、ConnectionManager、X_MS_MediaReceiverRegistrar | 相同 |
| 发现 | SSDP 239.255.255.250:1900 | 相同，`SO_REUSEPORT` 与 Plex 共存 |
| 媒体流 | `Accept-Ranges`、206 分段、`transferMode.dlna.org: Streaming` | 相同 |
| DLNA 标记 | `DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=0150…` | 相同 |
| `<res>` 地址 | 使用客户端连入的 IP | 相同 |
| 转码 | 有 | **无**，原文件直出，由电视解码 |

HTTP 端口固定为 `52100`。

## 局限

- 不转码：电视不支持的编码（如部分 HEVC/DTS）将无法播放。
- 不显示时长与封面（DLNA 中可选字段）。
