#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
// Objective-C exceptions from audio device changes must never cross into Swift.
BOOL VIInstallAudioTap(AVAudioNode *node, AVAudioNodeBus bus, AVAudioFrameCount size,
                       AVAudioFormat * _Nullable format, AVAudioNodeTapBlock tap,
                       NSError * _Nullable * _Nullable error);

@interface VIAudioInputCapture : NSObject
@property (nonatomic, readonly) AVAudioEngine *engine;
- (BOOL)startWithTap:(AVAudioNodeTapBlock)tap error:(NSError **)error
    NS_SWIFT_NAME(start(tap:));
- (void)stop;
@end
NS_ASSUME_NONNULL_END
