-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| GSA.ABI.Foreign — FFI declarations for Game Server Admin
|||
||| Declares all C ABI function signatures that map to Zig implementations
||| in src/interface/ffi/src/. Functions use "C:gossamer_gsa_*" foreign pragmas,
||| linking against libgsa (src/interface/ffi/build.zig).
|||
||| This module provides two layers:
|||   1. Primitive FFI declarations (prim__*) — raw C calls via PrimIO
|||   2. Typed wrappers — preserve handles on returned results and convert
|||      errors. Unimplemented or unscoped operations fail closed. This is not
|||      a proof of native behavior or exception-safe cleanup.
|||
||| Intended resource protocol (the current record does not enforce it globally):
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
import Responses

import Data.List
import Data.Maybe
import Data.So
import Data.String

%default total

||| First integer a successful probe returns as a linear handle id. Must equal
||| main.FIRST_HANDLE_ID on the Zig side (probe returns id >= this; error codes
||| are the GsaResult range 0-18, strictly below it). The gap is what lets a
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
||| code (0-18) on failure. Values are non-negative in both cases; classify by
||| magnitude, not sign.
|||
||| C signature: int32_t gossamer_gsa_probe(const char* host, int32_t port)
export
%foreign "C:gossamer_gsa_probe, libgsa"
prim__probe : String -> Int -> PrimIO Int

||| Fingerprint ports supplied as a JSON array. Returns borrowed JSON text;
||| the native parser and multi-result typed decoder are not yet qualified.
|||
||| C signature: const char* gossamer_gsa_fingerprint(const char* host, const char* ports_json)
export
%foreign "C:gossamer_gsa_fingerprint, libgsa"
prim__fingerprint : String -> String -> PrimIO String

||| Extract configuration from a managed server given its handle and
||| the game profile ID to use for parsing. Returns borrowed A2ML text or ERR,
||| NOT a binary A2MLConfig. Never pass this text to prim__free.
|||
||| C signature: const char* gossamer_gsa_extract_config(int32_t handle, const char* profile_id)
export
%foreign "C:gossamer_gsa_extract_config, libgsa"
prim__extractConfig : Int -> String -> PrimIO String

||| Legacy validation-only endpoint: checks a binary config and handle, but
||| DOES NOT write configuration. Do not interpret Ok as an applied change.
||| Returns 0 on validation success or a positive GsaResult error code.
|||
||| C signature: int32_t gossamer_gsa_apply_config(int32_t handle, void* config)
export
%foreign "C:gossamer_gsa_apply_config, libgsa"
prim__applyConfig : Int -> AnyPtr -> PrimIO Int

||| Send a named action to the server (e.g., "start", "stop", "restart",
||| "status", "backup"). Returns a JSON result string
||| ({"success":bool,"output":...,"exit_code":N}) — NOT an int code.
|||
||| C signature: const char* gossamer_gsa_server_action(int32_t handle, const char* action_json)
export
%foreign "C:gossamer_gsa_server_action, libgsa"
prim__serverAction : Int -> String -> PrimIO String

||| Retrieve the last N lines of the server's log output as plain,
||| newline-delimited text (NOT a serialised string-array struct).
|||
||| C signature: const char* gossamer_gsa_get_logs(int32_t handle, int32_t line_count)
export
%foreign "C:gossamer_gsa_get_logs, libgsa"
prim__getLogs : Int -> Int -> PrimIO String

||| Store JSON in VeriSimDB. Returns 0 on success or a positive error code.
||| The native function does not return the assigned document ID.
|||
||| C signature: int32_t gossamer_gsa_verisimdb_store(const char* octad_json)
export
%foreign "C:gossamer_gsa_verisimdb_store, libgsa"
prim__verisimdbStore : String -> PrimIO Int

||| Execute a VQL (VeriSimDB Query Language) query string.
||| Returns borrowed JSON text, or ERR on error. Never free it.
|||
||| C signature: const char* gossamer_gsa_verisimdb_query(const char* vql)
export
%foreign "C:gossamer_gsa_verisimdb_query, libgsa"
prim__verisimdbQuery : String -> PrimIO String

