-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| GSA.ABI.Types — Core type definitions for Game Server Admin ABI
|||
||| Defines all domain types with dependent type proofs for the Game Server
||| Admin system. Types are designed for C ABI compatibility via the Zig FFI
||| layer, with formal guarantees on port ranges, non-empty identifiers,
||| configuration validity, and result classification.
|||
||| All record types map 1:1 to Zig structs in ffi/zig/src/.
||| VeriSimDB integration uses the ServerOctad type for 8-modality storage.
|||
||| @see GSA.ABI.Foreign for FFI declarations using these types
||| @see GSA.ABI.Layout for memory layout proofs of these types

module Types

import Data.List
import Data.List.Elem
import Data.Maybe
import Data.Nat
import Data.So
import Data.Vect

%default total

--------------------------------------------------------------------------------
-- Result Codes
--------------------------------------------------------------------------------

||| Result codes for all FFI operations.
||| Maps to C int32 values 0-12. Each variant has a fixed integer encoding
||| used across the ABI boundary. Results are classified as terminal (no retry)
||| or transient (retry may succeed).
public export
data Result : Type where
  ||| Operation completed successfully (code 0)
  Ok               : Result
  ||| Generic/unclassified error (code 1)
  Error            : Result
  ||| A parameter failed validation (code 2)
  InvalidParam     : Result
  ||| Memory allocation failed (code 3)
  OutOfMemory      : Result
  ||| A null pointer was dereferenced or passed (code 4)
  NullPointer      : Result
  ||| A linear resource was used after consumption (code 5)
  AlreadyConsumed  : Result
  ||| A linear resource was not consumed before going out of scope (code 6)
  ResourceLeaked   : Result
  ||| A linear resource was freed more than once (code 7)
  DoubleFree       : Result
  ||| A server probe timed out waiting for response (code 8)
  ProbeTimeout     : Result
  ||| TCP connection to target host:port was refused (code 9)
  ConnectionRefused : Result
  ||| Authentication credentials were rejected (code 10)
  AuthFailed       : Result
  ||| Configuration file could not be parsed (code 11)
  ConfigParseError : Result
  ||| VeriSimDB instance is unreachable or not running (code 12)
  VeriSimDBUnavailable : Result

||| Convert a Result to its C-compatible integer representation.
||| These values are stable across ABI versions and must not change.
public export
resultToInt : Result -> Int
resultToInt Ok                  = 0
resultToInt Error               = 1
resultToInt InvalidParam        = 2
resultToInt OutOfMemory         = 3
resultToInt NullPointer         = 4
resultToInt AlreadyConsumed     = 5
resultToInt ResourceLeaked      = 6
resultToInt DoubleFree          = 7
resultToInt ProbeTimeout        = 8
resultToInt ConnectionRefused   = 9
resultToInt AuthFailed          = 10
resultToInt ConfigParseError    = 11
resultToInt VeriSimDBUnavailable = 12

||| Parse a C integer back into a Result.
||| Returns Nothing for unrecognised codes, providing forward compatibility
||| when new result codes are added in future ABI versions.
public export
resultFromInt : Int -> Maybe Result
resultFromInt 0  = Just Ok
resultFromInt 1  = Just Error
resultFromInt 2  = Just InvalidParam
resultFromInt 3  = Just OutOfMemory
resultFromInt 4  = Just NullPointer
resultFromInt 5  = Just AlreadyConsumed
resultFromInt 6  = Just ResourceLeaked
resultFromInt 7  = Just DoubleFree
resultFromInt 8  = Just ProbeTimeout
resultFromInt 9  = Just ConnectionRefused
resultFromInt 10 = Just AuthFailed
resultFromInt 11 = Just ConfigParseError
resultFromInt 12 = Just VeriSimDBUnavailable
resultFromInt _  = Nothing

