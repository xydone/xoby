INSERT INTO collectors.list (provider, external_id, media_type, priority)
SELECT $1, unnest($2::bigint[]), $3::content.media_type, unnest($4::double precision[])
ON CONFLICT DO NOTHING
