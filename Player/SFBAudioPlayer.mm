//
// Copyright (c) 2006 - 2024 Stephen F. Booth <me@sbooth.org>
// Part of https://github.com/sbooth/SFBAudioEngine
// MIT license
//

#import <atomic>
#import <cmath>
#import <mutex>
#import <queue>

#import <os/log.h>

#import "SFBAudioPlayer.h"

#import "SFBUnfairLock.hpp"

#import "AVAudioFormat+SFBFormatTransformation.h"
#import "SFBAudioDecoder.h"
#import "SFBCStringForOSType.h"
#import "SFBTimeUtilities.hpp"

namespace {

using DecoderQueue = std::queue<id <SFBPCMDecoding>>;
os_log_t _audioPlayerLog = os_log_create("org.sbooth.AudioEngine", "AudioPlayer");

enum eAudioPlayerFlags : unsigned int {
	eAudioPlayerFlagRenderingImminent				= 1u << 0,
	eAudioPlayerFlagHavePendingDecoder				= 1u << 1,
	eAudioPlayerFlagPendingDecoderBecameActive		= 1u << 2
};

}

@interface SFBAudioPlayer ()
{
@private
	/// The underlying \c AVAudioEngine instance
	AVAudioEngine 			*_engine;
	/// The dispatch queue used to access \c _engine
	dispatch_queue_t		_engineQueue;
	/// Cached value of \c _engine.isRunning
	std::atomic_bool		_engineIsRunning;
	/// The player driving the audio processing graph
	SFBAudioPlayerNode		*_playerNode;
	/// The lock used to protect access to \c _queuedDecoders
	SFB::UnfairLock			_queueLock;
	/// Decoders enqueued for non-gapless playback
	DecoderQueue 			_queuedDecoders;
	/// The lock used to protect access to \c _nowPlaying
	SFB::UnfairLock			_nowPlayingLock;
	/// The currently rendering decoder
	id <SFBPCMDecoding> 	_nowPlaying;
	/// Flags
	std::atomic_uint		_flags;
}
- (BOOL)internalDecoderQueueIsEmpty;
- (void)clearInternalDecoderQueue;
- (void)pushDecoderToInternalQueue:(id <SFBPCMDecoding>)decoder;
- (id <SFBPCMDecoding>)popDecoderFromInternalQueue;
- (void)handleAudioEngineConfigurationChange:(NSNotification *)notification;
#if TARGET_OS_IPHONE
- (void)handleAudioSessionInterruption:(NSNotification *)notification;
#endif
- (BOOL)configureForAndEnqueueDecoder:(id <SFBPCMDecoding>)decoder forImmediatePlayback:(BOOL)forImmediatePlayback error:(NSError **)error;
- (BOOL)configureEngineForGaplessPlaybackOfFormat:(AVAudioFormat *)format forceUpdate:(BOOL)forceUpdate;
@end

@implementation SFBAudioPlayer

- (instancetype)init
{
	if((self = [super init])) {
		_engineQueue = dispatch_queue_create("org.sbooth.AudioEngine.AudioPlayer.AVAudioEngineIsolationQueue", DISPATCH_QUEUE_SERIAL);
		if(!_engineQueue) {
			os_log_error(_audioPlayerLog, "Unable to create AVAudioEngine isolation dispatch queue: dispatch_queue_create failed");
			return nil;
		}

		// Create the audio processing graph
		_engine = [[AVAudioEngine alloc] init];
		if(![self configureEngineForGaplessPlaybackOfFormat:[[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2] forceUpdate:NO]) {
			os_log_error(_audioPlayerLog, "Unable to create audio processing graph for 44.1 kHz stereo");
			return nil;
		}

		// Register for configuration change notifications
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAudioEngineConfigurationChange:) name:AVAudioEngineConfigurationChangeNotification object:_engine];

#if TARGET_OS_IPHONE
		// Register for audio session interruption notifications
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAudioSessionInterruption:) name:AVAudioSessionInterruptionNotification object:[AVAudioSession sharedInstance]];
#endif
	}
	return self;
}

#pragma mark - Playlist Management

- (BOOL)playURL:(NSURL *)url error:(NSError **)error
{
	NSParameterAssert(url != nil);

	if(![self enqueueURL:url forImmediatePlayback:YES error:error])
		return NO;
	return [self playReturningError:error];
}

- (BOOL)playDecoder:(id <SFBPCMDecoding>)decoder error:(NSError **)error
{
	NSParameterAssert(decoder != nil);

	if(![self enqueueDecoder:decoder forImmediatePlayback:YES error:error])
		return NO;
	return [self playReturningError:error];
}

- (BOOL)enqueueURL:(NSURL *)url error:(NSError **)error
{
	NSParameterAssert(url != nil);

	return [self enqueueURL:url forImmediatePlayback:NO error:error];
}

- (BOOL)enqueueURL:(NSURL *)url forImmediatePlayback:(BOOL)forImmediatePlayback error:(NSError **)error
{
	NSParameterAssert(url != nil);

	SFBAudioDecoder *decoder = [[SFBAudioDecoder alloc] initWithURL:url error:error];
	if(!decoder)
		return NO;
	return [self enqueueDecoder:decoder forImmediatePlayback:forImmediatePlayback error:error];
}

