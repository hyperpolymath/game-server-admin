-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>

module Responses

import Types
import Data.Maybe

%default total

||| The native profile loader returns either a count or a positive error code.
||| Only the immediately captured thread-local error disambiguates them.
||| A legitimate count of 13 must not become NotInitialized, and a native
||| NotInitialized error must not become thirteen successfully loaded profiles.
export
decodeProfileCount : Int -> String -> Either Result Nat
decodeProfileCount count err =
  if err /= ""
    then Left (if count == 0 then ProtocolError
                 else fromMaybe Error (resultFromInt count))
    else if count < 0 then Left ProtocolError
         else Right (cast count)
