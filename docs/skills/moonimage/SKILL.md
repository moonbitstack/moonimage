---
name: moonimage
description: "Read and write image files in MoonBit: PNG, JPEG, GIF, WebP, BMP, TGA, QOI, TIFF, ICO and CUR, PNM, Radiance HDR, OpenEXR, farbfeld, and block-compressed DDS. Use it to decode an upload, convert between formats, resize or crop a picture, apply colour adjustments, or walk the frames of an animation."
---

# moonimage

One package for image files, in pure MoonBit. `decode` looks at the first bytes
and picks the codec; `encode` writes the format you name. Everything between the
two — pixel layouts, geometry, scaling, blurring, colour — is arithmetic on an
`Image`, which is a rectangle of samples and nothing else.

No file I/O: a caller hands in a `Bytes` and gets a `Bytes` back, which is why
the library runs on all four backends, including in a browser.

## Installing

```bash
moon add moonbitstack/moonimage@0.1.2
```

```moonbit
import {
  "moonbitstack/moonimage" as @moonimage,
}
```

## Reading a file and writing it back

`decode` takes the bytes of any format and returns an image; `encode` takes an
image and the format to write. Nothing needs to be told what the file is.

```moonbit
test {
  let image = @moonimage.Image::new(4, 3, @moonimage.PixelFormat::Rgba8)
  let file = @moonimage.encode(image, @moonimage.Format::Png)
  let back = @moonimage.decode(file)
  assert_eq(back.width, 4)
  assert_eq(@moonimage.Format::of(file), @moonimage.Format::Png)
}
```

`Refused` carries the offset it stopped at and what it expected:

```moonbit
test {
  let refused = try {
    ignore(@moonimage.decode(b"not an image"))
    abort("unreachable")
  } catch {
    error => error
  }
  assert_eq(refused is @moonimage.Refused::Unknown(_), true)
}
```

A caller reading untrusted files passes `Limits`, which is checked before
anything is allocated:

```moonbit
test {
  let image = @moonimage.Image::new(2, 2, @moonimage.PixelFormat::Rgb8)
  let file = @moonimage.encode(image, @moonimage.Format::Png)
  let small = @moonimage.decode(file, limits=@moonimage.Limits::strict())
  assert_eq(small.width, 2)
}
```

## Choosing how a format is written

`encode` uses the format's defaults. When the compression level, the bit depth
or the quality matters, call the format's own package, which takes an options
record and returns the same `Bytes`.

```moonbit
import {
  "moonbitstack/moonimage" as @moonimage,
  "moonbitstack/moonimage/tiff" as @tiff,
  "moonbitstack/moonimage/jpeg" as @jpeg,
}

test {
  let image = @moonimage.Image::new(3, 3, @moonimage.PixelFormat::Rgb8)
  let squeezed = @tiff.encode(image, options=@tiff.EncodeOptions::squeezed())
  assert_eq(@tiff.decode(squeezed).width, 3)
  let photograph = @jpeg.encode(image, options={ quality: 82, subsampling: @jpeg.Subsampling::Yuv420 })
  assert_eq(@jpeg.decode(photograph).height, 3)
}
```

## Moving pixels

Every operation returns a new image; the one you hold never changes. Geometry is
a permutation and keeps every sample exactly, scaling and blurring resample.

```moonbit
test {
  let image = @moonimage.Image::new(8, 6, @moonimage.PixelFormat::Rgba8)
  let small = image.scale(4, 3, sampling=@moonimage.Sampling::Lanczos)
  assert_eq(small.width, 4)
  let turned = image.rotate(quarters=1)
  assert_eq(turned.width, 6)
  let tilted = image.rotate_by(7.0, expand=true)
  assert_eq(tilted.height >= 6, true)
  let crop = image.crop(1, 1, 4, 4)
  assert_eq(crop.height, 4)
}
```

Colour and filters work on straight alpha and leave the alpha channel alone:

