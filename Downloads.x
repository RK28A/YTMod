#import "YTLite.h"
#import "Utils/YTLSafeMode.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <Photos/Photos.h>

static __weak YTPlayerViewController *ytlWatchPlayer;
static __weak YTPlayerViewController *ytlShortsPlayer;
static CFTimeInterval ytlWatchTick, ytlShortsTick;
static const NSInteger kDownloadButtonTag = 998;
static const long long kChunkSize = 10 * 1024 * 1024;

static UIImage *YTLIcon(NSString *name) {
    return [UIImage imageNamed:name inBundle:[NSBundle mainBundle] compatibleWithTraitCollection:nil];
}

static NSString *YTLStringValue(id object, NSString *key) {
    id value = YTLValue(object, key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static BOOL YTLBoolValue(id object, NSString *key) {
    id value = YTLValue(object, key);
    return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

static long long YTLLongValue(id object, NSString *key) {
    id value = YTLValue(object, key);
    return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
}

static id YTLPlayerDetails(YTPlayerViewController *player) {
    id response = YTLValue(player, @"contentPlayerResponse") ?: YTLValue(player, @"playerResponse");
    id data = [response respondsToSelector:@selector(playerData)] ? YTLValue(response, @"playerData") : response;
    return YTLValue(data, @"videoDetails");
}

static NSString *YTLSafeFileName(NSString *name) {
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"/\\?%*|\"<>:\n\r\t"];
    NSString *clean = [[name componentsSeparatedByCharactersInSet:invalid] componentsJoinedByString:@" "];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (clean.length > 80) clean = [clean substringToIndex:80];
    return clean.length ? clean : @"video";
}

static NSString *YTLMime(id format) {
    return YTLStringValue(YTLValue(format, @"formatStream"), @"mimeType") ?: [YTLValue(format, @"MIMEType") description] ?: @"";
}

static NSURL *YTLFormatURL(id format) {
    id url = YTLValue(format, @"URL");
    if ([url isKindOfClass:[NSURL class]]) return url;
    NSString *string = YTLStringValue(YTLValue(format, @"formatStream"), @"URL");
    return string.length ? [NSURL URLWithString:string] : nil;
}

static long long YTLFormatLength(id format) {
    return YTLLongValue(YTLValue(format, @"formatStream"), @"contentLength");
}

static NSArray *YTLVideoFormats(YTPlayerViewController *player) {
    NSArray *formats = YTLValue(YTLValue(player, @"activeVideo"), @"selectableVideoFormats");
    NSMutableDictionary <NSString *, id> *byLabel = [NSMutableDictionary dictionary];

    for (id format in [formats isKindOfClass:[NSArray class]] ? formats : @[]) {
        NSString *mime = YTLMime(format);
        NSString *label = YTLStringValue(format, @"qualityLabel");
        if (!label.length || ![mime containsString:@"mp4"] || ![mime containsString:@"avc1"] || !YTLFormatURL(format)) continue;

        id existing = byLabel[label];
        if (!existing || YTLLongValue(format, @"bitrate") > YTLLongValue(existing, @"bitrate")) byLabel[label] = format;
    }

    return [byLabel.allValues sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [@(YTLLongValue(b, @"singleDimensionResolution")) compare:@(YTLLongValue(a, @"singleDimensionResolution"))];
    }];
}

static id YTLAudioFormat(YTPlayerViewController *player) {
    id video = YTLValue(player, @"activeVideo");
    NSArray *formats = YTLValue(video, @"selectableAudioFormats");
    NSString *selectedTrack = YTLStringValue(YTLValue(video, @"selectedAudioFormat"), @"audioTrackID");
    id best = nil;
    NSInteger bestScore = -1;

    for (id format in [formats isKindOfClass:[NSArray class]] ? formats : @[]) {
        NSString *mime = YTLMime(format);
        if (![mime containsString:@"mp4"] || !YTLFormatURL(format)) continue;

        NSInteger score = (NSInteger)(YTLLongValue(format, @"bitrate") / 1000);
        NSString *track = YTLStringValue(format, @"audioTrackID");
        if (selectedTrack.length && [track isEqualToString:selectedTrack]) score += 1000000;
        else if (YTLBoolValue(format, @"isDefaultAudio")) score += 500000;

        if (score > bestScore) {
            bestScore = score;
            best = format;
        }
    }
    return best;
}

@interface YTLDownloadTask : NSObject
@property (nonatomic, strong) UIAlertController *alert;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) long long totalBytes;
@property (nonatomic, assign) long long doneBytes;
@property (nonatomic, copy) NSString *status;
@end

@implementation YTLDownloadTask
- (void)updateProgress {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *percent = self.totalBytes > 0 ? [NSString stringWithFormat:@"%d%%", (int)(100.0 * self.doneBytes / self.totalBytes)] : @"…";
        self.alert.message = [NSString stringWithFormat:@"%@\n%@", self.status ?: @"", percent];
    });
}