- (BOOL)enqueueDecoder:(id <SFBPCMDecoding>)decoder error:(NSError **)error
{
	NSParameterAssert(decoder != nil);

	return [self enqueueDecoder:decoder forImmediatePlayback:NO error:error];
}

- (BOOL)enqueueDecoder:(id <SFBPCMDecoding>)decoder forImmediatePlayback:(BOOL)forImmediatePlayback error:(NSError **)error
{
	NSParameterAssert(decoder != nil);

	// Open the decoder if necessary
	if(!decoder.isOpen && ![decoder openReturningError:error])
		return NO;

	// Reconfigure the audio processing graph for the decoder's processing format if requested
	if(forImmediatePlayback)
		return [self configureForAndEnqueueDecoder:decoder forImmediatePlayback:YES error:error];
	// To preserve the order of enqueued decoders, when the internal queue is not empty
	// enqueue all decoders there regardless of format compability with _playerNode
	// This prevents incorrect playback order arising from the scenario where
	// decoders A and AA have formats supported by _playerNode and decoder B does not;
	// bypassing the internal queue for supported formats when enqueueing A, B, AA
	// would result in playback order A, AA, B
	else if(self.internalDecoderQueueIsEmpty && [_playerNode supportsFormat:decoder.processingFormat]) {
		// Enqueuing is expected to succeed since the formats are compatible
		return [_playerNode enqueueDecoder:decoder error:error];
	}
	// If the internal queue is not empty or _playerNode doesn't support
	// the decoder's processing format add the decoder to our internal queue
	else {
		[self pushDecoderToInternalQueue:decoder];
		return YES;
	}
}

- (BOOL)formatWillBeGaplessIfEnqueued:(AVAudioFormat *)format
{
	NSParameterAssert(format != nil);
	return [_playerNode supportsFormat:format];
}

- (void)clearQueue
{
	[_playerNode clearQueue];
	[self clearInternalDecoderQueue];
}

- (BOOL)queueIsEmpty
{
	return _playerNode.queueIsEmpty && self.internalDecoderQueueIsEmpty;
}

#pragma mark - Playback Control

- (BOOL)playReturningError:(NSError **)error
{
	if(self.isPlaying)
		return YES;

	__block NSError *err = nil;
	dispatch_async_and_wait(_engineQueue, ^{
		_engineIsRunning = [_engine startAndReturnError:&err];
		if(_engineIsRunning)
			[_playerNode play];
	});

	if(!_engineIsRunning) {
		os_log_error(_audioPlayerLog, "Error starting AVAudioEngine: %{public}@", err);
		if(error)
			*error = err;
		return NO;
	}

	if([_delegate respondsToSelector:@selector(audioPlayerPlaybackStateChanged:)])
		[_delegate audioPlayerPlaybackStateChanged:self];

	return YES;
}

- (void)pause
{
	if(!self.isPlaying)
		return;

	[_playerNode pause];

	if([_delegate respondsToSelector:@selector(audioPlayerPlaybackStateChanged:)])
		[_delegate audioPlayerPlaybackStateChanged:self];
}

- (void)resume
{
	if(!self.isPaused)
		return;

	[_playerNode play];

	if([_delegate respondsToSelector:@selector(audioPlayerPlaybackStateChanged:)])
		[_delegate audioPlayerPlaybackStateChanged:self];
}

- (void)stop
{
	if(self.isStopped)
		return;

	dispatch_async_and_wait(_engineQueue, ^{
		[_engine stop];
		_engineIsRunning = NO;
		[_playerNode stop];
	});

	[self clearInternalDecoderQueue];

	if([_delegate respondsToSelector:@selector(audioPlayerPlaybackStateChanged:)])
		[_delegate audioPlayerPlaybackStateChanged:self];
}

- (BOOL)togglePlayPauseReturningError:(NSError **)error
{
	switch(self.playbackState) {
		case SFBAudioPlayerPlaybackStatePlaying:
			[self pause];
			return YES;
		case SFBAudioPlayerPlaybackStatePaused:
			[self resume];
			return YES;
		case SFBAudioPlayerPlaybackStateStopped:
			return [self playReturningError:error];
	}
}

- (void)reset
{
	dispatch_async_and_wait(_engineQueue, ^{
		[_playerNode reset];
		[_engine reset];
	});

	[self clearInternalDecoderQueue];
}

#pragma mark - Player State

- (BOOL)engineIsRunning
{
	__block BOOL isRunning;
	dispatch_async_and_wait(_engineQueue, ^{
		isRunning = _engine.isRunning;
#if DEBUG
		NSAssert(_engineIsRunning == isRunning, @"Cached value for _engine.isRunning invalid");
#endif
	});
	return isRunning;
}

- (BOOL)playerNodeIsPlaying
{
	return _playerNode.isPlaying;
}

