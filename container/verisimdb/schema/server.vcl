-- SPDX-License-Identifier: PMPL-1.0-or-later
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath)
--
-- VQL schema for Game Server Admin octads
-- Each managed game server is an octad with all 8 modalities:
--
-- 1. Graph:      server→game-profile, server→cluster, mod→server edges
-- 2. Vector:     config embedding for "find similar servers"
-- 3. Tensor:     performance metrics [player_count, tps, memory_mb, cpu_pct] over time
-- 4. Semantic:   typed annotations (game_type, version, mod_list, status, profile_id)
-- 5. Document:   full config file text (A2ML format, full-text indexed)
-- 6. Temporal:   every config version with timestamp
-- 7. Provenance: who changed what, when, why (SHA-256 hash-chain)
-- 8. Spatial:    datacenter geolocation (WGS84)

-- =============================================================================
-- Server octad schema
-- =============================================================================

-- Create a new server octad with all modalities populated
-- Usage: POST /api/v1/octads with this structure
--
-- {
--   "title": "valheim-1",
--   "body": "<full A2ML config text>",
--   "embedding": [0.1, 0.2, ...],
--   "types": ["https://gsa.hyperpolymath.dev/types/GameServer"],
--   "relationships": [
--     ["has-profile", "profile:valheim"],
--     ["in-cluster", "cluster:home-lab"]
--   ],
--   "tensor": {
--     "shape": [4],
--     "data": [12, 20.0, 2048, 45.2]
--   },
--   "provenance": {
--     "event_type": "created",
--     "actor": "gsa-gui",
--     "description": "Server added via probe"
--   },
--   "spatial": {
--     "latitude": 51.5074,
--     "longitude": -0.1278,
--     "altitude": 0.0,
--     "srid": 4326
--   },
--   "metadata": {
--     "game_id": "valheim",
--     "game_name": "Valheim",
--     "host": "${GSA_VPS_HOST}",
--     "port": "2456",
--     "protocol": "steam-query",
--     "config_format": "env",
--     "config_path": "/config/valheim/server.env",
--     "container_name": "valheim",
--     "container_runtime": "podman",
--     "status": "running",
--     "version": "0.217.46",
--     "max_players": "10",
--     "player_count": "3",
--     "fingerprint": "Valheim/0.217.46"
--   }
-- }

-- =============================================================================
-- Semantic type URIs for game servers
-- =============================================================================

-- Base type hierarchy:
--   https://gsa.hyperpolymath.dev/types/GameServer
--   https://gsa.hyperpolymath.dev/types/GameServer/Valheim
--   https://gsa.hyperpolymath.dev/types/GameServer/Minecraft
--   https://gsa.hyperpolymath.dev/types/VoiceServer (Burble)
--   https://gsa.hyperpolymath.dev/types/CustomServer (IDApTIK)
--   https://gsa.hyperpolymath.dev/types/GameProfile
--   https://gsa.hyperpolymath.dev/types/ConfigSnapshot

-- =============================================================================
-- Pre-built VQL queries for the dashboard
-- =============================================================================

-- All servers with status
-- SELECT document, semantic, temporal FROM octads LIMIT 100

-- Servers by game type
-- SELECT document, semantic FROM octads
--   WHERE metadata.game_id = 'valheim'
--   LIMIT 50

-- Servers with high drift
-- SHOW DRIFT

-- Config search across all servers
-- SEARCH TEXT 'MaxPlayers' LIMIT 50

-- Similar configs (vector search)
-- SEARCH VECTOR [0.1, 0.2, ...] LIMIT 10

-- Server relationships (graph traversal)
-- SEARCH RELATED 'server:valheim-1' BY 'in-cluster'

-- Config version history
-- SELECT temporal, provenance FROM octads WHERE id = 'server:valheim-1'

-- Performance metrics (tensor)
-- SELECT tensor FROM octads WHERE metadata.game_id = 'valheim'
