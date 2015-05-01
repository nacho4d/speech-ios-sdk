/**
 * Copyright 2014 IBM Corp. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import <SpeechToText.h>
#import "VadProcessor.h"
#import "OpusHelper.h"
#import "watsonSpeexdec.h"
#import "watsonSpeexenc.h"
#import "WebSocketUploader.h"

// type defs for block callbacks
#define NUM_BUFFERS 3
#define NOTIFICATION_VAD_STOP_EVENT @"STOP_RECORDING"
typedef void (^RecognizeCallbackBlockType)(NSDictionary*, NSError*);
typedef void (^PowerLevelCallbackBlockType)(float);
typedef struct
{
    AudioStreamBasicDescription  dataFormat;
    AudioQueueRef                queue;
    AudioQueueBufferRef          buffers[NUM_BUFFERS];
    AudioFileID                  audioFile;
    SInt64                       currentPacket;
    bool                         recording;
    FILE*						 stream;
    int                          slot;
} RecordingState;


@interface SpeechToText()

@property NSString* pathPCM;
@property NSString* pathSPX;
@property NSTimer *PeakPowerTimer;
@property OpusHelper* opus;
@property RecordingState recordState;
@property WebSocketUploader* wsuploader;
@property (nonatomic,copy) RecognizeCallbackBlockType recognizeCallback;
@property (nonatomic,copy) PowerLevelCallbackBlockType powerLevelCallback;

@end

@implementation SpeechToText

@synthesize recognizeCallback;
@synthesize powerLevelCallback;



// static for use by c code
static BOOL isNewRecordingAllowed;
static BOOL isCompressedOpus;
static BOOL isCompressedSpeex;
static int audioRecordedLength;
static int serialno;
static NSString* tmpPCM=nil;
static NSString* tmpSPX;
static long pageSeq;
static bool isTempPathSet = false;
static bool isVadEnabled = true;


id uploaderRef;
id delegateRef;
id opusRef;




#pragma mark public methods

/**
 *  Static method to return a SpeechToText object given the service url
 *
 *  @param newURL the service url for the STT service
 *
 *  @return SpeechToText
 */
+(id)initWithConfig:(STTConfiguration *)config {
    
    SpeechToText *watson = [[self alloc] initWithConfig:config] ;
    return watson;
}

/**
 *  init method to return a SpeechToText object given the service url
 *
 *  @param newURL the service url for the STT service
 *
 *  @return SpeechToText
 */
- (id)initWithConfig:(STTConfiguration *)config {
    
    self.config = config;
    //[self setSpeechServer:newURL];
    
    // set audio encoding flags so they are accessible in c audio callbacks
    isCompressedOpus = [config.audioCodec isEqualToString:WATSONSDK_AUDIO_CODEC_TYPE_SPEEX] ? YES:NO;
    isCompressedSpeex =[config.audioCodec isEqualToString:WATSONSDK_AUDIO_CODEC_TYPE_OPUS] ? YES:NO;
    
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(didReceiveVadStopNotification:)
     name:NOTIFICATION_VAD_STOP_EVENT
     object:nil];
    
    isNewRecordingAllowed=YES;
    
    // setup opus helper
    self.opus = [[OpusHelper alloc] init];
    [self.opus createEncoder];
    opusRef = self->_opus;
    
    return self;
}

/**
 *  stream audio from the device microphone to the STT service
 *
 *  @param recognizeHandler (^)(NSDictionary*, NSError*)
 */
- (void) recognize:(void (^)(NSDictionary*, NSError*)) recognizeHandler {
    
    // perform asset here
    
    // store the block
    self.recognizeCallback = recognizeHandler;
    
    if(!isNewRecordingAllowed)
    {
        NSLog(@"Transcription already in progress");
        NSMutableDictionary* details = [NSMutableDictionary dictionary];
        [details setValue:@"A voice query is already in progress" forKey:NSLocalizedDescriptionKey];
        
        // populate the error object with the details
        NSError *recordError = [NSError errorWithDomain:@"com.ibm.cio.watsonsdk" code:409 userInfo:details];
        self.recognizeCallback(nil,recordError);
        return;
    }
    
    // don't allow a new recording to be allowed until this transaction has completed
    isNewRecordingAllowed= NO;
    [self startRecordingAudio];
    
    
}

-(void) endRecognize
{
    [self stopRecordingAudio];
    
    [self.wsuploader sendEndOfStreamMarker];
    
    isNewRecordingAllowed=YES;
}


