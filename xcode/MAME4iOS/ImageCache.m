//
//  ImageCache.m
//  MAME4iOS
//
//  Created by Todd Laney on 10/20/19.
//

#import "ImageCache.h"

#define ImageCacheDebug 0
#if !ImageCacheDebug
#define NSLog(...) (void)0
#endif

#if !__has_feature(objc_arc)
#error("This file assumes ARC")
#endif

#define ERROR_RETRY_TIME (1.0 * 60.0)   // retry again after this amount...

@implementation ImageCache
{
    NSCache* cache;
    NSMutableDictionary* task_dict;
}

static ImageCache* sharedInstance = nil;

+(ImageCache*) sharedInstance
{
    NSParameterAssert([NSThread isMainThread]);
    if (sharedInstance == nil)
        sharedInstance = [[ImageCache alloc] init];
    return sharedInstance;
}

-(id)init
{
    if ((self = [super init]))
    {
        cache = [[NSCache alloc] init];
        task_dict = [[NSMutableDictionary alloc] init];
    }
    return self;
}

-(void)dealloc
{
    if (sharedInstance == self)
        sharedInstance = nil;
}

- (void)flush
{    
    [cache removeAllObjects];
}

- (void)getData:(NSURL*)url localURL:(NSURL*)localURL completionHandler:(void (^)(NSData* data, NSError* error))handler
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        if (localURL != nil && ImageCacheDebug == 0)
        {
            NSData* data = [NSData dataWithContentsOfURL:localURL];
            
            if (data != nil)
                return handler(data, nil);
        }
        
        if (url == nil)
            return handler(nil, nil);
        
        NSURLSession* session = [NSURLSession sharedSession];
        NSURLRequest* request = [NSURLRequest requestWithURL:url];
        
#if ImageCacheDebug
        // randomly force a timeout to test code....
        if (arc4random_uniform(10) == 0) {
            NSLog(@"TESTING A NETWORK ERROR: %@", url);
            request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"http://www.example.com:81/wombat.png"]];
        }
#endif
        NSURLSessionDataTask* task = [session dataTaskWithRequest:request
            completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {

            NSInteger status = [(NSHTTPURLResponse*)response statusCode];

            if (error != nil)
                NSLog(@"GET DATA\n\tURL:%@\n\tERROR:%@", url, error);

            if (status != 200)
            {
                NSLog(@"GET DATA: BAD RESPONSE (%d)\n\tURL:%@\n\tBODY:%@",
                      (int)status, url, [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                data = nil;
            }

            if (localURL != nil && data != nil && error == nil)
                [data writeToURL:localURL atomically:YES];

            handler(data, error);
        }];
        [task resume];
        dispatch_async(dispatch_get_main_queue(), ^{
            NSParameterAssert([NSThread isMainThread]);
            self->task_dict[url] = task;
        });
    });
}

