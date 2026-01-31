INSERT INTO content.media_images (
    media_id,
    image_type,
    provider_name,
    path,
    is_primary
)
SELECT * FROM UNNEST(
    $1::uuid[],
    $2::content.image_type[],
    $3::text[],
    $4::text[],
    $5::boolean[]
);
