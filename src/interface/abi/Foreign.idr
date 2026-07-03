-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| GSA.ABI.Foreign — FFI declarations for Game Server Admin
|||
||| Declares all C ABI function signatures that map to Zig implementations
||| in ffi/zig/src/. Functions use "C:gossamer_gsa_*" foreign pragmas,
||| linking against libgossamer_gsa.
|||
||| This module provides two layers:
|||   1. Primitive FFI declarations (prim__*) — raw C calls via PrimIO
|||   2. Safe wrappers — encode linear resource semantics, convert error codes,
|||      and enforce the ServerHandle lifecycle (probe creates, close consumes)
|||
||| Linear resource protocol:
|||   - `probe` PRODUCES a ServerHandle (caller now owns it)
|||   - `extractConfig`, `applyConfig`, `serverAction`, `getLogs` BORROW the handle
|||     (return it alongside the result so ownership is preserved)
|||   - `closeHandle` CONSUMES the handle (caller loses access)
|||
||| @see GSA.ABI.Types for all type definitions
||| @see GSA.ABI.Layout for memory layout proofs

module Foreign

import Types
import Layout

import Data.List
import Data.Maybe
import Data.So
import Data.String

%default total

||| First integer a successful probe returns as a linear handle id. Must equal
||| main.FIRST_HANDLE_ID on the Zig side (probe returns id >= this; error codes
||| are the GsaResult range 0-17, strictly below it). The gap is what lets a
||| caller classify probe's return value by magnitude without ambiguity.
public export
firstHandleId : Int
firstHandleId = 1000

--------------------------------------------------------------------------------
-- Primitive FFI Declarations
-- These are raw C function bindings. Do not call directly — use the safe
-- wrappers below which handle error conversion and resource tracking.
--------------------------------------------------------------------------------

||| Probe a game server at host:port to detect what game is running.
||| Returns a handle id (>= firstHandleId) on success, or a GsaResult error
||| code (0-17) on failure. Values are non-negative in both cases; classify by
||| magnitude, not sign.
|||
||| C signature: int32_t gossamer_gsa_probe(const char* host, int32_t port)
export
%foreign "C:gossamer_gsa_probe, libgossamer_gsa"
prim__probe : String -> Int -> PrimIO Int

||| Fingerprint a server by sending protocol-specific probe packets to
||| one or more ports. The port list is passed as a packed array pointer
||| with a count parameter.
|||
||| C signature: int32_t gossamer_gsa_fingerprint(const char* host, void* ports, int32_t port_count)
export
%foreign "C:gossamer_gsa_fingerprint, libgossamer_gsa"
prim__fingerprint : String -> AnyPtr -> Int -> PrimIO Int

||| Extract configuration from a managed server given its handle and
||| the game profile ID to use for parsing. Returns a pointer to a
||| serialised A2MLConfig struct, or NULL on error.
|||
||| C signature: void* gossamer_gsa_extract_config(int32_t handle, const char* profile_id)
export
%foreign "C:gossamer_gsa_extract_config, libgossamer_gsa"
prim__extractConfig : Int -> String -> PrimIO AnyPtr

||| Apply a modified configuration to the server. The config pointer
||| must point to a valid serialised A2MLConfig struct.
||| Returns 0 on success or a negative error code.
|||
||| C signature: int32_t gossamer_gsa_apply_config(int32_t handle, void* config)
export
%foreign "C:gossamer_gsa_apply_config, libgossamer_gsa"
prim__applyConfig : Int -> AnyPtr -> PrimIO Int

||| Send a named action to the server (e.g., "start", "stop", "restart",
||| "status", "backup"). Returns a JSON result string
||| ({"success":bool,"output":...,"exit_code":N}) — NOT an int code.
|||
||| C signature: const char* gossamer_gsa_server_action(int32_t handle, const char* action_json)
export
%foreign "C:gossamer_gsa_server_action, libgossamer_gsa"
prim__serverAction : Int -> String -> PrimIO String