||| Classify whether a Result is terminal (will never succeed on retry)
||| or transient (retry may succeed). This drives retry logic in the
||| safe wrappers: terminal results abort immediately, transient results
||| may be retried with backoff.
|||
||| Terminal: InvalidParam, NullPointer, AlreadyConsumed, ResourceLeaked,
|||           DoubleFree, ConfigParseError (these indicate bugs, not transient failures)
||| Transient: ProbeTimeout, ConnectionRefused, AuthFailed, VeriSimDBUnavailable,
|||            OutOfMemory, Error (these may resolve with retry)
||| Ok is neither — it indicates success.
public export
resultIsTerminal : Result -> Bool
resultIsTerminal Ok                  = False
resultIsTerminal Error               = False
resultIsTerminal InvalidParam        = True
resultIsTerminal OutOfMemory         = False
resultIsTerminal NullPointer         = True
resultIsTerminal AlreadyConsumed     = True
resultIsTerminal ResourceLeaked      = True
resultIsTerminal DoubleFree          = True
resultIsTerminal ProbeTimeout        = False
resultIsTerminal ConnectionRefused   = False
resultIsTerminal AuthFailed          = False
resultIsTerminal ConfigParseError    = True
resultIsTerminal VeriSimDBUnavailable = False

||| Human-readable description of each result code.
||| Used for logging and error reporting.
public export
resultDescription : Result -> String
resultDescription Ok                  = "Success"
resultDescription Error               = "Generic error"
resultDescription InvalidParam        = "Invalid parameter"
resultDescription OutOfMemory         = "Out of memory"
resultDescription NullPointer         = "Null pointer"
resultDescription AlreadyConsumed     = "Resource already consumed"
resultDescription ResourceLeaked      = "Resource leaked without cleanup"
resultDescription DoubleFree          = "Double free detected"
resultDescription ProbeTimeout        = "Server probe timed out"
resultDescription ConnectionRefused   = "Connection refused"
resultDescription AuthFailed          = "Authentication failed"
resultDescription ConfigParseError    = "Configuration parse error"
resultDescription VeriSimDBUnavailable = "VeriSimDB instance unavailable"

||| Decidable equality for Result, enabling pattern matching and proof
||| construction over result codes at the type level.
public export
Eq Result where
  Ok == Ok = True
  Error == Error = True
  InvalidParam == InvalidParam = True
  OutOfMemory == OutOfMemory = True
  NullPointer == NullPointer = True
  AlreadyConsumed == AlreadyConsumed = True
  ResourceLeaked == ResourceLeaked = True
  DoubleFree == DoubleFree = True
  ProbeTimeout == ProbeTimeout = True
  ConnectionRefused == ConnectionRefused = True
  AuthFailed == AuthFailed = True
  ConfigParseError == ConfigParseError = True
  VeriSimDBUnavailable == VeriSimDBUnavailable = True
  _ == _ = False

||| Show instance for logging and debugging
public export
Show Result where
  show = resultDescription

--------------------------------------------------------------------------------
-- Configuration Format
--------------------------------------------------------------------------------

