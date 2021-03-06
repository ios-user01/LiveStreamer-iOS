//
//  OWSegmentingAppleEncoder.m
//  OpenWatch
//
//  Created by Christopher Ballinger on 11/13/12.
//  Copyright (c) 2012 OpenWatch FPC. All rights reserved.
//

#import "OWSegmentingAppleEncoder.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import "OWUtilities.h"
#import "OWAppDelegate.h"

#import "OWSharedS3Client.h"

#define kMinVideoBitrate 100000
#define kMaxVideoBitrate 400000

#define BUCKET_NAME @"openwatch-livestreamer"

@implementation OWSegmentingAppleEncoder
@synthesize segmentationTimer, queuedAssetWriter;
@synthesize queuedAudioEncoder, queuedVideoEncoder;
@synthesize audioBPS, videoBPS, shouldBeRecording;
@synthesize segmentCount;
@synthesize manifestGenerator;
@synthesize ffmpegWrapper;

- (void) dealloc {
    if (self.segmentationTimer) {
        [self performSelectorOnMainThread:@selector(invalidateTimer) withObject:nil waitUntilDone:NO];
    }
}

- (void) finishEncoding {
    self.readyToRecordAudio = NO;
    self.readyToRecordVideo = NO;
    self.shouldBeRecording = NO;
    if (self.segmentationTimer) {
        [self performSelectorOnMainThread:@selector(invalidateTimer) withObject:nil waitUntilDone:NO];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super finishEncoding];
    //[[OWCaptureAPIClient sharedClient] finishedRecording:self.recording];
}

- (void) invalidateTimer {
    [self.segmentationTimer invalidate];
    self.segmentationTimer = nil;
}

- (void) createAndScheduleTimer {
    self.segmentationTimer = [NSTimer scheduledTimerWithTimeInterval:segmentationInterval target:self selector:@selector(segmentRecording:) userInfo:nil repeats:YES];
    //[[NSRunLoop mainRunLoop] addTimer:segmentationTimer forMode:NSDefaultRunLoopMode];
}

