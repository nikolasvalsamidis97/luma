# Luma website

[Live website](https://nikolasvalsamidis97.github.io/luma/) · [Downloads](https://github.com/nikolasvalsamidis97/luma/releases) · [Support](https://github.com/nikolasvalsamidis97/luma/issues)

The website lives in `website/` alongside the Mac and Windows application source. The GitHub Pages workflow publishes only this folder on pushes to `main`; no build dependencies are needed. Preview with `python3 -m http.server 8000 --directory website`.

Current downloads: free Luma 0.7.2 for Apple silicon Macs running macOS 14+, and an unsigned Windows 10/11 x64 preview. The Windows interface/playback still requires testing on a Windows PC. Both packages include their playback engines; Windows also bundles .NET.

With each release, upload `Luma.zip`, `Luma-Windows-x64.zip` and `SHA256SUMS.txt`, then update the versioned links, version and decimal download sizes in `index.html`. Keep platform requirements, preview limitations and privacy information aligned with the published binaries. Never publish provider logins, access URLs or private screenshots.

The product image uses fictional preview titles. See [third-party notices](third-party.txt) for bundled playback components. Licensing code in the source tree is preparation for a future release; it is not enabled in these free downloads.
