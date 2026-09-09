#import "PhoneCamSyphon.h"
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

// Public API documented by https://github.com/Syphon/Syphon-Framework.
// Using a protocol keeps Syphon optional; standard CLI commands never load it.
@protocol PCSyphonMetalAPI <NSObject>
- (instancetype)initWithName:(NSString *)name device:(id<MTLDevice>)device options:(NSDictionary *)options;
- (void)publishFrameTexture:(id<MTLTexture>)texture onCommandBuffer:(id<MTLCommandBuffer>)buffer imageRegion:(NSRect)region flipped:(BOOL)flipped;
@property(readonly) BOOL hasClients;
- (void)stop;
@end

static BOOL PCFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"PhoneCam.Syphon" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}

@implementation PCSyphonOutput {
    NSBundle *_framework;
    id<PCSyphonMetalAPI> _server;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    CVMetalTextureCacheRef _cache;
}
- (instancetype)initWithFrameworkPath:(NSString *)path name:(NSString *)name error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _framework = [NSBundle bundleWithPath:path];
    if (!_framework || ![_framework loadAndReturnError:error]) {
        if (error && !*error) PCFail(error,@"Syphon.framework is unavailable. Install OBS or provide --syphon-framework.");
        return nil;
    }
    Class serverClass = NSClassFromString(@"SyphonMetalServer");
    if (!serverClass || ![serverClass instancesRespondToSelector:@selector(publishFrameTexture:onCommandBuffer:imageRegion:flipped:)]) {
        PCFail(error,@"The selected Syphon framework does not support Metal publishing."); return nil;
    }
    _device = MTLCreateSystemDefaultDevice(); _queue = [_device newCommandQueue];
    if (!_device || !_queue || CVMetalTextureCacheCreate(kCFAllocatorDefault,NULL,_device,NULL,&_cache) != kCVReturnSuccess) {
        PCFail(error,@"Cannot create the Metal resources required for Syphon."); return nil;
    }
    _server = [(id<PCSyphonMetalAPI>)[serverClass alloc] initWithName:name device:_device options:@{}];
    if (!_server) { PCFail(error,@"Cannot start the local Syphon server."); return nil; }
    return self;
}
- (BOOL)hasClients { return _server.hasClients; }
- (BOOL)publish:(CVPixelBufferRef)pixel error:(NSError **)error {
    if (!_server) return PCFail(error,@"Syphon output is stopped.");
    if (CVPixelBufferGetPixelFormatType(pixel) != kCVPixelFormatType_32BGRA)
        return PCFail(error,@"Syphon expects processed BGRA frames.");
    const size_t width=CVPixelBufferGetWidth(pixel),height=CVPixelBufferGetHeight(pixel);
    CVMetalTextureRef textureRef=NULL;
    CVReturn result=CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,_cache,pixel,NULL,
        MTLPixelFormatBGRA8Unorm,width,height,0,&textureRef);
    if (result != kCVReturnSuccess || !textureRef) return PCFail(error,@"Cannot expose the processed frame as a Metal texture.");
    id<MTLTexture> texture=CVMetalTextureGetTexture(textureRef);
    id<MTLCommandBuffer> buffer=[_queue commandBuffer];
    if (!texture || !buffer) { CFRelease(textureRef); return PCFail(error,@"Cannot allocate Syphon transfer resources."); }
    // CVPixelBuffer/Metal rows start at the top; Syphon's image convention starts at the bottom.
    // Normalize here so OpenGL clients such as OBS see the same orientation as AVFoundation preview.
    [_server publishFrameTexture:texture onCommandBuffer:buffer imageRegion:NSMakeRect(0,0,width,height) flipped:YES];
    [buffer commit];
    // Bound the transfer queue and keep the backing pixel/texture alive until GPU copy completion.
    [buffer waitUntilCompleted];
    CFRelease(textureRef);
    if (buffer.status == MTLCommandBufferStatusError) return PCFail(error,buffer.error.localizedDescription ?: @"Syphon GPU transfer failed.");
    return YES;
}
- (void)stop { [_server stop]; _server=nil; }
- (void)dealloc { [self stop]; if (_cache) CFRelease(_cache); }
@end
