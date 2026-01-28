WITH input_data AS (
    SELECT 
        val.title, 
        val.rel_date::DATE as rel_date, 
        val.descr, 
        val.chapters,
        val.idx
    FROM UNNEST(
        $1::text[],
        $2::text[],
        $3::text[],
        $4::integer[]
    ) WITH ORDINALITY AS val(title, rel_date, descr, chapters, idx)
),
inserted_media AS (
    INSERT INTO content.media_items (title, release_date, description, media_type, user_id)
    SELECT title, rel_date, descr, 'manga', $5::uuid
    FROM input_data
    ORDER BY idx
    RETURNING id, title
),
inserted_media_with_idx AS (
    SELECT id, ROW_NUMBER() OVER () as idx FROM inserted_media
)
INSERT INTO content.manga (media_id, total_chapters)
SELECT 
    im.id,
    idat.chapters
FROM inserted_media_with_idx im
JOIN input_data idat ON im.idx = idat.idx
RETURNING media_id;
