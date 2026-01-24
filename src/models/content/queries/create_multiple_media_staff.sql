INSERT INTO content.media_staff (media_id, person_id, role_name, character_name)
SELECT * FROM UNNEST(
    $1::uuid[],
    $2::uuid[],
    $3::text[],
    $4::text[]
)
ON CONFLICT (media_id, person_id, role_name) DO NOTHING;
