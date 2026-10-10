#import "AudioCapture.h"
#include <math.h>

static NSError *VIAudioError(NSString *message) {
    return [NSError errorWithDomain:@"VoiceInput.AudioCapture" code:1
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

BOOL VIInstallAudioTap(AVAudioNode *node, AVAudioNodeBus bus, AVAudioFrameCount size,
                       AVAudioFormat *format, AVAudioNodeTapBlock tap, NSError **error) {
    @try {
        if (@available(macOS 27.0, *)) {
            BOOL installed = [node installTapOnBus:bus bufferSize:size format:format error:error block:tap];
            if (!installed && error && !*error) *error = VIAudioError(@"无法创建音频采集，请重新按住 Fn 再试。");
            return installed;
        }
        [node installTapOnBus:bus bufferSize:size format:format block:tap];
        return YES;
    } @catch (NSException *exception) {
        if (error) *error = VIAudioError(exception.reason ?: @"无法创建音频采集，请重新连接麦克风后再试。");
        return NO;
    }
}

@implementation VIAudioInputCapture {
    AVAudioEngine *_engine;
    AVAudioInputNode *_input;
    BOOL _tapInstalled;
}
- (instancetype)init {
    if ((self = [super init])) _engine = [[AVAudioEngine alloc] init];
    return self;
}
- (AVAudioEngine *)engine { return _engine; }
- (BOOL)startWithTap:(AVAudioNodeTapBlock)tap error:(NSError **)error {
    [self stop];
    @try {
        _input = _engine.inputNode;
        AVAudioFormat *format = [_input outputFormatForBus:0];
        if (!isfinite(format.sampleRate) || format.sampleRate <= 0 || format.channelCount == 0) {
            if (error) *error = VIAudioError(@"未找到可用的麦克风，请检查声音输入设备。");
            return NO;
        }
        // Let the new engine select the current hardware format; do not force a cached format.
        // Apple's tap API specifies a 100–400 ms buffer range.
        AVAudioFrameCount frames = (AVAudioFrameCount)ceil(format.sampleRate * 0.1);
        if (!VIInstallAudioTap(_input, 0, frames, nil, tap, error)) { [self stop]; return NO; }
        _tapInstalled = YES;
        [_engine prepare];
        if (![_engine startAndReturnError:error]) { [self stop]; return NO; }
        return YES;
    } @catch (NSException *exception) {
        [self stop];
        if (error) *error = VIAudioError(exception.reason ?: @"麦克风启动失败，请重新按住 Fn 再试。");
        return NO;
    }
}
- (void)stop {
    @try { [_engine stop]; } @catch (NSException *exception) { }
    if (_tapInstalled) {
        _tapInstalled = NO;
        @try { [_input removeTapOnBus:0]; } @catch (NSException *exception) { }
    }
    _input = nil;
}
- (void)dealloc { [self stop]; }
@end
