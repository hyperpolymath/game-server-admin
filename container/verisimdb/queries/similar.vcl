-- SPDX-License-Identifier: MPL-2.0
-- Find servers with similar configuration (vector similarity)
-- Replace the embedding with the target server's config embedding
-- Usage: POST /api/v1/vql/execute with this query

SEARCH VECTOR [0.0] LIMIT 10