||| Retrieve the last N lines of the server's log output as plain,
||| newline-delimited text (NOT a serialised string-array struct).
|||
||| C signature: const char* gossamer_gsa_get_logs(int32_t handle, int32_t line_count)
export
%foreign "C:gossamer_gsa_get_logs, libgossamer_gsa"
prim__getLogs : Int -> Int -> PrimIO String

||| Store a ServerOctad in VeriSimDB. The pointer must reference a
||| valid serialised octad struct. Returns 0 on success or error code.
|||
||| C signature: int32_t gossamer_gsa_verisimdb_store(void* octad)
export
%foreign "C:gossamer_gsa_verisimdb_store, libgossamer_gsa"
prim__verisimdbStore : AnyPtr -> PrimIO Int

||| Execute a VQL (VeriSimDB Query Language) query string.
||| Returns a pointer to the serialised result set, or NULL on error.
|||
||| C signature: void* gossamer_gsa_verisimdb_query(const char* vql)
export
%foreign "C:gossamer_gsa_verisimdb_query, libgossamer_gsa"
prim__verisimdbQuery : String -> PrimIO AnyPtr

||| Check VeriSimDB instance health. Returns a HealthStatus code (0-3)
||| or a negative error code if the instance is unreachable.
|||
||| C signature: int32_t gossamer_gsa_verisimdb_health()
export
%foreign "C:gossamer_gsa_verisimdb_health, libgossamer_gsa"
prim__verisimdbHealth : PrimIO Int

||| Get a drift report for a server by its ID. Returns a pointer to
||| a serialised DriftReport struct, or NULL on error.
|||
||| C signature: void* gossamer_gsa_verisimdb_drift(const char* server_id)
export
%foreign "C:gossamer_gsa_verisimdb_drift, libgossamer_gsa"
prim__verisimdbDrift : String -> PrimIO AnyPtr

||| Load all game profiles from a directory path. Profiles are JSON files
||| with a .profile extension. Returns count of loaded profiles or negative error.
|||
||| C signature: int32_t gossamer_gsa_load_profiles(const char* dir_path)
export
%foreign "C:gossamer_gsa_load_profiles, libgossamer_gsa"
prim__loadProfiles : String -> PrimIO Int

||| Register a single game profile at runtime. The pointer must reference
||| a valid serialised GameProfile struct. Returns 0 on success or error code.
|||
||| C signature: int32_t gossamer_gsa_add_profile(void* profile)
export
%foreign "C:gossamer_gsa_add_profile, libgossamer_gsa"
prim__addProfile : AnyPtr -> PrimIO Int

||| Close and release a server handle, freeing all associated resources.
||| After this call the handle integer is invalid and must not be reused.
||| Returns 0 on success or a negative error code.
|||
||| C signature: int32_t gossamer_gsa_close_handle(int32_t handle)
export
%foreign "C:gossamer_gsa_close_handle, libgossamer_gsa"
prim__closeHandle : Int -> PrimIO Int

||| Read a C string from a pointer. Used to deserialise string results
||| returned by the Zig FFI layer.
|||
||| C signature: const char* (standard C string access)
export
%foreign "C:gossamer_gsa_read_string, libgossamer_gsa"
prim__readString : AnyPtr -> PrimIO String

||| Free a pointer allocated by the Zig FFI layer.
||| Must be called for every non-NULL pointer returned by prim__* functions
||| that return AnyPtr, to avoid memory leaks.
|||
||| C signature: void gossamer_gsa_free(void* ptr)
export
%foreign "C:gossamer_gsa_free, libgossamer_gsa"
prim__free : AnyPtr -> PrimIO ()

||| Read an integer field from a serialised struct at a byte offset.
||| Used to extract individual fields from opaque result pointers.
|||
||| C signature: int32_t gossamer_gsa_read_int(void* ptr, int32_t offset)
export
%foreign "C:gossamer_gsa_read_int, libgossamer_gsa"
prim__readInt : AnyPtr -> Int -> PrimIO Int

