#!/usr/bin/env swift

import AppKit
import Foundation

struct Palette {
  static let shellTop = NSColor(calibratedRed: 0.965, green: 0.922, blue: 0.865, alpha: 1)
  static let shellBottom = NSColor(calibratedRed: 0.890, green: 0.816, blue: 0.714, alpha: 1)
  static let shellStroke = NSColor(calibratedRed: 0.643, green: 0.549, blue: 0.451, alpha: 0.28)
  static let shellHighlight = NSColor(calibratedRed: 1.0, green: 0.982, blue: 0.954, alpha: 0.82)
  static let paperFront = NSColor(calibratedRed: 0.148, green: 0.131, blue: 0.120, alpha: 1)
  static let paperBack = NSColor(calibratedRed: 0.281, green: 0.237, blue: 0.204, alpha: 1)
  static let paperStroke = NSColor(calibratedRed: 0.962, green: 0.933, blue: 0.894, alpha: 0.18)
  static let paperLine = NSColor(calibratedRed: 0.968, green: 0.925, blue: 0.843, alpha: 0.82)
  static let accentTop = NSColor(calibratedRed: 0.980, green: 0.612, blue: 0.345, alpha: 1)
  static let accentBottom = NSColor(calibratedRed: 0.839, green: 0.427, blue: 0.247, alpha: 1)
  static let accentGlow = NSColor(calibratedRed: 0.925, green: 0.471, blue: 0.278, alpha: 0.18)
  static let lens = NSColor(calibratedRed: 1.0, green: 0.964, blue: 0.910, alpha: 1)
  static let handle = NSColor(calibratedRed: 0.269, green: 0.204, blue: 0.169, alpha: 0.95)
}

let fileManager = FileManager.default
let projectRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let assetsDirectory = projectRoot.appendingPathComponent("electron/assets", isDirectory: true)
let iconsetDirectory = assetsDirectory.appendingPathComponent("DuplicateMe.iconset", isDirectory: true)
let iconOutput = assetsDirectory.appendingPathComponent("DuplicateMe.icns")
let previewOutput = assetsDirectory.appendingPathComponent("DuplicateMe-preview.png")

try? fileManager.removeItem(at: iconsetDirectory)
try fileManager.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
try fileManager.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)

let iconDefinitions: [(name: String, pixels: Int)] = [
  ("icon_16x16.png", 16),
  ("icon_16x16@2x.png", 32),
  ("icon_32x32.png", 32),
  ("icon_32x32@2x.png", 64),
  ("icon_128x128.png", 128),
  ("icon_128x128@2x.png", 256),
  ("icon_256x256.png", 256),
  ("icon_256x256@2x.png", 512),
  ("icon_512x512.png", 512),
  ("icon_512x512@2x.png", 1024),
]

for definition in iconDefinitions {
  let image = renderIcon(size: CGFloat(definition.pixels))
  let target = iconsetDirectory.appendingPathComponent(definition.name)
  try writePNG(image: image, to: target)
}

try writePNG(image: renderIcon(size: 1024), to: previewOutput)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDirectory.path, "-o", iconOutput.path]
try iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
  throw NSError(domain: "DuplicateMeIcon", code: Int(iconutil.terminationStatus))
}

try? fileManager.removeItem(at: iconsetDirectory)
print("icon_path=\(iconOutput.path)")
print("preview_path=\(previewOutput.path)")

func renderIcon(size: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size))
  image.lockFocus()
  defer { image.unlockFocus() }

  NSGraphicsContext.current?.imageInterpolation = .high

  let canvas = CGRect(origin: .zero, size: CGSize(width: size, height: size))
  drawBackdrop(in: canvas)
  drawDuplicateSheets(in: canvas)
  drawSearchBadge(in: canvas)

  return image
}

func drawBackdrop(in canvas: CGRect) {
  let shellRect = canvas.insetBy(dx: canvas.width * 0.08, dy: canvas.height * 0.08)
  let shellPath = NSBezierPath(roundedRect: shellRect, xRadius: canvas.width * 0.19, yRadius: canvas.width * 0.19)

  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor(calibratedWhite: 0.10, alpha: 0.16)
  shadow.shadowBlurRadius = canvas.width * 0.08
  shadow.shadowOffset = NSSize(width: 0, height: -canvas.height * 0.02)
  shadow.set()

  let shellGradient = NSGradient(colors: [Palette.shellTop, Palette.shellBottom])!
  shellGradient.draw(in: shellPath, angle: -38)
  NSGraphicsContext.restoreGraphicsState()

  Palette.shellStroke.setStroke()
  shellPath.lineWidth = max(1, canvas.width * 0.012)
  shellPath.stroke()

  let innerStrokeRect = shellRect.insetBy(dx: canvas.width * 0.02, dy: canvas.height * 0.02)
  let innerStroke = NSBezierPath(roundedRect: innerStrokeRect, xRadius: canvas.width * 0.16, yRadius: canvas.width * 0.16)
  Palette.shellHighlight.setStroke()
  innerStroke.lineWidth = max(1, canvas.width * 0.006)
  innerStroke.stroke()

  let glowRect = CGRect(
    x: shellRect.minX + canvas.width * 0.08,
    y: shellRect.maxY - canvas.height * 0.30,
    width: canvas.width * 0.32,
    height: canvas.height * 0.20
  )
  let glowPath = NSBezierPath(ovalIn: glowRect)
  Palette.accentGlow.setFill()
  glowPath.fill()
}

