//
//  ViewController.swift
//  GStreamer MacOSX Example
//
//  Created by Mixaill on 04.06.2021.
//

import Cocoa

class ViewController: NSViewController {

    @IBOutlet weak var gstInitButton: NSButton!
    @IBOutlet weak var playButton: NSButton!
    @IBOutlet weak var pauseButton: NSButton!
    @IBOutlet weak var messageLabel: NSTextField!

    @IBOutlet weak var imgView: NSImageView!
    
    var gstBackend: GStreamerBackend? = nil
    
    override func viewDidLoad() {
        super.viewDidLoad()

        playButton.isEnabled = false
        pauseButton.isEnabled = false
        
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
    
    @IBAction func gstInitButtonClicked(_ sender: Any) {
        gstBackend = GStreamerBackend.init(backendDelegate: self)
    }

    @IBAction func playButtonClicked(_ sender: Any) {
        gstBackend?.play()
    }

    @IBAction func pauseButtonClicked(_ sender: Any) {
        gstBackend?.pause()
    }
}

extension ViewController: GStreamerBackendDelegate {
    
    func gstreamerInitialized() {
        DispatchQueue.main.async {
            self.playButton.isEnabled = true
            self.pauseButton.isEnabled = true
            self.messageLabel.stringValue = "Ready"
            self.gstBackend?.setUri("rtsp://192.168.0.106/user=admin_password=master_channel=2_stream=1.sdp")
        }
    }
    
    func capturedNewFrame(_ image: CGImage!) {
        DispatchQueue.main.async {
            self.imgView.image = NSImage(cgImage: image, size:.zero)
        }
    }
    
}
