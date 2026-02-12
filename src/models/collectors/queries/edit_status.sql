UPDATE
  collectors.list
SET
  status = $3,
  updated_at = now()
WHERE
  provider = $1
  AND external_id = ANY ($2::text[]);
