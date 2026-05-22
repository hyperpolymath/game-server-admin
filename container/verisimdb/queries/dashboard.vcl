-- SPDX-License-Identifier: MPL-2.0
-- Dashboard overview: all managed servers with key metadata

SELECT
  document,
  semantic,
  temporal,
  provenance
FROM octads
LIMIT 200