- (void)downloadURL:(NSURL *)url length:(long long)length to:(NSURL *)file completion:(void (^)(NSError *error))completion {
    [[NSFileManager defaultManager] createFileAtPath:file.path contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:file.path];
    if (!handle) {
        completion([NSError errorWithDomain:@"YTLite" code:1 userInfo:@{NSLocalizedDescriptionKey: @"file"}]);
        return;
    }

    __block long long offset = 0;
    __block void (^next)(void);
    __weak typeof(self) weakSelf = self;

    next = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.cancelled) {
            [handle closeFile];
            completion([NSError errorWithDomain:@"YTLite" code:NSUserCancelledError userInfo:nil]);
            next = nil;
            return;
        }

        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSMutableArray *items = [components.queryItems mutableCopy] ?: [NSMutableArray array];
        long long end = length > 0 ? MIN(offset + kChunkSize, length) - 1 : offset + kChunkSize - 1;
        [items addObject:[NSURLQueryItem queryItemWithName:@"range" value:[NSString stringWithFormat:@"%lld-%lld", offset, end]]];
        components.queryItems = items;

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL ?: url];
        request.timeoutInterval = 30;

        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (error || (status != 200 && status != 206) || data.length == 0) {
                [handle closeFile];
                completion(error ?: [NSError errorWithDomain:@"YTLite" code:status userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)status]}]);
                next = nil;
                return;
            }

            [handle writeData:data];
            offset += data.length;
            weakSelf.doneBytes += data.length;
            [weakSelf updateProgress];

            BOOL finished = length > 0 ? offset >= length : (long long)data.length < kChunkSize;
            if (finished) {
                [handle closeFile];
                completion(nil);
                next = nil;
            } else {
                next();
            }
        }] resume];
    };

    next();
}
@end

static NSURL *YTLDownloadsDirectory(void) {
    NSURL *dir = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:@"YTLiteDownloads" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}


#pragma mark - Library

static NSURL *YTLLibraryDirectory(void) {
    NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [documents URLByAppendingPathComponent:@"YTModulation/Downloads" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:@{NSFileProtectionKey: NSFileProtectionNone} error:nil];
    return dir;
}

static NSDictionary *YTLDownloadMeta(YTPlayerViewController *player) {
    id details = YTLPlayerDetails(player);
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    meta[@"videoID"] = player.contentVideoID ?: YTLStringValue(details, @"videoId") ?: [NSUUID UUID].UUIDString;
    meta[@"title"] = YTLStringValue(details, @"title") ?: meta[@"videoID"];
    meta[@"channel"] = YTLStringValue(details, @"author") ?: @"";
    meta[@"duration"] = @(YTLLongValue(details, @"lengthSeconds"));
    meta[@"date"] = @([[NSDate date] timeIntervalSince1970]);
    return meta;
}

static NSArray <NSDictionary *> *YTLLibraryItems(void) {
    NSURL *dir = YTLLibraryDirectory();
    NSArray <NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dir includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray *items = [NSMutableArray array];
    for (NSURL *file in files) {
        if (![file.pathExtension isEqualToString:@"json"]) continue;
        NSDictionary *meta = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:file] ?: [NSData data] options:0 error:nil];
        if (![meta isKindOfClass:[NSDictionary class]]) continue;
        NSURL *media = [dir URLByAppendingPathComponent:meta[@"file"] ?: @""];
        if (![[NSFileManager defaultManager] fileExistsAtPath:media.path]) continue;
        NSMutableDictionary *item = [meta mutableCopy];
        item[@"mediaURL"] = media;
        item[@"metaURL"] = file;
        NSURL *thumb = [dir URLByAppendingPathComponent:meta[@"thumb"] ?: @""];
        if (meta[@"thumb"] && [[NSFileManager defaultManager] fileExistsAtPath:thumb.path]) item[@"thumbURL"] = thumb;
        [items addObject:item];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"] ?: @0];
    }];
    return items;
}

static NSURL *YTLStoreInLibrary(NSURL *file, NSDictionary *meta) {
    NSURL *dir = YTLLibraryDirectory();
    NSString *base = [NSString stringWithFormat:@"%@-%ld", YTLSafeFileName(meta[@"videoID"]), (long)[[NSDate date] timeIntervalSince1970]];
    NSURL *target = [dir URLByAppendingPathComponent:[base stringByAppendingPathExtension:file.pathExtension ?: @"mp4"]];
    if (![[NSFileManager defaultManager] moveItemAtURL:file toURL:target error:nil]) return nil;

    NSMutableDictionary *saved = [meta mutableCopy];
    saved[@"file"] = target.lastPathComponent;
    saved[@"audioOnly"] = @([file.pathExtension isEqualToString:@"m4a"]);
    NSString *thumbName = [base stringByAppendingPathExtension:@"jpg"];
    saved[@"thumb"] = thumbName;
    [[NSJSONSerialization dataWithJSONObject:saved options:0 error:nil] writeToURL:[dir URLByAppendingPathComponent:[base stringByAppendingPathExtension:@"json"]] atomically:YES];

    NSURL *thumbURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", meta[@"videoID"]]];
    if (thumbURL) {
        [[[NSURLSession sharedSession] dataTaskWithURL:thumbURL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data.length > 1000) [data writeToURL:[dir URLByAppendingPathComponent:thumbName] atomically:YES];
        }] resume];
    }
    return target;
}

static void YTLSaveToPhotos(NSURL *file, UIViewController *presenter) {
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized && status != (PHAuthorizationStatus)4) {
            dispatch_async(dispatch_get_main_queue(), ^{ [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"PhotosDenied") firstResponder:presenter] send]; });
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:file];
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(success ? @"SavedToPhotos" : @"DownloadFailed") firstResponder:presenter] send];
            });
        }];
    }];
}

static void YTLShareCopy(NSURL *file, UIViewController *presenter, UIView *source) {
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = source ?: presenter.view;
        activity.popoverPresentationController.sourceRect = source ? source.bounds : CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 0, 0);
    }
    [presenter presentViewController:activity animated:YES completion:nil];
}

