import Foundation
import CoreGraphics
import ImageIO

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func image(_ filename: String, width: Int, height: Int, transparent: Bool = false) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let w = CGFloat(width), h = CGFloat(height)
    if !transparent {
        let colors = [CGColor(srgbRed: 0.16, green: 0.56, blue: 0.88, alpha: 1),
                      CGColor(srgbRed: 0.68, green: 0.88, blue: 0.98, alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: .zero, options: [])
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.77, blue: 0.28, alpha: 1))
        context.fillEllipse(in: CGRect(x: w * 0.65, y: h * 0.62, width: w * 0.22, height: w * 0.22))
        context.setFillColor(CGColor(srgbRed: 0.13, green: 0.54, blue: 0.38, alpha: 1))
        context.move(to: .zero)
        context.addLine(to: CGPoint(x: w * 0.42, y: h * 0.66))
        context.addLine(to: CGPoint(x: w * 0.7, y: h * 0.18))
        context.addLine(to: CGPoint(x: w, y: h * 0.36))
        context.addLine(to: CGPoint(x: w, y: 0))
        context.closePath()
        context.fillPath()
    } else {
        context.setFillColor(CGColor(srgbRed: 0.91, green: 0.28, blue: 0.4, alpha: 0.9))
        context.fillEllipse(in: CGRect(x: w * 0.1, y: h * 0.15, width: w * 0.55, height: h * 0.55))
        context.setFillColor(CGColor(srgbRed: 0.21, green: 0.45, blue: 0.94, alpha: 0.85))
        context.fillEllipse(in: CGRect(x: w * 0.4, y: h * 0.35, width: w * 0.48, height: h * 0.48))
    }
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent(filename) as CFURL,
                                                     "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination))
}
try image("01_横長のサンプル.png", width: 800, height: 420)
try image("02_縦長のサンプル.png", width: 420, height: 800)
try image("03_透過のサンプル.png", width: 600, height: 600, transparent: true)
try FileManager.default.createDirectory(at: directory.appendingPathComponent("サンプルフォルダ"), withIntermediateDirectories: true)
try "画面確認用のサンプルファイルです。\n".write(to: directory.appendingPathComponent("04_メモ.txt"), atomically: true, encoding: .utf8)
