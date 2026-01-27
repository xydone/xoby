pub const MovieIDResponse = struct {
    adult: bool,
    backdrop_path: ?[]const u8,
    // belongs_to_collection: struct {
    //     id: i64,
    //     name: []const u8,
    //     poster_path: []const u8,
    //     backdrop_path: []const u8,
    // },
    budget: i64,
    genres: []Genre,
    homepage: []const u8,
    id: i64,
    // TODO: not sure if this can actually be null?
    imdb_id: ?[]const u8,
    origin_country: [][]const u8,
    original_language: []const u8,
    original_title: []const u8,
    overview: []const u8,
    popularity: f32,
    poster_path: ?[]const u8,
    production_companies: []ProductionCompany,
    production_countries: []ProductionCountry,
    release_date: []const u8,
    revenue: i64,
    runtime: i64,
    spoken_languages: []SpokenLanguage,
    // TODO: enum?
    status: []const u8,
    tagline: ?[]const u8,
    title: []const u8,
    video: bool,
    vote_average: f32,
    vote_count: i64,
    credits: Credits,
    images: Images,

    pub const Genre = struct {
        id: i64,
        name: []const u8,
    };

    pub const ProductionCompany = struct {
        id: i64,
        logo_path: ?[]const u8,
        name: []const u8,
        origin_country: []const u8,
    };

    pub const ProductionCountry = struct {
        iso_3166_1: []const u8,
        name: []const u8,
    };

    pub const SpokenLanguage = struct {
        english_name: []const u8,
        iso_639_1: []const u8,
        name: []const u8,
    };

    pub const Credits = struct {
        cast: []Cast,
        crew: []Crew,

        pub const Cast = struct {
            adult: bool,
            gender: u16,
            id: u64,
            known_for_department: ?[]const u8,
            name: []const u8,
            original_name: []const u8,
            popularity: f32,
            profile_path: ?[]const u8,
            cast_id: u64,
            character: []const u8,
            credit_id: []const u8,
            order: u64,
        };

        pub const Crew = struct {
            adult: bool,
            gender: u16,
            id: u64,
            known_for_department: ?[]const u8,
            name: []const u8,
            original_name: []const u8,
            popularity: f32,
            profile_path: ?[]const u8,
            credit_id: []const u8,
            department: []const u8,
            job: []const u8,
        };
    };

    pub const Images = struct {
        backdrops: []Image,
        logos: []Image,
        posters: []Image,

        const ImageType = enum { backdrops, logos, posters };

        pub const Image = struct {
            aspect_ratio: f32,
            height: i32,
            iso_3166_1: ?[]const u8,
            iso_639_1: ?[]const u8,
            file_path: []const u8,
            vote_average: f32,
            vote_count: u64,
            width: i32,
        };
    };
};