- (SFBAudioPlayerPlaybackState)playbackState
{
	if(_engineIsRunning)
		return _playerNode.isPlaying ? SFBAudioPlayerPlaybackStatePlaying : SFBAudioPlayerPlaybackStatePaused;
	else
		return SFBAudioPlayerPlaybackStateStopped;
}

- (BOOL)isPlaying
{
	return _engineIsRunning && _playerNode.isPlaying;
}

- (BOOL)isPaused
{
	return _engineIsRunning && !_playerNode.isPlaying;
}

- (BOOL)isStopped
{
	return !_engineIsRunning;
}

- (BOOL)isReady
{
	return _playerNode.isReady;
}

- (id<SFBPCMDecoding>)currentDecoder
{
	return _playerNode.currentDecoder;
}

- (id<SFBPCMDecoding>)nowPlaying
{
	std::lock_guard<SFB::UnfairLock> lock(_nowPlayingLock);
	return _nowPlaying;
}

- (void)setNowPlaying:(id<SFBPCMDecoding>)nowPlaying
{
	std::lock_guard<SFB::UnfairLock> lock(_nowPlayingLock);
#if DEBUG
	NSAssert(_nowPlaying != nowPlaying, @"Unnecessary _nowPlaying change");
#endif
	_nowPlaying = nowPlaying;
}

#pragma mark - Playback Properties

- (AVAudioFramePosition)framePosition
{
	return self.playbackPosition.framePosition;
}

- (AVAudioFramePosition)frameLength
{
	return self.playbackPosition.frameLength;
}

- (SFBAudioPlayerPlaybackPosition)playbackPosition
{
	return _playerNode.playbackPosition;
}

- (NSTimeInterval)currentTime
{
	return self.playbackTime.currentTime;
}

- (NSTimeInterval)totalTime
{
	return self.playbackTime.totalTime;
}

- (SFBAudioPlayerPlaybackTime)playbackTime
{
	return _playerNode.playbackTime;
}

- (BOOL)getPlaybackPosition:(SFBAudioPlayerPlaybackPosition *)playbackPosition andTime:(SFBAudioPlayerPlaybackTime *)playbackTime
{
	return [_playerNode getPlaybackPosition:playbackPosition andTime:playbackTime];
}

#pragma mark - Seeking

- (BOOL)seekForward
{
	return [self seekForward:3];
}

- (BOOL)seekBackward
{
	return [self seekBackward:3];
}

- (BOOL)seekForward:(NSTimeInterval)secondsToSkip
{
	return [_playerNode seekForward:secondsToSkip];
}

- (BOOL)seekBackward:(NSTimeInterval)secondsToSkip
{
	return [_playerNode seekBackward:secondsToSkip];
}

- (BOOL)seekToTime:(NSTimeInterval)timeInSeconds
{
	return [_playerNode seekToTime:timeInSeconds];
}

- (BOOL)seekToPosition:(double)position
{
	return [_playerNode seekToPosition:position];
}

- (BOOL)seekToFrame:(AVAudioFramePosition)frame
{
	return [_playerNode seekToFrame:frame];
}

- (BOOL)supportsSeeking
{
	return _playerNode.supportsSeeking;
}

#if TARGET_OS_OSX

#pragma mark - Volume Control

- (float)volume
{
	return [self volumeForChannel:0];
}

- (BOOL)setVolume:(float)volume error:(NSError **)error
{
	return [self setVolume:volume forChannel:0 error:error];
}

- (float)volumeForChannel:(AudioObjectPropertyElement)channel
{
	__block float volume = std::nanf("1");
	dispatch_async_and_wait(_engineQueue, ^{
		AudioUnitParameterValue channelVolume;
		OSStatus result = AudioUnitGetParameter(_engine.outputNode.audioUnit, kHALOutputParam_Volume, kAudioUnitScope_Global, channel, &channelVolume);
		if(result != noErr) {
			os_log_error(_audioPlayerLog, "AudioUnitGetParameter (kHALOutputParam_Volume, kAudioUnitScope_Global, %u) failed: %d '%{public}.4s'", channel, result, SFBCStringForOSType(result));
			return;
		}

		volume = channelVolume;
	});

	return volume;
}

- (BOOL)setVolume:(float)volume forChannel:(AudioObjectPropertyElement)channel error:(NSError **)error
{
	os_log_info(_audioPlayerLog, "Setting volume for channel %u to %f", channel, volume);

	__block BOOL success = NO;
	__block NSError *err = nil;
	dispatch_async_and_wait(_engineQueue, ^{
		AudioUnitParameterValue channelVolume = volume;
		OSStatus result = AudioUnitSetParameter(_engine.outputNode.audioUnit, kHALOutputParam_Volume, kAudioUnitScope_Global, channel, channelVolume, 0);
		if(result != noErr) {
			os_log_error(_audioPlayerLog, "AudioUnitGetParameter (kHALOutputParam_Volume, kAudioUnitScope_Global, %u) failed: %d '%{public}.4s'", channel, result, SFBCStringForOSType(result));
			err = [NSError errorWithDomain:NSOSStatusErrorDomain code:result userInfo:nil];
			return;
		}

		success = YES;
	});

	if(!success && error)
		*error = err;

	return success;
}