static NSString *YTLDurationText(NSInteger seconds) {
    if (seconds <= 0) return @"";
    if (seconds >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(seconds / 3600), (long)((seconds / 60) % 60), (long)(seconds % 60)];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

static void YTLCompressVideo(NSURL *input, NSURL *output, void (^progress)(float value), void (^completion)(NSError *error)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:input options:nil];
        AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
        double duration = CMTimeGetSeconds(asset.duration);
#pragma clang diagnostic pop
        if (!videoTrack) {
            completion([NSError errorWithDomain:@"YTLite" code:10 userInfo:@{NSLocalizedDescriptionKey: @"video"}]);
            return;
        }

        AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
        [[NSFileManager defaultManager] removeItemAtURL:output error:nil];
        AVAssetWriter *writer = reader ? [AVAssetWriter assetWriterWithURL:output fileType:AVFileTypeMPEG4 error:&error] : nil;
        if (!reader || !writer) {
            completion(error ?: [NSError errorWithDomain:@"YTLite" code:11 userInfo:nil]);
            return;
        }
        writer.shouldOptimizeForNetworkUse = YES;

        CGSize size = videoTrack.naturalSize;
        double sourceRate = videoTrack.estimatedDataRate > 0 ? videoTrack.estimatedDataRate : 2500000;
        double targetRate = MAX(300000, sourceRate * 0.45);
        float fps = videoTrack.nominalFrameRate > 0 ? videoTrack.nominalFrameRate : 30;

        AVAssetReaderTrackOutput *videoOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)}];
        videoOutput.alwaysCopiesSampleData = NO;
        AVAssetWriterInput *videoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
            AVVideoCodecKey: AVVideoCodecTypeHEVC,
            AVVideoWidthKey: @((int)size.width),
            AVVideoHeightKey: @((int)size.height),
            AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @(targetRate), AVVideoExpectedSourceFrameRateKey: @(fps)}
        }];
        videoInput.expectsMediaDataInRealTime = NO;
        videoInput.transform = videoTrack.preferredTransform;
        if (![reader canAddOutput:videoOutput] || ![writer canAddInput:videoInput]) {
            completion([NSError errorWithDomain:@"YTLite" code:12 userInfo:@{NSLocalizedDescriptionKey: @"HEVC"}]);
            return;
        }
        [reader addOutput:videoOutput];
        [writer addInput:videoInput];

        AVAssetReaderTrackOutput *audioOutput = nil;
        AVAssetWriterInput *audioInput = nil;
        if (audioTrack) {
            const AudioStreamBasicDescription *asbd = NULL;
            id description = audioTrack.formatDescriptions.firstObject;
            if (description) asbd = CMAudioFormatDescriptionGetStreamBasicDescription((__bridge CMAudioFormatDescriptionRef)description);
            NSInteger channels = asbd && asbd->mChannelsPerFrame > 0 ? MIN((NSInteger)asbd->mChannelsPerFrame, 2) : 2;
            double sampleRate = asbd && asbd->mSampleRate > 0 ? asbd->mSampleRate : 44100;
            audioOutput = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:@{AVFormatIDKey: @(kAudioFormatLinearPCM), AVNumberOfChannelsKey: @(channels), AVSampleRateKey: @(sampleRate)}];
            audioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVNumberOfChannelsKey: @(channels), AVSampleRateKey: @(sampleRate), AVEncoderBitRateKey: @(channels > 1 ? 96000 : 64000)}];
            audioInput.expectsMediaDataInRealTime = NO;
            if ([reader canAddOutput:audioOutput] && [writer canAddInput:audioInput]) {
                [reader addOutput:audioOutput];
                [writer addInput:audioInput];
            } else {
                audioOutput = nil;
                audioInput = nil;
            }
        }

        if (![reader startReading] || ![writer startWriting]) {
            completion(writer.error ?: reader.error ?: [NSError errorWithDomain:@"YTLite" code:13 userInfo:nil]);
            return;
        }
        [writer startSessionAtSourceTime:kCMTimeZero];

        dispatch_group_t group = dispatch_group_create();
        dispatch_queue_t videoQueue = dispatch_queue_create("ytl.compress.video", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_t audioQueue = dispatch_queue_create("ytl.compress.audio", DISPATCH_QUEUE_SERIAL);

        dispatch_group_enter(group);
        __block BOOL videoDone = NO;
        [videoInput requestMediaDataWhenReadyOnQueue:videoQueue usingBlock:^{
            while (videoInput.isReadyForMoreMediaData && !videoDone) {
                CMSampleBufferRef buffer = [videoOutput copyNextSampleBuffer];
                if (!buffer) {
                    videoDone = YES;
                    [videoInput markAsFinished];
                    dispatch_group_leave(group);
                    break;
                }
                double time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer));
                BOOL appended = [videoInput appendSampleBuffer:buffer];
                CFRelease(buffer);
                if (progress && duration > 0) progress(MIN(time / duration, 1));
                if (!appended) {
                    videoDone = YES;
                    [videoInput markAsFinished];
                    dispatch_group_leave(group);
                    break;
                }
            }
        }];

        if (audioInput) {
            dispatch_group_enter(group);
            __block BOOL audioDone = NO;
            [audioInput requestMediaDataWhenReadyOnQueue:audioQueue usingBlock:^{
                while (audioInput.isReadyForMoreMediaData && !audioDone) {
                    CMSampleBufferRef buffer = [audioOutput copyNextSampleBuffer];
                    if (!buffer) {
                        audioDone = YES;
                        [audioInput markAsFinished];
                        dispatch_group_leave(group);
                        break;
                    }
                    BOOL appended = [audioInput appendSampleBuffer:buffer];
                    CFRelease(buffer);
                    if (!appended) {
                        audioDone = YES;
                        [audioInput markAsFinished];
                        dispatch_group_leave(group);
                        break;
                    }
                }
            }];
        }

        dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            if (reader.status == AVAssetReaderStatusFailed || writer.status == AVAssetWriterStatusFailed) {
                [reader cancelReading];
                [writer cancelWriting];
                completion(writer.error ?: reader.error ?: [NSError errorWithDomain:@"YTLite" code:14 userInfo:nil]);
                return;
            }
            [writer finishWritingWithCompletionHandler:^{
                completion(writer.status == AVAssetWriterStatusCompleted ? nil : (writer.error ?: [NSError errorWithDomain:@"YTLite" code:15 userInfo:nil]));
            }];
        });
    });
}

