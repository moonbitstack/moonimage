// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// Reading JPEG.
//
// The file is a list of markers: quantisation tables, Huffman tables, a frame
// header that says how many components there are and how they are subsampled,
// and one or more scans. A scan is entropy-coded — a bit stream with no byte
// alignment, and an escape for the byte that would otherwise look like a marker —
// and it decodes to coefficients, not pixels. Pixels come at the end, one inverse
// cosine transform per eight by eight block.
//
// Progressive files split one image across several scans: the first sends the
// high bits of every coefficient, later ones refine them. That is why the
// coefficients are kept for the whole image before anything is transformed: a
// baseline file could be decoded a block at a time, a progressive one cannot.

///|
/// One component: its sampling, its tables, and where its coefficients live.
priv struct Component {
  id : Int32
  h : Int32
  v : Int32
  quant : Int32
  blocks_w : Int32
  blocks_h : Int32
  coeffs : FixedArray[Int32]
  mut predictor : Int32
}

///|
/// A Huffman table, as the canonical code the standard defines: how many codes
/// there are of each length, and the symbols in code order.
priv struct Huffman {
  counts : Array[Int32]
  symbols : Array[Int32]
}

///|
/// A quantisation table, in the zig-zag order the file stores it.
priv struct Quant {
  values : Array[Int32]
}

///|
/// A component as it appears in a scan header.
priv struct ScanComponent {
  index : Int32
  dc : Int32
  ac : Int32
}

///|
/// Something that lives across blocks rather than inside one: the run of empty
/// blocks an end-of-band code stands for.
priv struct ScanState {
  mut eob_run : Int32
}

///|
/// What a scan header says.
priv struct Scan {
  components : Array[ScanComponent]
  start : Int32
  end : Int32
  high : Int32
  low : Int32
}

///|
/// The image in a JPEG file.
///
/// With `orient=true` the pixels are rearranged to match the EXIF orientation,
/// which is what a viewer does; without it they are as stored.
pub fn decode(
  bytes : BytesView,
  limits? : @raster.Limits,
  orient? : Bool,
) -> @raster.Image raise @raster.Refused {
  let limits = limits.unwrap_or(@raster.Limits::default())
  let image = decode_full(bytes, limits)
  if orient.unwrap_or(false) {
    match exif_orientation(bytes) {
      Some(orientation) => apply_orientation(image, orientation)
      None => image
    }
  } else {
    image
  }
}

///|
fn decode_full(
  bytes : BytesView,
  limits : @raster.Limits,
) -> @raster.Image raise @raster.Refused {
  if bytes.length() < 4 ||
    bytes[0].to_int() != 0xFF ||
    bytes[1].to_int() != 0xD8 {
    raise @raster.Unknown(at=0, got=@raster.hex(bytes, 0, 2))
  }
  let quants : Array[Quant?] = [None, None, None, None]
  let dc_tables : Array[Huffman?] = [None, None, None, None]
  let ac_tables : Array[Huffman?] = [None, None, None, None]
  let mut width = 0
  let mut height = 0
  let components : Array[Component] = []
  let mut hmax = 1
  let mut vmax = 1
  let mut restart_interval = 0
  let mut position = 2
  while position + 3 < bytes.length() {
    if bytes[position].to_int() != 0xFF {
      position = position + 1
      continue
    }
    let marker = bytes[position + 1].to_int()
    if marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) {
      position = position + 2
      continue
    }
    if marker == 0xD9 {
      break
    }
    let length = bytes[position + 2].to_int() * 256 +
      bytes[position + 3].to_int()
    if length < 2 || position + 2 + length > bytes.length() {
      raise @raster.Truncated(at=position, want=length)
    }
    let body = bytes.clamped_view(start=position + 4, end=position + 2 + length)
    match marker {
      0xDB => read_quantisation(body, quants)
      0xC4 => read_huffman(body, dc_tables, ac_tables)
      0xC0 | 0xC1 | 0xC2 => {
        let frame = read_frame(body)
        width = frame.width
        height = frame.height
        hmax = frame.hmax
        vmax = frame.vmax
        components.clear()
        for component in frame.components {
          components.push(component)
        }
      }
      0xDD => {
        if body.length() < 2 {
          raise @raster.Truncated(at=position, want=2)
        }
        restart_interval = body[0].to_int() * 256 + body[1].to_int()
      }
      0xDA => {
        if components.is_empty() {
          raise @raster.Unexpected(
            at=position,
            got="a scan before the frame",
            want="a SOF marker first",
          )
        }
        let scan = read_scan(body, components)
        decode_scan(
          bytes,
          position + 2 + length,
          scan,
          components,
          dc_tables,
          ac_tables,
          restart_interval,
          width,
          height,
          hmax,
          vmax,
        )
        // Skip whatever the entropy decoder left behind, up to the next marker.
        position = skip_scan(bytes, position + 2 + length)
        continue
      }
      _ => ()
    }
    position = position + 2 + length
  }
  if width == 0 || height == 0 {
    raise @raster.Unexpected(at=0, got="no frame header", want="a SOF marker")
  }
  limits.check(width, height)
  assemble(components, width, height, hmax, vmax, quants)
}

