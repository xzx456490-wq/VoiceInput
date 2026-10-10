#import "AudioCaptureTestSupport.h"

@interface VIExceptionNode : AVAudioMixerNode
@end
@implementation VIExceptionNode
- (void)installTapOnBus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)size
                format:(AVAudioFormat *)format block:(AVAudioNodeTapBlock)tap {
    [NSException raise:NSInvalidArgumentException format:@"Simulated audio-device format change"];
}
- (BOOL)installTapOnBus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)size
                format:(AVAudioFormat *)format error:(NSError **)error block:(AVAudioNodeTapBlock)tap {
    [NSException raise:NSInvalidArgumentException format:@"Simulated audio-device format change"];
    return NO;
}
@end

@interface VIFailedTapNode : AVAudioMixerNode
@end
@implementation VIFailedTapNode
- (BOOL)installTapOnBus:(AVAudioNodeBus)bus bufferSize:(AVAudioFrameCount)size
                format:(AVAudioFormat *)format error:(NSError **)error block:(AVAudioNodeTapBlock)tap {
    return NO;
}
@end

AVAudioNode *VIExceptionTestNode(void) { return [[VIExceptionNode alloc] init]; }
AVAudioNode *VIFailedTapTestNode(void) { return [[VIFailedTapNode alloc] init]; }
