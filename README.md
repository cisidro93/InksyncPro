# InkSync Pro — CBZ/CBR to Kindle-optimized EPUB3 converter for iOS/iPadOS

[![Build Native iOS App](https://github.com/cisidro93/InksyncPro/actions/workflows/build.yml/badge.svg)](https://github.com/cisidro93/InksyncPro/actions)

## Features

- **CBZ/CBR Import**: Seamlessly import your comic archives.
- **EPUB3 Output**: Generates Kindle-optimized EPUB files with full RegionMagnification panel view support.
- **PDF Output**: Alternative output format to PDF.
- **Webtoon Slicing**: Slices long webtoon strips into readable pages.
- **Manga Right-to-Left Mode**: Natively supported orientation for manga reading.
- **Image Enhancement Pipeline**: Enhances comic quality automatically during conversion.
- **Split Volume Support**: Split large volumes with badged covers.
- **Web Interface**: Includes a web interface for remote access and file management.

## Requirements

- **OS**: iOS/iPadOS 16 or later
- **Xcode**: Xcode 15 or later
- **Installation**: Sideloading required via [Signulous](https://www.signulous.com/) or [AltStore](https://altstore.io/).

## Build Instructions

To build the application manually:
1. Clone the repository natively or download the source code.
2. Open `ComicToPDF/ComicToPDF.xcodeproj` in Xcode.
3. Select your desired deployment target and click "Build" (Cmd+B) or "Run" (Cmd+R).
4. Alternatively, push to GitHub and let GitHub Actions produce the `.ipa` artifact automatically.

## Sideloading Instructions

1. If you don't wish to build the app manually, download the latest compiled unsigned `.ipa` artifact from GitHub Actions (Actions → latest successful run → Artifacts).
2. Sideload the IPA onto your iOS or iPadOS device using a service such as [Signulous](https://www.signulous.com/) or [AltStore](https://altstore.io/).

## License

*(License details to be specified)*