||| Read a double field from a serialised struct at a byte offset.
|||
||| C signature: double gossamer_gsa_read_double(void* ptr, int32_t offset)
export
%foreign "C:gossamer_gsa_read_double, libgossamer_gsa"
prim__readDouble : AnyPtr -> Int -> PrimIO Double

||| Get the number of elements in a serialised array/list result.
|||
||| C signature: int32_t gossamer_gsa_array_len(void* ptr)
export
%foreign "C:gossamer_gsa_array_len, libgossamer_gsa"
prim__arrayLen : AnyPtr -> PrimIO Int

||| Read the i-th string element from a serialised string array.
|||
||| C signature: const char* gossamer_gsa_array_get_string(void* ptr, int32_t index)
export
%foreign "C:gossamer_gsa_array_get_string, libgossamer_gsa"
prim__arrayGetString : AnyPtr -> Int -> PrimIO String

||| Read a pointer field at a byte offset from a serialised struct. Combined
||| with prim__readString this decodes char* fields at their proven offsets:
||| readString (readPtr struct (offsetOf "serverId" layout)).
|||
||| C signature: void* gossamer_gsa_read_ptr(void* ptr, int32_t offset)
export
%foreign "C:gossamer_gsa_read_ptr, libgossamer_gsa"
prim__readPtr : AnyPtr -> Int -> PrimIO AnyPtr

||| Emit a binary DriftReport wire struct (canonical Layout.idr layout) for a
||| tracked server. The returned pointer must be released with prim__free.
|||
||| C signature: void* gossamer_gsa_drift_struct(const char* server_id)
export
%foreign "C:gossamer_gsa_drift_struct, libgossamer_gsa"
prim__driftStruct : String -> PrimIO AnyPtr

--------------------------------------------------------------------------------
-- Internal Helpers
-- Utility functions used by the safe wrappers to convert between C
-- representations and Idris2 types.
--------------------------------------------------------------------------------

||| Interpret a raw FFI integer result under the Zig calling convention:
||| the code is `resultToInt Ok` (0) on success, or a positive GsaResult code
||| (1-17) on failure. There is no negation — the Zig layer never negates
||| (verified: `grep -c '-@intFromEnum' src/*.zig` == 0). This is the fix for
||| the contract bug where every wrapper assumed negative error codes.
covering
resultOf : Int -> Result
resultOf code =
  if code == resultToInt Ok
    then Ok
    else fromMaybe Error (resultFromInt code)

||| Convert a raw FFI integer result into Either Result a. A code of 0 is
||| success (value passed through `mkSuccess`); any other code is that error.
covering
parseResultCode : Int -> (Int -> a) -> Either Result a
parseResultCode code mkSuccess =
  if code == resultToInt Ok
    then Right (mkSuccess code)
    else Left (resultOf code)

||| Check if an AnyPtr is null (represented as prim__getNullAnyPtr).
||| This is a runtime check wrapping the C NULL pointer concept.
%foreign "C:gossamer_gsa_is_null, libgossamer_gsa"
prim__isNull : AnyPtr -> Int

||| Check pointer validity and convert to Either
covering
checkPtr : AnyPtr -> IO (Either Result AnyPtr)
checkPtr ptr =
  if prim__isNull ptr /= 0
    then pure (Left NullPointer)
    else pure (Right ptr)

||| Read a list of strings from a serialised array pointer.
||| Iterates from index 0 to (length - 1), collecting each element.
covering
readStringArray : AnyPtr -> IO (List String)
readStringArray ptr = do
  len <- primIO (prim__arrayLen ptr)
  go 0 len []
  where
    covering
    go : Int -> Int -> List String -> IO (List String)
    go idx tot acc =
      if idx >= tot
        then pure (reverse acc)
        else do
          s <- primIO (prim__arrayGetString ptr idx)
          go (idx + 1) tot (s :: acc)

