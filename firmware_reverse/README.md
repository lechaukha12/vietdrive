# VietMap firmware evidence

This directory records reverse-engineering evidence used to decode `map-data/secrect.bin` without guessing provider values.

## Reference images

- Firmware: `/Users/lechaukha12/Desktop/vietmap/firmware/FW96670A.bin`
  - SHA-256: `aae511ea849c6978f7f171ed5ed88297be734b84136224c5b2363df1a472c45a`
- Bundled firmware data: `/Users/lechaukha12/Desktop/vietmap/firmware/secrect.bin`
  - SHA-256: `9c76cf81c3cd4ebcf69ac8d1cb6b01c4f039ddfeeabd6f8b22a4289c2adf8f3f`
- Project data: `map-data/secrect.bin`
  - SHA-256: `c3210a65bf0e766a9dcb49b20ee07ab3abf507f238885e6a6122f48da2391cb1`

## Exact byte decoder

The MIPS function at virtual address `0x00cc08b0` decodes every byte as:

```text
decoded_byte = table[encoded_byte XOR 0xAA]
```

`table` is the 256-byte permutation stored in the firmware at virtual address `0x01c674a0`. The existing `build_full_map()` implementation is not equivalent: it derives a partial mapping from assumed Vietnamese plaintext and manually added substitutions. That changes numeric fields as well as text and therefore cannot be used for production data.

Examples from the first `edogen.bin` record in the project archive:

```text
firmware decoder: 104.847283, 8.576372, type 1, speed 50, direction 304
old manual map:   104.947295, 9.376572, type 1, speed 30, direction 504
```

## Archive members

The 512-byte archive header and firmware path strings establish this order:

1. `edogen.bin` — traffic/camera/sign points
2. `citiesen.bin` — province/city lookup
3. `districtsen.bin` — district/road-name lookup
4. `roadsenz.bin` — compressed road graph

The current extractor assigns incorrect filenames to the first three members, although their byte ranges are split at the correct sizes.

## Road record layout

Firmware parser `0x00cb5b08` builds a `0x90c`-byte runtime record:

1. Road serial number (`+0x00`)
2. Provider road ID (`+0x0c`)
3. Inline road name (`+0x10`)
4. Direction-1 district/name lookup ID (`+0xa8`)
5. Direction-2 district/name lookup ID (`+0xac`)
6. Direction-1 speed (`+0xb0`)
7. Direction-2 speed (`+0xb4`)
8. Alternating coordinates, stored in two 260-float arrays (`+0xc0` and `+0x4d0`)

The values in fields 4 and 5 are not graph `from_node_id` and `to_node_id` values.

## Firmware matching behavior

- `0x00cb7c00` computes the minimum distance from the current GPS coordinate to all segments in a road record.
- Candidate refinement uses 500 m, 100 m and 10 m sampling/threshold passes.
- `0x00cb725c` determines direction from the last two GPS fixes and the road's first/last coordinates.
- A directional match requires an angular difference below 30 degrees when the firmware enables the direction check.
- `0x00cb473c` chooses the paired lookup ID and speed from direction 1 or direction 2. The chosen speed is copied directly to the UI state by `0x00ca29b0`; there is no `30 -> 50` conversion.

## Bình Lợi control case

Exact decoding with the firmware substitution table yields consecutive road records named `Bình Lợi` with both directional speeds equal to `50`. For example, source record 282186 decodes to:

```text
282186,178264,Bình Lợi,23052,23052,50,50,
106.706716,10.825314,106.706642,10.825651
```

The old manual mapping exported the corresponding data as speed `30` and also changed the coordinates. The incorrect app result is therefore primarily a decode corruption, before map matching is considered.

`DecompileAt.java` and `ListReferences.java` are headless Ghidra helpers used to reproduce the address-level findings above.
