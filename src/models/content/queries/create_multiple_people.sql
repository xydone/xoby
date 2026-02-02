WITH
  input_data AS (
    SELECT DISTINCT
      ON (provider, external_id) t.full_name,
      t.bio,
      t.provider,
      t.external_id
    FROM
      UNNEST($1::text[], $2::text[], $3::text[], $4::text[]) AS t (full_name, bio, provider, external_id)
    ORDER BY
      provider,
      external_id
  ),
  existing_mappings AS (
    SELECT
      m.person_id,
      i.full_name,
      i.bio,
      i.provider,
      i.external_id
    FROM
      input_data i
      JOIN external.people m ON i.provider = m.provider
      AND i.external_id = m.external_id
  ),
  updated_people AS (
    UPDATE
      content.people p
    SET
      full_name = em.full_name,
      bio = em.bio
    FROM
      existing_mappings em
    WHERE
      p.id = em.person_id
    RETURNING
      p.id,
      em.external_id
  ),
  inserted_people AS (
    INSERT INTO
      content.people (full_name, bio)
    SELECT
      i.full_name,
      i.bio
    FROM
      input_data i
    WHERE
      NOT EXISTS (
        SELECT
          1
        FROM
          existing_mappings em
        WHERE
          em.provider = i.provider
          AND em.external_id = i.external_id
      )
    RETURNING
      id
  ),
  inserted_mappings AS (
    INSERT INTO
      external.people (person_id, provider, external_id)
    SELECT
      ip.id,
      i.provider,
      i.external_id
    FROM
      (
        SELECT
          id,
          row_number() OVER () as rn
        FROM
          inserted_people
      ) ip
      JOIN (
        SELECT
          provider,
          external_id,
          row_number() OVER () as rn
        FROM
          input_data i
        WHERE
          NOT EXISTS (
            SELECT
              1
            FROM
              existing_mappings em
            WHERE
              em.provider = i.provider
              AND em.external_id = i.external_id
          )
      ) i ON ip.rn = i.rn
    RETURNING
      person_id,
      external_id
  )
SELECT
  id,
  external_id
FROM
  updated_people
UNION ALL
SELECT
  person_id,
  external_id
FROM
  inserted_mappings;
