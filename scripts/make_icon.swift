#!/usr/bin/env swift
// Draws the app icon. Run from the repo root: swift scripts/make_icon.swift
import AppKit
import CoreGraphics
import CoreText

let size = 1024
let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colourSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("Couldn't create a drawing context") }

func colour(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(colorSpace: colourSpace, components: [red, green, blue, 1])!
}

let ebony = colour(0.071, 0.043, 0.039)
let cherry = colour(0.557, 0.165, 0.094)
let amber = colour(0.898, 0.565, 0.169)
let honey = colour(0.969, 0.784, 0.408)

context.setFillColor(ebony)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// The sunburst.
let gradient = CGGradient(
    colorsSpace: colourSpace,
    colors: [honey, honey, amber, cherry, ebony] as CFArray,
    locations: [0, 0.18, 0.42, 0.72, 1]
)!
let centre = CGPoint(x: 512, y: 512)
context.drawRadialGradient(
    gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 690,
    options: [.drawsAfterEndLocation]
)

// The note, in the same face as the app.
let font = CTFontCreateWithName("Superclarendon-Black" as CFString, 720, nil)
let text = NSAttributedString(string: "E", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): ebony,
])
let line = CTLineCreateWithAttributedString(text)
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
context.textPosition = CGPoint(
    x: 512 - bounds.width / 2 - bounds.minX,
    y: 512 - bounds.height / 2 - bounds.minY
)
CTLineDraw(line, context)

guard let image = context.makeImage(),
      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else { fatalError("Couldn't encode the icon") }

try data.write(to: URL(fileURLWithPath: "InstTuner/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
print("Wrote AppIcon.png")
