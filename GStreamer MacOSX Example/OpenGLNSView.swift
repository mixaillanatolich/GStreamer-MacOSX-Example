//
//  OpenGLNSView.swift
//  GStreamer MacOSX Example
//
//  Created by Mixaill on 04.06.2021.
//

import Cocoa

class OpenGLNSView: NSView {

    override func makeBackingLayer() -> CALayer {
        return CAOpenGLLayer();
    }
    
}
