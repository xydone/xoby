INSERT INTO content.people (full_name, bio, provider, external_id)
SELECT DISTINCT ON (provider, external_id) 
    full_name, bio, provider, external_id
FROM UNNEST($1::text[], $2::text[], $3::text[], $4::text[]) 
       AS t(full_name, bio, provider, external_id)
ORDER BY provider, external_id
ON CONFLICT (provider, external_id) DO UPDATE 
SET 
    full_name = EXCLUDED.full_name,
    bio = EXCLUDED.bio
RETURNING id, external_id;