||| Check VeriSimDB reachability. Returns 0 or a positive GsaResult error,
||| NOT a HealthStatus code or evidence of completed storage/scoring.
|||
||| C signature: int32_t gossamer_gsa_verisimdb_health()
export
%foreign "C:gossamer_gsa_verisimdb_health, libgsa"
prim__verisimdbHealth : PrimIO Int

||| Get borrowed drift JSON for a server, or ERR. For the allocated binary
||| report use prim__driftStruct instead. Never free this JSON text.
|||
||| C signature: const char* gossamer_gsa_verisimdb_drift(const char* server_id)
export
%foreign "C:gossamer_gsa_verisimdb_drift, libgsa"
prim__verisimdbDrift : String -> PrimIO String

||| Load .a2ml profiles from a directory. Counts overlap positive error codes;
||| read prim__lastError immediately on the same thread to distinguish them.
|||
||| C signature: int32_t gossamer_gsa_load_profiles(const char* dir_path)
export
%foreign "C:gossamer_gsa_load_profiles, libgsa"
prim__loadProfiles : String -> PrimIO Int

||| Register a single game profile supplied as A2ML text, not a struct or path.
||| Returns 0 on success or a positive error code.
|||
||| C signature: int32_t gossamer_gsa_add_profile(const char* a2ml)
export
%foreign "C:gossamer_gsa_add_profile, libgsa"
prim__addProfile : String -> PrimIO Int

||| Borrowed thread-local error text. Read immediately after the operation;
||| another native operation on that thread can overwrite/clear it.
export
%foreign "C:gossamer_gsa_last_error, libgsa"
prim__lastError : PrimIO String

||| Close and release a server handle, freeing all associated resources.
||| After this call the handle integer is invalid and must not be reused.
||| Returns 0 on success or a positive error code.
|||
||| C signature: int32_t gossamer_gsa_close_handle(int32_t handle)
export
%foreign "C:gossamer_gsa_close_handle, libgsa"
prim__closeHandle : Int -> PrimIO Int

||| Read a C string from a pointer. Used to deserialise string results
||| returned by the Zig FFI layer.
|||
||| C signature: const char* (standard C string access)
export
%foreign "C:gossamer_gsa_read_string, libgsa"
prim__readString : AnyPtr -> PrimIO String

||| Free a pointer allocated by the Zig FFI layer.
||| Only free owned emitter allocations (such as prim__driftStruct), once.
||| Never free borrowed text, pointer fields returned by prim__readPtr, or
||| interior pointers into another allocation.
|||
||| C signature: void gossamer_gsa_free(void* ptr)
export
%foreign "C:gossamer_gsa_free, libgsa"
prim__free : AnyPtr -> PrimIO ()

||| Read an integer field from a serialised struct at a byte offset.
||| Used to extract individual fields from opaque result pointers.
|||
||| C signature: int32_t gossamer_gsa_read_int(void* ptr, int32_t offset)
export
%foreign "C:gossamer_gsa_read_int, libgsa"
prim__readInt : AnyPtr -> Int -> PrimIO Int

||| Read a double field from a serialised struct at a byte offset.
|||
||| C signature: double gossamer_gsa_read_double(void* ptr, int32_t offset)
export
%foreign "C:gossamer_gsa_read_double, libgsa"
prim__readDouble : AnyPtr -> Int -> PrimIO Double

||| Get the number of elements in a serialised array/list result.
|||
||| C signature: int32_t gossamer_gsa_array_len(void* ptr)
export
%foreign "C:gossamer_gsa_array_len, libgsa"
prim__arrayLen : AnyPtr -> PrimIO Int

||| Read the i-th string element from a serialised string array.
|||
||| C signature: const char* gossamer_gsa_array_get_string(void* ptr, int32_t index)
export
%foreign "C:gossamer_gsa_array_get_string, libgsa"
prim__arrayGetString : AnyPtr -> Int -> PrimIO String

||| Read a pointer field at a byte offset from a serialised struct. Combined
||| with prim__readString this decodes char* fields at their proven offsets:
||| readString (readPtr struct (offsetOf "serverId" layout)).
|||
||| C signature: void* gossamer_gsa_read_ptr(void* ptr, int32_t offset)
export
%foreign "C:gossamer_gsa_read_ptr, libgsa"
prim__readPtr : AnyPtr -> Int -> PrimIO AnyPtr