func drawDuplicateSheets(in canvas: CGRect) {
  let baseRect = CGRect(
    x: canvas.width * 0.26,
    y: canvas.height * 0.28,
    width: canvas.width * 0.34,
    height: canvas.height * 0.42
  )
  let rearRect = baseRect.offsetBy(dx: canvas.width * 0.12, dy: canvas.height * 0.11)

  drawSheet(in: rearRect, fill: Palette.paperBack, corner: canvas.width * 0.06)
  drawSheet(in: baseRect, fill: Palette.paperFront, corner: canvas.width * 0.06)
}

func drawSheet(in rect: CGRect, fill: NSColor, corner: CGFloat) {
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor(calibratedWhite: 0.07, alpha: 0.16)
  shadow.shadowBlurRadius = rect.width * 0.12
  shadow.shadowOffset = NSSize(width: 0, height: -rect.width * 0.04)
  shadow.set()

  let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
  fill.setFill()
  path.fill()
  NSGraphicsContext.restoreGraphicsState()

  Palette.paperStroke.setStroke()
  path.lineWidth = max(1, rect.width * 0.045)
  path.stroke()

  let foldSize = rect.width * 0.18
  let fold = NSBezierPath()
  fold.move(to: CGPoint(x: rect.maxX - foldSize, y: rect.maxY))
  fold.line(to: CGPoint(x: rect.maxX, y: rect.maxY))
  fold.line(to: CGPoint(x: rect.maxX, y: rect.maxY - foldSize))
  fold.close()
  NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
  fold.fill()

  let lineHeight = rect.height * 0.055
  let firstLine = CGRect(x: rect.minX + rect.width * 0.16, y: rect.midY + rect.height * 0.10, width: rect.width * 0.56, height: lineHeight)
  let secondLine = CGRect(x: rect.minX + rect.width * 0.16, y: rect.midY - rect.height * 0.01, width: rect.width * 0.48, height: lineHeight)
  let thirdLine = CGRect(x: rect.minX + rect.width * 0.16, y: rect.midY - rect.height * 0.12, width: rect.width * 0.36, height: lineHeight)
  for line in [firstLine, secondLine, thirdLine] {
    let linePath = NSBezierPath(roundedRect: line, xRadius: lineHeight / 2, yRadius: lineHeight / 2)
    Palette.paperLine.setFill()
    linePath.fill()
  }
}

func drawSearchBadge(in canvas: CGRect) {
  let badgeRect = CGRect(
    x: canvas.width * 0.56,
    y: canvas.height * 0.15,
    width: canvas.width * 0.26,
    height: canvas.height * 0.26
  )
  let badgePath = NSBezierPath(ovalIn: badgeRect)

  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor(calibratedWhite: 0.08, alpha: 0.18)
  shadow.shadowBlurRadius = canvas.width * 0.05
  shadow.shadowOffset = NSSize(width: 0, height: -canvas.width * 0.02)
  shadow.set()
  let gradient = NSGradient(colors: [Palette.accentTop, Palette.accentBottom])!
  gradient.draw(in: badgePath, angle: -55)
  NSGraphicsContext.restoreGraphicsState()

  let lensDiameter = badgeRect.width * 0.43
  let lensRect = CGRect(
    x: badgeRect.minX + badgeRect.width * 0.22,
    y: badgeRect.minY + badgeRect.height * 0.28,
    width: lensDiameter,
    height: lensDiameter
  )
  let lensPath = NSBezierPath(ovalIn: lensRect)
  Palette.lens.setStroke()
  lensPath.lineWidth = badgeRect.width * 0.08
  lensPath.stroke()

  let sparkle = NSBezierPath(ovalIn: lensRect.insetBy(dx: lensDiameter * 0.23, dy: lensDiameter * 0.23))
  NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
  sparkle.fill()

  let handle = NSBezierPath()
  handle.move(to: CGPoint(x: lensRect.maxX - lensDiameter * 0.02, y: lensRect.minY + lensDiameter * 0.04))
  handle.line(to: CGPoint(x: badgeRect.maxX - badgeRect.width * 0.18, y: badgeRect.minY + badgeRect.height * 0.16))
  Palette.lens.setStroke()
  handle.lineWidth = badgeRect.width * 0.09
  handle.lineCapStyle = .round
  handle.stroke()

  let handleCore = NSBezierPath()
  handleCore.move(to: CGPoint(x: lensRect.maxX - lensDiameter * 0.02, y: lensRect.minY + lensDiameter * 0.04))
  handleCore.line(to: CGPoint(x: badgeRect.maxX - badgeRect.width * 0.18, y: badgeRect.minY + badgeRect.height * 0.16))
  Palette.handle.setStroke()
  handleCore.lineWidth = badgeRect.width * 0.045
  handleCore.lineCapStyle = .round
  handleCore.stroke()
}

func writePNG(image: NSImage, to url: URL) throws {
  guard
    let tiff = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
  else {
    throw NSError(domain: "DuplicateMeIcon", code: 2)
  }

  try png.write(to: url)
}
