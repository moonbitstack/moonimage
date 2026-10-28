# moonimage

Image codecs for MoonBit: PNG, QOI, BMP, TGA, JPEG and GIF read and written, with
the pixel arithmetic that sits between them.

No I/O, no dependencies beyond the deflate stream a PNG needs, all four backends.

<!-- nocheck -->
```moonbit
let image = @moonimage.decode(bytes)          // whichever format the bytes are
image.width                                   // 640
image.height                                  // 480
image.format                                  // @moonimage.PixelFormat::Rgba8

let small = image.scale(160, 120, sampling=@moonimage.Sampling::Bilinear)
let file = @moonimage.encode(small, @moonimage.Format::Png)
```

`moon run src/examples/tour` walks one picture through every format and every
operation in one run.

## Reading and writing

`decode` reads the signature and hands the bytes to the package that knows that
format. It takes the limits a reader works under, which are checked before
anything is allocated:

<!-- nocheck -->
```moonbit
let image = @moonimage.decode(bytes, limits=@moonimage.Limits::strict())
```

A file that is damaged, truncated, or larger than the limits raises `Refused`,
which says where it stopped and what it wanted:

<!-- nocheck -->
```moonbit
let refused : @moonimage.Refused = try {
  ignore(@moonimage.decode(b"not an image"))
  abort("unreachable")
} catch {
  error => error
}
println("\{refused}")     // at 0: 6e 6f 74 20 61 6e is not a format this library reads
```

`Unexpected` and `Checksum` mean damaged bytes, `Truncated` means the file ends
early, `OverLimit` means the caller's limits refused it, `Unknown` means it is not
a format this library reads, and `Unsupported` means a part of a format it does
not implement.

`encode` writes the format the caller names, with that format's defaults. A
caller that wants to choose how it is written goes to the format's own package,
which takes its options record.

| Format | Read | Write | Animation | Package |
|:--|:--:|:--:|:--:|:--|
| PNG | every colour type and depth, palette and `tRNS`, Adam7, five filters, CRC, `gAMA` `cHRM` `sRGB` `iCCP` `tEXt` `zTXt` `iTXt` | 8 and 16 bits, adaptive filtering, interlaced on request, metadata | APNG | `@moonimage/png` |
| QOI | all six opcodes | the reference encoder's choices, byte for byte | — | `@moonimage/qoi` |
| BMP | every header version, 1/4/8/16/24/32 bits, `BI_RGB` `BI_RLE4` `BI_RLE8` `BI_BITFIELDS`, both row orders | 24 and 32 bits | — | `@moonimage/bmp` |
| TGA | colour mapped, true colour and grey, run lengths, 8/15/16/24/32 bits, both row orders | 24 and 32 bits, run lengths on request | — | `@moonimage/tga` |
| JPEG | baseline and progressive, every subsampling, greyscale, EXIF orientation | baseline, quality 1–100 | — | `@moonimage/jpeg` |
| GIF | palettes, transparency, interlace, run lengths | palette by exact colours or median cut, dithering | yes | `@moonimage/gif` |
| WebP | the container and its frame records | — | — | `@moonimage/webp` |

WebP is the one gap: the RIFF container and the animation records are read, and
the codecs inside — VP8L for lossless and VP8 for lossy — are not implemented yet,
so both directions raise `Unsupported` rather than return something wrong.

## The image

An image is a rectangle of samples, the format that says how to read them, and the
metadata that travelled with them.

<!-- nocheck -->
```moonbit
pub(all) struct Image {
  width : Int
  height : Int
  format : PixelFormat
  stride : Int
  pixels : Bytes
  premultiplied : Bool
  metadata : Metadata
}
```

The row stride is separate from the width because a caller uploading to a GPU needs
rows padded to a multiple of 256 bytes. Pixels are immutable: every operation
returns a new image rather than writing into the old one.

| Pixel format | Samples | Bytes a pixel |
|:--|:--|:--|
| `Gray8`, `GrayAlpha8`, `Rgb8`, `Rgba8` | 8-bit | 1, 2, 3, 4 |
| `Gray16`, `GrayAlpha16`, `Rgb16`, `Rgba16` | 16-bit, big-endian | 2, 4, 6, 8 |
| `RgbaF32` | floats, 0–1, little-endian | 16 |

## Moving pixels

Conversions widen, narrow, add or drop alpha, and turn grey into three equal
channels. Narrowing rounds rather than truncates, and colour becoming grey is a
luminance rather than one of the channels:

