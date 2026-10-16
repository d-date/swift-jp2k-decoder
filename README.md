# JP2K

JP2K is a pure Swift JPEG 2000 Part 1 decoder for JP2 files and raw codestreams. It has no package dependencies and uses no native or unsafe code in the library.

## Features

- Read image metadata without decoding pixels; decode components at their original precision or convert to 8-bit gray, gray with alpha, RGB, or RGBA.
- Decode reversible 5/3 and irreversible 9/7 streams, multiple tiles and tile-parts, all five progression orders, POC, ROI, subsampling, and Part 1 code-block modes.
- Handle JP2 palette and channel definitions, sYCC colour, pixel or fractional regions, and top-down 32-bit BGRA BMP output. Region decoding allocates only the cropped **output** buffer during colour conversion; the codestream components are still decoded in full.

Part 2, HTJ2K, component precision above 16 bits, reduced-resolution decoding, and ICC colour management are unsupported. ICC profile bytes remain available through `decodeComponents`.

## Use

Requires Swift 6.4 or later. Add this repository as a Swift package dependency and import `JP2K`:

```swift
import Foundation
import JP2K

let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: "image.jp2")))
let decoder = JP2KDecoder()
let info = try decoder.readInfo(bytes)
let image = try decoder.decodePixels(bytes)
let bmp = try image.bmp()

// For a raw codestream with no declared colour space:
let rawBytes = Array(try Data(contentsOf: URL(fileURLWithPath: "image.j2k")))
let components = try decoder.decodeComponents(rawBytes)
let gray = try decoder.decodePixels(rawBytes, color: .assume(.gray8))
let crop = try decoder.decodePixels(rawBytes, color: .assume(.gray8),
                                    region: .pixels(x: 0, y: 0, width: 32, height: 32))
```

`decodePixels` uses the JP2 container's colour space by default. For a raw codestream, supply `.assume(...)` or `.inferFromComponentCount`. All decoding errors use `JP2KError`.

## Default limits

`JP2KDecoder(limits: Limits())` applies these caller-configurable ceilings. Dimensions and pixel counts apply to the full image, including when a region is requested. The work limits were sized from generated fixtures and conformance streams, with additional room for a 16-megapixel, eight-layer image; see the rationale in `Sources/JP2K/API/Limits.swift`.

| `Limits` property | Default | Controls |
| --- | ---: | --- |
| `maxInputBytes` | 32 MiB | Input byte length |
| `maxPixels` | 16,000,000 | Full-image width × height |
| `maxComponents` | 4 | Codestream components |
| `maxBitDepth` | 16 | Component precision; higher precision is unsupported |
| `maxTiles` | 4,096 | Tiles in the image |
| `maxTileParts` | 32,768 | Tile-parts across all tiles |
| `maxLayers` | 128 | Quality layers |
| `maxMemoryBytes` | 512 MiB | Budgeted input, working storage, and output allocations |
| `maxPackets` | 262,144 | Decoded packets |
| `maxPacketIterations` | 4,194,304 | Packet scan steps, including skipped positions |
| `maxCodingPasses` | 8,388,608 | Code-block coding passes |
| `maxMarkerDataBytes` | 8 MiB | Retained marker data |

## Safety and platforms

Verify the source of the data before decoding when you can. The decoder validates JP2 boxes and codestream markers against format rules and configured limits, then continues checking bounds and arithmetic during decoding. Within the configured limits, malformed input should return `JP2KError` rather than trap. Large allocations are checked against the memory budget before allocation. Exhaustion of the host's actual memory is not covered by this guarantee.

The package targets Windows x64 and ARM64, Linux, Android, macOS, and iOS. CI tests Linux, Windows x64 and ARM64, and an Android emulator, and checks lint and the public API listing. Apple platforms are verified locally; CI has no macOS runner.

## Performance

Apple Silicon release build, `swift run -c release jp2k-bench`: five warm-ups and 50 timed iterations, with medians in milliseconds. JP2K measures `decodePixels`; ImageIO measures image source creation plus drawing into a matching bitmap, so its lazy decode is included.

| Input | JP2K | ImageIO |
| --- | ---: | ---: |
| Gray 378×472, lossless 5/3 | 49.1 | 29.8 |
| Gray 378×472, lossy 9/7 | 11.3 | 2.8 |
| RGB 64×64, lossless | 3.6 | 2.0 |
| RGB 64×64, lossy | 0.67 | 0.37 |
| `p0_07.j2k`, 2048×2048 | ~2,860–3,590 | ~1,500–1,780 |

ImageIO is faster today: about 2× on most of these cases and about 4× on the small lossy gray case. JP2K trades speed for strict validation and no native or unsafe library code. A quick Linux aarch64 Docker run measured 48.8 ms for the gray lossless case; Windows timings are printed by CI.

## Testing

Run `swift test` for generated fixtures, malformed inputs, limit boundaries, and decoding tests. An exhaustive sweep of 16,410 truncations and 72,000 bit flips completed cleanly in macOS and Linux release builds. A libFuzzer harness is in `Fuzz/`; total fuzzing time: see release notes.

FUZZ_HOURS_TBD

ISO/IEC 15444-4 class-1 cases at ResFactor 0 pass their official PEAK/MSE tolerances. The a–g codestream set matches its reference images exactly. Colour conformance files `file2.jp2`, `file3.jp2`, and `file9.jp2` match OpenJPEG output apart from one `file2.jp2` pixel where the OpenJPEG reference build used fused multiply-add; this decoder uses platform-independent arithmetic.

Conformance data is not committed. Fetch the pinned `openjpeg-data` commit and run the tests with:

```sh
bash Scripts/fetch-conformance.sh .conformance-data
JP2K_CONFORMANCE_DIR="$PWD/.conformance-data" swift test
```

Keep the fetched `input/conformance/COPYRIGHT` and `baseline/conformance/COPYRIGHT` notices with any copy of the data. The data's licence restricts its use to JPEG 2000 conformance work.

## Provenance and licence

The decoder is derived from [OpenJPEG v2.5.4](https://github.com/uclouvain/openjpeg/tree/v2.5.4). Function-level mappings are in [docs/provenance.md](docs/provenance.md). This package is BSD-2-Clause licensed; see [LICENSE](LICENSE) and the retained OpenJPEG notice in [THIRD_PARTY/openjpeg-LICENSE](THIRD_PARTY/openjpeg-LICENSE).

JPEG 2000 Part 1 was designed to be royalty-free, but no implementation can guarantee freedom from patent claims; consult your own counsel.