/**
 *  listModels - List speech models supported by the service
 *
 *  @param handler(NSDictionary*, NSError*) block to be called when response has been received from the service
 */
- (void) listModels:(void (^)(NSDictionary*, NSError*))handler {
    
    [self performGet:handler forURL:[self.config getModelsServiceURL]];
    
}

/**
 *  listModel details with a given model ID
 *
 *  @param handler handler(NSDictionary*, NSError*) block to be called when response has been received from the service
 *  @param modelName the name of the model e.g. WatsonModel
 */
- (void) listModel:(void (^)(NSDictionary*, NSError*))handler withName:(NSString*) modelName {
    
    [self performGet:handler forURL:[self.config getModelServiceURL:modelName]];
    
}

/**
 *  setIsVADenabled
 *  User voice activated detection to automatically detect when speech has finished and stop the recognize operation
 *
 *  @param isEnabled true/false
 */
- (void) setIsVADenabled:(bool) isEnabled {
    
    isVadEnabled = isEnabled;
}


/**
 *  getTranscript - convenience method to get the transcript from the JSON results
 *
 *  @param results NSDictionary containing parsed JSON returned from the service
 *
 *  @return NSString containing transcript
 */
-(NSString*) getTranscript:(NSDictionary*) results {
    
    if([results objectForKey:@"results"] != nil) {
        
        NSArray *resultArray = [results objectForKey:@"results"];
        if( [resultArray count] != 0 && [resultArray objectAtIndex:0] != nil) {
            
            NSDictionary *result =[resultArray objectAtIndex:0];
            
            NSArray *alternatives = [result objectForKey:@"alternatives"];
            
            if([alternatives objectAtIndex:0] != nil) {
                NSDictionary *alternative = [alternatives objectAtIndex:0];
                
                if([alternative objectForKey:@"transcript"] != nil) {
                    NSString *transcript = [alternative objectForKey:@"transcript"];
                    
                    return transcript;
                }
            }
        }
    }
    
    return nil;
}

/**
 *  getPowerLevel - listen for updates to the Db level of the speaker, can be used for a voice wave visualization
 *
 *  @param powerHandler - callback block
 */
- (void) getPowerLevel:(void (^)(float)) powerHandler {
    
    self.powerLevelCallback = powerHandler;
}

#pragma mark private methods

/**
 *  performGet - shared method for performing GET requests to a given url calling a handler parameter with the result
 *
 *  @param handler (^)(NSDictionary*, NSError*))
 *  @param url     url to perform GET request on
 */
- (void) performGet:(void (^)(NSDictionary*, NSError*))handler forURL:(NSURL*)url{
    
    // Create and set authentication headers
    NSURLSessionConfiguration *defaultConfigObject = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSDictionary* headers = [self createRequestHeaders];
    [defaultConfigObject setHTTPAdditionalHeaders:headers];
    NSURLSession *defaultSession = [NSURLSession sessionWithConfiguration: defaultConfigObject delegate: self delegateQueue: [NSOperationQueue mainQueue]];
    
    
    NSURLSessionDataTask * dataTask = [defaultSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *reqError) {
        
        if(reqError == nil)
        {
            NSString * text = [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
            NSLog(@"Data = %@",text);
            
            NSError *localError = nil;
            NSDictionary *parsedObject = [NSJSONSerialization JSONObjectWithData:data options:0 error:&localError];
            
            if (localError != nil) {
                handler(nil,localError);
            } else {
                handler(parsedObject,nil);
            }
            
            
        } else {
            handler(nil,reqError);
        }
        
    }];
    
    [dataTask resume];
    
}

