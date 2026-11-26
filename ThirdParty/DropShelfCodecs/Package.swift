// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DropShelfCodecs",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DropShelfCodecs", targets: ["DropShelfCodecs"]),
    ],
    targets: [
        .target(
            name: "COgg",
            exclude: ["COPYING"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "CVorbis",
            dependencies: ["COgg"],
            exclude: ["COPYING"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "COpus",
            exclude: ["COPYING"],
            sources: ["src", "celt", "silk"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("celt"),
                .headerSearchPath("silk"),
                .headerSearchPath("silk/float"),
                .define("OPUS_BUILD"),
                .define("USE_ALLOCA"),
                .define("HAVE_LRINT"),
                .define("HAVE_LRINTF"),
                .define("HAVE_STDINT_H"),
                .define("HAVE_STDLIB_H"),
                .define("HAVE_STRING_H"),
                .define("FLOATING_POINT"),
                .define("PACKAGE_VERSION", to: "\"1.6.1\""),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "CFlac",
            exclude: ["COPYING.Xiph", "internal"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("internal"),
                .define("PACKAGE_VERSION", to: "\"1.5.0\""),
                .define("FLAC__NO_ASM"),
                .define("FLAC__NO_DLL"),
                .define("FLAC__HAS_OGG", to: "0"),
                .define("HAVE_LROUND", to: "1"),
                .define("HAVE_STDINT_H", to: "1"),
                .define("HAVE_INTTYPES_H", to: "1"),
                .define("HAVE_SYS_PARAM_H", to: "1"),
                .define("HAVE_FSEEKO", to: "1"),
                .define("HAVE_BSWAP32", to: "1"),
                .define("HAVE_BSWAP16", to: "1"),
                .define("ENABLE_64_BIT_WORDS", to: "1"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "CLame",
            exclude: ["COPYING"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .define("HAVE_CONFIG_H"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "CWebP",
            exclude: ["COPYING"],
            sources: ["sharpyuv", "src/dec", "src/dsp", "src/enc", "src/utils"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("src"),
                .headerSearchPath("include"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "CWavPack",
            exclude: ["COPYING"],
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
                .define("ENABLE_LEGACY"),
                .define("ENABLE_DSD"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "DropShelfCodecs",
            dependencies: ["COgg", "CVorbis", "COpus", "CFlac", "CLame", "CWebP", "CWavPack"]
        ),
    ]
)
