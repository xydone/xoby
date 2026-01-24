WITH new_person AS (
    INSERT INTO content.people (full_name, bio)
    VALUES ($1, $2)
    RETURNING id
),
mapping AS (
    INSERT INTO content.people_external_mappings (person_id, provider, external_id)
    SELECT id, $3, $4 FROM new_person
)
INSERT INTO content.media_staff (media_id, person_id, role_name)
SELECT $5, id, $6 FROM new_person
RETURNING person_id;