#pragma mark - Output Device

- (AUAudioObjectID)outputDeviceID
{
	__block AUAudioObjectID objectID = kAudioObjectUnknown;
	dispatch_async_and_wait(_engineQueue, ^{
		objectID = _engine.outputNode.AUAudioUnit.deviceID;
	});
	return objectID;
}

- (BOOL)setOutputDeviceID:(AUAudioObjectID)outputDeviceID error:(NSError **)error
{
	os_log_info(_audioPlayerLog, "Setting output device to 0x%x", outputDeviceID);

	__block BOOL result;
	__block NSError *err = nil;
	dispatch_async_and_wait(_engineQueue, ^{
		result = [_engine.outputNode.AUAudioUnit setDeviceID:outputDeviceID error:&err];
	});

	if(!result) {
		os_log_error(_audioPlayerLog, "Error setting output device: %{public}@", err);
		if(error)
			*error = err;
	}

	return result;
}

#endif

#pragma mark - AVAudioEngine

- (void)withEngine:(SFBAudioPlayerAVAudioEngineBlock)block
{
	dispatch_async_and_wait(_engineQueue, ^{
		block(_engine);
		// SFBAudioPlayer requires that the mixer node be connected to the output node
		NSAssert([_engine inputConnectionPointForNode:_engine.outputNode inputBus:0].node == _engine.mainMixerNode, @"Illegal AVAudioEngine configuration");
		NSAssert(_engine.isRunning == _engineIsRunning, @"AVAudioEngine may not be started or stopped outside of SFBAudioPlayer");
	});
}

#pragma mark - Decoder Queue

- (BOOL)internalDecoderQueueIsEmpty
{
	std::lock_guard<SFB::UnfairLock> lock(_queueLock);
	return _queuedDecoders.empty();
}

- (void)clearInternalDecoderQueue
{
	std::lock_guard<SFB::UnfairLock> lock(_queueLock);
	while(!_queuedDecoders.empty())
		_queuedDecoders.pop();
}

- (void)pushDecoderToInternalQueue:(id <SFBPCMDecoding>)decoder
{
	std::lock_guard<SFB::UnfairLock> lock(_queueLock);
	_queuedDecoders.push(decoder);
}

- (id <SFBPCMDecoding>)popDecoderFromInternalQueue
{
	std::lock_guard<SFB::UnfairLock> lock(_queueLock);
	id <SFBPCMDecoding> decoder = nil;
	if(!_queuedDecoders.empty()) {
		decoder = _queuedDecoders.front();
		_queuedDecoders.pop();
	}
	return decoder;
}

#pragma mark - Internals

- (void)handleAudioEngineConfigurationChange:(NSNotification *)notification
{
	NSAssert([notification object] == _engine, @"AVAudioEngineConfigurationChangeNotification received for incorrect AVAudioEngine instance");
	os_log_debug(_audioPlayerLog, "Received AVAudioEngineConfigurationChangeNotification");

	// AVAudioEngine stops itself when interrupted and there is no way to determine if the engine was
	// running before this notification was issued unless the state is cached
	BOOL engineWasRunning = _engineIsRunning;
	_engineIsRunning = NO;

	// Attempt to preserve the playback state
	BOOL playerNodeWasPlaying = _playerNode.isPlaying;

	// AVAudioEngine posts this notification from a dedicated queue
	__block BOOL success;
	dispatch_async_and_wait(_engineQueue, ^{
		[_playerNode pause];

		success = [self configureEngineForGaplessPlaybackOfFormat:_playerNode.renderingFormat forceUpdate:YES];
		if(success) {
			// Restart AVAudioEngine if previously running
			if(engineWasRunning) {
				NSError *error = nil;
				_engineIsRunning = [_engine startAndReturnError:&error];
				if(_engineIsRunning) {
					if(playerNodeWasPlaying)
						[_playerNode play];
				}
				else
					os_log_error(_audioPlayerLog, "Error starting AVAudioEngine: %{public}@", error);
			}
		}
	});

	// Success in this context means the graph is in a working state
	if(!success) {
		os_log_error(_audioPlayerLog, "Unable to create audio processing graph for %{public}@", _playerNode.renderingFormat);
		if([_delegate respondsToSelector:@selector(audioPlayer:encounteredError:)]) {
			NSError *error = [NSError errorWithDomain:SFBAudioPlayerNodeErrorDomain code:SFBAudioPlayerNodeErrorCodeFormatNotSupported userInfo:nil];
			[_delegate audioPlayer:self encounteredError:error];
		}
		return;
	}

	if((engineWasRunning != _engineIsRunning || playerNodeWasPlaying != _playerNode.isPlaying) && [_delegate respondsToSelector:@selector(audioPlayerPlaybackStateChanged:)])
		[_delegate audioPlayerPlaybackStateChanged:self];

	if([_delegate respondsToSelector:@selector(audioPlayerAVAudioEngineConfigurationChange:)])
		[_delegate audioPlayerAVAudioEngineConfigurationChange:self];
}