||| Emit a binary DriftReport wire struct (canonical Layout.idr layout) for a
||| tracked server. The returned pointer must be released with prim__free.
|||
||| C signature: void* gossamer_gsa_drift_struct(const char* server_id)
export
%foreign "C:gossamer_gsa_drift_struct, libgsa"
prim__driftStruct : String -> PrimIO AnyPtr

--------------------------------------------------------------------------------
-- Internal Helpers
-- Utility functions used by the safe wrappers to convert between C
-- representations and Idris2 types.
--------------------------------------------------------------------------------

||| Interpret a raw FFI integer result under the Zig calling convention:
||| the code is `resultToInt Ok` (0) on success, or a positive GsaResult code
||| (1-18) on failure. Status-code endpoints use this positive convention;
||| JSON/text/count endpoints must be decoded using their own contracts.
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
%foreign "C:gossamer_gsa_is_null, libgsa"
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
-- These functions express the intended ServerHandle protocol:
-- probe PRODUCES, operations BORROW, closeHandle CONSUMES.
--------------------------------------------------------------------------------

||| Probe a game server at the given host and port.
||| On success, PRODUCES a linear ServerHandle that the caller must eventually
||| consume by calling closeHandle. On failure, returns a Result error code.
|||
||| The returned handle encodes integer positivity (So (rawPtr > 0)), not a
||| pointer proof or a global uniqueness/authority guarantee.
|||
||| @param host Hostname or IP address to probe
||| @param port Port number to probe (checked before narrowing to the C ABI)
||| @return Left Result on failure, Right ServerHandle on success
export
covering
probe : String -> Nat -> IO (Either Result ServerHandle)
probe host port = do
  if port == 0 || port > 65535 || host == "" || elem '\0' (unpack host)
    then pure (Left InvalidParam)
    else do
      result <- primIO (prim__probe host (cast port))
      if result >= firstHandleId
        then case choose (result > 0) of
               Left prf => pure (Right (MkServerHandle result (host ++ ":" ++ show port) prf))
               Right _ => pure (Left Error)
        else pure (Left (if result == 0 then ProtocolError else resultOf result))

||| Fingerprint a server by probing multiple ports.
||| This is a pure query operation — no linear handle is produced or consumed.
||| The result contains the response signature and latency data needed to
||| identify the game server software.
|||
||| @param host Hostname or IP address to fingerprint
||| @param ports List of port numbers to probe
||| @return Left Result on failure, Right Fingerprint on success
||| Currently UnsupportedOperation: the native multi-port result does not
||| provide the signature required by this record. Do not invent it.
export
covering
fingerprint : String -> List Nat -> IO (Either Result Fingerprint)
fingerprint _ _ = pure (Left UnsupportedOperation)

||| Extract configuration from a server, BORROWING the handle.
||| The handle is returned alongside the result so the caller retains
||| its fields. See Types.ServerHandle for the current uniqueness-proof limits.
|||
||| @param handle Linear server handle (borrowed, returned in result)
||| @param profile Game profile defining how to parse the configuration
||| @return (Either error config, handle) — handle always returned
||| Currently UnsupportedOperation: native target binding and an A2ML decoder
||| are missing. The primitive returns text, not a binary config structure.
export
covering
extractConfig : (1 handle : ServerHandle) -> GameProfile -> IO (Either Result A2MLConfig, ServerHandle)
extractConfig (MkServerHandle p sid v) _ =
  pure (Left UnsupportedOperation, MkServerHandle p sid v)

||| Apply a modified configuration to the server, BORROWING the handle.
||| Currently UnsupportedOperation: there is no typed serializer/write/read-back
||| path. The native apply_config endpoint validates only; it does not write.
|||
||| @param handle Linear server handle (borrowed, returned in result)
||| @param config The configuration to apply
||| @return (Either error unit, handle) — handle always returned
export
covering
applyConfig : (1 handle : ServerHandle) -> A2MLConfig -> IO (Either Result (), ServerHandle)
applyConfig (MkServerHandle p sid v) _ =
  pure (Left UnsupportedOperation, MkServerHandle p sid v)