- (void) startRecordingAudio {
    
    // lets start the socket connection right away
    [self initializeStreaming];
    [self setFilePaths];
    [self setupAudioFormat:&_recordState.dataFormat];
    
    _recordState.currentPacket = 0;
    audioRecordedLength = 0;
    
    OSStatus status = AudioQueueNewInput(&_recordState.dataFormat,
                                         AudioInputStreamingCallback,
                                         &_recordState,
                                         CFRunLoopGetCurrent(),
                                         kCFRunLoopCommonModes,
                                         0,
                                         &_recordState.queue);
    
    
    if(status == 0) {
        
        for(int i = 0; i < NUM_BUFFERS; i++) {
            
            AudioQueueAllocateBuffer(_recordState.queue,
                                     16000.0, &_recordState.buffers[i]);
            AudioQueueEnqueueBuffer(_recordState.queue,
                                    _recordState.buffers[i], 0, NULL);
        }
        
        _recordState.stream=fopen([self.pathPCM UTF8String],"wb");
        BOOL openFileOk = (_recordState.stream!=NULL);
        
        if(openFileOk) {
            
            _recordState.recording = true;
            OSStatus rc = AudioQueueStart(_recordState.queue, NULL);
            UInt32 enableMetering = 1;
            status = AudioQueueSetProperty(_recordState.queue, kAudioQueueProperty_EnableLevelMetering, &enableMetering,sizeof(enableMetering));
            
            // start peak power timer
            self.PeakPowerTimer = [NSTimer scheduledTimerWithTimeInterval:0.125
                                                                   target:self
                                                                 selector:@selector(samplePeakPower)
                                                                 userInfo:nil
                                                                  repeats:YES];
            
            if (rc!=0) {
                NSLog(@"startPlaying AudioQueueStart returned %d.", (int)rc);
            } else {
                if(isVadEnabled)
                    _recordState.slot = VadProcessor_allocate(320,16000);//
            }
        }
    }
    
}



- (void) stopRecordingAudio {
    
    NSLog(@"stopRecordingAudio");
    
    [self.PeakPowerTimer invalidate];
    self.PeakPowerTimer = nil;
    [self setFilePaths];
    AudioQueueReset (_recordState.queue);
    AudioQueueStop (_recordState.queue, YES);
    AudioQueueDispose (_recordState.queue, YES);
    fclose(_recordState.stream);
    
    isNewRecordingAllowed = YES;
    NSLog(@"stopRecordingAudio->fclose done");
    
}


/**
 *  samplePeakPower - Get the decibel level from the AudioQueue
 */
- (void) samplePeakPower {
    
    AudioQueueLevelMeterState meters[1];
    UInt32 dlen = sizeof(meters);
    OSErr Status = AudioQueueGetProperty(_recordState.queue,kAudioQueueProperty_CurrentLevelMeterDB,meters,&dlen);
    
    if (Status == 0) {
        
        if(self.powerLevelCallback !=nil) {
            self.powerLevelCallback(meters[0].mAveragePower);
        }
        
    }
}



#pragma mark audio upload

- (NSDictionary*) createRequestHeaders {
    
    NSMutableDictionary *headers = [[NSMutableDictionary alloc] init];
    
    if(self.config.basicAuthPassword && self.config.basicAuthUsername) {
        NSString *authStr = [NSString stringWithFormat:@"%@:%@", self.config.basicAuthUsername,self.config.basicAuthPassword];
        NSData *authData = [authStr dataUsingEncoding:NSUTF8StringEncoding];
        NSString *authValue = [NSString stringWithFormat:@"Basic %@", [authData base64Encoding]];
        [headers setObject:authValue forKey:@"Authorization"];
    }
    
    return headers;
    
}



- (void) initializeStreaming {
    NSLog(@"CALL STARTING STREAM 1050");
    
    // init the websocket uploader if its nil
    if(self.wsuploader == nil) {
        self.wsuploader = [[WebSocketUploader alloc] init];
        [self.wsuploader setRecognizeHandler:recognizeCallback];
    }
    
    
    // connect if we are not connected
    if(![self.wsuploader isWebSocketConnected])
        [self.wsuploader connect:self.config headers:[self createRequestHeaders]];
    
    
    // set a pointer to the wsuploader class so it is accessible in the c callback
    uploaderRef = self.wsuploader;
    
    
    // write spx header
    if (isCompressedSpeex)
        [self writeSpeexHeader];
    
    
}


-(void)didReceiveVadStopNotification:(NSNotification *)notification {
    
    [self endRecognize];
    
}



#pragma mark audio

- (void)writeSpeexHeader {
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask, YES);
    NSString* docDir = [paths objectAtIndex:0];
    NSString *spxHeaderFile = [NSString stringWithFormat:@"%@%@",docDir,@"/header.bin"];
    FILE *fo_tmp = fopen([spxHeaderFile UTF8String], "wb");
    headerToFile(fo_tmp, serialno, &pageSeq);
    fclose(fo_tmp);
    
    [uploaderRef writeData:[NSData dataWithContentsOfFile:spxHeaderFile]];
}

