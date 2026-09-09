#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
/// Optional adapter for the public Syphon Metal server API. No framework binary is bundled.
@interface PCSyphonOutput : NSObject
- (nullable instancetype)initWithFrameworkPath:(NSString *)path name:(NSString *)name error:(NSError **)error;
- (BOOL)publish:(CVPixelBufferRef)pixel error:(NSError **)error;
@property(nonatomic, readonly) BOOL hasClients;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
