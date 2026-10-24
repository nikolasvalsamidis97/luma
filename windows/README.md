# Luma for Windows

Windows companion to the SwiftUI Mac app. WPF interface, .NET 10 self-contained runtime, LibVLCSharp 3.10.2 and bundled LibVLC 3.0.24. Targets Windows 10/11 on Intel/AMD x64. End users extract the complete ZIP and run Luma.exe without installing VLC or .NET. Mac source/builds are independent.

## Build

On a developer Windows PC with .NET 10 SDK:

```powershell
./windows/scripts/publish.ps1
```

From macOS with a .NET 10 SDK:

```sh
dotnet run --project windows/Luma.Checks -c Release
dotnet publish windows/Luma.Windows -c Release -r win-x64 --self-contained true -o dist/Luma-Windows-x64
```

The SDK is build-time tooling only. `EnableWindowsTargeting` downloads Microsoft's reference/runtime packs when building on macOS. Runtime files and native VLC DLLs remain loose so LibVLC plugins load normally and compatible LGPL libraries can be replaced. Do not trim this WPF build or distribute only the EXE. Dependency lock files capture the resolved NuGet inputs.

## Features

- Xtream Codes and M3U link login, Live TV, Movies, Series, categories and search, with the same provider-facing User-Agent as Mac. M3U grouping, supported metadata and limits are described in the root README. Playlist links are encrypted with DPAPI; stream URLs stay in memory.
- Dark/coral interface, full-width sidebar hit targets, 48-title pages to bound image/network/memory work on large libraries.
- Named saved playlists, a sidebar switcher, rename/remove management and migration from older single-account saves. Credentials stay encrypted with DPAPI.
- Per-account Continue Watching, Watchlist and Favorites; movie/episode resume and next-episode progression across numbered regular seasons. Back leaves the episode list and selected season intact.
- Provider-specific season badges loaded serially, with a 600 ms spacing, 30-second 403/429 cooldown and bounded 30-minute cache. Unknown metadata is distinct from a failed request.
- Explicit 4K/1080p/MULTISUB badges; generic MULTI AUDIO is not treated as multiple subtitles.
- Embedded VLC, hardware-decoding preference, 4-second on-demand / 1.5-second live buffering, seek/volume, F11 fullscreen, Escape and Space shortcuts.
- Audio and subtitle selectors beside one another; external subtitles; size, text/background colors, opacity, signed delay and bottom offset. Style application reloads with position/pause/track restoration where the stream supports it.
- HLS quality choices from a master playlist exposed with a .m3u8 extension; resolution caps keep the master URL and rendition groups. Embedded alternate video tracks also appear. No invented resolutions for a single stream.
- Windows DPAPI encrypts provider credentials, progress and saved subtitle style for the current Windows login. Files are replaced atomically. Provider-bearing URLs and raw failures are never shown in error dialogs.
- Display-only Windows power assertion; no simulated keypresses. Assertion clears on pause, end, failure and close.

## Validation and limits

The core fixture checks run on macOS without connecting to a real provider. They cover URL credential encoding, JSON variants, duplicate IDs, season counts, episode ordering, media-badge false positives, HLS variants, persistence and safe errors. A Windows-targeted build is cross-compiled separately.

An actual Windows UI/playback test is required before calling this a stable release. Check launch from a clean Windows account without VLC/.NET installed, a provider stream, hardware-decoded 4K, seek/resume, subtitles/style reload, audio switching, fullscreen, and Play next. Windows native GUI and GPU behavior cannot be exercised on this Mac. No Windows runtime result is implied by successful compilation.

This is an unsigned x64 preview, not a native ARM64 release. The first port does not yet implement Mac-style auto-hiding player controls, a visible EPG panel, playback-observed thumbnail metadata, or paid licensing. The free 0.7.2 release includes this Windows preview; Cloudflare/Stripe setup remains separate and is not enabled in these downloads. Native Windows UI/playback verification and code signing are still pending.
