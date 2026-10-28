# moonimage

Image codecs for MoonBit: PNG, QOI, BMP, TGA, JPEG, GIF and WebP, read and
written, and the pixel arithmetic that sits between them.

No I/O, no dependencies beyond the deflate stream a PNG needs, all four backends.

```moonbit
let image = @moonimage.decode(bytes)
image.width                 // 640
image.format                // @moonimage.PixelFormat::Rgba8

let small = image.scale(width=160, height=120, sampling=Bilinear)
let bytes = @moonimage.encode(small, format=Png)
```

The interface table lands first; the readers follow.
