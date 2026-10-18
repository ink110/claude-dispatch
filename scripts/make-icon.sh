#!/bin/bash
# 生成 Resources/AppIcon.icns（零第三方依赖：Swift/AppKit + sips + iconutil）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/draw.swift" <<'SWIFT'
import AppKit

let app = NSApplication.shared
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS 图标网格：824×824 圆角底，四周留透明边距。
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.18, alpha: 1),
    NSColor(calibratedRed: 0.045, green: 0.05, blue: 0.065, alpha: 1)
])!
background.draw(in: shape, angle: -90)

NSColor.white.withAlphaComponent(0.10).setStroke()
shape.lineWidth = 5
shape.stroke()

// 脉冲波形：粗线 + 暖橙微光，缩小到 16px 仍然可辨认。
let orange = NSColor(calibratedRed: 1.0, green: 0.47, blue: 0.20, alpha: 1)
let shadow = NSShadow()
shadow.shadowColor = orange.withAlphaComponent(0.75)
shadow.shadowBlurRadius = 46
shadow.shadowOffset = .zero
shadow.set()

let points: [NSPoint] = [
    NSPoint(x: 205, y: 512),
    NSPoint(x: 330, y: 512),
    NSPoint(x: 382, y: 452),
    NSPoint(x: 428, y: 570),
    NSPoint(x: 476, y: 318),
    NSPoint(x: 524, y: 706),
    NSPoint(x: 570, y: 466),
    NSPoint(x: 616, y: 548),
    NSPoint(x: 662, y: 512),
    NSPoint(x: 819, y: 512)
]
let wave = NSBezierPath()
wave.move(to: points[0])
for point in points.dropFirst() { wave.line(to: point) }
wave.lineWidth = 68
wave.lineCapStyle = .round
wave.lineJoinStyle = .round
orange.setStroke()
wave.stroke()

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("icon render failed\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT

swift "$TMP/draw.swift" "$TMP/icon_1024.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
make_size() {
  local px="$1" name="$2"
  sips -z "$px" "$px" "$TMP/icon_1024.png" --out "$ICONSET/$name" >/dev/null
}
make_size 16 icon_16x16.png
make_size 32 icon_16x16@2x.png
make_size 32 icon_32x32.png
make_size 64 icon_32x32@2x.png
make_size 128 icon_128x128.png
make_size 256 icon_128x128@2x.png
make_size 256 icon_256x256.png
make_size 512 icon_256x256@2x.png
make_size 512 icon_512x512.png
make_size 1024 icon_512x512@2x.png

mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "Wrote $ROOT/Resources/AppIcon.icns"
