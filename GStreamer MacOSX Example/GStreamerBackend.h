//
//  GStreamerBackend.h
//  GStreamer MacOSX Example
//
//  Created by Mixaill on 04.06.2021.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import "GStreamerBackendDelegate.h"

@interface GStreamerBackend : NSObject

/* Initialization method. Pass the delegate that will take care of the UI.
 * This delegate must implement the GStreamerBackendDelegate protocol. */

-(id) initWithBackendDelegate:(id) backendDelegate;

-(void) setUri:(NSString*)uri;

/* Set the pipeline to PLAYING */
-(void) play;

/* Set the pipeline to PAUSED */
-(void) pause;

@end