- (id) initWithBasePath:(NSString *)newBasePath segmentationInterval:(NSTimeInterval)timeInterval {
    if (self = [super init]) {
        self.basePath = newBasePath;
        self.shouldBeRecording = YES;
        segmentationInterval = timeInterval;
        [self performSelectorOnMainThread:@selector(createAndScheduleTimer) withObject:nil waitUntilDone:NO];
        //[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(receivedBandwidthUpdateNotification:) name:kOWCaptureAPIClientBandwidthNotification object:nil];
        segmentingQueue = dispatch_queue_create("Segmenting Queue", DISPATCH_QUEUE_SERIAL);
        self.segmentCount = 0;
        self.ffmpegWrapper = [[FFmpegWrapper alloc] init];
        NSString *manifestFileName = @"chunklist.m3u8";
        NSString *m3u8Path = [newBasePath stringByAppendingPathComponent:manifestFileName];
        self.manifestGenerator = [[OWManifestGenerator alloc] initWithM3U8Path:m3u8Path targetSegmentDuration:(int)timeInterval];
        
        NSError *error = nil;
        NSString *htmlFilePath = [[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"];
        NSString *crossDomainPath = [[NSBundle mainBundle] pathForResource:@"crossdomain" ofType:@"xml"];
        NSString *crossdomainOutputPath = [self.basePath stringByAppendingPathComponent:@"crossdomain.xml"];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        [fileManager copyItemAtPath:crossDomainPath toPath:crossdomainOutputPath error:&error];
        if (error) {
            NSLog(@"error copying cross domain file: %@", error.userInfo);
        }
        NSString *rootPlaylistPath = [[NSBundle mainBundle] pathForResource:@"playlist" ofType:@"m3u8"];
        NSString *rootPlaylistOutputPath = [self.basePath stringByAppendingPathComponent:@"playlist.m3u8"];
        [fileManager copyItemAtPath:rootPlaylistPath toPath:rootPlaylistOutputPath error:&error];
        if (error) {
            NSLog(@"error copying cross domain file: %@", error.userInfo);
        }
        
        NSString *html = [NSString stringWithContentsOfFile:htmlFilePath encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            NSLog(@"error loading html: %@", error.userInfo);
        }
        NSString *newHTML = [html stringByReplacingOccurrencesOfString:@"{% manifest_file_name %}" withString:manifestFileName];
        NSString *htmlIndexPath = [self.basePath stringByAppendingPathComponent:@"index.html"];
        [newHTML writeToFile:htmlIndexPath atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) {
            NSLog(@"error writing index.html: %@", error.userInfo);
        }
        
        NSString *playlistPath = [[NSBundle mainBundle] pathForResource:@"playlist" ofType:@"m3u8"];
        NSString *playlistKey = [NSString stringWithFormat:@"%@/%@",self.uuid, [playlistPath lastPathComponent]];
        [[OWSharedS3Client sharedClient] postObjectWithFile:playlistPath bucket:BUCKET_NAME key:playlistKey acl:@"public-read" success:^(S3PutObjectResponse *responseObject) {
            NSLog(@"success sending first manifest");
        } failure:^(NSError *error) {
            NSLog(@"error: %@", error.userInfo);
        }];
    }
    return self;
}

- (void) receivedBandwidthUpdateNotification:(NSNotification*)notification {
    double bps = [[[notification userInfo] objectForKey:@"bps"] doubleValue];
    double vbps = (bps*0.5) - audioBPS;
    if (vbps < kMinVideoBitrate) {
        vbps = kMinVideoBitrate;
    }
    if (vbps > kMaxVideoBitrate) {
        vbps = kMaxVideoBitrate;
    }
    self.videoBPS = vbps;
    //self.videoBPS = videoBPS * 0.75;
    NSLog(@"bps: %f\tvideoBPS: %d\taudioBPS: %d", bps, videoBPS, audioBPS);
}



- (void) segmentRecording:(NSTimer*)timer {
    if (!shouldBeRecording) {
        [timer invalidate];
    }
    AVAssetWriter *tempAssetWriter = self.assetWriter;
    AVAssetWriterInput *tempAudioEncoder = self.audioEncoder;
    AVAssetWriterInput *tempVideoEncoder = self.videoEncoder;
    self.assetWriter = queuedAssetWriter;
    self.audioEncoder = queuedAudioEncoder;
    self.videoEncoder = queuedVideoEncoder;
    NSLog(@"Switching encoders");
    
    dispatch_async(segmentingQueue, ^{
        if (tempAssetWriter.status == AVAssetWriterStatusWriting) {
            @try {
                [tempAudioEncoder markAsFinished];
                [tempVideoEncoder markAsFinished];
                [tempAssetWriter finishWritingWithCompletionHandler:^{
                    if (tempAssetWriter.status == AVAssetWriterStatusFailed) {
                        [self showError:tempAssetWriter.error];
                    } else {
                        [self uploadLocalURL:tempAssetWriter.outputURL];
                    }
                }];
            }
            @catch (NSException *exception) {
                NSLog(@"Caught exception: %@", [exception description]);
                //[BugSenseController logException:exception withExtraData:nil];
            }
        }
        self.segmentCount++;
        if (self.readyToRecordAudio && self.readyToRecordVideo) {
            NSError *error = nil;
            self.queuedAssetWriter = [[AVAssetWriter alloc] initWithURL:[OWUtilities urlForRecordingSegmentCount:segmentCount basePath:self.basePath] fileType:(NSString *)kUTTypeMPEG4 error:&error];
            if (error) {
                [self showError:error];
            }
            self.queuedVideoEncoder = [self setupVideoEncoderWithAssetWriter:self.queuedAssetWriter formatDescription:videoFormatDescription bitsPerSecond:videoBPS];
            self.queuedAudioEncoder = [self setupAudioEncoderWithAssetWriter:self.queuedAssetWriter formatDescription:audioFormatDescription bitsPerSecond:audioBPS];
            //NSLog(@"Encoder switch finished");
        }
    });
}



- (void) setupVideoEncoderWithFormatDescription:(CMFormatDescriptionRef)formatDescription bitsPerSecond:(int)bps {
    videoFormatDescription = formatDescription;
    videoBPS = bps;
    if (!self.assetWriter) {
        NSError *error = nil;
        self.assetWriter = [[AVAssetWriter alloc] initWithURL:[OWUtilities urlForRecordingSegmentCount:segmentCount basePath:self.basePath] fileType:(NSString *)kUTTypeMPEG4 error:&error];
        if (error) {
            [self showError:error];
        }
    }
    self.videoEncoder = [self setupVideoEncoderWithAssetWriter:self.assetWriter formatDescription:formatDescription bitsPerSecond:bps];
    
    if (!queuedAssetWriter) {
        self.segmentCount++;
        NSError *error = nil;
        self.queuedAssetWriter = [[AVAssetWriter alloc] initWithURL:[OWUtilities urlForRecordingSegmentCount:segmentCount basePath:self.basePath] fileType:(NSString *)kUTTypeMPEG4 error:&error];
        if (error) {
            [self showError:error];
        }
    }
    self.queuedVideoEncoder = [self setupVideoEncoderWithAssetWriter:self.queuedAssetWriter formatDescription:formatDescription bitsPerSecond:bps];
    self.readyToRecordVideo = YES;
}



- (void) setupAudioEncoderWithFormatDescription:(CMFormatDescriptionRef)formatDescription bitsPerSecond:(int)bps {
    audioFormatDescription = formatDescription;
    audioBPS = bps;
    if (!self.assetWriter) {
        NSError *error = nil;
        self.assetWriter = [[AVAssetWriter alloc] initWithURL:[OWUtilities urlForRecordingSegmentCount:segmentCount basePath:self.basePath] fileType:(NSString *)kUTTypeMPEG4 error:&error];
        if (error) {
            [self showError:error];
        }
    }
    self.audioEncoder = [self setupAudioEncoderWithAssetWriter:self.assetWriter formatDescription:formatDescription bitsPerSecond:bps];
    
    if (!queuedAssetWriter) {
        self.segmentCount++;
        NSError *error = nil;
        self.queuedAssetWriter = [[AVAssetWriter alloc] initWithURL:[OWUtilities urlForRecordingSegmentCount:segmentCount basePath:self.basePath] fileType:(NSString *)kUTTypeMPEG4 error:&error];
        if (error) {
            [self showError:error];
        }
    }
    self.queuedAudioEncoder = [self setupAudioEncoderWithAssetWriter:self.queuedAssetWriter formatDescription:formatDescription bitsPerSecond:bps];
    self.readyToRecordAudio = YES;
}

- (void) handleException:(NSException *)exception {
    [super handleException:exception];
    [self segmentRecording:nil];
}

- (void) uploadLocalURL:(NSURL*)url {
    NSLog(@"upload local url: %@", url);
    NSString *inputPath = [url path];
    NSString *outputPath = [inputPath stringByReplacingOccurrencesOfString:@".mp4" withString:@".ts"];
    NSString *outputFileName = [outputPath lastPathComponent];
    NSDictionary *options = @{kFFmpegOutputFormatKey: @"mpegts"};
    NSLog(@"%@ conversion...", outputFileName);
    [ffmpegWrapper convertInputPath:[url path] outputPath:outputPath options:options progressBlock:nil completionBlock:^(BOOL success, NSError *error) {
        if (success) {
            NSLog(@"%@ conversion complete", outputFileName);
            NSString *segmentKey = [NSString stringWithFormat:@"%@/%@", self.uuid, outputFileName];
            [[OWSharedS3Client sharedClient] postObjectWithFile:outputPath bucket:BUCKET_NAME key:segmentKey acl:@"public-read" success:^(S3PutObjectResponse *responseObject) {
                [manifestGenerator appendSegmentPath:outputPath duration:(int)segmentationInterval sequence:segmentCount completionBlock:^(BOOL success, NSError *error) {
                    if (success) {
                        NSString *manifestKey = [NSString stringWithFormat:@"%@/%@", self.uuid, [manifestGenerator.manifestPath lastPathComponent]];
                        [[OWSharedS3Client sharedClient] postObjectWithFile:manifestGenerator.manifestPath bucket:BUCKET_NAME key:manifestKey acl:@"public-read" success:^(S3PutObjectResponse *responseObject) {
                            NSLog(@"success updating manifest after uploading %@", outputFileName);
                        } failure:^(NSError *error) {
                            NSLog(@"error uplaoding manifest after %@", outputFileName);
                        }];
                    } else {
                        NSLog(@"Error creating manifest: %@", error.userInfo);
                    }
                }];
                NSLog(@"%@ upload complete: %@", outputFileName, responseObject.description);
            } failure:^(NSError *error) {
                NSLog(@"error posting segment %@: %@", outputFileName, error.userInfo);
            }];
        } else {
            NSLog(@"conversion error: %@", error.userInfo);
        }
    }];
}



@end
