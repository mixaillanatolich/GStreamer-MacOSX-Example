//
//  GStreamerBackend.m
//  GStreamer MacOSX Example
//
//  Created by Mixaill on 04.06.2021.
//

#import "GStreamerBackend.h"

#include <gst/gst.h>
#include <gst/video/video.h>

GST_DEBUG_CATEGORY_STATIC (debug_category);
#define GST_CAT_DEFAULT debug_category

/* Do not allow seeks to be performed closer than this distance. It is visually useless, and will probably
 * confuse some demuxers. */
#define SEEK_MIN_DELAY (500 * GST_MSECOND)

@interface GStreamerBackend()
-(void)app_function;
-(void)check_initialization_complete;
@end

@implementation GStreamerBackend {
    id backendDelegate;        /* Class that we use to interact with the user interface */
    
    GstElement *pipeline;        /* The running pipeline */
    GstElement *video_sink;      /* The video sink element which receives XOverlay commands */
    GMainContext *context;       /* GLib context used to run the main loop */
    GMainLoop *main_loop;        /* GLib main loop */
    gboolean initialized;        /* To avoid informing the UI multiple times about the initialization */
    GstState state;              /* Current pipeline state */
    GstState target_state;       /* Desired pipeline state, to be set once buffering is complete */
    gint64 duration;             /* Cached clip duration */
    gint64 desired_position;     /* Position to seek to, once the pipeline is running */
    GstClockTime last_seek_time; /* For seeking overflow prevention (throttling) */
}

/*
 * Interface methods
 */

-(id) initWithBackendDelegate:(id) backendDelegate {
    if (self = [super init]) {
        self->backendDelegate = backendDelegate;
        self->duration = GST_CLOCK_TIME_NONE;

        GST_DEBUG_CATEGORY_INIT (debug_category, "LM", 0, "iOS LM");
        gst_debug_set_threshold_for_name("LM", GST_LEVEL_DEBUG);
        
        /* Start the bus monitoring task */
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self app_function];
        });
    }

    return self;
}

-(void) deinit {
    NSLog(@"GStreamerBackend.deinit");
    
    if (main_loop) {
        NSLog(@"GStreamerBackend.deinit. Main Loop Exists. Quiting it");
        g_main_loop_quit(main_loop);
    }
}

-(void) play {
    target_state = GST_STATE_PLAYING;
    gst_element_set_state (pipeline, GST_STATE_PLAYING);
}

-(void) pause {
    target_state = GST_STATE_PAUSED;
    gst_element_set_state (pipeline, GST_STATE_PAUSED);
}

-(void) setUri:(NSString*)uri {
    const char *char_uri = [uri UTF8String];
    
    GstElement *src;
    src = gst_bin_get_by_name (GST_BIN (pipeline), "src");
    g_object_set (src, "uri", char_uri, NULL);
    
    gst_object_unref(src);

    GST_DEBUG ("URI set to %s", char_uri);
}


/*
 * Private methods
 */

/* Forward declaration for the delayed seek callback */
static gboolean delayed_seek_cb (GStreamerBackend *self);

/* Perform seek, if we are not too close to the previous seek. Otherwise, schedule the seek for
 * some time in the future. */
static void execute_seek (gint64 position, GStreamerBackend *self) {
    gint64 diff;

    if (position == GST_CLOCK_TIME_NONE)
        return;

    diff = gst_util_get_timestamp () - self->last_seek_time;

    if (GST_CLOCK_TIME_IS_VALID (self->last_seek_time) && diff < SEEK_MIN_DELAY) {
        /* The previous seek was too close, delay this one */
        GSource *timeout_source;

        if (self->desired_position == GST_CLOCK_TIME_NONE) {
            /* There was no previous seek scheduled. Setup a timer for some time in the future */
            timeout_source = g_timeout_source_new ((SEEK_MIN_DELAY - diff) / GST_MSECOND);
            g_source_set_callback (timeout_source, (GSourceFunc)delayed_seek_cb, (__bridge void *)self, NULL);
            g_source_attach (timeout_source, self->context);
            g_source_unref (timeout_source);
        }
        /* Update the desired seek position. If multiple requests are received before it is time
         * to perform a seek, only the last one is remembered. */
        self->desired_position = position;
        GST_DEBUG ("Throttling seek to %" GST_TIME_FORMAT ", will be in %" GST_TIME_FORMAT,
                   GST_TIME_ARGS (position), GST_TIME_ARGS (SEEK_MIN_DELAY - diff));
    } else {
        /* Perform the seek now */
        GST_DEBUG ("Seeking to %" GST_TIME_FORMAT, GST_TIME_ARGS (position));
        self->last_seek_time = gst_util_get_timestamp ();
        gst_element_seek_simple (self->pipeline, GST_FORMAT_TIME, GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT, position);
        self->desired_position = GST_CLOCK_TIME_NONE;
    }
}

