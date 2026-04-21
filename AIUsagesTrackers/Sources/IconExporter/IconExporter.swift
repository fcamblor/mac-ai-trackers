import Foundation
import ImageIO
import UniformTypeIdentifiers
import AppIconKit

/// CLI that rasterises `AppIconView` into the ten PNG files expected by
/// `iconutil -c icns`. Invoked by the packaging script; not part of the
/// runtime app.
@main
@MainActor
struct IconExporter {
    private struct Variant {
        let pixelSize: CGFloat
        let fileName: String
    }

    // Sizes and filenames dictated by iconutil's iconset layout.
    private static let variants: [Variant] = [
        Variant(pixelSize: 16,   fileName: "icon_16x16.png"),
        Variant(pixelSize: 32,   fileName: "icon_16x16@2x.png"),
        Variant(pixelSize: 32,   fileName: "icon_32x32.png"),
        Variant(pixelSize: 64,   fileName: "icon_32x32@2x.png"),
        Variant(pixelSize: 128,  fileName: "icon_128x128.png"),
        Variant(pixelSize: 256,  fileName: "icon_128x128@2x.png"),
        Variant(pixelSize: 256,  fileName: "icon_256x256.png"),
        Variant(pixelSize: 512,  fileName: "icon_256x256@2x.png"),
        Variant(pixelSize: 512,  fileName: "icon_512x512.png"),
        Variant(pixelSize: 1024, fileName: "icon_512x512@2x.png"),
    ]

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: IconExporter <output.iconset-dir>\n".utf8))
            exit(EX_USAGE)
        }

        let outputDirectory = URL(fileURLWithPath: arguments[1])

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            FileHandle.standardError.write(Data(
                "failed to create \(outputDirectory.path): \(error)\n".utf8
            ))
            exit(EXIT_FAILURE)
        }

        for variant in variants {
            let url = outputDirectory.appendingPathComponent(variant.fileName)
            do {
                try writePNG(pixelSize: variant.pixelSize, to: url)
            } catch {
                FileHandle.standardError.write(Data(
                    "failed to write \(url.path): \(error)\n".utf8
                ))
                exit(EXIT_FAILURE)
            }
        }
    }

    private static func writePNG(pixelSize: CGFloat, to url: URL) throws {
        guard let cgImage = AppIconRenderer.makeCGImage(pixelSize: pixelSize) else {
            throw ExportError.renderFailed(pixelSize: pixelSize)
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.destinationUnavailable(url: url)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.finalizeFailed(url: url)
        }
    }

    private enum ExportError: Error, CustomStringConvertible {
        case renderFailed(pixelSize: CGFloat)
        case destinationUnavailable(url: URL)
        case finalizeFailed(url: URL)

        var description: String {
            switch self {
            case .renderFailed(let size):
                return "ImageRenderer.cgImage returned nil at \(Int(size))px"
            case .destinationUnavailable(let url):
                return "CGImageDestination could not be created for \(url.path)"
            case .finalizeFailed(let url):
                return "CGImageDestinationFinalize failed for \(url.path)"
            }
        }
    }
}