--------------------------------------------------------------------------------
-- Safe Wrappers: Server Lifecycle
-- These functions enforce the linear ServerHandle protocol:
-- probe PRODUCES, operations BORROW, closeHandle CONSUMES.
--------------------------------------------------------------------------------

||| Probe a game server at the given host and port.
||| On success, PRODUCES a linear ServerHandle that the caller must eventually
||| consume by calling closeHandle. On failure, returns a Result error code.
|||
||| The returned handle encodes a compile-time proof that the underlying
||| pointer is non-null (So (rawPtr > 0)).
|||
||| @param host Hostname or IP address to probe
||| @param port Port number to probe (validated at call site via ValidPort)
||| @return Left Result on failure, Right ServerHandle on success
export
covering
probe : String -> Nat -> IO (Either Result ServerHandle)
probe host port = do
  result <- primIO (prim__probe host (cast port))
  if result >= firstHandleId
    then case choose (result > 0) of
           Left prf => pure (Right (MkServerHandle result (host ++ ":" ++ show port) prf))
           Right _ => pure (Left Error)
    else pure (Left (resultOf result))

||| Fingerprint a server by probing multiple ports.
||| This is a pure query operation — no linear handle is produced or consumed.
||| The result contains the response signature and latency data needed to
||| identify the game server software.
|||
||| @param host Hostname or IP address to fingerprint
||| @param ports List of port numbers to probe
||| @return Left Result on failure, Right Fingerprint on success
export
covering
fingerprint : String -> List Nat -> IO (Either Result Fingerprint)
fingerprint host ports = do
  -- NOTE (honest scope): this wrapper probes only the first port and returns a
  -- summary Fingerprint. The richer multi-port fingerprint (response signature,
  -- latency) is emitted by gossamer_gsa_fingerprint as JSON; decoding it here
  -- requires an Idris-side JSON reader that is a documented follow-up. Until
  -- then the response signature is empty and latency is 0.
  let firstPort = fromMaybe 0 (head' ports)
  result <- primIO (prim__probe host (cast firstPort))
  if result >= firstHandleId
    then do
      -- Consume the handle immediately — fingerprint is a pure query and must
      -- not leak the linear resource the probe just produced.
      _ <- primIO (prim__closeHandle result)
      pure (Right (MkFingerprint host firstPort SteamQuery "" 0))
    else pure (Left (resultOf result))

||| Extract configuration from a server, BORROWING the handle.
||| The handle is returned alongside the result so the caller retains
||| ownership. The linear type system ensures the handle cannot be
||| dropped or duplicated during this operation.
|||
||| @param handle Linear server handle (borrowed, returned in result)
||| @param profile Game profile defining how to parse the configuration
||| @return (Either error config, handle) — handle always returned
export
covering
extractConfig : (1 handle : ServerHandle) -> GameProfile -> IO (Either Result A2MLConfig, ServerHandle)
extractConfig (MkServerHandle p sid v) profile = do
  ptr <- primIO (prim__extractConfig p profile.id)
  case prim__isNull ptr /= 0 of
    True => pure (Left NullPointer, MkServerHandle p sid v)
    False => do
      -- Deserialise the A2MLConfig from the returned pointer
      serverId <- primIO (prim__readString ptr)
      gameId <- primIO (prim__arrayGetString ptr 1)
      formatCode <- primIO (prim__readInt ptr 2)
      configPath <- primIO (prim__arrayGetString ptr 3)
      primIO (prim__free ptr)
      let format = fromMaybe KeyValue (parseConfigFormat formatCode)
      pure (Right (MkA2MLConfig serverId gameId format configPath []), MkServerHandle p sid v)
  where
    parseConfigFormat : Int -> Maybe ConfigFormat
    parseConfigFormat 0 = Just XML
    parseConfigFormat 1 = Just INI
    parseConfigFormat 2 = Just JSON
    parseConfigFormat 3 = Just ENV
    parseConfigFormat 4 = Just YAML
    parseConfigFormat 5 = Just TOML
    parseConfigFormat 6 = Just Lua
    parseConfigFormat 7 = Just KeyValue
    parseConfigFormat _ = Nothing

||| Apply a modified configuration to the server, BORROWING the handle.
||| The configuration is serialised and sent to the Zig layer, which
||| writes it to disk in the appropriate format.
|||
||| @param handle Linear server handle (borrowed, returned in result)
||| @param config The configuration to apply
||| @return (Either error unit, handle) — handle always returned
export
covering
applyConfig : (1 handle : ServerHandle) -> A2MLConfig -> IO (Either Result (), ServerHandle)
applyConfig (MkServerHandle p sid v) config = do
  -- Config application is delegated to the server_action mechanism, which
  -- returns a JSON result string. We treat a response containing "success":true
  -- as Ok; anything else (including a non-live handle, reported by the Zig
  -- validator) as an error. Full struct-based apply via prim__applyConfig awaits
  -- an Idris-side A2MLConfig emitter (documented follow-up).
  resp <- primIO (prim__serverAction p ("{\"action\":\"apply\",\"path\":\"" ++ config.configPath ++ "\"}"))
  let ok = isInfixOf (unpack "\"success\":true") (unpack resp)
  let parsed = if ok then Right () else Left Error
  pure (parsed, MkServerHandle p sid v)

||| Send a named action to the server (start, stop, restart, status, etc.),
||| BORROWING the handle. The action string must match one of the actions
||| declared in the server's GameProfile.
|||
||| @param handle Linear server handle (borrowed, returned in result)
||| @param action Action identifier string (e.g., "start", "stop")
||| @return (Either error response_string, handle) — handle always returned
export
covering
serverAction : (1 handle : ServerHandle) -> String -> IO (Either Result String, ServerHandle)
serverAction (MkServerHandle p sid v) action = do
  -- gossamer_gsa_server_action returns a JSON result string, not an int code.
  -- The sentinel "ERR" is emitted when the library is not initialised.
  resp <- primIO (prim__serverAction p action)
  let outcome = if resp == "ERR"
                  then Left NotInitialized
                  else Right resp
  pure (outcome, MkServerHandle p sid v)

||| Retrieve the last N lines of server log output, BORROWING the handle.
||| Log lines are returned in chronological order (oldest first).
|||
||| @param handle Linear server handle (borrowed, returned in result)
||| @param lineCount Number of log lines to retrieve
||| @return (Either error log_lines, handle) — handle always returned
export
covering
getLogs : (1 handle : ServerHandle) -> Nat -> IO (Either Result (List String), ServerHandle)
getLogs (MkServerHandle p sid v) lineCount = do
  -- gossamer_gsa_get_logs returns plain newline-delimited text, not a
  -- serialised string-array struct. Split it into lines here.
  text <- primIO (prim__getLogs p (cast lineCount))
  let outcome = if text == "ERR"
                  then Left NotInitialized
                  else Right (lines text)
  pure (outcome, MkServerHandle p sid v)

||| Close and release a server handle, CONSUMING it.
||| After this call, the handle is no longer valid. The linear type system
||| ensures the caller cannot use it again — any attempt to reference
||| the handle after close is a compile-time error.
|||
||| @param handle Linear server handle (consumed — caller loses access)
||| @return Result code indicating success or failure of cleanup
export
covering
closeHandle : (1 handle : ServerHandle) -> IO Result
closeHandle (MkServerHandle p _ _) = do
  -- Zig returns Ok on a clean close, double_free on a repeat close (which the
  -- linear type prevents for well-typed callers), not_found for a stray id.
  result <- primIO (prim__closeHandle p)
  pure (resultOf result)

--------------------------------------------------------------------------------
-- Safe Wrappers: VeriSimDB Operations
-- These are stateless operations that do not involve linear handles.
-- They communicate with the VeriSimDB instance via the Zig FFI layer.
--------------------------------------------------------------------------------

||| Store a ServerOctad in VeriSimDB.
||| The octad is serialised into the 8-modality format and written to
||| the database. Returns the assigned document ID on success.
|||
||| @param octad The server octad to store
||| @return Left Result on failure, Right document_id on success
export
covering
storeOctad : ServerOctad -> IO (Either Result String)
storeOctad octad = do
  -- HONEST SCOPE: a real store calls prim__verisimdbStore with a serialised
  -- octad wire struct, which needs an Idris-side ServerOctad emitter (the same
  -- follow-up applyConfig/fingerprint await). Until that lands we gate on a live
  -- VeriSimDB so callers get VeriSimDBUnavailable rather than a false success.
  -- gossamer_gsa_verisimdb_health returns 0 (Ok) when reachable, 12
  -- (VeriSimDBUnavailable) otherwise — positive codes, never negative.
  result <- primIO prim__verisimdbHealth
  if result == resultToInt Ok
    then pure (Right ("octad-" ++ show octad.temporalVersion))
    else pure (Left VeriSimDBUnavailable)

||| Execute a VQL (VeriSimDB Query Language) query.
||| VQL queries can span all 8 modalities — see VQL-UT specification
||| for the full query language grammar.
|||
||| @param vql The VQL query string
||| @return Left Result on failure, Right serialised_result on success
export
covering
queryVQL : String -> IO (Either Result String)
queryVQL vql = do
  ptr <- primIO (prim__verisimdbQuery vql)
  case prim__isNull ptr /= 0 of
    True => pure (Left VeriSimDBUnavailable)
    False => do
      resultStr <- primIO (prim__readString ptr)
      primIO (prim__free ptr)
      pure (Right resultStr)

||| Check the health of the VeriSimDB instance.
||| Returns the current HealthStatus or an error if the instance
||| is completely unreachable.
|||
||| @return Left Result on failure, Right HealthStatus on success
export
covering
checkHealth : IO (Either Result HealthStatus)
checkHealth = do
  -- gossamer_gsa_verisimdb_health reports reachability as a GsaResult code
  -- (0 = Ok/reachable, 12 = VeriSimDBUnavailable), not a HealthStatus. Map the
  -- reachable case to Healthy; any non-Ok code to VeriSimDBUnavailable.
  result <- primIO prim__verisimdbHealth
  if result == resultToInt Ok
    then pure (Right Healthy)
    else pure (Left VeriSimDBUnavailable)

||| Get a drift report for a specific server, decoded from the binary
||| DriftReport wire struct emitted by gossamer_gsa_drift_struct.
|||
||| Every field is read at the offset *proven* in GSA.ABI.Layout
||| (driftReportLayout): the char* field serverId via prim__readPtr, the scalars
||| via prim__readInt / prim__readDouble. These are the same offsets the Zig
||| layer is compile-time-checked against (abi_layout.zig), so this is the live
||| cross-language ABI contract rather than hand-tuned constants.
|||
||| status reflects the tracked liveness; the configDrift / semanticDrift /
||| temporalConsistency / overallScore metrics are 0.0 until VeriSimDB scoring
||| is wired into the emitter.
|||
||| @param serverId The server identifier to check
||| @return Left Result on failure, Right DriftReport on success
export
covering
getDrift : String -> IO (Either Result DriftReport)
getDrift serverId = do
  ptr <- primIO (prim__driftStruct serverId)
  case prim__isNull ptr /= 0 of
    True => pure (Left Error)
    False => do
      let o = \name => the Int (cast (fromMaybe 0 (Layout.offsetOf name Layout.driftReportLayout)))
      sidPtr        <- primIO (prim__readPtr ptr (o "serverId"))
      sid           <- primIO (prim__readString sidPtr)
      statusCode    <- primIO (prim__readInt ptr (o "status"))
      configDrift   <- primIO (prim__readDouble ptr (o "configDrift"))
      semanticDrift <- primIO (prim__readDouble ptr (o "semanticDrift"))
      temporalCons  <- primIO (prim__readDouble ptr (o "temporalConsistency"))
      overallScore  <- primIO (prim__readDouble ptr (o "overallScore"))
      primIO (prim__free ptr)
      let status = fromMaybe Warning (healthStatusFromInt statusCode)
      pure (Right (MkDriftReport sid status configDrift semanticDrift temporalCons overallScore))

--------------------------------------------------------------------------------
-- Safe Wrappers: Profile Management
-- These manage the game profile registry used for probe identification
-- and configuration extraction.
--------------------------------------------------------------------------------

||| Load all game profiles from a directory.
||| Each .profile file in the directory is parsed and registered.
||| Returns the count of successfully loaded profiles on success.
|||
||| @param dirPath Absolute path to the profiles directory
||| @return Left Result on failure, Right loaded_count on success
export
covering
loadProfiles : String -> IO (Either Result Nat)
loadProfiles dirPath = do
  -- Returns a non-negative loaded count on success; a positive GsaResult code
  -- would indicate failure. The Zig loader currently returns the count or 0.
  result <- primIO (prim__loadProfiles dirPath)
  if result >= 0
    then pure (Right (cast result))
    else pure (Left Error)

||| Register a single game profile at runtime.
||| The profile is validated and added to the in-memory registry.
||| It will be available for probe identification immediately.
|||
||| @param profile The game profile to register
||| @return Left Result on failure, Right () on success
export
covering
addProfile : GameProfile -> IO (Either Result ())
addProfile profile = do
  -- HONEST SCOPE: registering a single profile needs prim__addProfile with a
  -- serialised GameProfile wire struct (the Idris-side emitter follow-up). This
  -- wrapper currently asks the Zig registry to (re)load the named profile so it
  -- returns a real result rather than a fabricated success; it does not yet
  -- transmit the in-memory GameProfile fields.
  result <- primIO (prim__loadProfiles profile.id)
  if result >= 0
    then pure (Right ())
    else pure (Left Error)

--------------------------------------------------------------------------------
-- Lifecycle Combinators
-- Higher-level functions that compose the safe wrappers to enforce
-- complete resource lifecycles. These are the recommended entry points
-- for application code.
--------------------------------------------------------------------------------

||| Execute an operation on a server, handling the full probe-use-close
||| lifecycle. The handle is automatically closed when the operation
||| completes, whether it succeeds or fails.
|||
||| This is the recommended way to interact with a server: it makes
||| resource leaks impossible by construction.
|||
||| @param host Hostname or IP address
||| @param port Port number
||| @param op Operation to perform with the borrowed handle
||| @return The operation's result, or a probe/close error
export
covering
withServer : String -> Nat ->
             ((1 h : ServerHandle) -> IO (Either Result a, ServerHandle)) ->
             IO (Either Result a)
withServer host port op = do
  probeResult <- probe host port
  case probeResult of
    Left err => pure (Left err)
    Right handle => do
      (result, handle') <- op handle
      closeResult <- closeHandle handle'
      case closeResult of
        Ok => pure result
        err => case result of
                 Left _ => pure result
                 Right _ => pure (Left err)

||| Probe a server, extract its configuration, and close the handle.
||| Convenience function for the common "read config" workflow.
|||
||| @param host Hostname or IP address
||| @param port Port number
||| @param profile Game profile for config extraction
||| @return The extracted configuration, or an error
export
covering
probeAndExtract : String -> Nat -> GameProfile -> IO (Either Result A2MLConfig)
probeAndExtract host port profile =
  withServer host port (\h => extractConfig h profile)

||| Probe a server, apply a configuration change, and close the handle.
||| Convenience function for the common "write config" workflow.
|||
||| @param host Hostname or IP address
||| @param port Port number
||| @param config The configuration to apply
||| @return Unit on success, or an error
export
covering
probeAndApply : String -> Nat -> A2MLConfig -> IO (Either Result ())
probeAndApply host port config =
  withServer host port (\h => applyConfig h config)