@interface YTLDownloadsViewController : UITableViewController
@property (nonatomic, copy) NSArray <NSDictionary *> *items;
@property (nonatomic, strong) NSMutableDictionary <NSString *, NSNumber *> *compressing;
@end

@implementation YTLDownloadsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"MyDownloads");
    self.compressing = [NSMutableDictionary dictionary];
    self.tableView.rowHeight = 84;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    [self updateBars];
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)updateBars {
    if (self.tableView.isEditing) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:LOC(@"SelectAll") style:UIBarButtonItemStylePlain target:self action:@selector(selectAll)];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(endSelection)];
        NSUInteger count = self.tableView.indexPathsForSelectedRows.count;
        UIBarButtonItem *compress = [[UIBarButtonItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ (%lu)", LOC(@"Compress"), (unsigned long)count] style:UIBarButtonItemStylePlain target:self action:@selector(compressSelected)];
        UIBarButtonItem *remove = [[UIBarButtonItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ (%lu)", LOC(@"Delete"), (unsigned long)count] style:UIBarButtonItemStylePlain target:self action:@selector(deleteSelected)];
        remove.tintColor = [UIColor systemRedColor];
        compress.enabled = remove.enabled = count > 0;
        UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
        self.toolbarItems = @[compress, flex, remove];
        [self.navigationController setToolbarHidden:NO animated:YES];
    } else {
        self.navigationItem.leftBarButtonItem = nil;
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
        self.toolbarItems = nil;
        [self.navigationController setToolbarHidden:YES animated:YES];
    }
}

- (void)reload {
    self.items = YTLLibraryItems();
    UILabel *empty = nil;
    if (self.items.count == 0) {
        empty = [UILabel new];
        empty.text = LOC(@"NoDownloads");
        empty.textAlignment = NSTextAlignmentCenter;
        empty.numberOfLines = 0;
        empty.textColor = [UIColor secondaryLabelColor];
    }
    self.tableView.backgroundView = empty;
    [self.tableView reloadData];
    if (self.tableView.isEditing && self.items.count == 0) [self endSelection];
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)beginSelectionWithItem:(NSIndexPath *)indexPath {
    [self.tableView setEditing:YES animated:YES];
    if (indexPath && indexPath.row < (NSInteger)self.items.count) [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    [self updateBars];
}

- (void)endSelection {
    [self.tableView setEditing:NO animated:YES];
    [self updateBars];
}

- (void)selectAll {
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0] animated:NO scrollPosition:UITableViewScrollPositionNone];
    [self updateBars];
}

- (NSArray <NSDictionary *> *)selectedItems {
    NSMutableArray *selected = [NSMutableArray array];
    for (NSIndexPath *indexPath in self.tableView.indexPathsForSelectedRows) {
        if (indexPath.row < (NSInteger)self.items.count) [selected addObject:self.items[indexPath.row]];
    }
    return selected;
}

- (void)deleteSelected {
    for (NSDictionary *item in [self selectedItems]) [self removeFiles:item];
    [self endSelection];
    [self reload];
}

- (void)compressSelected {
    NSArray <NSDictionary *> *selected = [self selectedItems];
    [self endSelection];
    for (NSDictionary *item in selected) [self compressItem:item];
}

- (void)compressItem:(NSDictionary *)item {
    NSString *key = [item[@"mediaURL"] lastPathComponent];
    if ([item[@"audioOnly"] boolValue] || [item[@"compressed"] boolValue] || self.compressing[key]) return;
    self.compressing[key] = @0;
    [self.tableView reloadData];

    NSURL *input = item[@"mediaURL"];
    NSURL *temp = [[input URLByDeletingPathExtension] URLByAppendingPathExtension:@"compressing.mp4"];
    __block UIBackgroundTaskIdentifier task = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    }];
    __weak YTLDownloadsViewController *weakSelf = self;
    YTLCompressVideo(input, temp, ^(float value) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTLDownloadsViewController *strongSelf = weakSelf;
            NSInteger percent = (NSInteger)(value * 100);
            if (!strongSelf || [strongSelf.compressing[key] integerValue] == percent) return;
            strongSelf.compressing[key] = @(percent);
            [strongSelf refreshRowForKey:key];
        });
    }, ^(NSError *error) {
        NSFileManager *fm = [NSFileManager defaultManager];
        long long before = [[fm attributesOfItemAtPath:input.path error:nil][NSFileSize] longLongValue];
        long long after = [[fm attributesOfItemAtPath:temp.path error:nil][NSFileSize] longLongValue];
        BOOL useful = !error && after > 0 && after < before;
        if (useful) {
            [fm removeItemAtURL:input error:nil];
            [fm moveItemAtURL:temp toURL:input error:nil];
            NSMutableDictionary *meta = [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:item[@"metaURL"]] ?: [NSData data] options:0 error:nil] mutableCopy] ?: [NSMutableDictionary dictionary];
            meta[@"compressed"] = @YES;
            meta[@"originalSize"] = @(before);
            [[NSJSONSerialization dataWithJSONObject:meta options:0 error:nil] writeToURL:item[@"metaURL"] atomically:YES];
        } else {
            [fm removeItemAtURL:temp error:nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            YTLDownloadsViewController *strongSelf = weakSelf;
            [strongSelf.compressing removeObjectForKey:key];
            [strongSelf reload];
            NSString *message = useful ? [NSString stringWithFormat:LOC(@"CompressDone"), [NSByteCountFormatter stringFromByteCount:before - after countStyle:NSByteCountFormatterCountStyleFile]] : LOC(error ? @"CompressFailed" : @"CompressUseless");
            UIViewController *responder = strongSelf.navigationController.presentingViewController;
            if (responder) [[YTLClass(@"YTToastResponderEvent") eventWithMessage:message firstResponder:responder] send];
            if (task != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:task];
                task = UIBackgroundTaskInvalid;
            }
        });
    });
}

