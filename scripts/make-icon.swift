import AppKit
let size: CGFloat = 1024
let image=NSImage(size:NSSize(width:size,height:size))
image.lockFocus()
NSColor(calibratedRed:0.91,green:0.94,blue:0.87,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:50,y:50,width:924,height:924),xRadius:210,yRadius:210).fill()
let green=NSColor(calibratedRed:0.19,green:0.34,blue:0.25,alpha:1)
green.setStroke()
let ring=NSBezierPath(ovalIn:NSRect(x:220,y:220,width:584,height:584)); ring.lineWidth=10; ring.stroke()
NSGraphicsContext.saveGraphicsState()
let transform=NSAffineTransform(); transform.translateX(by:512,yBy:512); transform.rotate(byDegrees:-36); transform.concat()
let orbit=NSBezierPath(ovalIn:NSRect(x:-132,y:-292,width:264,height:584)); orbit.lineWidth=16; orbit.stroke()
NSGraphicsContext.restoreGraphicsState()
green.setFill(); NSBezierPath(ovalIn:NSRect(x:674,y:686,width:76,height:76)).fill()
image.unlockFocus()
let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