///|
/// The end of an entropy-coded segment: the next marker that is not a stuffed
/// zero and not a restart.
fn skip_scan(bytes : BytesView, from : Int32) -> Int32 {
  let mut position = from
  while position + 1 < bytes.length() {
    if bytes[position].to_int() == 0xFF {
      let marker = bytes[position + 1].to_int()
      if marker != 0x00 && !(marker >= 0xD0 && marker <= 0xD7) {
        return position
      }
      position = position + 2
    } else {
      position = position + 1
    }
  }
  bytes.length()
}

///|
/// The frame header.
priv struct FrameInfo {
  width : Int32
  height : Int32
  hmax : Int32
  vmax : Int32
  components : Array[Component]
}

///|
fn read_frame(body : BytesView) -> FrameInfo raise @raster.Refused {
  if body.length() < 6 {
    raise @raster.Truncated(at=0, want=6)
  }
  let precision = body[0].to_int()
  if precision != 8 {
    raise @raster.Unsupported(at=0, got="\{precision}-bit samples")
  }
  let height = body[1].to_int() * 256 + body[2].to_int()
  let width = body[3].to_int() * 256 + body[4].to_int()
  let count = body[5].to_int()
  if count == 0 || count > 4 {
    raise @raster.Unexpected(
      at=5,
      got="\{count} components",
      want="one to four",
    )
  }
  if body.length() < 6 + count * 3 {
    raise @raster.Truncated(at=6, want=6 + count * 3)
  }
  let components : Array[Component] = []
  let mut hmax = 1
  let mut vmax = 1
  for index in 0..<count {
    let at = 6 + index * 3
    let sampling = body[at + 1].to_int()
    let h = (sampling >> 4) & 0x0F
    let v = sampling & 0x0F
    if h == 0 || v == 0 || h > 4 || v > 4 {
      raise @raster.Unexpected(
        at=at + 1,
        got="sampling \{h}x\{v}",
        want="one to four each way",
      )
    }
    if h > hmax {
      hmax = h
    }
    if v > vmax {
      vmax = v
    }
    components.push({
      id: body[at].to_int(),
      h,
      v,
      quant: body[at + 2].to_int(),
      blocks_w: 0,
      blocks_h: 0,
      coeffs: FixedArray::make(0, 0),
      predictor: 0,
    })
  }
  let mcu_w = (width + 8 * hmax - 1) / (8 * hmax)
  let mcu_h = (height + 8 * vmax - 1) / (8 * vmax)
  for index in 0..<components.length() {
    let component = components[index]
    let blocks_w = mcu_w * component.h
    let blocks_h = mcu_h * component.v
    components[index] = {
      id: component.id,
      h: component.h,
      v: component.v,
      quant: component.quant,
      blocks_w,
      blocks_h,
      coeffs: FixedArray::make(blocks_w * blocks_h * 64, 0),
      predictor: 0,
    }
  }
  { width, height, hmax, vmax, components, }
}