- (void)refreshRowForKey:(NSString *)key {
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        if ([[self.items[i][@"mediaURL"] lastPathComponent] isEqualToString:key]) {
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]];
            if (cell) cell.detailTextLabel.text = [self detailForItem:self.items[i]];
        }
    }
}

- (NSString *)detailForItem:(NSDictionary *)item {
    NSString *key = [item[@"mediaURL"] lastPathComponent];
    if (self.compressing[key]) return [NSString stringWithFormat:LOC(@"Compressing"), (long)[self.compressing[key] integerValue]];
    NSMutableArray *parts = [NSMutableArray array];
    if ([item[@"channel"] length]) [parts addObject:item[@"channel"]];
    NSString *duration = YTLDurationText([item[@"duration"] integerValue]);
    if (duration.length) [parts addObject:duration];
    NSNumber *size = [[NSFileManager defaultManager] attributesOfItemAtPath:[item[@"mediaURL"] path] error:nil][NSFileSize];
    if (size) [parts addObject:[NSByteCountFormatter stringFromByteCount:size.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];
    if ([item[@"compressed"] boolValue]) [parts addObject:LOC(@"Compressed")];
    if ([item[@"audioOnly"] boolValue]) [parts addObject:@"M4A"];
    return [parts componentsJoinedByString:@" · "];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"item"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"item"];
    NSDictionary *item = self.items[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    cell.detailTextLabel.text = [self detailForItem:item];
    cell.detailTextLabel.textColor = [item[@"compressed"] boolValue] ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
    UIImage *thumb = item[@"thumbURL"] ? [UIImage imageWithContentsOfFile:[item[@"thumbURL"] path]] : nil;
    CGSize box = CGSizeMake(104, 58);
    cell.imageView.image = [[[UIGraphicsImageRenderer alloc] initWithSize:box] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, box} cornerRadius:8] addClip];
        [[UIColor tertiarySystemFillColor] setFill];
        UIRectFill((CGRect){CGPointZero, box});
        if (thumb) {
            CGFloat scale = MAX(box.width / thumb.size.width, box.height / thumb.size.height);
            CGSize drawn = CGSizeMake(thumb.size.width * scale, thumb.size.height * scale);
            [thumb drawInRect:CGRectMake((box.width - drawn.width) / 2, (box.height - drawn.height) / 2, drawn.width, drawn.height)];
        }
    }];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) {
        [self updateBars];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.items[indexPath.row];
    if (self.compressing[[item[@"mediaURL"] lastPathComponent]]) return;
    AVPlayerViewController *playerController = [AVPlayerViewController new];
    playerController.player = [AVPlayer playerWithURL:item[@"mediaURL"]];
    [self presentViewController:playerController animated:YES completion:^{ [playerController.player play]; }];
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) [self updateBars];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (tableView.isEditing) return nil;
    NSDictionary *item = self.items[indexPath.row];
    __weak YTLDownloadsViewController *weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:LOC(@"Delete") handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
        [weakSelf removeFiles:item];
        [weakSelf reload];
        completion(YES);
    }];
    remove.image = [UIImage systemImageNamed:@"trash"];
    UIContextualAction *select = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:LOC(@"Select") handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
        completion(YES);
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf beginSelectionWithItem:indexPath]; });
    }];
    select.image = [UIImage systemImageNamed:@"checkmark.circle"];
    select.backgroundColor = [UIColor systemBlueColor];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove, select]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [UISwipeActionsConfiguration configurationWithActions:@[]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (tableView.isEditing) return nil;
    NSDictionary *item = self.items[indexPath.row];
    __weak YTLDownloadsViewController *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray <UIMenuElement *> *suggested) {
        NSMutableArray *actions = [NSMutableArray array];
        if (![item[@"audioOnly"] boolValue]) {
            [actions addObject:[UIAction actionWithTitle:LOC(@"SaveToPhotos") image:[UIImage systemImageNamed:@"photo.on.rectangle"] identifier:nil handler:^(UIAction *action) {
                YTLSaveToPhotos(item[@"mediaURL"], weakSelf.navigationController.presentingViewController ?: weakSelf);
            }]];
            if (![item[@"compressed"] boolValue]) {
                [actions addObject:[UIAction actionWithTitle:LOC(@"Compress") image:[UIImage systemImageNamed:@"arrow.down.right.and.arrow.up.left"] identifier:nil handler:^(UIAction *action) {
                    [weakSelf compressItem:item];
                }]];
            }
        }
        [actions addObject:[UIAction actionWithTitle:LOC(@"Share") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action) {
            YTLShareCopy(item[@"mediaURL"], weakSelf, [tableView cellForRowAtIndexPath:indexPath]);
        }]];
        [actions addObject:[UIAction actionWithTitle:LOC(@"Select") image:[UIImage systemImageNamed:@"checkmark.circle"] identifier:nil handler:^(UIAction *action) {
            [weakSelf beginSelectionWithItem:indexPath];
        }]];
        UIAction *remove = [UIAction actionWithTitle:LOC(@"Delete") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
            [weakSelf removeFiles:item];
            [weakSelf reload];
        }];
        remove.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:remove];
        return [UIMenu menuWithTitle:@"" children:actions];
    }];
}

- (void)removeFiles:(NSDictionary *)item {
    for (NSString *key in @[@"mediaURL", @"metaURL", @"thumbURL"]) {
        if (item[key]) [[NSFileManager defaultManager] removeItemAtURL:item[key] error:nil];
    }
}

@end