- (void)getImage:(NSURL*)url size:(CGSize)size localURL:(NSURL*)localURL completionHandler:(ImageCacheCallback)handler;
{
    NSParameterAssert([NSThread isMainThread]);
    NSParameterAssert(handler != nil);
    NSParameterAssert(localURL == nil || [localURL isFileURL]);

    NSLog(@"IMAGE CACHE: getImage: %@ [%f,%f]", url.path, size.width, size.height);
    
    NSString* key = [NSString stringWithFormat:@"%@[%f,%f]", url.path, size.width, size.height];
    id val = [cache objectForKey:key];
    
    if ([val isKindOfClass:[UIImage class]])
    {
        NSLog(@"....IMAGE CACHE HIT");
        return handler(val);
    }
    
    if ([val isKindOfClass:[NSDate class]])
    {
        if ([((NSDate*)val) timeIntervalSinceNow] > (-1.0 * ERROR_RETRY_TIME))
        {
            NSLog(@"....IMAGE LOAD ERROR: NIL");
            return handler(nil);
        }
        NSLog(@"....IMAGE LOAD ERROR: RETRY");
        val = nil;
    }
    
    if ([val isKindOfClass:[NSNull class]])
    {
        NSLog(@"....IMAGE CACHE NULL");
        return handler(nil);
    }

    if ([val isKindOfClass:[NSMutableArray class]])
    {
        NSLog(@"....IMAGE CACHE LOADING");
        return [val addObject:handler];
    }
    
    // if we have a local copy on disk, and we dont need to resize, get the image synchronously.
    // this prevents showing default icons unless we need to go to the net, at expense of a little scrolling perf.
    if (localURL != nil && (size.width == 0 && size.height == 0) && ImageCacheDebug == 0)
    {
        if ([[NSFileManager defaultManager] fileExistsAtPath:localURL.path])
        {
            NSLog(@"....IMAGE LOCAL CACHE HIT");
            UIImage* image = [UIImage imageWithData:[NSData dataWithContentsOfURL:localURL]];
            [cache setObject:(image ?: [NSNull null]) forKey:key];
            return handler(image);
        }
    }
    
    NSLog(@"....IMAGE CACHE MISS");
    NSParameterAssert(val == nil);
    [cache setObject:[NSMutableArray arrayWithObject:handler] forKey:key];
    
    [self getData:url localURL:localURL completionHandler:^(NSData *data, NSError* error) {
        NSLog(@"IMAGE CACHE DATA: %d bytes", (int)[data length]);
        UIImage* image = [UIImage imageWithData:data];
        NSLog(@"IMAGE IMAGE: %@", image);
        image = [image scaledToSize:size];
        NSLog(@"IMAGE SCALE IMAGE: %@", image);

#if ImageCacheDebug
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, arc4random_uniform(5000) * USEC_PER_SEC), dispatch_get_main_queue(), ^{
#else
        dispatch_async(dispatch_get_main_queue(), ^{
#endif
            self->task_dict[url] = nil;
            NSArray* callbacks = [self->cache objectForKey:key];

            if (image == nil && error != nil && [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
                NSLog(@"IMAGE LOAD CANCELED: %@ [%d clients]", url.lastPathComponent, (int)[callbacks count]);
                [self->cache removeObjectForKey:key];
            }
            else {
                //  * if we got an error, put the current date in the cache
                //    so we will try again later (after a while)
                //
                //  * if we got an image, put that in the cache, success!
                //
                //  * if we got a nil image, but no error, the url must not exist (404)
                //    or be a bad image. put a NSNull in the cache.
                //
                if (image == nil && error != nil)
                    [self->cache setObject:[NSDate date] forKey:key];
                else
                    [self->cache setObject:(image ?: [NSNull null]) forKey:key];
                
                NSLog(@"IMAGE START CALLBACKS for %@ [%d clients]", url.lastPathComponent, (int)[callbacks count]);
                for (ImageCacheCallback callback in callbacks) {
                    NSLog(@"....IMAGE CALLBACK: %@", image);
                    callback(image);
                }
                NSLog(@"IMAGE STOP CALLBACKS for %@", url.lastPathComponent);
            }
        });
    }];
}

- (void)getImage:(NSURL*)url size:(CGSize)size completionHandler:(ImageCacheCallback)handler;
{
    [self getImage:url size:size localURL:nil completionHandler:handler];
}

- (void)getImage:(NSURL*)url completionHandler:(ImageCacheCallback)handler
{
    [self getImage:url size:CGSizeZero completionHandler:handler];
}
                       
- (void)cancelImage:(NSURL*)url
{
    NSParameterAssert([NSThread isMainThread]);
    NSURLSessionDataTask* task = task_dict[url];
    if (task != nil) {
        NSLog(@"cancelImage: %@", url);
        [task cancel];
        task_dict[url] = nil;
    }
}


@end

//
// background safe image resize
//
static UIImage* resizeImage(UIImage* image, CGFloat width, CGFloat height, UIViewContentMode mode)
{
    CGRect src;
    CGRect dst;
    CGFloat scale;
    
    if (image == nil)
        return nil;
    
    if (width == 0.0 && height == 0.0)
        return image;
    
    if (width == 0.0)
        width = floor(height * image.size.width / image.size.height);
    
    if (height == 0.0)
        height = floor(width * image.size.height / image.size.width);
    
    if (width == image.size.width && height == image.size.height)
        return image;
    
    if ([UIImage respondsToSelector:@selector(imageWithCGImage:scale:orientation:)])
        scale = [[UIScreen mainScreen] scale];
    else
        scale = 1.0;
    
    width *= scale;
    height *= scale;
    
    if (mode == UIViewContentModeScaleToFill)
    {
        src = CGRectMake(0,0,image.size.width,image.size.height);
        dst = CGRectMake(0,0,width,height);
    }
    else if (mode == UIViewContentModeScaleAspectFit)
    {
        // Aspect Fit
        CGFloat w = width;
        CGFloat h = width * image.size.height / image.size.width;
        
        if (h > height)
        {
            w = height * image.size.width / image.size.height;
            h = height;
        }
        
        src = CGRectMake(0,0,image.size.width,image.size.height);
        dst = CGRectMake((width - w)/2,(height-h)/2,w,h);
    }
    else // mode == UIViewContentModeScaleAspectFill
    {
        // Aspect Fill
        
        dst = CGRectMake(0,0,width,height);
        
        if ((image.size.width / image.size.height) <= (width / height))
        {
            CGFloat w = image.size.width;
            CGFloat h = image.size.width * height / width;
            src = CGRectMake(0,(image.size.height - h)/2,w,h);
        }
        else
        {
            CGFloat w = image.size.height * width / height;
            CGFloat h = image.size.height;
            src = CGRectMake((image.size.width - w)/2,0,w,h);
        }
    }
    
    CGImageRef imageRef = [image CGImage];
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(imageRef);
    CGColorSpaceRef colorSpaceInfo = CGColorSpaceCreateDeviceRGB();
    
    if (alphaInfo == kCGImageAlphaNone)
        alphaInfo = kCGImageAlphaNoneSkipLast;
    if (alphaInfo == kCGImageAlphaFirst)
        alphaInfo = kCGImageAlphaPremultipliedFirst;
    if (alphaInfo == kCGImageAlphaLast)
        alphaInfo = kCGImageAlphaPremultipliedFirst;

    CGContextRef bitmap = CGBitmapContextCreate(NULL, width, height, 8, 4 * width, colorSpaceInfo, alphaInfo);
    CGImageRef source = CGImageCreateWithImageInRect(imageRef, src);
    CGContextDrawImage(bitmap, dst, source);
    CGImageRef ref = CGBitmapContextCreateImage(bitmap);
    
    UIImage* newImage;
    
    if (scale == 1.0)
        newImage = [UIImage imageWithCGImage:ref];
    else
        newImage = [UIImage imageWithCGImage:ref scale:scale orientation:UIImageOrientationUp];
    
    CGContextRelease(bitmap);
    CGImageRelease(source);
    CGImageRelease(ref);
    CGColorSpaceRelease(colorSpaceInfo);
    
    return newImage;
}

@implementation UIImage (Resize)
- (UIImage*)scaledToSize:(CGSize)size mode:(UIViewContentMode)mode
{
    return resizeImage(self, size.width, size.height, mode);
}
- (UIImage*)scaledToSize:(CGSize)size
{
    return [self scaledToSize:size mode:UIViewContentModeScaleToFill];
}
@end