///|
fn read_quantisation(
  body : BytesView,
  quants : Array[Quant?],
) -> Unit raise @raster.Refused {
  let mut position = 0
  while position < body.length() {
    let header = body[position].to_int()
    let precision = header >> 4
    let index = header & 0x0F
    position = position + 1
    if index > 3 {
      raise @raster.Unexpected(
        at=position,
        got="table \{index}",
        want="a table below four",
      )
    }
    // The file lists the values in zig-zag order; keep them by the coefficient
    // they belong to, which is the order the transform works in.
    let values : Array[Int32] = []
    for _ in 0..<64 {
      values.push(0)
    }
    if precision == 0 {
      if position + 64 > body.length() {
        raise @raster.Truncated(at=position, want=64)
      }
      for step in 0..<64 {
        values[zigzag(step)] = body[position + step].to_int()
      }
      position = position + 64
    } else {
      if position + 128 > body.length() {
        raise @raster.Truncated(at=position, want=128)
      }
      for step in 0..<64 {
        values[zigzag(step)] = body[position + step * 2].to_int() * 256 +
          body[position + step * 2 + 1].to_int()
      }
      position = position + 128
    }
    quants[index] = Some({ values, })
  }
}

///|
fn read_huffman(
  body : BytesView,
  dc_tables : Array[Huffman?],
  ac_tables : Array[Huffman?],
) -> Unit raise @raster.Refused {
  let mut position = 0
  while position < body.length() {
    let header = body[position].to_int()
    let kind = header >> 4
    let index = header & 0x0F
    position = position + 1
    if index > 3 {
      raise @raster.Unexpected(
        at=position,
        got="table \{index}",
        want="a table below four",
      )
    }
    if position + 16 > body.length() {
      raise @raster.Truncated(at=position, want=16)
    }
    let counts : Array[Int32] = []
    let mut total = 0
    for step in 0..<16 {
      let value = body[position + step].to_int()
      counts.push(value)
      total = total + value
    }
    position = position + 16
    if position + total > body.length() {
      raise @raster.Truncated(at=position, want=total)
    }
    let symbols : Array[Int32] = []
    for step in 0..<total {
      symbols.push(body[position + step].to_int())
    }
    position = position + total
    let table = { counts, symbols, }
    if kind == 0 {
      dc_tables[index] = Some(table)
    } else {
      ac_tables[index] = Some(table)
    }
  }
}

///|
fn read_scan(
  body : BytesView,
  components : Array[Component],
) -> Scan raise @raster.Refused {
  if body.length() < 4 {
    raise @raster.Truncated(at=0, want=4)
  }
  let count = body[0].to_int()
  if count == 0 || count > 4 || body.length() < 1 + count * 2 + 3 {
    raise @raster.Unexpected(
      at=0,
      got="a scan of \{count} components",
      want="one to four",
    )
  }
  let chosen : Array[ScanComponent] = []
  for index in 0..<count {
    let id = body[1 + index * 2].to_int()
    let tables = body[2 + index * 2].to_int()
    let mut found = -1
    for candidate in 0..<components.length() {
      if components[candidate].id == id {
        found = candidate
      }
    }
    if found < 0 {
      raise @raster.Unexpected(
        at=1 + index * 2,
        got="component \{id}",
        want="one the frame declared",
      )
    }
    chosen.push({ index: found, dc: (tables >> 4) & 0x0F, ac: tables & 0x0F, })
  }
  let at = 1 + count * 2
  {
    components: chosen,
    start: body[at].to_int(),
    end: body[at + 1].to_int(),
    high: (body[at + 2].to_int() >> 4) & 0x0F,
    low: body[at + 2].to_int() & 0x0F,
  }
}