void YTLPresentDownloadsLibrary(void) {
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    if (!presenter) return;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[YTLDownloadsViewController new]];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [presenter presentViewController:navigation animated:YES completion:nil];
}

static void YTLAfterDownload(NSURL *stored, UIViewController *presenter) {
    YTDefaultSheetController *sheet = [YTLClass(@"YTDefaultSheetController") sheetControllerWithParentResponder:nil];
    UIViewController *top = [YTLClass(@"YTUIUtils") topViewControllerForPresenting] ?: presenter;
    if (!sheet || !top) return;
    [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"OpenMyDownloads") iconImage:[UIImage systemImageNamed:@"arrow.down.circle"] style:0 handler:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ YTLPresentDownloadsLibrary(); });
    }]];
    if (![stored.pathExtension isEqualToString:@"m4a"]) {
        [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"SaveToPhotos") iconImage:[UIImage systemImageNamed:@"photo.on.rectangle"] style:0 handler:^{
            YTLSaveToPhotos(stored, top);
        }]];
    }
    [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"Share") iconImage:[UIImage systemImageNamed:@"square.and.arrow.up"] style:0 handler:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTLShareCopy(stored, [YTLClass(@"YTUIUtils") topViewControllerForPresenting] ?: top, nil);
        });
    }]];
    [sheet presentFromViewController:top animated:YES completion:nil];
    [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"DownloadSaved") firstResponder:top] send];
}

static void YTLShareFile(NSURL *file, UIViewController *presenter) {
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    activity.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
        if (completed || !type) [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
    };
    if (activity.popoverPresentationController) {
        activity.popoverPresentationController.sourceView = presenter.view;
        activity.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(presenter.view.bounds), CGRectGetMidY(presenter.view.bounds), 0, 0);
        activity.popoverPresentationController.permittedArrowDirections = 0;
    }
    [presenter presentViewController:activity animated:YES completion:nil];
}

static void YTLFinish(YTLDownloadTask *task, UIViewController *presenter, NSURL *file, NSError *error, NSDictionary *meta) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [task.alert dismissViewControllerAnimated:YES completion:^{
            if (error) {
                if (error.code != NSUserCancelledError) {
                    NSString *message = [NSString stringWithFormat:@"%@: %@", LOC(@"DownloadFailed"), error.localizedDescription ?: @"?"];
                    [[YTLClass(@"YTToastResponderEvent") eventWithMessage:message firstResponder:presenter] send];
                }
                return;
            }
            NSURL *stored = meta ? YTLStoreInLibrary(file, meta) : nil;
            if (stored) YTLAfterDownload(stored, presenter);
            else YTLShareFile(file, presenter);
        }];
    });
}

static void YTLMux(NSURL *videoFile, NSURL *audioFile, NSURL *output, void (^completion)(NSError *error)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVURLAsset *video = [AVURLAsset URLAssetWithURL:videoFile options:nil];
    AVURLAsset *audio = [AVURLAsset URLAssetWithURL:audioFile options:nil];
    AVAssetTrack *videoTrack = [[video tracksWithMediaType:AVMediaTypeVideo] firstObject];
    AVAssetTrack *audioTrack = [[audio tracksWithMediaType:AVMediaTypeAudio] firstObject];
#pragma clang diagnostic pop

    if (!videoTrack || !audioTrack) {
        completion([NSError errorWithDomain:@"YTLite" code:2 userInfo:@{NSLocalizedDescriptionKey: @"tracks"}]);
        return;
    }

    AVMutableComposition *composition = [AVMutableComposition composition];
    NSError *error = nil;
    CMTime duration = CMTimeMinimum(video.duration, audio.duration);
    CMTimeRange range = CMTimeRangeMake(kCMTimeZero, CMTIME_IS_VALID(duration) && CMTimeGetSeconds(duration) > 0 ? duration : video.duration);

    AVMutableCompositionTrack *compVideo = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    [compVideo insertTimeRange:range ofTrack:videoTrack atTime:kCMTimeZero error:&error];
    compVideo.preferredTransform = videoTrack.preferredTransform;
    if (!error) {
        AVMutableCompositionTrack *compAudio = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
        [compAudio insertTimeRange:range ofTrack:audioTrack atTime:kCMTimeZero error:&error];
    }
    if (error) {
        completion(error);
        return;
    }

    [[NSFileManager defaultManager] removeItemAtURL:output error:nil];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
    export.outputURL = output;
    export.outputFileType = AVFileTypeMPEG4;
    export.shouldOptimizeForNetworkUse = YES;
    [export exportAsynchronouslyWithCompletionHandler:^{
        completion(export.status == AVAssetExportSessionStatusCompleted ? nil : (export.error ?: [NSError errorWithDomain:@"YTLite" code:3 userInfo:@{NSLocalizedDescriptionKey: @"export"}]));
    }];
}

