-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

module AbiRuntimeTest

import Types
import Foreign
import Responses
import Data.So
import System

%default covering

%foreign "C:gossamer_gsa_init, libgsa"
prim__init : String -> String -> PrimIO Int

%foreign "C:gossamer_gsa_shutdown, libgsa"
prim__shutdown : PrimIO Int

expect : String -> Bool -> IO ()
expect label True = putStrLn ("PASS " ++ label)
expect label False = do
  putStrLn ("FAIL " ++ label)
  exitFailure

isError : Result -> Either Result a -> Bool
isError expected (Left actual) = expected == actual
isError _ (Right _) = False

profile : GameProfile
profile = MkGameProfile "abi-fixture" "Fixture" "none" [] SteamQuery ""
                        KeyValue "unused" [] []

config : A2MLConfig
config = MkA2MLConfig "fixture" "abi-fixture" KeyValue "unused" []

octad : ServerOctad
octad = MkServerOctad "" [] [] [] "fixture" 1 "" Nothing

-- This is intentionally a synthetic positive integer, NOT a real capability.
-- A public ServerHandle constructor proves positivity, not issuance or authority.
-- Unsupported wrappers must reject it without dispatch and return it unchanged.
testContainment : IO ()
testContainment = do
  let handle = MkServerHandle 1000 "fixture" Oh
  (extracted, h1) <- extractConfig handle profile
  expect "typed extraction rejects unsupported decoding" (isError UnsupportedOperation extracted)
  (applied, h2) <- applyConfig h1 config
  expect "typed apply cannot claim validation was a write" (isError UnsupportedOperation applied)
  (acted, h3) <- serverAction h2 "start"
  expect "typed action cannot dispatch against an unbound target" (isError UnsupportedOperation acted)
  (logs, h4) <- getLogs h3 10
  expect "typed logs cannot select an unrelated tracked server" (isError UnsupportedOperation logs)
  let MkServerHandle raw sid _ = h4
  expect "failed borrows preserve handle fields" (raw == 1000 && sid == "fixture")
  fp <- fingerprint "unused" [1]
  expect "no fabricated fingerprint" (isError UnsupportedOperation fp)
  stored <- storeOctad octad
  expect "no invented document ID" (isError UnsupportedOperation stored)
  added <- addProfile profile
  expect "no directory load masquerading as profile registration" (isError UnsupportedOperation added)

testPureResponses : IO ()
testPureResponses = do
  expect "thirteen profiles is a valid count" (decodeProfileCount 13 "" == Right 13)
  expect "error 13 is not thirteen profiles"
         (decodeProfileCount 13 "not initialized" == Left NotInitialized)
  expect "fifteen profiles is a valid count" (decodeProfileCount 15 "" == Right 15)
  expect "error 15 is not fifteen profiles"
         (decodeProfileCount 15 "not a directory" == Left IoError)
  expect "zero profiles is valid" (decodeProfileCount 0 "" == Right 0)
  expect "error plus zero fails closed" (decodeProfileCount 0 "failure" == Left ProtocolError)
  expect "negative count fails closed" (decodeProfileCount (-1) "" == Left ProtocolError)
  expect "unknown error fails closed" (decodeProfileCount 999 "failure" == Left Error)
  expect "unsupported status is stable and terminal"
         (resultToInt UnsupportedOperation == 18 && resultIsTerminal UnsupportedOperation)

testNative : String -> IO ()
testNative fixtures = do
  -- No initialization: these native calls must return without doing network I/O
  -- or spawning a subprocess. This exercises actual C symbol/signature loading.
  loaded <- loadProfiles fixtures
  expect "native uninitialized loader returns an error, not count 13"
         (loaded == Left NotInitialized)
  health <- checkHealth
  expect "native uninitialized health is not availability evidence"
         (isError NotInitialized health)
  query <- queryVQL "SELECT * FROM octads"
  expect "native query ERR is rejected without freeing static text" (isError Error query)
  queryAgain <- queryVQL "SELECT * FROM octads"
  expect "repeated static query result is safe" (isError Error queryAgain)
  extracted <- primIO (prim__extractConfig 1000 "abi-fixture")
  expect "extraction C ABI returns text" (extracted == "ERR")
  logs <- primIO (prim__getLogs 1000 10)
  expect "logs C ABI returns text" (logs == "ERR")
  action <- primIO (prim__serverAction 1000 "{}")
  expect "action C ABI returns text" (action == "ERR")
  drift <- primIO (prim__verisimdbDrift "fixture")
  expect "drift JSON C ABI returns text" (drift == "ERR")
  stored <- primIO (prim__verisimdbStore "{}")
  expect "store accepts JSON text and preserves native failure" (stored == 13)
  added <- primIO (prim__addProfile "@game-profile(id=\"fixture\"):")
  expect "add profile accepts A2ML text and preserves native failure" (added == 13)
  fingerprints <- primIO (prim__fingerprint "unused" "[]")
  expect "empty native fingerprint request returns JSON without probing" (fingerprints == "[]")
  zeroPort <- probe "unused" 0
  expect "zero port rejected before native dispatch" (isError InvalidParam zeroPort)
  largePort <- probe "unused" 65536
  expect "out-of-range port rejected before cast" (isError InvalidParam largePort)
  nulHost <- probe "host\0suffix" 1
  expect "embedded NUL hostname rejected" (isError InvalidParam nulHost)
  nulQuery <- queryVQL "SELECT\0ignored"
  expect "embedded NUL query rejected" (isError InvalidParam nulQuery)

  -- init only creates in-process state. No health/store/probe/action call is
  -- made while initialized. The only actual operation is fixture-file loading.
  initialized <- primIO (prim__init "http://127.0.0.1:1" fixtures)
  expect "real native library initializes" (initialized == 0)
  invalidDirectory <- loadProfiles (fixtures ++ "/fixture.a2ml")
  expect "native directory failure is not count 15" (invalidDirectory == Left IoError)
  valid <- loadProfiles fixtures
  expect "real profile fixture loads and clears previous native error" (valid == Right 1)
  stopped <- primIO prim__shutdown
  expect "real native state shuts down" (stopped == 0)
  afterShutdown <- loadProfiles fixtures
  expect "use after shutdown fails" (afterShutdown == Left NotInitialized)

main : IO ()
main = do
  args <- getArgs
  case args of
    [_, fixtures] => do
      testPureResponses
      testContainment
      testNative fixtures
      putStrLn "ABI runtime checks passed (fixture-only; no game operation or UI acceptance claimed)."
    _ => do
      putStrLn "Usage: gsa-abi-runtime-test <absolute path to ABI fixtures>"
      exitFailure
