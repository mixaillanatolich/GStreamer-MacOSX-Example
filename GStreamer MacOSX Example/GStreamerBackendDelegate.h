//
//  GStreamerBackendDelegate.h
//  GStreamer MacOSX Example
//
//  Created by Mixaill on 04.06.2021.
//

#ifndef GStreamerBackendDelegate_h
#define GStreamerBackendDelegate_h

#import <Foundation/Foundation.h>

@protocol GStreamerBackendDelegate <NSObject>


/* Called when the GStreamer backend has finished initializing
 * and is ready to accept orders. */
- (void) gstreamerInitialized;

/* Called when the GStreamer backend received a new frame from stream */
- (void) capturedNewFrame:(CGImageRef)image;

@end

#endif /* GStreamerBackendDelegate_h */
