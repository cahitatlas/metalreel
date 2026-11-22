// swift-tools-version:6.0
import PackageDescription

let package = Package(
	name: "MetalReel",
	platforms: [.macOS(.v15)],
	products: [
		.executable(name: "metalreel", targets: ["metalreel"]),
	],
	targets: [
		// Vendored Yoga (MIT, Meta) — flexbox layout engine. See Sources/CYoga/YOGA_COMMIT.txt.
		.target(name: "CYoga", path: "Sources/CYoga", sources: ["yoga"], publicHeadersPath: ".",
		        cxxSettings: [.headerSearchPath("."), .unsafeFlags(["-O3"])]),
		// Everything native lives in one executable target:
		//   Painter (Metal / Core Image display-list painter), Encoder (VideoToolbox + audio mix),
		//   JS runtime host (JavaScriptCore), Layout (Yoga), Text (Core Text), WebKit fallback.
		.executableTarget(name: "metalreel", dependencies: ["CYoga"], path: "Sources/metalreel",
		                  resources: [.copy("Resources")],
		                  swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
	],
	swiftLanguageModes: [.v5],
	cxxLanguageStandard: .cxx20
)