///|
fn decode_scan(
  bytes : BytesView,
  start : Int32,
  scan : Scan,
  components : Array[Component],
  dc_tables : Array[Huffman?],
  ac_tables : Array[Huffman?],
  restart_interval : Int32,
  width : Int32,
  height : Int32,
  hmax : Int32,
  vmax : Int32,
) -> Unit raise @raster.Refused {
  let single = scan.components.length() == 1
  let mut total = 0
  let mut mcu_w = 0
  let mut mcu_h = 0
  if single {
    let component = components[scan.components[0].index]
    total = component.blocks_w * component.blocks_h
  } else {
    mcu_w = (width + 8 * hmax - 1) / (8 * hmax)
    mcu_h = (height + 8 * vmax - 1) / (8 * vmax)
    total = mcu_w * mcu_h
  }
  let reader = BitsReader::new(bytes, start)
  let state = ScanState::{ eob_run: 0, }
  let mut index = 0
  while index < total {
    if restart_interval > 0 && index > 0 && index % restart_interval == 0 {
      reader.restart()
      for component in components {
        component.predictor = 0
      }
    }
    if single {
      let chosen = scan.components[0]
      decode_block(
        reader,
        components,
        chosen.index,
        index,
        scan,
        dc_tables,
        ac_tables,
        chosen,
        state,
      )
    } else {
      let mcu_x = index % mcu_w
      let mcu_y = index / mcu_w
      for chosen in scan.components {
        let component = components[chosen.index]
        for v in 0..<component.v {
          for h in 0..<component.h {
            let bx = mcu_x * component.h + h
            let by = mcu_y * component.v + v
            if bx < component.blocks_w && by < component.blocks_h {
              decode_block(
                reader,
                components,
                chosen.index,
                by * component.blocks_w + bx,
                scan,
                dc_tables,
                ac_tables,
                chosen,
                state,
              )
            }
          }
        }
      }
    }
    index = index + 1
  }
  let _ = mcu_w
  let _ = mcu_h
}

///|
/// One block: the DC coefficient, then the run-length coded AC ones.
fn decode_block(
  reader : BitsReader,
  components : Array[Component],
  which : Int32,
  block : Int32,
  scan : Scan,
  dc_tables : Array[Huffman?],
  ac_tables : Array[Huffman?],
  chosen : ScanComponent,
  state : ScanState,
) -> Unit raise @raster.Refused {
  let component = components[which]
  let at = block * 64
  if scan.start == 0 {
    if scan.high == 0 {
      let table = match dc_tables[chosen.dc & 3] {
        Some(table) => table
        None =>
          raise @raster.Unexpected(
            at=reader.position,
            got="no DC table",
            want="one the scan names",
          )
      }
      let length = decode_symbol(reader, table)
      if length > 15 {
        raise @raster.Unexpected(
          at=reader.position,
          got="a DC length of \{length}",
          want="at most fifteen",
        )
      }
      let difference = if length == 0 {
        0
      } else {
        let value = reader.bits(length)
        if value < 1 << (length - 1) {
          value - (1 << length) + 1
        } else {
          value
        }
      }
      // The predictor lives on the component, not on this copy of it: a frame
      // codes every block as a difference from the one before.
      let predicted = components[which].predictor + difference
      components[which].predictor = predicted
      component.coeffs[at] = predicted * (1 << scan.low)
    } else if reader.bit() == 1 {
      component.coeffs[at] = component.coeffs[at] | (1 << scan.low)
    }
  }
  if scan.end == 0 {
    return
  }
  let table = match ac_tables[chosen.ac & 3] {
    Some(table) => table
    None =>
      raise @raster.Unexpected(
        at=reader.position,
        got="no AC table",
        want="one the scan names",
      )
  }
  if scan.high == 0 {
    if state.eob_run > 0 {
      // The whole block was covered by an end-of-band run started earlier.
      state.eob_run = state.eob_run - 1
      return
    }
    // Coefficient zero is the DC one, which was read above: the run lengths
    // count from the first AC coefficient.
    let mut k = if scan.start == 0 { 1 } else { scan.start }
    while k <= scan.end {
      let symbol = decode_symbol(reader, table)
      let run = (symbol >> 4) & 0x0F
      let size = symbol & 0x0F
      if size == 0 {
        if run == 15 {
          k = k + 16
          continue
        }
        // An end-of-band code, which also says how many blocks follow empty.
        state.eob_run = (1 << run) - 1
        if run > 0 {
          state.eob_run = state.eob_run + reader.bits(run)
        }
        break
      }
      k = k + run
      if k > scan.end {
        break
      }
      let value = reader.bits(size)
      let signed = if value < 1 << (size - 1) {
        value - (1 << size) + 1
      } else {
        value
      }
      component.coeffs[at + zigzag(k)] = signed * (1 << scan.low)
      k = k + 1
    }
  } else {
    refine_ac(reader, component, at, scan, table, state)
  }
}

