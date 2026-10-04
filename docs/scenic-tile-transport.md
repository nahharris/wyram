# Scenic tile transport

Visual tiles have a versioned, little-endian representation independent of
native struct layout. The public `Wyram.Scenery.Key` validates signed 32-bit
coordinates and levels zero through ten, and calculates origins and parents
with floor division for negative coordinates.

`WSL1` begins each tile. The next four bytes contain the level, storage mode,
and two reserved zero bytes, followed by three signed 32-bit coordinates.
Mode zero carries no cells; mode one carries one uniform cell; mode two carries
the full 16³ grid in Y/Z/X order. A cell contains a 16-bit material, a 32-bit
occupied sample count, an occupied-child mask, and a zero-or-one mixing flag.
Encoded lengths are exactly 20, 28, or 32,788 bytes.

`WSL2` keeps that header and adds a 16-bit top-surface material to each cell.
Its lengths are 20, 30, or 40,980 bytes. Tiles without separate surface metadata
continue to use `WSL1`; the native decoder accepts both versions. The surface
material is zero exactly when the cell is empty, and leaves cannot override
their exact material. Dense surface data canonicalizes independently of the
occupancy grid. Cache admission reserves the larger maximum for every node.

Top materials use one vote per horizontal child column, taking its highest
occupied child. Volume material selection and occupied counts are unchanged.
Direct coarse generation also samples the geological surface above the last
occupied stratum, so thin surface layers can retain their color when the volume
sample misses them. Known sample edits override both values. These remain
approximate visual summaries; unsampled edits and thin geometry can be omitted.

Scenery capability two accepts both tile versions. Clients advertising an older
capability receive near rendering only, avoiding unsupported tile data.

Decoding checks version, reserved bytes, exact length, resolution, material and
count agreement, count capacity, and child-mask capacity. Leaf cells cannot
carry reduction hints. Dense input is canonicalized to uniform storage when
all cells match. The decoder accepts a uniform empty payload and emits the
short empty encoding when it is encoded again.

The engine exposes two batched dirty-CPU native operations. Chunk import
accepts at most sixteen exact packed chunks per call. Reduction accepts at
most eight groups of eight complete sibling tiles. Results preserve input
batch order; malformed encodings and incomplete or incompatible siblings
return errors. These operations consume immutable data and never load a
gameplay region, read the world, or send a renderer message.

The payload is visual data, not a cache identity or authoritative snapshot.
A future cache envelope must include world seed, generator and material
identity, reducer version, and edit revision. Runtime IPC, persistence,
generation policy, and distant drawing are separate integration work.

Validation covers golden bytes, all truncated lengths, oversized and unknown
headers, impossible cells, sparse reduced tiles, coordinate parity, reordered
sibling batches, and native batch limits. This change adds no dependencies.