static YTLDownloadTask *YTLStartTask(UIViewController *presenter) {
    YTLDownloadTask *task = [YTLDownloadTask new];
    task.status = LOC(@"Downloading");
    task.alert = [UIAlertController alertControllerWithTitle:LOC(@"Download") message:@"…" preferredStyle:UIAlertControllerStyleAlert];
    __weak YTLDownloadTask *weakTask = task;
    [task.alert addAction:[UIAlertAction actionWithTitle:LOC(@"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        weakTask.cancelled = YES;
    }]];
    [presenter presentViewController:task.alert animated:YES completion:nil];
    objc_setAssociatedObject(task.alert, @selector(YTLStartTask), task, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return task;
}

static void YTLDownloadVideo(YTPlayerViewController *player, id videoFormat, UIViewController *presenter) {
    id audioFormat = YTLAudioFormat(player);
    NSURL *videoURL = YTLFormatURL(videoFormat), *audioURL = YTLFormatURL(audioFormat);
    if (!videoURL || !audioURL) {
        [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"StreamUnavailable") firstResponder:presenter] send];
        return;
    }

    NSString *name = YTLSafeFileName(YTLStringValue(YTLPlayerDetails(player), @"title") ?: player.contentVideoID);
    NSURL *dir = YTLDownloadsDirectory();
    NSDictionary *meta = YTLDownloadMeta(player);
    NSURL *videoFile = [dir URLByAppendingPathComponent:@"video.part.mp4"];
    NSURL *audioFile = [dir URLByAppendingPathComponent:@"audio.part.m4a"];
    NSURL *output = [dir URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"mp4"]];

    YTLDownloadTask *task = YTLStartTask(presenter);
    long long videoLength = YTLFormatLength(videoFormat), audioLength = YTLFormatLength(audioFormat);
    task.totalBytes = videoLength + audioLength;

    void (^cleanup)(void) = ^{
        [[NSFileManager defaultManager] removeItemAtURL:videoFile error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:audioFile error:nil];
    };

    [task downloadURL:videoURL length:videoLength to:videoFile completion:^(NSError *error) {
        if (error) { cleanup(); YTLFinish(task, presenter, nil, error, nil); return; }
        [task downloadURL:audioURL length:audioLength to:audioFile completion:^(NSError *error) {
            if (error) { cleanup(); YTLFinish(task, presenter, nil, error, nil); return; }
            task.status = LOC(@"Saving");
            [task updateProgress];
            YTLMux(videoFile, audioFile, output, ^(NSError *error) {
                cleanup();
                YTLFinish(task, presenter, output, error, meta);
            });
        }];
    }];
}

static void YTLDownloadAudio(YTPlayerViewController *player, UIViewController *presenter) {
    id audioFormat = YTLAudioFormat(player);
    NSURL *audioURL = YTLFormatURL(audioFormat);
    if (!audioURL) {
        [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"StreamUnavailable") firstResponder:presenter] send];
        return;
    }

    NSString *name = YTLSafeFileName(YTLStringValue(YTLPlayerDetails(player), @"title") ?: player.contentVideoID);
    NSURL *output = [YTLDownloadsDirectory() URLByAppendingPathComponent:[name stringByAppendingPathExtension:@"m4a"]];
    NSDictionary *meta = YTLDownloadMeta(player);
    YTLDownloadTask *task = YTLStartTask(presenter);
    task.totalBytes = YTLFormatLength(audioFormat);

    [task downloadURL:audioURL length:task.totalBytes to:output completion:^(NSError *error) {
        if (error) [[NSFileManager defaultManager] removeItemAtURL:output error:nil];
        YTLFinish(task, presenter, output, error, meta);
    }];
}

static void YTLDownloadThumbnail(NSString *videoID, UIViewController *presenter) {
    NSArray *names = @[@"maxresdefault.jpg", @"sddefault.jpg", @"hqdefault.jpg"];
    __block void (^attempt)(NSUInteger);
    attempt = ^(NSUInteger index) {
        if (index >= names.count) {
            [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"DownloadFailed") firstResponder:presenter] send];
            attempt = nil;
            return;
        }
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/%@", videoID, names[index]]];
        [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            UIImage *image = data ? [UIImage imageWithData:data] : nil;
            NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (!image || status != 200 || image.size.width <= 120) {
                attempt(index + 1);
                return;
            }
            [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                [[PHAssetCreationRequest creationRequestForAsset] addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
            } completionHandler:^(BOOL success, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSString *message = success ? LOC(@"Saved") : [NSString stringWithFormat:@"%@: %@", LOC(@"Error"), error.localizedDescription ?: @"?"];
                    [[YTLClass(@"YTToastResponderEvent") eventWithMessage:message firstResponder:presenter] send];
                });
            }];
            attempt = nil;
        }] resume];
    };
    attempt(0);
}

static YTPlayerViewController *YTLDownloadTarget(void) {
    YTPlayerViewController *watch = ytlWatchPlayer, *shorts = ytlShortsPlayer;
    BOOL shortsVisible = shorts.view.window != nil;
    if (shortsVisible && (!watch.view.window || ytlShortsTick > ytlWatchTick)) return shorts;
    return watch ?: shorts;
}

static BOOL YTLShortsOnScreen(void) {
    YTPlayerViewController *shorts = ytlShortsPlayer;
    return shorts.view.window && YTLDownloadTarget() == shorts;
}

void YTLPresentDownloadMenu(UIViewController *presenter) {
    YTPlayerViewController *player = YTLDownloadTarget();
    NSString *videoID = player.contentVideoID;
    if (!player || !videoID.length || !presenter) {
        [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"StreamUnavailable") firstResponder:presenter] send];
        return;
    }

    YTDefaultSheetController *sheet = [YTLClass(@"YTDefaultSheetController") sheetControllerWithParentResponder:nil];

    for (id format in YTLVideoFormats(player)) {
        NSString *title = [NSString stringWithFormat:@"%@ %@", LOC(@"DownloadVideo"), YTLStringValue(format, @"qualityLabel")];
        [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:title iconImage:YTLIcon(@"yt_outline_download_24pt") style:0 handler:^{
            YTLDownloadVideo(player, format, presenter);
        }]];
    }

    [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"DownloadAudio") iconImage:YTLIcon(@"yt_outline_audio_24pt") style:0 handler:^{
        YTLDownloadAudio(player, presenter);
    }]];

    [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"DownloadThumbnail") iconImage:YTLIcon(@"yt_outline_image_24pt") style:0 handler:^{
        YTLDownloadThumbnail(videoID, presenter);
    }]];

    [sheet addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"MyDownloads") iconImage:[UIImage systemImageNamed:@"arrow.down.circle"] style:0 handler:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ YTLPresentDownloadsLibrary(); });
    }]];

    [sheet presentFromViewController:presenter animated:YES completion:nil];
}