<!-- nocheck -->
```moonbit
let grey = image.convert(@moonimage.PixelFormat::Gray8)
let wide = image.convert(@moonimage.PixelFormat::Rgba16)
let flat = image.to_premultiplied()          // colour × alpha
let back = flat.to_straight()
```

The three operations that are pure permutation keep the format and the metadata:

<!-- nocheck -->
```moonbit
image.flip_horizontal()
image.flip_vertical()
image.rotate(quarters=1)                     // clockwise, and it wraps
image.crop(16, 16, 64, 64)                   // raises if it does not fit
```

Scaling has three filters. Nearest is what pixel art wants, bilinear what a
photograph wants when it is scaled a little, and Lanczos what it wants when it is
scaled a lot:

<!-- nocheck -->
```moonbit
let thumb = image.scale(160, 120, sampling=@moonimage.Sampling::Lanczos)
```

Alpha is resampled premultiplied even when the image is not stored that way, so a
transparent pixel's colour does not bleed into its neighbours.

## Metadata

What a file says about itself travels with the image, and goes back out when it is
written. Nothing here is interpreted: colour management is not this library's
business.

<!-- nocheck -->
```moonbit
pub(all) struct Metadata {
  gamma : Double?
  chromaticities : Chromaticities?
  intent : Intent?
  icc : Icc?
  texts : Array[Text]
}
```

`Text` keeps the flavour of the chunk it came from — `Latin` for `tEXt`,
`Compressed` for `zTXt`, `International` for `iTXt` — so that writing the image
back produces the same kind of chunk.

## Animation

Three formats animate, and they agree on the shape even where they disagree on the
arithmetic: a canvas, a rectangle per frame, a delay, a rule for what to do with
the pixels underneath, and a rule for what to leave behind.

<!-- nocheck -->
```moonbit
let animation = @moonimage.decode_animation(bytes)
animation.width                               // the canvas
animation.frames.length()                     // 12
animation.frames[3].delay                     // milliseconds
animation.frames[3].dispose                   // Keep, Background or Previous
animation.frames[3].blend                     // Source or Over
animation.compose()                           // every frame as a full canvas
```

`compose` applies the disposal and blending rules in order, which is what a viewer
does and what a test compares against.

## Limits

Every reader takes a `Limits` record: the widest and tallest image, the most
pixels, and the most bytes an expansion may produce.

<!-- nocheck -->
```moonbit
@moonimage.Limits::default()                  // 1 Mpx a side, 256 megapixels, 1 GiB
@moonimage.Limits::strict()                   // 8192 a side, 64 megapixels, 256 MiB
```

The defaults are what a desktop application can live with. A caller reading
untrusted files should pass `strict` or a tighter record of its own.

## Interface

| Call | What it does |
|:--|:--|
| `decode(bytes, limits?)` | read an image, whichever format the bytes are |
| `decode_animation(bytes, limits?)` | read every frame; a still image is one frame |
| `encode(image, format)` | write an image, with that format's defaults |
| `encode_animation(animation, format)` | write the frames, or the first one where the format has no animation |
| `Format::of(bytes)`, `Format::extension`, `Format::mime` | what the bytes are, and how they are named |
| `Image::new`, `Image::of` | an image, blank or over bytes that already exist |
| `Image::row`, `Image::pixel` | one row, one pixel |
| `Image::convert` | the same image in another sample format |
| `Image::to_premultiplied`, `Image::to_straight` | colour × alpha, and back |
| `Image::flip_horizontal`, `Image::flip_vertical`, `Image::rotate`, `Image::crop` | moving pixels without reading them |
| `Image::scale` | a new size, by nearest, bilinear or Lanczos |
| `Animation::new`, `Animation::compose` | frames, and every frame as a full canvas |
| `png.encode`, `png.decode`, `png.EncodeOptions`, `png.Filter` | PNG, with its compression level and row filter |
| `qoi.encode`, `qoi.decode` | QOI |
| `bmp.encode`, `bmp.decode`, `bmp.EncodeOptions`, `bmp.Depth` | BMP, 24 or 32 bits |
| `tga.encode`, `tga.decode`, `tga.EncodeOptions`, `tga.Depth` | TGA, with run lengths |
| `jpeg.encode`, `jpeg.decode`, `jpeg.EncodeOptions`, `jpeg.Subsampling`, `jpeg.exif_orientation` | JPEG, and the orientation a camera wrote |
| `gif.encode`, `gif.encode_animation`, `gif.decode`, `gif.decode_animation`, `gif.EncodeOptions` | GIF, with dithering and transparency |
| `webp.decode`, `webp.encode` | WebP: the container is read, the codecs are not |

## Licence

Apache-2.0. See [LICENSE](LICENSE).
