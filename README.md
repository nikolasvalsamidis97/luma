# Luma

[Website](https://nikolasvalsamidis97.github.io/luma/) · [Download 0.7.2](https://github.com/nikolasvalsamidis97/luma/releases/tag/v0.7.2)

A native macOS IPTV player for Xtream Codes providers and M3U playlist links. SwiftUI interface, embedded VLC playback, and macOS Keychain credential storage.

## Windows preview

A separate Windows 10/11 x64 version is available in `dist/Luma-Windows-x64.zip`. Extract the complete folder and run `Luma.exe`; VLC, codecs and the .NET runtime are bundled. It includes provider login, movies/series/live TV, Continue Watching, Watchlist, episode navigation, audio/subtitles and fullscreen. See [Windows build and validation notes](windows/README.md). The executable is cross-compiled on Mac and needs a real Windows playback/UI check before public release. It is an unsigned preview; native Windows playback and UI verification remain pending.

## Open the app

Unzip `dist/Luma.zip` and open `Luma.app`. Enter your provider’s server URL (including `http://` or `https://` and any port), username, and password. Or select **M3U link**, paste your full HTTP(S) playlist URL, and connect. Choose **Take a look around** to explore a clearly labelled sample library without credentials.

The application bundle contains its playback engine and plug-ins. End users do **not** need VLC, Xcode, Homebrew, or a separate runtime. This build targets Apple Silicon Macs running macOS 14 or later. The first build is locally signed; distribution to other users needs Developer ID signing and Apple notarization.

## Included

- Live TV, movies, and series with season and episode selection
- Continue watching and Watchlist panels at the top of Movies and Series, with saved playback positions
- Search, provider categories, alphabetical sorting, refresh, and per-account favorites
- Per-version season-count badges on series thumbnails, based on listed episodes
- 4K / 1080p and MULTISUB thumbnail badges when provider or playback information is available
- Audio-track dropdown beside subtitles, plus quality buttons for HLS variants and embedded video tracks
- Embedded VLC player, play/pause, volume, seeking for supported on-demand streams, and window full screen
- Subtitle button with track selection, external SRT/WebVTT/ASS files, text size and color, background color/opacity, vertical offset, and signed sync delay
- Current/upcoming programme information when the provider supplies short EPG data
- Multiple named playlists, a sidebar switcher, and rename/remove controls; credentials stay in Keychain
- Loading, empty, login, provider, and playback error states

Preview mode contains fictional titles, and does not play provider content. No TV service or subscription is included.

## Multiple playlists

Use **Add playlist** at the bottom of the sidebar, give it an optional name, and enter another Xtream Codes account or M3U link. Leave **Remember login** enabled to keep it in the playlist menu. Re-entering the same server and username updates its password and keeps its existing history rather than creating a duplicate. Different accounts on the same server are supported.

Select a saved name in the sidebar to switch. The previous playlist remains available if the new provider refuses the connection. Switching closes active Mac playback after saving its position; Windows playback is modal and must be closed first. Each provider keeps its own favorites, watchlist and viewing progress. Existing single-account logins migrate automatically.

**Manage playlists** lets you rename or remove saved connections. **Disconnect** closes the current library while keeping saved playlists available on the welcome screen. Removing a playlist deletes its stored login; it does not delete local viewing history. Credentials remain in macOS Keychain or Windows DPAPI, including the playlist names and active selection. An unremembered connection lasts only for the current session and does not remove other saved connections.

## M3U links

Mac and Windows accept extended M3U/M3U8 catalogs and plain HTTP(S) M3U lists. Choose **Add playlist** in the sidebar to connect another source, then use the playlist menu to switch. Remember stores the link in macOS Keychain or Windows DPAPI, since playlist links often contain credentials. Playback URLs remain in memory, while Continue Watching, Watchlist and Favorites use opaque IDs scoped to the source.

Playlist names, `tvg-name`, `tvg-logo`, `group-title` and `#EXTGRP` supply the library labels, artwork and categories. Explicit `tvg-type` values (`live`, `movie`/`vod`, `series`) take priority. Otherwise `/movie/` and `/series/` paths and `Show S01E02` titles identify on-demand content. Numbered episodes with the same show name and group share a series and get season counts and Play next. Unclassified entries appear in Live TV; missing season information stays unknown. A direct HLS master/media link is one playable stream, never a list of segments.

Refresh downloads the playlist again and updates every section. History is preserved, but a removed stream cannot be resumed. Changing the source URL or stream URLs (including rotating tokens) changes their opaque identity. Downloads are limited to 32 MB. This first implementation supports UTF-8 playlists and HTTP(S) playback links; local files, RTSP/UDP, custom per-entry HTTP headers and XMLTV guide imports are not included.

Validation: `swift run StreamCoreChecks`, `./scripts/check-m3u-library.sh`, and the Windows core checks cover parsing, safe failures, source isolation and local fixture playback/resume. The integration fixture uses an in-memory credential vault and isolated preferences, without reading or changing your real account.

## Build from source

Developers need Apple's command line tools with Swift 5.9 or later. Full Xcode is optional.

```sh
./scripts/build-app.sh
unzip -q dist/Luma.zip -d /tmp/luma-preview
open /tmp/luma-preview/Luma.app
```

The build script fetches the pinned official VLCKit 3.7.2 binary if needed, checks its SHA-256, builds the executable, embeds the framework, includes its license, signs the bundle locally, and creates `dist/Luma.zip`. Pass `--install` to also copy the app into `~/Applications`. The download happens at build time only. See `THIRD_PARTY_NOTICES.txt` for upstream references.

```sh
swift run StreamCoreChecks
```

The dependency-free check runner works with command line tools alone and uses a local URLProtocol fixture to cover login responses, mixed provider JSON types, duplicate IDs, series ordering, EPG decoding, and URL encoding of reserved characters in credentials.

## Implementation notes

`StreamCore` contains provider models, URL construction, and the asynchronous API client. `StreamApp` contains the SwiftUI interface, account state, Keychain storage, and VLCKit player. No credentials are written to project files or UserDefaults. API requests use an ephemeral URLSession and errors do not echo credential-bearing URLs. HTTP is supported for providers that require it; use HTTPS when your provider offers it.

This initial version keeps one account connected at a time and loads each section on demand. It does not yet include catch-up TV, a full grid EPG. Real provider compatibility still needs testing with the user's subscription; test fixtures are not a substitute for that check.

## Subtitles

Click the captions button beside the volume controls. Track selection and delay apply immediately; positive delay shows subtitles later, negative delay earlier. Delay resets for each new video. The appearance preview lets you adjust size, text color, background color/opacity, and how far to raise subtitles from the bottom.

**Apply style** saves the appearance on this Mac and briefly reloads playback. Seekable movies and episodes resume near their previous position, preserving pause and subtitle selection; live TV reconnects to live. Use **Defaults**, then **Apply style**, to reset appearance. Text styling cannot recolor image-based subtitles; authored ASS/SSA styling may take precedence. Subtitles burned into the video cannot be changed or disabled.

Developer subtitle integration check (local generated video, isolated test app, no provider login):

```sh
./scripts/check-subtitles.sh
```

Add `--manual` to leave the test player open for visual verification. The check exercises file import, track enable/disable, delay in both directions, style reload with paused-position restoration, and persisted appearance. It compiles the production player and subtitle views into a separate temporary app.

## Series season badges

Series thumbnails show the number of distinct regular seasons containing listed episodes for that exact provider entry. Empty seasons and season 0 (specials) do not inflate the count. Specials-only entries are labelled **Specials only**; missing season fields show **Seasons unknown**. A failed request instead shows **Retry seasons**, with a retry button and the provider error in its tooltip. Neither invents a zero. This describes the provider’s catalogue, not a guarantee that every listed episode will play.

Counts load as cards appear, with one provider detail request in flight and at least half a second between starts. HTTP 403/429 pauses further detail requests for 30 seconds; retry after provider access returns. Leaving a card cancels work that no other view needs. Thumbnail and episode-detail requests share a session/account-specific cache, capped at 128 series with a 30-minute lifetime. Refresh clears the cache; accounts never share it. Movies do not receive season badges.

The core checks cover nonconsecutive seasons, empty groups, specials, missing season fields, nested/flat provider responses, request sharing, cancellation, concurrency limits, cache expiry, and account/session isolation. Run `./scripts/check-season-badges.sh` for an isolated visual check using synthetic data and the production thumbnail component.

## Audio, quality and media badges

The waveform button beside subtitles opens a simple audio-track dropdown. Tracks come from the current video and can be changed during playback. A video with no audio shows an empty-state message.

The quality button appears when a recognized HLS master playlist advertises multiple resolutions, or the file exposes video tracks at different resolutions. HLS offers **Auto** plus a button for each resolution; a manual choice uses the highest-bandwidth stream up to that resolution, retaining the original playlist’s audio/subtitle groups. Switching briefly reconnects and restores the position and paused state for seekable movies/episodes. Live TV returns to live. Audio choice, subtitle selection, delay and appearance are retained. Single-resolution files do not get artificial quality choices, and separate provider listings are not merged. DASH quality selection and HLS hidden behind non-playlist URLs are not currently discovered.

Thumbnail badges use explicit title tokens such as `4K`, `UHD`, `1080p`, `FHD`, and `MULTISUB`, structured video/subtitle metadata when supplied, and tracks observed during playback. Generic `MULTI` or `MULTI AUDIO` does not mean multiple subtitles. Series metadata is promoted to a series badge only when all listed episodes agree; imported subtitle files do not produce a MULTISUB badge. Unknown information leaves the corresponding badge absent. Playback observations are session-only and cleared when refreshing or changing accounts; browsing does not open videos to probe their tracks.

Developer media-control check (uses [Apple’s public HLS test stream](https://developer.apple.com/streaming/examples/), never a provider account):

```sh
./scripts/check-media-controls.sh
```

This exercises embedded audio selection, actual decoded 360p/720p resolutions, Auto, and position/pause/subtitle-delay restoration. Add `--manual` for a visual inspection. Core checks cover badge false positives, mixed metadata, and HLS variants with quoted attributes, duplicate resolutions, audio-only streams and iframe previews.

## Fullscreen and 4K playback

The player’s fullscreen button targets its own window, including after opening an audio/subtitle popover. Double-click the video or use Control–Command–F to toggle fullscreen; Escape exits. In fullscreen, the video uses the whole content area and controls overlay it. Controls hide after 2.5 seconds of inactivity during playback and return with mouse movement or a key press. They remain available while paused or interacting with a popover/control. The picture retains its original aspect ratio.

Playback explicitly prefers Apple’s VideoToolbox hardware decoder, retaining fallback for unsupported formats. On-demand network buffering is four seconds (live TV stays at 1.5 seconds). Track metadata is refreshed less often than the playback clock. Buffering adds startup/seek latency and cannot compensate for a connection slower than the video bitrate. The local generated 4K HEVC fixture checks hardware decoding and rendered/lost frames; it does not represent provider bandwidth or every codec/HDR profile.

```sh
./scripts/check-fullscreen.sh --manual
```

The check runs in a separate app with generated local video and no provider credentials. The manual mode leaves it open for checking fullscreen entry/exit, auto-hiding controls, and aspect-ratio preservation.


## Episode navigation and display sleep

The player’s back arrow returns to the episode list, retaining its selected season. Playing an episode leaves that list open behind the player. **Play next** appears in the final 90 seconds (the final 10% for episodes shorter than 15 minutes) and remains available after playback finishes. It advances only when clicked, uses the next numbered episode in that exact provider entry, and can continue into the next available season. Specials stay separate. Missing episode/season numbers or the final episode do not produce a guessed next episode. No credits detection is implied. The player window and fullscreen state remain in place; the next episode starts at the beginning with fresh stream-specific tracks and saved subtitle appearance.

Luma holds a display-only power assertion during playback and releases it when paused, stopped, finished or failed. Its player subclass suppresses the pinned VLCKit 3.7.2 `delaySleep` method, which otherwise calls `UpdateSystemActivity(UsrActivity)` on position changes ([upstream source](https://github.com/videolan/vlckit/blob/3e42ae47/Sources/VLCMediaPlayer.m)). This prevents playback from repeatedly declaring user input and waking the keyboard backlight. Recheck that private selector when upgrading VLCKit. No system keyboard or display preferences are changed.

```sh
./scripts/check-episode-player.sh --manual
```

The isolated check uses generated local video and a synthetic catalogue, bypassing saved login/Keychain. It checks the actual Objective-C override, display assertion acquisition/release, near-end detection and clean episode transitions. Manual mode opens the production episode list and player for checking Play next across a season boundary, fullscreen retention and Back. Core checks cover ordering, specials, unknown metadata, final episodes and prompt timing. Physical keyboard lighting still requires observation on the affected Mac.


## Continue watching and Watchlist

Movies and Series replace the decorative banner with two side-by-side sections. **Continue watching** resumes a movie or the saved episode directly, using that account’s current credentials. The episode list stays behind the player for Back navigation. One entry per series keeps its latest episode; when an episode actually finishes, the next numbered available episode appears as **Up next**. Finished movies and final episodes leave Continue watching. Stopping during credits still saves the position. Right-click an entry to remove its saved progress.

**Watchlist** is separate from Favorites. Bookmark buttons on thumbnails and in title details add/remove movies and series; the bookmark in the Watchlist panel removes an entry. The two sections show the current library type and remain available while searching or filtering the catalogue.

Positions save during playback (every five seconds), on pause, and when closing the player or quitting normally. Saved subtitle/quality reloads retain the bookmark while seeking, so the opening frame does not overwrite it. Persistence is local and scoped by provider server and username, with separate preview data. Disconnecting hides that account’s data; switching back restores it. Playback URLs are not saved. The library stores up to 200 recent titles and 500 Watchlist entries. Resume depends on the stream supporting seeking. Progress begins with this update; earlier sessions cannot be reconstructed.

```sh
./scripts/check-viewing-library.sh --manual
```

This check uses generated local video, a loopback-only fixture provider on a dynamically allocated port, and an isolated preferences suite. It verifies real decoded resume time, persistence across fresh store/player instances, Watchlist preservation, final progress flush and account separation. Manual mode opens the production library to verify movie/episode resume, both panels, bookmark actions and Back navigation. Core checks cover serialization, completion, upcoming episodes, invalid/zero positions and independent title IDs.

## Trial, developer keys and subscriptions (prepared for 0.8.0)

A licensed build adds an explicit 3-day trial without a card, individual developer product keys, and a €4/month Stripe subscription after expiry. It is **not enabled in the existing public build**. See [licensing setup](licensing-server/README.md) for backend deployment, Stripe test/live setup, developer-key management, privacy updates and the `--licensed` build flag. Live payments require your Stripe account and a deployed HTTPS licensing service.