static BOOL YTLIsShortsPlayer(YTPlayerViewController *player) {
    for (UIView *view = player.view.superview; view; view = view.superview) {
        NSString *name = NSStringFromClass([view class]);
        if ([name rangeOfString:@"Reel"].location != NSNotFound || [name rangeOfString:@"Shorts"].location != NSNotFound) return YES;
    }
    return NO;
}

static void YTLTrackPlayer(YTPlayerViewController *player) {
    if (!player.view.window || [YTLValue(player, @"isPlayingAd") boolValue]) return;
    if ([player.view.superview isKindOfClass:NSClassFromString(@"YTWatchView")]) {
        ytlWatchPlayer = player;
        ytlWatchTick = CACurrentMediaTime();
    } else if (YTLIsShortsPlayer(player)) {
        ytlShortsPlayer = player;
        ytlShortsTick = CACurrentMediaTime();
    }
}

%hook YTPlayerViewController
- (void)potentiallyMutatedSingleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    YTLTrackPlayer(self);
}

- (void)singleVideo:(YTSingleVideoController *)video currentVideoTimeDidChange:(YTSingleVideoTime *)time { // legacy
    %orig;
    YTLTrackPlayer(self);
}
%end

%hook YTEngagementPanelView
- (void)layoutSubviews {
    %orig;

    if (!ytlBool(@"downloadButton") || !self.headerView || [self.headerView viewWithTag:kDownloadButtonTag]) return;
    NSString *panelID = self.panelIdentifier.identifierString;
    if (![panelID isKindOfClass:[NSString class]] || [panelID rangeOfString:@"description"].location == NSNotFound) return;

    YTQTMButton *button = [YTLClass(@"YTQTMButton") iconButton];
    if (!button) return;
    button.tag = kDownloadButtonTag;
    button.accessibilityLabel = LOC(@"Download");
    if ([button respondsToSelector:@selector(enableNewTouchFeedback)]) [button enableNewTouchFeedback];
    [button setImage:YTLIcon(@"yt_outline_download_24pt") forState:UIControlStateNormal];
    [button setTintColor:[UIColor labelColor]];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button addTarget:self action:@selector(ytl_didTapDownload:) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:button];

    CGFloat offset = ytlBool(@"copyVideoInfo") ? -88 : -48;
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:self.headerView.trailingAnchor constant:offset],
        [button.centerYAnchor constraintEqualToAnchor:self.headerView.centerYAnchor],
        [button.widthAnchor constraintEqualToConstant:40.0],
        [button.heightAnchor constraintEqualToConstant:40.0]
    ]];
}

%new
- (void)ytl_didTapDownload:(UIButton *)sender {
    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    YTLPresentDownloadMenu(presenter);
}
%end

static BOOL YTLHandleNativeDownload(id command) {
    if (!ytlBool(@"downloadButton")) return NO;
    NSString *videoID = nil;
    @try {
        id endpoint = YTLValue(command, @"offlineVideoEndpoint");
        videoID = YTLStringValue(endpoint, @"videoId");
    } @catch (NSException *exception) {}

    UIViewController *presenter = [YTLClass(@"YTUIUtils") topViewControllerForPresenting];
    YTPlayerViewController *player = YTLDownloadTarget();
    dispatch_async(dispatch_get_main_queue(), ^{
        if (videoID.length && player && ![player.contentVideoID isEqualToString:videoID]) {
            [[YTLClass(@"YTToastResponderEvent") eventWithMessage:LOC(@"OpenVideoToDownload") firstResponder:presenter] send];
            return;
        }
        YTLPresentDownloadMenu(presenter);
    });
    return YES;
}

%hook YTOfflineVideoEndpointCommandHandlerImpl
- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)view sender:(id)sender completionBlock:(id)completion {
    if (!YTLHandleNativeDownload(command)) %orig;
}

- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)view sender:(id)sender {
    if (!YTLHandleNativeDownload(command)) %orig;
}
%end

%hook YTYPCGetOfflineUpsellEndpointCommandHandlerImpl
- (void)executeWithCommand:(id)command entry:(id)entry fromView:(id)view sender:(id)sender {
    if (!YTLHandleNativeDownload(command)) %orig;
}
%end

static const char kYTLDownloadSheetKey;

%hook YTDefaultSheetController
- (void)presentFromViewController:(UIViewController *)controller animated:(BOOL)animated completion:(id)completion {
    @try {
        if (ytlBool(@"downloadButton") && !objc_getAssociatedObject(self, &kYTLDownloadSheetKey) && YTLShortsOnScreen()) {
            BOOL videoMenu = NO;
            NSArray *actions = [self respondsToSelector:@selector(actions)] ? [self performSelector:@selector(actions)] : nil;
            for (id action in [actions isKindOfClass:[NSArray class]] ? actions : @[]) {
                id identifier = YTLValue(action, @"_accessibilityIdentifier");
                if ([identifier isKindOfClass:[NSString class]] && [@[@"1", @"3", @"5", @"12", @"31", @"58"] containsObject:identifier]) {
                    videoMenu = YES;
                    break;
                }
            }
            if (videoMenu) {
                objc_setAssociatedObject(self, &kYTLDownloadSheetKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                [self addAction:[YTLClass(@"YTActionSheetAction") actionWithTitle:LOC(@"Download") iconImage:YTLIcon(@"yt_outline_download_24pt") style:0 handler:^{
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        YTLPresentDownloadMenu([YTLClass(@"YTUIUtils") topViewControllerForPresenting]);
                    });
                }]];
            }
        }
    } @catch (NSException *exception) {}
    %orig;
}
%end

%ctor {
    if (YTLSafeModeActive()) return;
    %init;
}