/* Delayed seek callback. This gets called by the timer setup in the above function. */
static gboolean delayed_seek_cb (GStreamerBackend *self) {
    GST_DEBUG ("Doing delayed seek to %" GST_TIME_FORMAT, GST_TIME_ARGS (self->desired_position));
    execute_seek (self->desired_position, self);
    return FALSE;
}

/* Retrieve errors from the bus and show them on the UI */
static void error_cb (GstBus *bus, GstMessage *msg, GStreamerBackend *self) {
    GError *err;
    gchar *debug_info;

    gst_message_parse_error (msg, &err, &debug_info);
    NSLog(@"Error_cb %s", debug_info);

    g_clear_error (&err);
    g_free (debug_info);
    
    gst_element_set_state (self->pipeline, GST_STATE_NULL);
}

/* Called when the End Of the Stream is reached. Just move to the beginning of the media and pause. */
static void eos_cb (GstBus *bus, GstMessage *msg, GStreamerBackend *self) {
    self->target_state = GST_STATE_PAUSED;
    gst_element_set_state (self->pipeline, GST_STATE_PAUSED);
    execute_seek (0, self);
}

/* Called when the duration of the media changes. Just mark it as unknown, so we re-query it in the next UI refresh. */
static void duration_cb (GstBus *bus, GstMessage *msg, GStreamerBackend *self) {
    self->duration = GST_CLOCK_TIME_NONE;
}

/* Called when buffering messages are received. We inform the UI about the current buffering level and
 * keep the pipeline paused until 100% buffering is reached. At that point, set the desired state. */
static void buffering_cb (GstBus *bus, GstMessage *msg, GStreamerBackend *self) {
    gint percent;

    gst_message_parse_buffering (msg, &percent);
    if (percent < 100 && self->target_state >= GST_STATE_PAUSED) {
        gchar * message_string = g_strdup_printf ("Buffering %d%%", percent);
        gst_element_set_state (self->pipeline, GST_STATE_PAUSED);
        g_free (message_string);
    } else if (self->target_state >= GST_STATE_PLAYING) {
        gst_element_set_state (self->pipeline, GST_STATE_PLAYING);
    }
}

/* Called when the clock is lost */
static void clock_lost_cb (GstBus *bus, GstMessage *msg, GStreamerBackend *self) {
    if (self->target_state >= GST_STATE_PLAYING) {
        gst_element_set_state (self->pipeline, GST_STATE_PAUSED);
        gst_element_set_state (self->pipeline, GST_STATE_PLAYING);
    }
}

/* Notify UI about pipeline state changes */
static void state_changed_cb (GstBus *bus, GstMessage *msg, GStreamerBackend *self) {
    GstState old_state, new_state, pending_state;
    gst_message_parse_state_changed (msg, &old_state, &new_state, &pending_state);
    /* Only pay attention to messages coming from the pipeline, not its children */
    if (GST_MESSAGE_SRC (msg) == GST_OBJECT (self->pipeline)) {
        self->state = new_state;
        gchar *message = g_strdup_printf("State changed to %s", gst_element_state_get_name(new_state));
        g_free (message);

        if (old_state == GST_STATE_READY && new_state == GST_STATE_PAUSED) {
            /* If there was a scheduled seek, perform it now that we have moved to the Paused state */
            if (GST_CLOCK_TIME_IS_VALID (self->desired_position))
                execute_seek (self->desired_position, self);
        }
    }
}

static GstFlowReturn new_sample (GstElement *sink, GStreamerBackend *self) {
    GstCaps *caps;
    gint width, height;
    GstMapInfo map;
    GstSample * videobuffer;
    
    g_signal_emit_by_name (sink, "pull-sample", &videobuffer);
    
    if (videobuffer) {
        caps = gst_sample_get_caps(videobuffer);
        if (!caps) {
            NSLog(@"Failed to extract caps");
            gst_sample_unref(videobuffer);
            return GST_FLOW_OK;
        }

        GstStructure *s = gst_caps_get_structure(caps, 0);

        gboolean res;
        res = gst_structure_get_int (s, "width", &width);
        res |= gst_structure_get_int (s, "height", &height);
        if (!res) {
            gst_sample_unref(videobuffer);
            return GST_FLOW_OK;
        }

        GstBuffer *snapbuffer = gst_sample_get_buffer(videobuffer);
        if (snapbuffer && gst_buffer_map (snapbuffer, &map, GST_MAP_READ)) {
            CGDataProviderRef provider = CGDataProviderCreateWithData(NULL,
                                                                      map.data,
                                                                      height * width * 4,
                                                                      NULL);

            CGColorSpaceRef colorSpaceRef = CGColorSpaceCreateDeviceRGB();
            CGBitmapInfo bitmapInfo = kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault; //kCGImageAlphaLast
            CGColorRenderingIntent renderingIntent = kCGRenderingIntentDefault;

            CGImageRef imageRef = CGImageCreate(width,
                                                height,
                                                8,
                                                4 * 8,
                                                width * 4,
                                                colorSpaceRef,
                                                bitmapInfo,
                                                provider,
                                                NULL,
                                                NO,
                                                renderingIntent);
            
            if (self->backendDelegate) {
                [self->backendDelegate capturedNewFrame:imageRef];
            }
            
            CGColorSpaceRelease(colorSpaceRef);
            CGImageRelease(imageRef);
            CGDataProviderRelease(provider);
            
            gst_buffer_unmap(snapbuffer, &map);
            
            gst_sample_unref(videobuffer);
            
            return GST_FLOW_OK;
        }
        NSLog(@"Failed to get buffer");
        return GST_FLOW_OK;
    }
    NSLog(@"Failed to get sample");
    return GST_FLOW_OK;
}

