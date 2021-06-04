//
//  AppDelegate.swift
//  GStreamer MacOSX Example
//
//  Created by Mixaill on 04.06.2021.
//

import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
        
        gst_init(nil, nil);
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }


}

