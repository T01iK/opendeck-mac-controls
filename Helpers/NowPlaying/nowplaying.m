// Now Playing helper.
//
// Since macOS 15.4 the private MediaRemote framework only serves now-playing information to Apple-signed
// processes. This library is therefore loaded into /usr/bin/perl (see nowplaying.pl), which is allowed to use it.
//
// Protocol:
//   stdout: one JSON object per line, {"type":"info", ...} whenever the now-playing state changes. "artwork" (base64
//           JPEG) is only included when it changed; "hasArtwork" says whether the item currently has any.
//   stdin:  one command per line: togglePlayPause | play | pause | stop | next | previous
// The helper exits when stdin is closed, i.e. when the plugin goes away.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#include <dlfcn.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*MRSendCommandFn)(int, NSDictionary *);

static MRGetInfoFn getInfo;
static MRGetIsPlayingFn getIsPlaying;
static MRGetPIDFn getPID;
static MRSendCommandFn sendCommand;

static NSUInteger lastArtworkHash = 0;
static BOOL refreshScheduled = NO;
static NSMutableData *stdinBuffer;

static void emit(NSDictionary *object) {
	NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
	if (!json) return;
	fwrite(json.bytes, 1, json.length, stdout);
	fputc('\n', stdout);
	fflush(stdout);
}

static NSString *thumbnailBase64(NSData *data) {
	CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
	if (!source) return nil;
	NSDictionary *options = @{
		(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
		(id)kCGImageSourceCreateThumbnailWithTransform: @YES,
		(id)kCGImageSourceThumbnailMaxPixelSize: @288,
	};
	CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
	CFRelease(source);
	if (!image) return nil;
	NSMutableData *out = [NSMutableData data];
	CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
	CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef) @{(id)kCGImageDestinationLossyCompressionQuality: @0.85});
	BOOL ok = CGImageDestinationFinalize(dest);
	CFRelease(dest);
	CGImageRelease(image);
	return ok ? [out base64EncodedStringWithOptions:0] : nil;
}

static void refresh(void) {
	getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
		getIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
			getPID(dispatch_get_main_queue(), ^(int pid) {
				NSMutableDictionary *out = [NSMutableDictionary dictionaryWithObject:@"info" forKey:@"type"];
				out[@"playing"] = @(playing);
				if (info.count == 0) {
					out[@"empty"] = @YES;
					lastArtworkHash = 0;
					emit(out);
					return;
				}
				NSDictionary *keys = @{
					@"kMRMediaRemoteNowPlayingInfoTitle": @"title",
					@"kMRMediaRemoteNowPlayingInfoArtist": @"artist",
					@"kMRMediaRemoteNowPlayingInfoAlbum": @"album",
					@"kMRMediaRemoteNowPlayingInfoDuration": @"duration",
					@"kMRMediaRemoteNowPlayingInfoElapsedTime": @"elapsed",
					@"kMRMediaRemoteNowPlayingInfoPlaybackRate": @"rate",
				};
				for (NSString *key in keys) {
					id value = info[key];
					if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) out[keys[key]] = value;
				}
				NSDate *timestamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
				if ([timestamp isKindOfClass:[NSDate class]]) out[@"timestamp"] = @(timestamp.timeIntervalSince1970);

				// Artwork is only sent when it changes. Right after play/pause MediaRemote briefly reports the item without
				// artwork; "hasArtwork": false lets the plugin keep showing the previous image for the same item.
				NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
				BOOL hasArtwork = [artwork isKindOfClass:[NSData class]] && artwork.length > 0;
				out[@"hasArtwork"] = @(hasArtwork);
				if (hasArtwork) {
					NSUInteger hash = artwork.length ^ (artwork.hash << 1);
					if (hash != lastArtworkHash) {
						NSString *encoded = thumbnailBase64(artwork);
						if (encoded) {
							out[@"artwork"] = encoded;
							lastArtworkHash = hash;
						}
					}
				} else {
					// Forget the hash so the artwork is sent again once it reappears.
					lastArtworkHash = 0;
				}

				NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
				if (app.bundleIdentifier) out[@"bundleId"] = app.bundleIdentifier;
				if (app.localizedName) out[@"appName"] = app.localizedName;
				emit(out);
			});
		});
	});
}

static void scheduleRefresh(void) {
	if (refreshScheduled) return;
	refreshScheduled = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
		refreshScheduled = NO;
		refresh();
	});
}

static void handleCommand(NSString *line) {
	NSDictionary *commands = @{
		@"play": @0, @"pause": @1, @"togglePlayPause": @2, @"stop": @3, @"next": @4, @"previous": @5,
	};
	NSString *name = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if (name.length == 0) return;
	if ([name isEqualToString:@"refresh"]) {
		lastArtworkHash = 0;
		refresh();
		return;
	}
	NSNumber *command = commands[name];
	if (!command) return;
	Boolean ok = sendCommand(command.intValue, nil);
	emit(@{@"type": @"command", @"command": name, @"ok": @(ok)});
}

static void readStdin(void) {
	stdinBuffer = [NSMutableData data];
	dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
	dispatch_source_set_event_handler(source, ^{
		char buf[1024];
		ssize_t n = read(STDIN_FILENO, buf, sizeof buf);
		if (n <= 0) exit(0);
		[stdinBuffer appendBytes:buf length:(NSUInteger)n];
		while (true) {
			NSRange newline = [stdinBuffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, stdinBuffer.length)];
			if (newline.location == NSNotFound) break;
			NSData *lineData = [stdinBuffer subdataWithRange:NSMakeRange(0, newline.location)];
			[stdinBuffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
			handleCommand([[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding]);
		}
	});
	dispatch_resume(source);
	// Keep the source alive for the lifetime of the process.
	CFBridgingRetain(source);
}

// Installed as a Perl XSUB by nowplaying.pl; the Perl arguments are ignored.
void macdeck_nowplaying_run(void *perl, void *cv) {
	@autoreleasepool {
		void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
		if (!mr) {
			emit(@{@"type": @"error", @"message": @"MediaRemote unavailable"});
			exit(1);
		}
		MRRegisterFn registerForNotifications = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
		getInfo = (MRGetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
		getIsPlaying = (MRGetIsPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
		getPID = (MRGetPIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
		sendCommand = (MRSendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
		if (!registerForNotifications || !getInfo || !getIsPlaying || !getPID || !sendCommand) {
			emit(@{@"type": @"error", @"message": @"MediaRemote symbols missing"});
			exit(1);
		}

		registerForNotifications(dispatch_get_main_queue());
		for (NSString *name in @[
			     @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
			     @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
			     @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
		     ]) {
			[NSNotificationCenter.defaultCenter addObserverForName:name
			                                                object:nil
			                                                 queue:NSOperationQueue.mainQueue
			                                            usingBlock:^(NSNotification *note) {
				                                            scheduleRefresh();
			                                            }];
		}

		readStdin();
		emit(@{@"type": @"ready"});
		refresh();
	}
	CFRunLoopRun();
	exit(0);
}