///|
/// The refinement pass: every coefficient already sent receives one bit, and new
/// ones appear only where the run says the next non-zero is.
fn refine_ac(
  reader : BitsReader,
  component : Component,
  at : Int32,
  scan : Scan,
  table : Huffman,
  state : ScanState,
) -> Unit raise @raster.Refused {
  let delta = 1 << scan.low
  let mut k = scan.start
  if state.eob_run > 0 {
    while k <= scan.end {
      let index = at + zigzag(k)
      if component.coeffs[index] != 0 {
        refine_bit(reader, component, index, delta)
      }
      k = k + 1
    }
    state.eob_run = state.eob_run - 1
    return
  }
  while k <= scan.end {
    let mut run = 0
    let mut value = 0
    let mut have_value = false
    if state.eob_run == 0 {
      let symbol = decode_symbol(reader, table)
      run = (symbol >> 4) & 0x0F
      let size = symbol & 0x0F
      if size != 0 {
        if size != 1 {
          raise @raster.Unexpected(
            at=reader.position,
            got="a refinement of \{size} bits",
            want="one bit",
          )
        }
        value = if reader.bit() == 1 { delta } else { -delta }
        have_value = true
      } else if run != 15 {
        state.eob_run = (1 << run) - 1
        if run > 0 {
          state.eob_run = state.eob_run + reader.bits(run)
        }
        while k <= scan.end {
          let index = at + zigzag(k)
          if component.coeffs[index] != 0 {
            refine_bit(reader, component, index, delta)
          }
          k = k + 1
        }
        return
      }
    }
    // Walk the run, refining the non-zero coefficients it passes over.
    while k <= scan.end {
      let index = at + zigzag(k)
      if component.coeffs[index] != 0 {
        refine_bit(reader, component, index, delta)
      } else if run == 0 {
        break
      } else {
        run = run - 1
      }
      k = k + 1
    }
    if have_value && k <= scan.end {
      component.coeffs[at + zigzag(k)] = value
      k = k + 1
    }
  }
}

///|
/// One refinement bit on a coefficient that already has a value.
fn refine_bit(
  reader : BitsReader,
  component : Component,
  index : Int32,
  delta : Int32,
) -> Unit {
  if reader.bit() == 0 {
    return
  }
  let value = component.coeffs[index]
  // The bit is only added once per pass, so a coefficient that already has it
  // does not get it twice.
  if (value & delta) != 0 {
    return
  }
  if value > 0 {
    component.coeffs[index] = value + delta
  } else {
    component.coeffs[index] = value - delta
  }
}

///|
/// The zig-zag order coefficients come in.
let zigzag_order : Array[Int32] = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
  41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15,
  23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62,
  63,
]

///|
fn zigzag(k : Int32) -> Int32 {
  zigzag_order[k]
}

///|
/// The value a JPEG writes for a magnitude in `bits` bits.
fn decode_symbol(
  reader : BitsReader,
  table : Huffman,
) -> Int32 raise @raster.Refused {
  let mut code = 0
  let mut first = 0
  let mut index = 0
  for length in 1..<=16 {
    code = (code << 1) | reader.bit()
    let count = table.counts[length - 1]
    if code - first < count {
      return table.symbols[index + code - first]
    }
    index = index + count
    first = (first + count) << 1
  }
  raise @raster.Unexpected(
    at=reader.position,
    got="a code no table has",
    want="a shorter code",
  )
}

///|
/// Bits, read the way JPEG writes them: most significant first, with a zero byte
/// after every 0xFF so that the stream cannot look like a marker.
priv struct BitsReader {
  data : BytesView
  mut position : Int32
  mut bits : Int32
  mut count : Int32
}

///|
fn BitsReader::new(data : BytesView, position : Int32) -> BitsReader {
  { data, position, bits: 0, count: 0, }
}

///|
fn BitsReader::fill(self : BitsReader) -> Unit {
  while self.count == 0 {
    if self.position >= self.data.length() {
      self.bits = 0
      self.count = 8
      return
    }
    let byte = self.data[self.position].to_int()
    if byte == 0xFF && self.position + 1 < self.data.length() {
      if self.data[self.position + 1].to_int() == 0x00 {
        self.position = self.position + 2
      } else {
        // A marker, so the scan has ended: feed zeroes rather than run away.
        self.bits = 0
        self.count = 8
        return
      }
    } else {
      self.position = self.position + 1
    }
    self.bits = byte
    self.count = 8
  }
}

