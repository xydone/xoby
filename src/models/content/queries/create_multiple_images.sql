INSERT INTO content.media_images (
    media_id,
    image_type,
    width,
    height,
    provider_name,
    path,
    is_primary
)
SELECT * FROM UNNEST(
    $1::uuid[],
    $2::content.image_type[],
    $3::integer[],
    $4::integer[],
    $5::text[],
    $6::text[],
    $7::boolean[]
);
