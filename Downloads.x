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

@interface YTLDownloadsViewController : UITableViewController
@property (nonatomic, copy) NSArray <NSDictionary *> *items;
@end

@implementation YTLDownloadsViewController

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = LOC(@"MyDownloads");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.tableView.rowHeight = 78;
    [self reload];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
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
}

- (void)done {
    [self dismissViewControllerAnimated:YES completion:nil];
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
    NSMutableArray *parts = [NSMutableArray array];
    if ([item[@"channel"] length]) [parts addObject:item[@"channel"]];
    NSString *duration = YTLDurationText([item[@"duration"] integerValue]);
    if (duration.length) [parts addObject:duration];
    NSNumber *size = [[NSFileManager defaultManager] attributesOfItemAtPath:[item[@"mediaURL"] path] error:nil][NSFileSize];
    if (size) [parts addObject:[NSByteCountFormatter stringFromByteCount:size.longLongValue countStyle:NSByteCountFormatterCountStyleFile]];
    if ([item[@"audioOnly"] boolValue]) [parts addObject:@"M4A"];
    cell.detailTextLabel.text = [parts componentsJoinedByString:@" · "];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    UIImage *thumb = item[@"thumbURL"] ? [UIImage imageWithContentsOfFile:[item[@"thumbURL"] path]] : nil;
    CGSize size2 = CGSizeMake(96, 54);
    cell.imageView.image = [[[UIGraphicsImageRenderer alloc] initWithSize:size2] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, size2} cornerRadius:8] addClip];
        [[UIColor tertiarySystemFillColor] setFill];
        UIRectFill((CGRect){CGPointZero, size2});
        if (thumb) {
            CGFloat scale = MAX(size2.width / thumb.size.width, size2.height / thumb.size.height);
            CGSize drawn = CGSizeMake(thumb.size.width * scale, thumb.size.height * scale);
            [thumb drawInRect:CGRectMake((size2.width - drawn.width) / 2, (size2.height - drawn.height) / 2, drawn.width, drawn.height)];
        }
    }];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.items[indexPath.row];
    AVPlayerViewController *playerController = [AVPlayerViewController new];
    playerController.player = [AVPlayer playerWithURL:item[@"mediaURL"]];
    [self presentViewController:playerController animated:YES completion:^{ [playerController.player play]; }];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    NSDictionary *item = self.items[indexPath.row];
    __weak YTLDownloadsViewController *weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray <UIMenuElement *> *suggested) {
        NSMutableArray *actions = [NSMutableArray array];
        if (![item[@"audioOnly"] boolValue]) {
            [actions addObject:[UIAction actionWithTitle:LOC(@"SaveToPhotos") image:[UIImage systemImageNamed:@"photo.on.rectangle"] identifier:nil handler:^(UIAction *action) {
                YTLSaveToPhotos(item[@"mediaURL"], weakSelf);
            }]];
        }
        [actions addObject:[UIAction actionWithTitle:LOC(@"Share") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(UIAction *action) {
            YTLShareCopy(item[@"mediaURL"], weakSelf, [tableView cellForRowAtIndexPath:indexPath]);
        }]];
        UIAction *remove = [UIAction actionWithTitle:LOC(@"Delete") image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
            [weakSelf deleteItem:item];
        }];
        remove.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:remove];
        return [UIMenu menuWithTitle:@"" children:actions];
    }];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.items[indexPath.row];
    __weak YTLDownloadsViewController *weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:LOC(@"Delete") handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
        [weakSelf deleteItem:item];
        completion(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}

- (void)deleteItem:(NSDictionary *)item {
    for (NSString *key in @[@"mediaURL", @"metaURL", @"thumbURL"]) {
        if (item[key]) [[NSFileManager defaultManager] removeItemAtURL:item[key] error:nil];
    }
    [self reload];
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