///|
fn BitsReader::bit(self : BitsReader) -> Int32 {
  self.fill()
  self.count = self.count - 1
  (self.bits >> self.count) & 1
}

///|
fn BitsReader::bits(self : BitsReader, count : Int32) -> Int32 {
  let mut value = 0
  for _ in 0..<count {
    value = (value << 1) | self.bit()
  }
  value
}

///|
/// Skip to the next restart marker, and reset the bit stream on it.
fn BitsReader::restart(self : BitsReader) -> Unit {
  self.bits = 0
  self.count = 0
  while self.position + 1 < self.data.length() {
    if self.data[self.position].to_int() == 0xFF {
      let marker = self.data[self.position + 1].to_int()
      if marker >= 0xD0 && marker <= 0xD7 {
        self.position = self.position + 2
        return
      }
      if marker != 0x00 {
        return
      }
    }
    self.position = self.position + 1
  }
}

///|
/// Dequantise, transform, upsample and colour-convert into pixels.
fn assemble(
  components : Array[Component],
  width : Int32,
  height : Int32,
  hmax : Int32,
  vmax : Int32,
  quants : Array[Quant?],
) -> @raster.Image raise @raster.Refused {
  let count = components.length()
  let planes : Array[FixedArray[Byte]] = []
  for index in 0..<count {
    let component = components[index]
    let table = match quants[component.quant & 3] {
      Some(table) => table
      None =>
        raise @raster.Unexpected(
          at=0,
          got="no quantisation table",
          want="one the frame names",
        )
    }
    let plane_width = component.blocks_w * 8
    let plane : FixedArray[Byte] = FixedArray::make(
      plane_width * component.blocks_h * 8,
      b'\x00',
    )
    let block : FixedArray[Double] = FixedArray::make(64, 0.0)
    for by in 0..<component.blocks_h {
      for bx in 0..<component.blocks_w {
        let at = (by * component.blocks_w + bx) * 64
        for k in 0..<64 {
          block[k] = (component.coeffs[at + k] * table.values[k]).to_double()
        }
        inverse_dct(block)
        for y in 0..<8 {
          for x in 0..<8 {
            plane[(by * 8 + y) * plane_width + bx * 8 + x] = clamp_byte(
              block[y * 8 + x] + 128.0,
            )
          }
        }
      }
    }
    planes.push(
      upsample(
        plane,
        plane_width,
        component.blocks_h * 8,
        width,
        height,
        hmax / component.h,
        vmax / component.v,
      ),
    )
  }
  let out_format = if count == 1 {
    @raster.PixelFormat::Gray8
  } else {
    @raster.PixelFormat::Rgb8
  }
  let stride = width * out_format.bytes()
  let output : FixedArray[Byte] = FixedArray::make(stride * height, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let at = y * stride + x * out_format.bytes()
      if count == 1 {
        output[at] = planes[0][y * width + x]
      } else if count >= 3 {
        let luma = planes[0][y * width + x].to_int()
        let cb = planes[1][y * width + x].to_int()
        let cr = planes[2][y * width + x].to_int()
        let (red, green, blue) = ycbcr_to_rgb(luma, cb, cr)
        output[at] = red.to_byte()
        output[at + 1] = green.to_byte()
        output[at + 2] = blue.to_byte()
      }
    }
  }
  {
    width,
    height,
    format: out_format,
    stride,
    pixels: Bytes::from_array(output.clamped_view()),
    premultiplied: false,
    metadata: @raster.Metadata::default(),
  }
}