- (void)setupAudioFormat:(AudioStreamBasicDescription*)format
{
    
    format->mSampleRate = 16000.0;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFramesPerPacket = 1;
    format->mChannelsPerFrame = 1;
    format->mBytesPerFrame = 2;
    format->mBytesPerPacket = 2;
    format->mBitsPerChannel = 16;
    format->mReserved = 0;
    format->mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
}

int getAudioRecordedLengthInMs()
{
    return audioRecordedLength/32;
}



void sendAudioOpusEncoded(NSData *data)
{
    if (data!=nil && [data length]!=0) {
        
        NSUInteger length = [data length];
        NSUInteger chunkSize = 160 * 2; // Frame Size * 2
        NSUInteger offset = 0;
        
        do {
            NSUInteger thisChunkSize = length - offset > chunkSize ? chunkSize : length - offset;
            NSData* chunk = [NSData dataWithBytesNoCopy:(char *)[data bytes] + offset
                                                 length:thisChunkSize
                                           freeWhenDone:NO];
            
            // opus encode block
            NSData *compressed = [opusRef encode:chunk];
            
            if(compressed !=nil)
                [uploaderRef writeData:compressed];
            
            offset += thisChunkSize;
        } while (offset < length);
    }
}

void sendAudioSpeexEncoded(NSData *data)
{
    if (data!=nil && [data length]!=0) {
        
        [SpeechToText setTmpFilePaths];
        [data writeToFile:tmpPCM atomically:YES];
        pcmEnc([tmpPCM UTF8String],[tmpSPX UTF8String], 0, serialno, &pageSeq);
        NSData *compressed = [NSData dataWithContentsOfFile:tmpSPX];
        [uploaderRef writeData:compressed];
        
    }
}


#pragma mark audio callbacks



void AudioInputStreamingCallback(
                                 void *inUserData,
                                 AudioQueueRef inAQ,
                                 AudioQueueBufferRef inBuffer,
                                 const AudioTimeStamp *inStartTime,
                                 UInt32 inNumberPacketDescriptions,
                                 const AudioStreamPacketDescription *inPacketDescs)
{
    OSStatus status=0;
    RecordingState* recordState = (RecordingState*)inUserData;
    
    
    
    NSData *data = [NSData  dataWithBytes:inBuffer->mAudioData length:inBuffer->mAudioDataByteSize];
    audioRecordedLength += [data length];
    
    if (isCompressedSpeex)
        sendAudioSpeexEncoded(data);
    else if(isCompressedOpus)
        sendAudioOpusEncoded(data);
    else
        [uploaderRef writeData:data];
        
    
    
    
    if(fwrite(inBuffer->mAudioData, 1,inBuffer->mAudioDataByteSize, recordState->stream)<=0) {
        status=-1;
    }
    
    if(isVadEnabled){
        VadProcessor_preprocessChunk(recordState->slot,(BYTE*)inBuffer->mAudioData,inBuffer->mAudioDataByteSize);
        
        if(VadProcessor_isPausing() == 1)
        {
            [[NSNotificationCenter defaultCenter] postNotificationName:NOTIFICATION_VAD_STOP_EVENT object:nil];
            if(status == 0) {
                recordState->currentPacket += inNumberPacketDescriptions;
            }
            
            AudioQueueEnqueueBuffer(recordState->queue, inBuffer, 0, NULL);
            
            NSLog(@"VAD Stop!");
            return;
        }
    }
    
    if(status == 0) {
        recordState->currentPacket += inNumberPacketDescriptions;
    }
    
    AudioQueueEnqueueBuffer(recordState->queue, inBuffer, 0, NULL);
}




#pragma mark utilities

+ (void) setTmpFilePaths{
    
    if (isTempPathSet) {
        return;
    }
    isTempPathSet = true;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
    NSString* docDir = [paths objectAtIndex:0];
    
    tmpPCM = [[NSString alloc]initWithFormat:@"%@%@",docDir,@"/tmp.pcm"];
    tmpSPX = [[NSString alloc]initWithFormat:@"%@%@",docDir,@"/tmp.spx"];
    
}

- (void) setFilePaths{
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                         NSUserDomainMask, YES);
    NSString* docDir = [paths objectAtIndex:0];
    
    self.pathPCM = [NSString stringWithFormat:@"%@%@",docDir,@"/out.pcm"];
    self.pathSPX = [NSString stringWithFormat:@"%@%@",docDir,@"/out.spx"];
    
}


@end
