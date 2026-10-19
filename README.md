# JP2K

JP2K is a pure Swift JPEG 2000 Part 1 decoder for JP2 files and raw codestreams. It has no package dependencies and uses no native or unsafe code in the library.

## Features

- Read image metadata without decoding pixels; decode components at their original precision or convert to 8-bit gray, gray with alpha, RGB, or RGBA.
- Decode reversible 5/3 and irreversible 9/7 streams, multiple tiles and tile-parts, all five progression orders, POC, ROI, subsampling, and Part 1 code-block modes.
- Handle JP2 palette and channel definitions, sYCC colour, pixel or fractional regions, and top-down 32-bit BGRA BMP output. Region decoding allocates only the cropped **output** buffer during colour conversion; the codestream components are still decoded in full.

Part 2, HTJ2K, component precision above 16 bits, reduced-resolution decoding, and ICC colour management are unsupported. ICC profile bytes remain available through `decodeComponents`.

## Use

Requires the Swift 6.4.1 toolchain or later. Supported platforms:

| Platform | Minimum |
| --- | --- |
| Linux | Swift 6.4.1 toolchain |
| Windows x64 and ARM64 | Swift 6.4.1 toolchain |
| Android | Swift 6.4.1 toolchain with its Android Swift SDK |
| macOS, iOS, tvOS, watchOS, visionOS | 26 |

Add this repository as a Swift package dependency and import `JP2K`:

```swift
import Foundation
import JP2K

let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: "image.jp2")))
let decoder = JP2KDecoder()
let info = try decoder.readInfo(bytes)
let image = try await decoder.decodePixels(bytes)
let bmp = try image.bmp()

// For a raw codestream with no declared colour space:
let rawBytes = Array(try Data(contentsOf: URL(fileURLWithPath: "image.j2k")))
let components = try await decoder.decodeComponents(rawBytes)
let gray = try await decoder.decodePixels(rawBytes, color: .assume(.gray8))
let crop = try await decoder.decodePixels(rawBytes, color: .assume(.gray8),
                                          region: .pixels(x: 0, y: 0, width: 32, height: 32))
```

`decodePixels` uses the JP2 container's colour space by default. For a raw codestream, supply `.assume(...)` or `.inferFromComponentCount`. All decoding errors use `JP2KError`.

`decodeComponents` and `decodePixels` are `async` and `@concurrent`: they run on the concurrency pool, never on the caller's actor, so calling them from the main actor does not block it. Large tiles fan out to child tasks. `readInfo` only parses headers and stays synchronous.

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
| `maxThreads` | 8 | Child tasks for decoding tiles or code-blocks; 1 is serial |

## Safety and platforms

Verify the source of the data before decoding when you can. The decoder validates JP2 boxes and codestream markers against format rules and configured limits, then continues checking bounds and arithmetic during decoding. Within the configured limits, malformed input should return `JP2KError` rather than trap. Large allocations are checked against the memory budget before allocation. Exhaustion of the host's actual memory is not covered by this guarantee.

`readInfo` already charges the decoded component planes to `maxMemoryBytes`, so an image that could not be decoded within the budget is rejected before any decoding work. As OpenJPEG does, a codestream that ends exactly after its last tile-part without an EOC marker is accepted; any other truncation is an error.

CI runs the full test suite on Linux, Windows x64 and ARM64, and an Android emulator, and checks lint and the public API listing. macOS and the iOS simulator are tested locally; CI has no macOS runner. tvOS, watchOS and visionOS are declared in the package but not tested.

## Performance

Apple Silicon release build, `swift run -c release jp2k-bench`: five warm-ups and 50 timed iterations, with medians in milliseconds. JP2K measures `decodePixels`; ImageIO measures image source creation plus drawing into a matching bitmap, so its lazy decode is included.

| Input | JP2K | ImageIO |
| --- | ---: | ---: |
| Gray 378×472, lossless 5/3 | 5.2 | 20.0 |
| Gray 378×472, lossy 9/7 | 2.3 | 1.9 |
| RGB 64×64, lossless | 0.72 | 1.5 |
| RGB 64×64, lossy | 0.23 | 0.27 |
| `file2.jp2`, 480×640 sYCC | 23.9 | 65.0 |
| `p0_07.j2k`, 2048×2048 | 245 | 1,136 |

The two conformance rows need `JP2K_CONFORMANCE_DIR`.

Up to `maxThreads` child tasks share the work: an image with several tiles reconstructs one tile per task (packet headers are still read in order first), and a single-tile image splits the code-blocks of all its components across tasks. Images and tiles with less than about 2 KB of coded data (counting one sixteenth of a byte per sample) stay on one thread, where starting tasks would cost more than it saves. The output is identical for every thread count, and the same input fails with the same error. Each task's working memory is reserved from `maxMemoryBytes` first; if it does not fit, a task outgrows it, or the input turns out to be damaged, decoding falls back to one thread.

Concurrency shortens each decode but adds a little CPU time for starting tasks. When many images are decoded at once, for example on a server, set `maxThreads` to 1 and decode images in parallel instead, which gives the best total throughput.

JP2K is about 3.8× faster than ImageIO on the gray lossless image, about 2.1× faster on the small RGB lossless image, about 2.7× faster on the sYCC image and about 4.6× faster on the 2048×2048 image. ImageIO stays ahead on the gray lossy image. `p0_07.j2k` has 256 tiles of 128×128, which are reconstructed concurrently; on one thread it takes about 1.45 s. A Linux aarch64 Docker run on the same machine measured 10.4 ms (lossless) and 3.0 ms (lossy) for the gray image; Windows timings are printed by CI.

## Testing

Run `swift test` for generated fixtures, malformed inputs, limit boundaries, and decoding tests. An exhaustive sweep of 16,410 truncations and 72,000 bit flips completed cleanly in macOS and Linux release builds. A libFuzzer harness (ASan) is in `Fuzz/`. About 7.8 hours of fuzzing (a 1.6-hour run with four jobs and a 6.2-hour run with three jobs, about 4 million inputs, seeded with the fixtures and conformance files) have found no crash, out-of-memory or hang in the decoder so far; longer runs use the manual `Extended checks` workflow.

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