||| Send a named action to the server (start, stop, restart, status, etc.),
||| BORROWING the handle. Currently UnsupportedOperation: the native JSON
||| dispatcher ignores the handle and accepts an independent target. A named
||| action must not be forwarded until target/authority binding is implemented.
|||
||| @param handle Linear server handle (borrowed, returned in result)
||| @param action Action identifier string (e.g., "start", "stop")
||| @return (Either error response_string, handle) — handle always returned
export
covering
serverAction : (1 handle : ServerHandle) -> String -> IO (Either Result String, ServerHandle)
serverAction (MkServerHandle p sid v) _ =
  pure (Left UnsupportedOperation, MkServerHandle p sid v)

||| Retrieve the last N lines of server log output, BORROWING the handle.
||| Currently UnsupportedOperation: the native implementation selects the
||| first tracked server instead of resolving the supplied handle. Its text
||| is borrowed and must never be interpreted/freed as a string-array struct.
|||
||| @param handle Linear server handle (borrowed, returned in result)
||| @param lineCount Number of log lines to retrieve
||| @return (Either error log_lines, handle) — handle always returned
export
covering
getLogs : (1 handle : ServerHandle) -> Nat -> IO (Either Result (List String), ServerHandle)
getLogs (MkServerHandle p sid v) _ =
  pure (Left UnsupportedOperation, MkServerHandle p sid v)

||| Close and release a server handle, CONSUMING it.
||| On native success the registry entry is closed. Native checks must reject
||| subsequent use: the public record currently permits forged/copied IDs.
|||
||| @param handle Linear server handle (consumed — caller loses access)
||| @return Result code indicating success or failure of cleanup
export
covering
closeHandle : (1 handle : ServerHandle) -> IO Result
closeHandle (MkServerHandle p _ _) = do
  result <- primIO (prim__closeHandle p)
  pure (fromMaybe Error (resultFromInt result))

--------------------------------------------------------------------------------
-- Safe Wrappers: VeriSimDB Operations
-- These are stateless operations that do not involve linear handles.
-- They communicate with the VeriSimDB instance via the Zig FFI layer.
--------------------------------------------------------------------------------

||| Store a ServerOctad in VeriSimDB.
||| Currently UnsupportedOperation: typed serialization and an assigned-ID
||| response are absent. A health check cannot establish that storage occurred.
|||
||| @param octad The server octad to store
||| @return Left Result on failure, Right document_id on success
export
covering
storeOctad : ServerOctad -> IO (Either Result String)
storeOctad _ = pure (Left UnsupportedOperation)

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
  if vql == "" || elem '\0' (unpack vql)
    then pure (Left InvalidParam)
    else do
      result <- primIO (prim__verisimdbQuery vql)
      err <- primIO prim__lastError
      -- The Idris FFI copies the returned C string. It is not an allocated
      -- wire struct and must not be passed to prim__free.
      pure (if result == "ERR" || err /= ""
              then Left Error
              else Right result)

||| Check the health of the VeriSimDB instance.
||| Returns the current HealthStatus or an error if the instance
||| is completely unreachable.
|||
||| @return Left Result on failure, Right HealthStatus on success
export
covering
checkHealth : IO (Either Result HealthStatus)
checkHealth = do
  -- Preserve the native error, including NotInitialized. Healthy here means
  -- reachable, not that storage or scoring has been verified.
  result <- primIO prim__verisimdbHealth
  if result == resultToInt Ok
    then pure (Right Healthy)
    else pure (Left (resultOf result))

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
||| Each .a2ml file in the directory is parsed and registered.
||| Returns the count of successfully loaded profiles on success.
|||
||| @param dirPath Absolute path to the profiles directory
||| @return Left Result on failure, Right loaded_count on success
export
covering
loadProfiles : String -> IO (Either Result Nat)
loadProfiles dirPath = do
  if dirPath == "" || elem '\0' (unpack dirPath)
    then pure (Left InvalidParam)
    else do
      result <- primIO (prim__loadProfiles dirPath)
      err <- primIO prim__lastError
      pure (decodeProfileCount result err)

||| Register a single game profile at runtime.
||| Currently UnsupportedOperation: there is no typed A2ML serializer. Loading
||| a directory named after the ID does not register the supplied profile.
|||
||| @param profile The game profile to register
||| @return Left Result on failure, Right () on success
export
covering
addProfile : GameProfile -> IO (Either Result ())
addProfile _ = pure (Left UnsupportedOperation)

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
||| cleanup explicit on returned success/error paths. It does not establish
||| cleanup on exceptions, cancellation or process termination.
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
