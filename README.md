# Luma for Mac

A native macOS player for your own Xtream Codes library: live TV, movies and series.

- [Website](https://nikolasvalsamidis97.github.io/luma/)
- [Download the latest release](https://github.com/nikolasvalsamidis97/luma/releases/latest)
- [Report a problem](https://github.com/nikolasvalsamidis97/luma/issues)

Requires an Apple silicon Mac (M1 or newer), macOS 14 or later, and a working provider subscription. Luma does not supply channels or media. The playback engine is bundled; no separate player installation is required.

## Install

Download `Luma.zip` from Releases, extract it and drag Luma to Applications. This early release is ad-hoc signed, not Apple-notarized. macOS may block the initial launch. After attempting to open the app, use System Settings → Privacy & Security → Open Anyway if you trust the download. [Apple's instructions](https://support.apple.com/en-us/102445).

## Website maintenance

This repository contains the public website and distribution information. GitHub Pages serves the root of `main`. Edit the HTML and CSS and push to publish changes. No build tools or dependencies are needed. Preview locally with `python3 -m http.server 8000`.

The download button points to the latest GitHub release asset named `Luma.zip`. Upload the new ZIP and matching SHA-256 checksum with each release, then update the version and size displayed on the website. Do not upload provider accounts, private logs or screenshots containing personal information.

The product image shows the real app with fictional preview titles. See [third-party notices](third-party.txt) for bundled playback components.