///|
/// Scale a component's plane up to the size of the image.
///
/// The triangle filter the reference decoder uses: a sample is worth three
/// quarters and its neighbour one, which keeps a colour edge from turning into a
/// staircase of blocks. The two axes are separable, so it is a horizontal pass
/// and then a vertical one.
fn upsample(
  plane : FixedArray[Byte],
  plane_width : Int32,
  plane_height : Int32,
  width : Int32,
  height : Int32,
  hx : Int32,
  vy : Int32,
) -> FixedArray[Byte] {
  let wide : FixedArray[Byte] = FixedArray::make(width * plane_height, b'\x00')
  for y in 0..<plane_height {
    for x in 0..<width {
      let source_x = x / hx
      if hx == 1 || x == 0 || x == width - 1 {
        wide[y * width + x] = plane[y * plane_width + source_x]
      } else {
        let neighbour = if x % 2 == 0 { source_x - 1 } else { source_x + 1 }
        let clamped = clamp_index(neighbour, plane_width)
        let base = plane[y * plane_width + source_x].to_int()
        let near = plane[y * plane_width + clamped].to_int()
        let bias = if x % 2 == 0 { 1 } else { 2 }
        wide[y * width + x] = ((base * 3 + near + bias) >> 2).to_byte()
      }
    }
  }
  let out : FixedArray[Byte] = FixedArray::make(width * height, b'\x00')
  for y in 0..<height {
    let source_y = y / vy
    for x in 0..<width {
      if vy == 1 || y == 0 || y == height - 1 {
        out[y * width + x] = wide[source_y * width + x]
      } else {
        let neighbour = if y % 2 == 0 { source_y - 1 } else { source_y + 1 }
        let clamped = clamp_index(neighbour, plane_height)
        let base = wide[source_y * width + x].to_int()
        let near = wide[clamped * width + x].to_int()
        let bias = if y % 2 == 0 { 1 } else { 2 }
        out[y * width + x] = ((base * 3 + near + bias) >> 2).to_byte()
      }
    }
  }
  out
}

///|
fn clamp_index(value : Int32, limit : Int32) -> Int32 {
  if value < 0 {
    0
  } else if value >= limit {
    limit - 1
  } else {
    value
  }
}

///|
fn ycbcr_to_rgb(y : Int32, cb : Int32, cr : Int32) -> (Int32, Int32, Int32) {
  let luma = y.to_double()
  let blue_difference = cb.to_double() - 128.0
  let red_difference = cr.to_double() - 128.0
  (
    clamp_component(luma + 1.402 * red_difference),
    clamp_component(
      luma - 0.344_136 * blue_difference - 0.714_136 * red_difference,
    ),
    clamp_component(luma + 1.772 * blue_difference),
  )
}

///|
fn clamp_component(value : Double) -> Int32 {
  if value <= 0.0 {
    0
  } else if value >= 255.0 {
    255
  } else {
    (value + 0.5).to_int()
  }
}

///|
fn clamp_byte(value : Double) -> Byte {
  if value <= 0.0 {
    b'\x00'
  } else if value >= 255.0 {
    b'\xff'
  } else {
    (value + 0.5).to_int().to_byte()
  }
}

///|
/// The inverse cosine transform, separable and in floating point.
fn inverse_dct(block : FixedArray[Double]) -> Unit {
  let temp : FixedArray[Double] = FixedArray::make(64, 0.0)
  for y in 0..<8 {
    for x in 0..<8 {
      let mut total = 0.0
      for u in 0..<8 {
        total = total + scale(u) * block[y * 8 + u] * cosine(x, u)
      }
      temp[y * 8 + x] = total * 0.5
    }
  }
  for x in 0..<8 {
    for y in 0..<8 {
      let mut total = 0.0
      for v in 0..<8 {
        total = total + scale(v) * temp[v * 8 + x] * cosine(y, v)
      }
      block[y * 8 + x] = total * 0.5
    }
  }
}

///|
fn scale(u : Int32) -> Double {
  if u == 0 {
    0.707_106_781_186_547_5
  } else {
    1.0
  }
}

///|
/// The transform's cosines, precomputed: a table of sixty-four doubles is cheaper
/// than a million calls to a trigonometric function.
let cosines : Array[Double] = precompute_cosines()

///|
fn precompute_cosines() -> Array[Double] {
  let values : Array[Double] = []
  for position in 0..<8 {
    for frequency in 0..<8 {
      let angle = (2.0 * position.to_double() + 1.0) *
        frequency.to_double() *
        3.141_592_653_589_793 /
        16.0
      values.push(@math.cos(angle))
    }
  }
  values
}

///|
fn cosine(position : Int32, frequency : Int32) -> Double {
  cosines[position * 8 + frequency]
}
