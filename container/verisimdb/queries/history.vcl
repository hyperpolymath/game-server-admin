-- SPDX-License-Identifier: MPL-2.0
-- Config change timeline with provenance for a specific server
-- Replace SERVER_ID with the target server's octad ID

SELECT temporal, provenance, document
FROM octads
WHERE id = 'SERVER_ID'
LIMIT 50