/* Check if all conditions are met to report GStreamer as initialized.
 * These conditions will change depending on the application */
-(void) check_initialization_complete {
    if (!initialized && main_loop) {
        GST_DEBUG ("Initialization complete, notifying application.");
        if (backendDelegate) {
            [backendDelegate gstreamerInitialized];
        }
        initialized = TRUE;
    }
}
/* Main method for the bus monitoring code */
-(void) app_function {
    GstBus *bus;
    GSource *bus_source;
    GError *error = NULL;
    GstElement *app_sink;

    GST_DEBUG ("Creating pipeline");

    /* Create our own GLib Main Context and make it the default one */
    context = g_main_context_new ();
    g_main_context_push_thread_default(context);

    /* Build pipeline */
    //pipeline = gst_parse_launch("uridecodebin latency=500 drop-on-latency=true name=src ! videoconvert ! appsink name=sink sync=false caps=\" video/x-raw,format=RGBA,pixel-aspect-ratio=1/1 \"", &error);
    pipeline = gst_parse_launch("uridecodebin3 name=src latency=0 drop-on-latency=true ! videorate ! capsfilter name=ratefilter ! video/x-raw,framerate=(fraction)5/1 ! videoconvert n-threads=8 ! appsink name=sink caps=\"video/x-raw,format=RGBA,pixel-aspect-ratio=1/1\"", &error);
    
    if (error) {
        gchar *message = g_strdup_printf("Unable to build pipeline: %s", error->message);
        g_clear_error (&error);
        g_free (message);
        NSLog(@"Unable to build pipeline: %s", error->message);
        return;
    }
    app_sink = gst_bin_get_by_name (GST_BIN (pipeline), "sink");
    
    if (!app_sink) {
        NSLog(@"No app sink!");
        return;
    }

    g_object_set (app_sink, "emit-signals", TRUE, NULL);
    g_signal_connect (app_sink, "new-sample", (GCallback)new_sample, (__bridge void *)self);

    g_object_set(app_sink,"max-buffers", 1, "drop", TRUE, "sync", FALSE, NULL);
    
    /* Set the pipeline to READY, so it can already accept a window handle */
    gst_element_set_state(pipeline, GST_STATE_READY);

    /* Instruct the bus to emit signals for each received message, and connect to the interesting signals */
    bus = gst_element_get_bus (pipeline);
    bus_source = gst_bus_create_watch (bus);
    g_source_set_callback (bus_source, (GSourceFunc) gst_bus_async_signal_func, NULL, NULL);
    g_source_attach (bus_source, context);
    g_source_unref (bus_source);
    g_signal_connect (G_OBJECT (bus), "message::error", (GCallback)error_cb, (__bridge void *)self);
    g_signal_connect (G_OBJECT (bus), "message::eos", (GCallback)eos_cb, (__bridge void *)self);
    g_signal_connect (G_OBJECT (bus), "message::state-changed", (GCallback)state_changed_cb, (__bridge void *)self);
    g_signal_connect (G_OBJECT (bus), "message::duration", (GCallback)duration_cb, (__bridge void *)self);
    g_signal_connect (G_OBJECT (bus), "message::buffering", (GCallback)buffering_cb, (__bridge void *)self);
    g_signal_connect (G_OBJECT (bus), "message::clock-lost", (GCallback)clock_lost_cb, (__bridge void *)self);
    gst_object_unref (bus);

    /* Create a GLib Main Loop and set it to run */
    GST_DEBUG ("Entering main loop...");
    main_loop = g_main_loop_new (context, FALSE);
    [self check_initialization_complete];
    g_main_loop_run (main_loop);
    GST_DEBUG ("Exited main loop");
    NSLog(@"Gstreamer backend. Exited Main Loop");
    g_main_loop_unref (main_loop);
    main_loop = NULL;

    /* Free resources */
    g_main_context_pop_thread_default(context);
    g_main_context_unref (context);
    gst_element_set_state (pipeline, GST_STATE_NULL);
    gst_object_unref (pipeline);
    gst_object_unref(app_sink);
    
    NSLog(@"Gstreamer. Resourced freed");
    pipeline = NULL;

    backendDelegate = NULL;

    return;
}

@end