#if TARGET_OS_IPHONE
- (void)handleAudioSessionInterruption:(NSNotification *)notification
{
	NSUInteger interruptionType = [[[notification userInfo] objectForKey:AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
	switch(interruptionType) {
		case AVAudioSessionInterruptionTypeBegan:
			os_log_debug(_audioPlayerLog, "Received AVAudioSessionInterruptionNotification (AVAudioSessionInterruptionTypeBegan)");
			[self pause];
			break;

		case AVAudioSessionInterruptionTypeEnded:
			os_log_debug(_audioPlayerLog, "Received AVAudioSessionInterruptionNotification (AVAudioSessionInterruptionTypeEnded)");

			// AVAudioEngine stops itself when AVAudioSessionInterruptionNotification is received
			// However, _engineIsRunning isn't updated and will indicate if the engine was running before the interruption
			if(_engineIsRunning) {
				dispatch_async_and_wait(_engineQueue, ^{
					NSError *error = nil;
					_engineIsRunning = [_engine startAndReturnError:&error];
					if(!_engineIsRunning)
						os_log_error(_audioPlayerLog, "Error starting AVAudioEngine: %{public}@", error);
				});
			}
			break;

		default:
			os_log_error(_audioPlayerLog, "Unknown value %lu for AVAudioSessionInterruptionTypeKey", static_cast<unsigned long>(interruptionType));
			break;
	}
}
#endif

- (BOOL)configureForAndEnqueueDecoder:(id <SFBPCMDecoding>)decoder forImmediatePlayback:(BOOL)forImmediatePlayback error:(NSError **)error
{
	_flags.fetch_or(eAudioPlayerFlagHavePendingDecoder);

	__block auto playbackStateChanged = false;
	__block BOOL success = YES;
	dispatch_async_and_wait(_engineQueue, ^{
		[_playerNode reset];
		[_engine reset];

		// If the current SFBAudioPlayerNode doesn't support the decoder's format (required for gapless join),
		// reconfigure AVAudioEngine with a new SFBAudioPlayerNode with the correct format
		if(auto format = decoder.processingFormat; ![_playerNode supportsFormat:format]) {
			success = [self configureEngineForGaplessPlaybackOfFormat:format forceUpdate:NO];
			playbackStateChanged = _engineIsRunning;
		}
	});

	if(!success) {
		if(error)
			*error = [NSError errorWithDomain:SFBAudioPlayerNodeErrorDomain code:SFBAudioPlayerNodeErrorCodeFormatNotSupported userInfo:nil];
		_flags.fetch_and(~eAudioPlayerFlagHavePendingDecoder);
		if(self.nowPlaying) {
			self.nowPlaying = nil;
			if([_delegate respondsToSelector:@selector(audioPlayerNowPlayingChanged:)])
				[_delegate audioPlayerNowPlayingChanged:self];
		}
		return NO;
	}

	if(forImmediatePlayback) {
		[self clearInternalDecoderQueue];
		success = [_playerNode resetAndEnqueueDecoder:decoder error:error];
	}
	else
		success = [_playerNode enqueueDecoder:decoder error:error];

	// Failure is unlikely since the audio processing graph was reconfigured for the decoder's processing format
	if(!success) {
		_flags.fetch_and(~eAudioPlayerFlagHavePendingDecoder);
		if(self.nowPlaying) {
			self.nowPlaying = nil;
			if([_delegate respondsToSelector:@selector(audioPlayerNowPlayingChanged:)])
				[_delegate audioPlayerNowPlayingChanged:self];
		}
		return NO;
	}

	if(playbackStateChanged && [_delegate respondsToSelector:@selector(audioPlayerPlaybackStateChanged:)])
		[_delegate audioPlayerPlaybackStateChanged:self];

	return YES;
}

- (BOOL)configureEngineForGaplessPlaybackOfFormat:(AVAudioFormat *)format forceUpdate:(BOOL)forceUpdate
{
	// SFBAudioPlayerNode requires the standard format
	if(!format.isStandard) {
		format = [format standardEquivalent];
		if(!format) {
			os_log_error(_audioPlayerLog, "Unable to convert format to standard");
			return NO;
		}
	}

	BOOL formatsEqual = [format isEqual:_playerNode.renderingFormat];
	if(formatsEqual && !forceUpdate)
		return YES;

	// Avoid creating a new SFBAudioPlayerNode if not necessary
	SFBAudioPlayerNode *playerNode = nil;
	if(!formatsEqual) {
		playerNode = [[SFBAudioPlayerNode alloc] initWithFormat:format];
		if(!playerNode) {
			os_log_error(_audioPlayerLog, "Unable to create SFBAudioPlayerNode with format %{public}@", format);
			return NO;
		}

		playerNode.delegate = self;
	}

	AVAudioOutputNode *outputNode = _engine.outputNode;
	AVAudioMixerNode *mixerNode = _engine.mainMixerNode;

	// SFBAudioPlayer requires that the main mixer node be connected to the output node
	NSAssert([_engine inputConnectionPointForNode:outputNode inputBus:0].node == mixerNode, @"Illegal AVAudioEngine configuration");

	AVAudioFormat *outputFormat = [outputNode outputFormatForBus:0];
	AVAudioFormat *previousOutputFormat = [outputNode inputFormatForBus:0];

	BOOL outputFormatChanged = outputFormat.channelCount != previousOutputFormat.channelCount || outputFormat.sampleRate != previousOutputFormat.sampleRate;
	if(outputFormatChanged)
		os_log_debug(_audioPlayerLog, "AVAudioEngine output format changed from %{public}@ to %{public}@", previousOutputFormat, outputFormat);

	if(outputFormatChanged) {
		[_engine disconnectNodeInput:outputNode bus:0];

		// Reconnect the mixer and output nodes using the output device's format
		[_engine connect:mixerNode to:outputNode format:outputFormat];
	}

	if(playerNode) {
		AVAudioConnectionPoint *playerNodeOutputConnectionPoint = nil;
		if(_playerNode) {
			playerNodeOutputConnectionPoint = [[_engine outputConnectionPointsForNode:_playerNode outputBus:0] firstObject];
			[_engine disconnectNodeOutput:_playerNode bus:0];
			[_engine detachNode:_playerNode];
		}

		_playerNode = playerNode;
		[_engine attachNode:_playerNode];

		// Reconnect the player node to its output
		if(playerNodeOutputConnectionPoint)
			[_engine connect:_playerNode to:playerNodeOutputConnectionPoint.node format:format];
		else
			[_engine connect:_playerNode to:mixerNode format:format];
	}

#if 1
	// AVAudioMixerNode handles sample rate conversion, but it may require input buffer sizes
	// (maximum frames per slice) greater than the default for AVAudioSourceNode (1156).
	//
	// For high sample rates, the sample rate conversion can require more rendered frames than are available by default.
	// For example, 192 KHz audio converted to 44.1 HHz requires approximately (192 / 44.1) * 512 = 2229 frames
	// So if the input and output sample rates on the mixer don't match, adjust
	// kAudioUnitProperty_MaximumFramesPerSlice to ensure enough audio data is passed per render cycle
	// See http://lists.apple.com/archives/coreaudio-api/2009/Oct/msg00150.html
	if(format.sampleRate > outputFormat.sampleRate) {
		os_log_debug(_audioPlayerLog, "AVAudioMixerNode input sample rate (%.2f Hz) and output sample rate (%.2f Hz) don't match", format.sampleRate, outputFormat.sampleRate);

		// 512 is the nominal "standard" value for kAudioUnitProperty_MaximumFramesPerSlice
		double ratio = format.sampleRate / outputFormat.sampleRate;
		auto maximumFramesToRender = static_cast<AUAudioFrameCount>(ceil(512 * ratio));

		if(auto audioUnit = _playerNode.AUAudioUnit; audioUnit.maximumFramesToRender < maximumFramesToRender) {
			BOOL renderResourcesAllocated = audioUnit.renderResourcesAllocated;
			if(renderResourcesAllocated)
				[audioUnit deallocateRenderResources];

			os_log_debug(_audioPlayerLog, "Adjusting SFBAudioPlayerNode's maximumFramesToRender to %u", maximumFramesToRender);
			audioUnit.maximumFramesToRender = maximumFramesToRender;

			NSError *error;
			if(renderResourcesAllocated && ![audioUnit allocateRenderResourcesAndReturnError:&error]) {
				os_log_error(_audioPlayerLog, "Error allocating AUAudioUnit render resources for SFBAudioPlayerNode: %{public}@", error);
			}
		}
	}
#endif

#if DEBUG
	os_log_debug(_audioPlayerLog, "↑ rendering: %{public}@", _playerNode.renderingFormat);
	if(![[_playerNode outputFormatForBus:0] isEqual:_playerNode.renderingFormat])
		os_log_debug(_audioPlayerLog, "← player out: %{public}@", [_playerNode outputFormatForBus:0]);

	if(![[_engine.mainMixerNode inputFormatForBus:0] isEqual:[_playerNode outputFormatForBus:0]])
		os_log_debug(_audioPlayerLog, "→ main mixer in: %{public}@", [_engine.mainMixerNode inputFormatForBus:0]);

	if(![[_engine.mainMixerNode outputFormatForBus:0] isEqual:[_engine.mainMixerNode inputFormatForBus:0]])
		os_log_debug(_audioPlayerLog, "← main mixer out: %{public}@", [_engine.mainMixerNode outputFormatForBus:0]);

	if(![[_engine.outputNode inputFormatForBus:0] isEqual:[_engine.mainMixerNode outputFormatForBus:0]])
		os_log_debug(_audioPlayerLog, "← output in: %{public}@", [_engine.outputNode inputFormatForBus:0]);

	if(![[_engine.outputNode outputFormatForBus:0] isEqual:[_engine.outputNode inputFormatForBus:0]])
		os_log_debug(_audioPlayerLog, "→ output out: %{public}@", [_engine.outputNode outputFormatForBus:0]);
#endif

	[_engine prepare];
	return YES;
}

#pragma mark - SFBAudioPlayerNodeDelegate

- (void)audioPlayerNode:(SFBAudioPlayerNode *)audioPlayerNode decodingStarted:(id<SFBPCMDecoding>)decoder
{
	if(audioPlayerNode != _playerNode) {
		os_log_fault(_audioPlayerLog, "Unexpected SFBAudioPlayerNode instance in -audioPlayerNode:decodingStarted:");
		return;
	}

	if((_flags.load() & eAudioPlayerFlagHavePendingDecoder) && !self.isPlaying) {
		_flags.fetch_or(eAudioPlayerFlagPendingDecoderBecameActive);
		self.nowPlaying = decoder;
		if([_delegate respondsToSelector:@selector(audioPlayerNowPlayingChanged:)])
			[_delegate audioPlayerNowPlayingChanged:self];
	}
	_flags.fetch_and(~eAudioPlayerFlagHavePendingDecoder);

	if([_delegate respondsToSelector:@selector(audioPlayer:decodingStarted:)])
		[_delegate audioPlayer:self decodingStarted:decoder];
}

- (void)audioPlayerNode:(SFBAudioPlayerNode *)audioPlayerNode decodingComplete:(id<SFBPCMDecoding>)decoder
{
	if(audioPlayerNode != _playerNode) {
		os_log_fault(_audioPlayerLog, "Unexpected SFBAudioPlayerNode instance in -audioPlayerNode:decodingComplete:");
		return;
	}

	if([_delegate respondsToSelector:@selector(audioPlayer:decodingComplete:)])
		[_delegate audioPlayer:self decodingComplete:decoder];
}

- (void)audioPlayerNode:(SFBAudioPlayerNode *)audioPlayerNode decodingCanceled:(id<SFBPCMDecoding>)decoder partiallyRendered:(BOOL)partiallyRendered
{
	if(audioPlayerNode != _playerNode) {
		os_log_fault(_audioPlayerLog, "Unexpected SFBAudioPlayerNode instance in -audioPlayerNode:decodingCanceled:partiallyRendered:");
		return;
	}

	_flags.fetch_and(~eAudioPlayerFlagRenderingImminent & ~eAudioPlayerFlagPendingDecoderBecameActive);

	if((partiallyRendered && !(_flags.load() & eAudioPlayerFlagHavePendingDecoder)) || self.isStopped) {
		if(self.nowPlaying) {
			self.nowPlaying = nil;
			if([_delegate respondsToSelector:@selector(audioPlayerNowPlayingChanged:)])
				[_delegate audioPlayerNowPlayingChanged:self];
		}
	}

	if([_delegate respondsToSelector:@selector(audioPlayer:decodingCanceled:partiallyRendered:)])
		[_delegate audioPlayer:self decodingCanceled:decoder partiallyRendered:partiallyRendered];
}

- (void)audioPlayerNode:(SFBAudioPlayerNode *)audioPlayerNode renderingWillStart:(id<SFBPCMDecoding>)decoder atHostTime:(uint64_t)hostTime
{
	if(audioPlayerNode != _playerNode) {
		os_log_fault(_audioPlayerLog, "Unexpected SFBAudioPlayerNode instance in -audioPlayerNode:renderingWillStart:atHostTime:");
		return;
	}

	_flags.fetch_or(eAudioPlayerFlagRenderingImminent);

	dispatch_after(hostTime, audioPlayerNode.delegateQueue, ^{
#if DEBUG
		const auto now = SFB::GetCurrentHostTime();
		const auto delta = SFB::ConvertAbsoluteHostTimeDeltaToNanoseconds(hostTime, now);
		const auto tolerance = static_cast<uint64_t>(1e9 / audioPlayerNode.renderingFormat.sampleRate);
		if(delta > tolerance)
			os_log_debug(_audioPlayerLog, "Rendering started notification for %{public}@ arrived %.2f msec %s", decoder, static_cast<double>(delta) / 1e6, now > hostTime ? "late" : "early");
#endif

		if(audioPlayerNode != self->_playerNode) {
			os_log_fault(_audioPlayerLog, "Unexpected SFBAudioPlayerNode instance following -audioPlayerNode:renderingWillStart:atHostTime:");
			return;
		}

		if(!(self->_flags.load() & eAudioPlayerFlagPendingDecoderBecameActive)) {
			self.nowPlaying = decoder;
			if([self->_delegate respondsToSelector:@selector(audioPlayerNowPlayingChanged:)])
				[self->_delegate audioPlayerNowPlayingChanged:self];
		}
		self->_flags.fetch_and(~eAudioPlayerFlagRenderingImminent & ~eAudioPlayerFlagPendingDecoderBecameActive);

		if([self->_delegate respondsToSelector:@selector(audioPlayer:renderingStarted:)])
			[self->_delegate audioPlayer:self renderingStarted:decoder];
	});

	if([_delegate respondsToSelector:@selector(audioPlayer:renderingWillStart:atHostTime:)])
		[_delegate audioPlayer:self renderingWillStart:decoder atHostTime:hostTime];
}

- (void)audioPlayerNode:(SFBAudioPlayerNode *)audioPlayerNode renderingWillComplete:(id<SFBPCMDecoding>)decoder atHostTime:(uint64_t)hostTime
{
	if(audioPlayerNode != _playerNode) {
		os_log_fault(_audioPlayerLog, "Unexpected SFBAudioPlayerNode instance in -audioPlayerNode:renderingWillComplete:atHostTime:");
		return;
	}

	dispatch_after(hostTime, audioPlayerNode.delegateQueue, ^{
#if DEBUG
		const auto now = SFB::GetCurrentHostTime();
		const auto delta = SFB::ConvertAbsoluteHostTimeDeltaToNanoseconds(hostTime, now);
		const auto tolerance = static_cast<uint64_t>(1e9 / audioPlayerNode.renderingFormat.sampleRate);
		if(delta > tolerance)
			os_log_debug(_audioPlayerLog, "Rendering complete notification for %{public}@ arrived %.2f msec %s", decoder, static_cast<double>(delta) / 1e6, now > hostTime ? "late" : "early");
#endif

		if(audioPlayerNode != self->_playerNode) {
			os_log_fault(_audioPlayerLog, "Unexpected SFBAudioPlayerNode instance following -audioPlayerNode:renderingWillComplete:atHostTime:");
			return;
		}

		if(auto flags = self->_flags.load(); !(flags & eAudioPlayerFlagRenderingImminent) && !(flags & eAudioPlayerFlagHavePendingDecoder) && self.internalDecoderQueueIsEmpty) {
			if(self.nowPlaying) {
				self.nowPlaying = nil;
				if([self->_delegate respondsToSelector:@selector(audioPlayerNowPlayingChanged:)])
					[self->_delegate audioPlayerNowPlayingChanged:self];
			}
		}

		if([self->_delegate respondsToSelector:@selector(audioPlayer:renderingComplete:)])
			[self->_delegate audioPlayer:self renderingComplete:decoder];
	});

	if([_delegate respondsToSelector:@selector(audioPlayer:renderingWillComplete:atHostTime:)])
		[_delegate audioPlayer:self renderingWillComplete:decoder atHostTime:hostTime];
}

- (void)audioPlayerNode:(SFBAudioPlayerNode *)audioPlayerNode audioWillEndAtHostTime:(uint64_t)hostTime
{
	if(audioPlayerNode != _playerNode) {
		os_log_fault(_audioPlayerLog, "Unexpected SFBAudioPlayerNode instance in -audioPlayerNode:audioWillEndAtHostTime:");
		return;
	}

	dispatch_after(hostTime, audioPlayerNode.delegateQueue, ^{
#if DEBUG
		const auto now = SFB::GetCurrentHostTime();
		const auto delta = SFB::ConvertAbsoluteHostTimeDeltaToNanoseconds(hostTime, now);
		const auto tolerance = static_cast<uint64_t>(1e9 / audioPlayerNode.renderingFormat.sampleRate);
		if(delta > tolerance)
			os_log_debug(_audioPlayerLog, "End of audio notification arrived %.2f msec %s", static_cast<double>(delta) / 1e6, now > hostTime ? "late" : "early");
#endif

		if(audioPlayerNode != self->_playerNode) {
			os_log_fault(_audioPlayerLog, "Unexpected SFBAudioPlayerNode instance following -audioPlayerNode:audioWillEndAtHostTime:");
			return;
		}

		if(auto flags = self->_flags.load(); (flags & eAudioPlayerFlagRenderingImminent) || (flags & eAudioPlayerFlagHavePendingDecoder))
			return;

		// Dequeue the next decoder
		id <SFBPCMDecoding> decoder = [self popDecoderFromInternalQueue];
		if(decoder) {
			NSError *error = nil;
			if(![self configureForAndEnqueueDecoder:decoder forImmediatePlayback:NO error:&error]) {
				if(error && [self->_delegate respondsToSelector:@selector(audioPlayer:encounteredError:)])
					[self->_delegate audioPlayer:self encounteredError:error];
				return;
			}

			if(![self playReturningError:&error]) {
				if(error && [self->_delegate respondsToSelector:@selector(audioPlayer:encounteredError:)])
					[self->_delegate audioPlayer:self encounteredError:error];
			}
		}
		else if([self->_delegate respondsToSelector:@selector(audioPlayerEndOfAudio:)])
			[self->_delegate audioPlayerEndOfAudio:self];
		else
			[self stop];
	});

	if([_delegate respondsToSelector:@selector(audioPlayer:audioWillEndAtHostTime:)])
		[_delegate audioPlayer:self audioWillEndAtHostTime:hostTime];
}

- (void)audioPlayerNode:(SFBAudioPlayerNode *)audioPlayerNode encounteredError:(NSError *)error
{
	if(audioPlayerNode != _playerNode) {
		os_log_fault(_audioPlayerLog, "Unexpected SFBAudioPlayerNode instance in -audioPlayerNode:encounteredError:");
		return;
	}

	if([_delegate respondsToSelector:@selector(audioPlayer:encounteredError:)])
		[_delegate audioPlayer:self encounteredError:error];
}

@end