||| Supported configuration file formats for game servers.
||| Each game server typically uses one of these formats for its settings.
||| The Custom variant allows extension for proprietary formats.
public export
data ConfigFormat : Type where
  ||| XML configuration (e.g., DayZ, some Unreal servers)
  XML      : ConfigFormat
  ||| INI-style configuration (e.g., many Source engine games)
  INI      : ConfigFormat
  ||| JSON configuration (e.g., Factorio, some modern servers)
  JSON     : ConfigFormat
  ||| Environment variable style (KEY=VALUE per line)
  ENV      : ConfigFormat
  ||| YAML configuration (e.g., Minecraft plugins, Paper)
  YAML     : ConfigFormat
  ||| TOML configuration (e.g., Rust game servers)
  TOML     : ConfigFormat
  ||| Lua-based configuration (e.g., Garry's Mod, FiveM)
  Lua      : ConfigFormat
  ||| Simple key=value pairs without sections
  KeyValue : ConfigFormat
  ||| Custom/proprietary format identified by name string
  Custom   : (formatName : String) -> ConfigFormat

||| Convert ConfigFormat to its C-compatible integer.
||| Custom formats use code 8; the format name is passed separately.
public export
configFormatToInt : ConfigFormat -> Int
configFormatToInt XML      = 0
configFormatToInt INI      = 1
configFormatToInt JSON     = 2
configFormatToInt ENV      = 3
configFormatToInt YAML     = 4
configFormatToInt TOML     = 5
configFormatToInt Lua      = 6
configFormatToInt KeyValue = 7
configFormatToInt (Custom _) = 8

||| Eq instance for ConfigFormat
public export
Eq ConfigFormat where
  XML == XML = True
  INI == INI = True
  JSON == JSON = True
  ENV == ENV = True
  YAML == YAML = True
  TOML == TOML = True
  Lua == Lua = True
  KeyValue == KeyValue = True
  (Custom a) == (Custom b) = a == b
  _ == _ = False

||| Show instance for ConfigFormat
public export
Show ConfigFormat where
  show XML      = "XML"
  show INI      = "INI"
  show JSON     = "JSON"
  show ENV      = "ENV"
  show YAML     = "YAML"
  show TOML     = "TOML"
  show Lua      = "Lua"
  show KeyValue = "KeyValue"
  show (Custom name) = "Custom(" ++ name ++ ")"

--------------------------------------------------------------------------------
-- Probe Protocol
--------------------------------------------------------------------------------

||| Network protocols used to probe and identify running game servers.
||| Each protocol defines how to send a query packet and interpret the response.
public export
data ProbeProtocol : Type where
  ||| Valve Source Query protocol (A2S_INFO, A2S_PLAYER, etc.)
  SteamQuery    : ProbeProtocol
  ||| Remote Console protocol (Source RCON, Minecraft RCON)
  RCON          : ProbeProtocol
  ||| Minecraft-specific query protocol (Basic/Full stat)
  MinecraftQuery : ProbeProtocol
  ||| GameSpy query protocol (older games: Battlefield, UT)
  GameSpy       : ProbeProtocol
  ||| HTTP/HTTPS REST API endpoint
  REST          : ProbeProtocol
  ||| SSH command execution (for checking process status)
  SSH           : ProbeProtocol
  ||| WebSocket-based query (modern game servers)
  WebSocket     : ProbeProtocol
  ||| Custom TCP protocol with user-defined handshake
  CustomTCP     : ProbeProtocol

||| Convert ProbeProtocol to C-compatible integer
public export
probeProtocolToInt : ProbeProtocol -> Int
probeProtocolToInt SteamQuery     = 0
probeProtocolToInt RCON           = 1
probeProtocolToInt MinecraftQuery = 2
probeProtocolToInt GameSpy        = 3
probeProtocolToInt REST           = 4
probeProtocolToInt SSH            = 5
probeProtocolToInt WebSocket      = 6
probeProtocolToInt CustomTCP      = 7

||| Parse a C integer back into a ProbeProtocol
public export
probeProtocolFromInt : Int -> Maybe ProbeProtocol
probeProtocolFromInt 0 = Just SteamQuery
probeProtocolFromInt 1 = Just RCON
probeProtocolFromInt 2 = Just MinecraftQuery
probeProtocolFromInt 3 = Just GameSpy
probeProtocolFromInt 4 = Just REST
probeProtocolFromInt 5 = Just SSH
probeProtocolFromInt 6 = Just WebSocket
probeProtocolFromInt 7 = Just CustomTCP
probeProtocolFromInt _ = Nothing

||| Eq instance for ProbeProtocol
public export
Eq ProbeProtocol where
  SteamQuery == SteamQuery = True
  RCON == RCON = True
  MinecraftQuery == MinecraftQuery = True
  GameSpy == GameSpy = True
  REST == REST = True
  SSH == SSH = True
  WebSocket == WebSocket = True
  CustomTCP == CustomTCP = True
  _ == _ = False

||| Show instance for ProbeProtocol
public export
Show ProbeProtocol where
  show SteamQuery     = "SteamQuery"
  show RCON           = "RCON"
  show MinecraftQuery = "MinecraftQuery"
  show GameSpy        = "GameSpy"
  show REST           = "REST"
  show SSH            = "SSH"
  show WebSocket      = "WebSocket"
  show CustomTCP      = "CustomTCP"

--------------------------------------------------------------------------------
-- Health Status
--------------------------------------------------------------------------------

||| Health status levels for monitored game servers.
||| Ordered by severity: Healthy < Warning < Degraded < Critical.
public export
data HealthStatus : Type where
  ||| Server is operating normally, all metrics within bounds
  Healthy  : HealthStatus
  ||| One or more metrics are approaching thresholds
  Warning  : HealthStatus
  ||| Server is partially functional but experiencing issues
  Degraded : HealthStatus
  ||| Server is non-functional or at risk of failure
  Critical : HealthStatus

||| Convert HealthStatus to C-compatible integer
public export
healthStatusToInt : HealthStatus -> Int
healthStatusToInt Healthy  = 0
healthStatusToInt Warning  = 1
healthStatusToInt Degraded = 2
healthStatusToInt Critical = 3

||| Parse a C integer back into a HealthStatus
public export
healthStatusFromInt : Int -> Maybe HealthStatus
healthStatusFromInt 0 = Just Healthy
healthStatusFromInt 1 = Just Warning
healthStatusFromInt 2 = Just Degraded
healthStatusFromInt 3 = Just Critical
healthStatusFromInt _ = Nothing

||| Eq and Show for HealthStatus
public export
Eq HealthStatus where
  Healthy == Healthy = True
  Warning == Warning = True
  Degraded == Degraded = True
  Critical == Critical = True
  _ == _ = False

public export
Show HealthStatus where
  show Healthy  = "Healthy"
  show Warning  = "Warning"
  show Degraded = "Degraded"
  show Critical = "Critical"

||| Ordering on HealthStatus by severity
public export
Ord HealthStatus where
  compare Healthy  Healthy  = EQ
  compare Healthy  _        = LT
  compare Warning  Healthy  = GT
  compare Warning  Warning  = EQ
  compare Warning  _        = LT
  compare Degraded Critical = LT
  compare Degraded Degraded = EQ
  compare Degraded _        = GT
  compare Critical Critical = EQ
  compare Critical _        = GT

--------------------------------------------------------------------------------
-- Linear Server Handle
--------------------------------------------------------------------------------

||| A linear server handle representing an active connection to a game server.
||| This is a linear resource: it MUST be consumed exactly once by calling
||| closeHandle. The Idris2 type system enforces this at compile time.
|||
||| The `valid` field is an erased proof that the underlying pointer is
||| non-null, preventing null-pointer dereferences at the type level.
|||
||| @param rawPtr The raw C pointer (as Int) to the server connection state
||| @param serverId The identifier string for this server instance
||| @param valid Erased proof that rawPtr is strictly positive (non-null)
public export
record ServerHandle where
  constructor MkServerHandle
  ||| Raw C pointer to the server connection state, encoded as Int.
  ||| This value is opaque — do not interpret or modify it.
  rawPtr   : Int
  ||| Identifier string for the connected server instance.
  ||| Guaranteed non-empty by the probe function that creates the handle.
  serverId : String
  ||| Erased compile-time proof that rawPtr > 0 (non-null).
  ||| This proof is constructed at handle creation time and costs nothing
  ||| at runtime — it exists only in the type checker.
  0 valid  : So (rawPtr > 0)

--------------------------------------------------------------------------------
-- Probe Result
--------------------------------------------------------------------------------

||| The result of probing a game server: identifies what game is running,
||| its version, how to communicate with it, and where its config lives.
||| This is a pure data record (affine — can be used zero or more times).
public export
record ProbeResult where
  constructor MkProbeResult
  ||| Canonical game identifier (e.g., "minecraft-java", "csgo", "valheim")
  gameId      : String
  ||| Server-reported version string
  version     : String
  ||| Protocol used to communicate with this server
  protocol    : ProbeProtocol
  ||| Response signature used for fingerprint matching
  fingerprint : String
  ||| List of discovered configuration file paths on the server
  configPaths : List String
  ||| Hostname or IP address of the probed server
  host        : String
  ||| Port number of the probed server
  port        : Nat

--------------------------------------------------------------------------------
-- Configuration Types
--------------------------------------------------------------------------------

||| A single configuration field definition.
||| Describes one adjustable setting in a game server's configuration,
||| including its type, display label, default value, and valid range.
public export
record ConfigField where
  constructor MkConfigField
  ||| Machine-readable key (e.g., "max_players", "server_name")
  key        : String
  ||| Current value as a string (all values serialised as strings for ABI)
  value      : String
  ||| Type hint for UI rendering (e.g., "int", "string", "bool", "enum")
  fieldType  : String
  ||| Human-readable label (e.g., "Maximum Players", "Server Name")
  label      : String
  ||| Default value, if one is defined by the game
  defaultVal : Maybe String
  ||| Minimum value for numeric fields
  rangeMin   : Maybe Int
  ||| Maximum value for numeric fields
  rangeMax   : Maybe Int
  ||| Whether this field contains sensitive data (passwords, RCON keys)
  isSecret   : Bool

||| A2ML-formatted configuration bundle for a game server.
||| Groups all settings for a single server instance with metadata about
||| the file format and location.
public export
record A2MLConfig where
  constructor MkA2MLConfig
  ||| Unique server instance identifier
  serverId   : String
  ||| Canonical game identifier matching ProbeResult.gameId
  gameId     : String
  ||| Format of the configuration file on disk
  format     : ConfigFormat
  ||| Absolute path to the configuration file
  configPath : String
  ||| List of configuration fields extracted from the file
  fields     : List ConfigField

--------------------------------------------------------------------------------
-- Game Profile
--------------------------------------------------------------------------------

||| A complete game profile defining how to manage a particular game server.
||| Profiles are loaded from disk and used by the probe, config extraction,
||| and server action subsystems. Each profile describes one game engine
||| and its specific management interface.
public export
record GameProfile where
  constructor MkGameProfile
  ||| Canonical game identifier (e.g., "minecraft-java")
  id                 : String
  ||| Human-readable game name (e.g., "Minecraft: Java Edition")
  name               : String
  ||| Game engine name (e.g., "Source", "Unreal", "Java", "Custom")
  engine             : String
  ||| Named port mappings: (label, port number) pairs
  ||| e.g., [("game", 25565), ("rcon", 25575), ("query", 25565)]
  ports              : List (String, Nat)
  ||| Primary query protocol for this game
  protocol           : ProbeProtocol
  ||| Regex-like pattern to match against probe response for identification
  fingerprintPattern : String
  ||| Configuration file format used by this game
  configFormat       : ConfigFormat
  ||| Default path to the configuration file (may contain placeholders)
  configPath         : String
  ||| List of known configuration field definitions
  fieldDefs          : List ConfigField
  ||| Available server actions as (action_id, description) pairs
  ||| e.g., [("start", "Start server"), ("stop", "Stop server")]
  actions            : List (String, String)

--------------------------------------------------------------------------------
-- VeriSimDB Integration: ServerOctad
--------------------------------------------------------------------------------

||| ServerOctad maps to VeriSimDB's 8-modality storage model.
||| Each game server's state is stored as an octad, enabling rich
||| multi-modal queries (graph traversal, vector similarity, temporal
||| versioning, spatial proximity, etc.).
|||
||| The 8 modalities are:
|||   1. Graph — relationships between servers, players, configs
|||   2. Vector — embedding for similarity search
|||   3. Tensor — multi-dimensional metric snapshots
|||   4. Semantic — annotated key-value metadata
|||   5. Document — full-text searchable content
|||   6. Temporal — version counter for change tracking
|||   7. Provenance — cryptographic hash of the data lineage
|||   8. Spatial — optional physical/logical coordinates
public export
record ServerOctad where
  constructor MkServerOctad
  ||| Graph modality: serialised graph data (adjacency list, edges, etc.)
  graphData          : String
  ||| Vector modality: embedding vector for similarity search
  vectorEmbedding    : List Double
  ||| Tensor modality: 2D metric tensor (rows of measurements)
  tensorMetrics      : List (List Double)
  ||| Semantic modality: annotated key-value pairs
  semanticAnnotations : List (String, String)
  ||| Document modality: full-text content for search indexing
  documentText       : String
  ||| Temporal modality: monotonically increasing version counter
  temporalVersion    : Nat
  ||| Provenance modality: SHA-256 hash of the data lineage chain
  provenanceHash     : String
  ||| Spatial modality: optional (x, y, z) coordinates
  ||| (e.g., data centre location, logical topology position)
  spatialCoords      : Maybe (Double, Double, Double)

--------------------------------------------------------------------------------
-- Fingerprint
--------------------------------------------------------------------------------

||| A network fingerprint captured from probing a game server.
||| Contains the raw response signature and timing information
||| used to identify the game and version running on the target.
public export
record Fingerprint where
  constructor MkFingerprint
  ||| Hostname or IP address that was probed
  host              : String
  ||| Port number that was probed
  port              : Nat
  ||| Protocol used for the probe
  protocol          : ProbeProtocol
  ||| Raw response bytes encoded as a hex string
  responseSignature : String
  ||| Round-trip time of the probe in milliseconds
  latencyMs         : Nat

--------------------------------------------------------------------------------
-- Drift Report
--------------------------------------------------------------------------------

||| A drift report comparing a server's current state against its expected
||| baseline. Drift scores are normalised to [0.0, 1.0] where 0.0 means
||| no drift (perfect match) and 1.0 means complete divergence.
public export
record DriftReport where
  constructor MkDriftReport
  ||| Server instance identifier
  serverId            : String
  ||| Overall health status derived from drift scores
  status              : HealthStatus
  ||| Configuration drift: how far current config has drifted from baseline
  configDrift         : Double
  ||| Semantic drift: changes in annotations and metadata
  semanticDrift       : Double
  ||| Temporal consistency: whether version history is coherent
  temporalConsistency : Double
  ||| Weighted overall drift score
  overallScore        : Double

--------------------------------------------------------------------------------
-- Proof Obligations
--------------------------------------------------------------------------------

||| Proof that a natural number is a valid network port (1-65535).
||| Port 0 is reserved/invalid; ports above 65535 exceed the 16-bit range.
|||
||| Returns a pair of proofs: that the port is at least 1, and at most 65535.
||| The Dec wrapper makes this decidable — it either produces a proof or
||| a proof of impossibility, with no partial cases.
|||
||| @param p The candidate port number
||| @return Yes (proof_ge_1, proof_le_65535) or No (impossibility proof)
public export
portInRange : (p : Nat) -> Dec (LTE 1 p, LTE p 65535)
portInRange Z = No (\(lte1, _) => absurd lte1)
portInRange (S k) =
  case isLTE 1 (S k) of
    Yes prf1 =>
      case isLTE (S k) 65535 of
        Yes prf2 => Yes (prf1, prf2)
        No contra2 => No (\(_, prf2) => contra2 prf2)
    No contra1 => No (\(prf1, _) => contra1 prf1)

||| Predicate: a list of characters is non-empty.
||| Used to prove that string identifiers are not blank.
public export
data NonEmpty : List a -> Type where
  IsNonEmpty : NonEmpty (x :: xs)

||| Uninhabited instance: the empty list is never NonEmpty.
||| This allows `absurd` to discharge impossible cases in proofs.
public export
Uninhabited (NonEmpty []) where
  uninhabited IsNonEmpty impossible

||| Decide whether a string is non-empty by unpacking it to a character list.
||| Server IDs, game IDs, and other identifiers must be non-empty strings.
|||
||| @param s The candidate string
||| @return Yes (proof of non-emptiness) or No (proof it's empty)
public export
nonEmptyId : (s : String) -> Dec (NonEmpty (unpack s))
nonEmptyId s =
  case unpack s of
    []        => No absurd
    (x :: xs) => Yes IsNonEmpty

||| Type-level evidence that a configuration has at least one field.
||| An A2MLConfig with zero fields is invalid — there's nothing to configure.
|||
||| This is expressed as a data type rather than a runtime assertion: the
||| proof must be constructed to use the configuration, and the empty case
||| is statically impossible.
public export
data ConfigHasFields : List ConfigField -> Type where
  ||| A list with at least one element satisfies the constraint.
  HasFields : ConfigHasFields (f :: fs)

||| Uninhabited instance: the empty field list never has fields.
public export
Uninhabited (ConfigHasFields []) where
  uninhabited HasFields impossible

||| Decide whether a field list is non-empty.
|||
||| @param fields The list of configuration fields
||| @return Yes (proof of non-emptiness) or No (proof it's empty)
public export
configFieldCountPositive : (fields : List ConfigField) -> Dec (ConfigHasFields fields)
configFieldCountPositive []        = No absurd
configFieldCountPositive (f :: fs) = Yes HasFields

||| A validated A2MLConfig: pairs the raw config with a proof that
||| it has at least one field. Functions that require valid configs
||| should take this type rather than raw A2MLConfig.
public export
record ValidConfig where
  constructor MkValidConfig
  ||| The underlying configuration data
  config    : A2MLConfig
  ||| Proof that the configuration has at least one field
  0 hasFields : ConfigHasFields (config.fields)

||| Attempt to validate an A2MLConfig, returning a ValidConfig if the
||| field list is non-empty, or Nothing if it has zero fields.
public export
validateConfig : (cfg : A2MLConfig) -> Maybe ValidConfig
validateConfig cfg =
  case configFieldCountPositive cfg.fields of
    Yes prf => Just (MkValidConfig cfg prf)
    No _    => Nothing

||| A validated port number: pairs a Nat with proof it's in range.
||| Functions that accept ports should take this type to prevent
||| invalid ports from ever reaching the FFI boundary.
public export
record ValidPort where
  constructor MkValidPort
  ||| The port number
  port     : Nat
  ||| Proof that port is in [1, 65535]
  0 inRange : (LTE 1 port, LTE port 65535)

||| Attempt to validate a port number, returning a ValidPort if in range.
public export
validatePort : (p : Nat) -> Maybe ValidPort
validatePort p =
  case portInRange p of
    Yes prf => Just (MkValidPort p prf)
    No _    => Nothing

||| A validated server identifier: pairs a String with proof it's non-empty.
public export
record ValidId where
  constructor MkValidId
  ||| The identifier string
  idStr    : String
  ||| Proof that the identifier is non-empty
  0 nonEmpty : NonEmpty (unpack idStr)

||| Attempt to validate a server identifier.
public export
validateId : (s : String) -> Maybe ValidId
validateId s =
  case nonEmptyId s of
    Yes prf => Just (MkValidId s prf)
    No _    => Nothing

--------------------------------------------------------------------------------
-- Compound Proofs
--------------------------------------------------------------------------------

||| Proof that all ports in a game profile are valid.
||| This is checked recursively over the port list.
public export
data AllPortsValid : List (String, Nat) -> Type where
  ||| The empty port list is vacuously valid
  NoPorts : AllPortsValid []
  ||| A non-empty port list is valid if the head port is in range
  ||| and all remaining ports are valid
  ConsPort : (LTE 1 p, LTE p 65535) -> AllPortsValid rest -> AllPortsValid ((name, p) :: rest)

||| Decide whether all ports in a list are valid.
public export
allPortsValid : (ports : List (String, Nat)) -> Dec (AllPortsValid ports)
allPortsValid [] = Yes NoPorts
allPortsValid ((name, p) :: rest) =
  case portInRange p of
    Yes prf =>
      case allPortsValid rest of
        Yes restPrf => Yes (ConsPort prf restPrf)
        No contra   => No (\case (ConsPort _ r) => contra r)
    No contra =>
      No (\case (ConsPort prf _) => contra prf)

||| A fully validated GameProfile: all ports in range, ID non-empty,
||| and at least one field definition present.
public export
record ValidGameProfile where
  constructor MkValidGameProfile
  ||| The underlying game profile
  profile        : GameProfile
  ||| Proof that the profile ID is non-empty
  0 validId      : NonEmpty (unpack (profile.id))
  ||| Proof that all declared ports are in valid range
  0 validPorts   : AllPortsValid (profile.ports)
  ||| Proof that there is at least one field definition
  0 hasFieldDefs : ConfigHasFields (profile.fieldDefs)

||| Attempt to validate a GameProfile, checking all constraints.
public export
validateGameProfile : (gp : GameProfile) -> Maybe ValidGameProfile
validateGameProfile gp =
  case nonEmptyId gp.id of
    No _ => Nothing
    Yes idPrf =>
      case allPortsValid gp.ports of
        No _ => Nothing
        Yes portsPrf =>
          case configFieldCountPositive gp.fieldDefs of
            No _ => Nothing
            Yes fieldsPrf => Just (MkValidGameProfile gp idPrf portsPrf fieldsPrf)

--------------------------------------------------------------------------------
-- Drift Score Proofs
--------------------------------------------------------------------------------

||| Proof that a Double is in the normalised range [0.0, 1.0].
||| Drift scores must be normalised; this type prevents out-of-range values.
public export
data Normalised : Double -> Type where
  IsNormalised : So (d >= 0.0 && d <= 1.0) -> Normalised d

||| Derive health status from an overall drift score.
||| Thresholds: [0, 0.25) Healthy, [0.25, 0.5) Warning,
||| [0.5, 0.75) Degraded, [0.75, 1.0] Critical.
public export
healthFromScore : Double -> HealthStatus
healthFromScore score =
  if score < 0.25 then Healthy
  else if score < 0.5 then Warning
  else if score < 0.75 then Degraded
  else Critical
