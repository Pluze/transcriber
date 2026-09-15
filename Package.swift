// swift-tools-version: 6.0
import Foundation
import PackageDescription

let fluidAudioDependency: Package.Dependency = {
    if let localPath = ProcessInfo.processInfo.environment["FLUID_AUDIO_PATH"], !localPath.isEmpty {
        return .package(path: localPath)
    }
    return .package(
        url: "https://github.com/FluidInference/FluidAudio.git",
        revision: "b68f484789d81fda21efbf81e2ca9fcfd9dc22aa"
    )
}()

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Transcriber", targets: ["Transcriber"]),
    ],
    dependencies: [fluidAudioDependency],
    targets: [
        .executableTarget(
            name: "Transcriber",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources"
        ),
    ]
)