```moonbit
test {
  let image = @moonimage.Image::new(4, 4, @moonimage.PixelFormat::Rgba8)
  let brighter = image.brightness(1.5).contrast(1.1)
  let soft = brighter.blur(1.5).unsharp_mask(radius=1.0, amount=120.0)
  let turned = soft.hue_rotate(120.0)
  assert_eq(turned.width, 4)
}
```

A blur is the Gaussian kernel unless you ask for the other arithmetic. Three box
passes, which is what Pillow, Skia and the browsers use, cost one addition and
one subtraction a sample and land within a step of the kernel everywhere; reach
for them when a picture has to match one of those:

```moonbit
test {
  let image = @moonimage.Image::new(4, 4, @moonimage.PixelFormat::Rgba8)
  let for_pillow = image.blur(2.0, kernel=@moonimage.Kernel::Boxes)
  assert_eq(for_pillow.width, 4)
}
```

## Animation

`decode_animation` returns frames whatever the file was; a still picture comes
back as one frame, so a caller that draws animations never branches.

```moonbit
test {
  let still = @moonimage.Image::new(4, 4, @moonimage.PixelFormat::Rgba8)
  let file = @moonimage.encode(still, @moonimage.Format::Gif)
  let animation = @moonimage.decode_animation(file)
  assert_eq(animation.frames.length(), 1)
  let pictures = animation.compose()
  assert_eq(pictures.length(), 1)
}
```

## Things that catch people out

- **`encode` raises.** A picture that cannot be written in the format asked for
  raises `Refused` rather than being written as something else. Handle it or
  declare `raise` on the function.
- **A DDS decodes into the layout the block is**: BC4 grey, BC5 red and green,
  BC6H float, the rest RGBA. That is right for a texture you are about to sample,
  and wrong for one you are about to draw; pass `format=` to `decode` — or to
  `decode_animation` — and it comes back in the layout you asked for, at no cost
  when the file already holds it.
- **Limits are checked before allocation**, not after. Pass
  `Limits::strict()` for uploads; the default allows a gigabyte of expansion.
- **Grey in a bit map is inverted.** In PBM a set bit is black; every other
  format here has nought as black.
- **Every filter widens its footprint at a downscale**, bilinear included: an
  output pixel averages what it stands for rather than sampling one of the input
  pixels. `Nearest` is the only one that still picks, and that is the point of
  it.
- **16-bit samples are big-endian** in every `PixelFormat`, whatever the file
  said, so that a round trip through `Gray16` is the identity.
- **`RgbaF32` is not clamped on the way in.** HDR and OpenEXR pictures keep
  values above one; converting to `Rgba8` is what clamps them.
- **OpenEXR is written in all nine of its compressions**, chosen with
  `exr.EncodeOptions`. `Pxr24` keeps twenty-four bits of every sample, so a float
  loses its last eight bits of mantissa; `B44` and `B44a` keep four bits of a
  half in a block of four by four; `Dwaa` and `Dwab` keep the frequencies of a
  block of eight by eight, and are the lossiest of the nine. The rest are exact.
- **A tiled TIFF is written by `encode_tiled`**, which takes the size of a tile;
  `encode` writes strips. Both read back as the same picture.
- **An OpenEXR may hold several parts.** `decode` returns the first; `decode_parts`
  returns them all, in the order the file lists them.
- **A DDS is written by `dds.encode`**, which takes a block format or nothing at
  all for a surface of plain samples — the only lossless choice, and the one
  `encode` makes. `Bc1` to `Bc7` are written; each block is one region fitted by
  least squares, and BC7 and BC6H take their mode with the finest weights.
- **A lossy WebP is written by `webp.encode_lossy`**, which takes a quality from
  nought to a hundred; `encode` writes lossless. The alpha of a lossy picture is
  kept exactly, in a chunk of its own.
- **An OpenEXR of several parts is written by `encode_parts`**, which takes the
  pictures with the names they go by. `encode` writes one.
