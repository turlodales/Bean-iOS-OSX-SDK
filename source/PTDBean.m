//
//  BeanDevice.m
//  BleArduino
//
//  Created by Raymond Kampmeier on 1/16/14.
//  Copyright (c) 2014 Punch Through Design. All rights reserved.
//

#import "PTDBean.h"
#import "PTDBean+Protected.h"
#import "PTDBeanManager+Protected.h"
#import "GattSerialProfile.h"
#import "BatteryProfile.h"
#import "AppMessages.h"
#import "AppMessagingLayer.h"
#import "NSData+CRC.h"
#import "PTDBeanRadioConfig.h"
#import "CBPeripheral+RSSI_Universal.h"
#import "PTDBeanRemoteFirmwareVersionManager.h"


#define DELAY_BEFORE_PROFILE_VALIDATION  0.5f
#define PROFILE_VALIDATION_RETRY_TIMEOUT  10.0f
#define PROFILE_VALIDATION_RETRIES    2
#define ARDUINO_OAD_MAX_CHUNK_SIZE 64

typedef enum { //These occur in sequence
    BeanArduinoOADLocalState_Inactive = 0,
	BeanArduinoOADLocalState_ResettingRemote,
	BeanArduinoOADLocalState_SendingStartCommand,
    BeanArduinoOADLocalState_SendingChunks,
    BeanArduinoOADLocalState_Finished,
} BeanArduinoOADLocalState;

@interface PTDBean () <CBPeripheralDelegate, AppMessagingLayerDelegate, OAD_Delegate, BatteryProfileDelegate>
@end

@implementation PTDBean
{
	BeanState                   _state;
	id<PTDBeanManager>          _beanManager;
    
    AppMessagingLayer*          appMessageLayer;
    
    NSTimer*                    validationRetryTimer;
    NSInteger                   validationRetryCount;
    DevInfoProfile*             deviceInfo_profile;
    OadProfile*                 oad_profile;
    GattSerialProfile*          gatt_serial_profile;
    BatteryProfile*             battery_profile;
    
    NSData*                     arduinoFwImage;
    NSInteger                   arduinoFwImage_chunkIndex;
    BeanArduinoOADLocalState    localArduinoOADState;
    NSTimer*                    arduinoOADStateTimout;
    NSTimer*                    arduinoOADChunkSendTimer;
    
    void (^firmwareUpdateAvailableHandler)(BOOL updateAvailable, NSError *error);
    NSDate*                     firmwareUpdateStartTime;
    
}
@dynamic delegate;

//Enforce that you can't use the "init" function of this class
- (id)init{
    NSAssert(false, @"Please use the \"initWithPeripheral:\" method to instantiate this class");
    return nil;
}

#pragma mark - Public Methods

- (BOOL)isEqual:(id)object {
    return [object isKindOfClass:[self class]] ? [self isEqualToBean:object] : NO;
}

- (NSUInteger)hash {
    return self.identifier.hash;
}

- (BOOL)isEqualToBean:(PTDBean *)bean {
    if([self.identifier isEqual:bean.identifier]){
        return YES;
    }
    return NO;
}

-(void)sendMessage:(GattSerialMessage*)message{
    [gatt_serial_profile sendMessage:message];
}

-(NSUUID*)identifier{
    if(_peripheral && _peripheral.identifier){
        return [_peripheral identifier];
    }
    return nil;
}
-(NSString*)name{
    //PTDLog(@"Bean advertname: %@", [_advertisementData objectForKey:CBAdvertisementDataLocalNameKey]);
    if(_peripheral.name){
        //PTDLog(@"Bean _peripheral.name: %@", _peripheral.name);
        return _peripheral.name;
    }
    return [_advertisementData objectForKey:CBAdvertisementDataLocalNameKey]?[_advertisementData objectForKey:CBAdvertisementDataLocalNameKey]:@"Unknown";//Local Name
}
-(NSNumber*)batteryVoltage{
    if([self connected]
       && battery_profile
       && [battery_profile batteryVoltage]){
        return [battery_profile batteryVoltage];
    }
    return nil;
}
-(BeanState)state{
    return _state;
}
-(NSDictionary*)advertisementData{
    return _advertisementData;
}
-(NSDate*)lastDiscovered{
    return _lastDiscovered;
}
-(NSString*)firmwareVersion{
    if(deviceInfo_profile && [deviceInfo_profile isValid:nil]){
        return deviceInfo_profile.firmwareVersion;
    }
    return nil;
}

-(PTDBeanManager*)beanManager{
    if(_beanManager){
        if([_beanManager isKindOfClass:[PTDBeanManager class]]){
            return _beanManager;
        }
    }
    return nil;
}

#pragma mark - SDK
- (void)releaseSerialGate {
  [appMessageLayer sendMessageWithID:MSG_ID_BT_END_GATE andPayload:nil];
}

- (BOOL)setPairingPin:(NSUInteger*)pinCode{
    if(![self connected]) {
        return FALSE;
    }
    
    if(pinCode){
        NSInteger pin = (UInt32)(*pinCode);
        if(pin < 0 || pin > 999999){
            //Pairing pin is not a positive integer with 6 digits or less
            return FALSE;
        }
    }
    BT_SET_PIN_T payload;
    payload.pinCode = pinCode?(UInt32)(*pinCode):(UInt32)0;
    payload.pincodeActive = pinCode?TRUE:FALSE;
    NSData *data = [NSData dataWithBytes:&payload length: sizeof(BT_SET_PIN_T)];
    [appMessageLayer sendMessageWithID:MSG_ID_BT_SET_PIN andPayload:data];
    return TRUE;
}
-(void)readArduinoSketchInfo{
    if(![self connected]) {
        return;
    }
    [appMessageLayer sendMessageWithID:MSG_ID_BL_GET_META andPayload:nil];
}
-(void)setArduinoPowerState:(ArduinoPowerState)state{
    if(![self connected])return;
    if(!(state == ArduinoPowerState_Off || state == ArduinoPowerState_On)) return;
    UInt8 byte = (state==ArduinoPowerState_On)?0x01:0x00;
    [appMessageLayer sendMessageWithID:MSG_ID_CC_POWER_ARDUINO andPayload:[NSData dataWithBytes:&byte length:1]];
    _arduinoPowerState = state;
}
-(void)readArduinoPowerState{
    if(![self connected])return;
    [appMessageLayer sendMessageWithID:MSG_ID_CC_GET_AR_POWER andPayload:nil];
}
-(void)programArduinoWithRawHexImage:(NSData*)hexImage andImageName:(NSString*)name{
    if(_state == BeanState_ConnectedAndValidated &&
       _peripheral.state == CBPeripheralStateConnected) //This second conditional is an assertion
    {
        [self __resetArduinoOADLocals];
        arduinoFwImage = hexImage?hexImage:[[NSData alloc] init];
        
        BL_SKETCH_META_DATA_T startPayload;
        NSData* commandPayload;
        UInt32 imageSize = (UInt32)[arduinoFwImage length];
        startPayload.hexSize = imageSize;
        startPayload.timestamp = [[NSDate date] timeIntervalSince1970];
        startPayload.hexCrc = [arduinoFwImage crc32];
        
        NSInteger maxNameLength = member_size(BL_SKETCH_META_DATA_T,hexName);
        if([name length] > maxNameLength){
            startPayload.hexNameSize = maxNameLength;
            const UInt8* nameBytes = [[[name substringWithRange:NSMakeRange(0,maxNameLength)] dataUsingEncoding:NSUTF8StringEncoding] bytes];
            memcpy(&(startPayload.hexName), nameBytes, maxNameLength);
        }else{
            startPayload.hexNameSize = [name length];
            const UInt8* nameBytes = [[name dataUsingEncoding:NSUTF8StringEncoding] bytes];
            memset(&(startPayload.hexName), ' ', maxNameLength);
            memcpy(&(startPayload.hexName), nameBytes, maxNameLength);
        }
        
        commandPayload = [[NSData alloc] initWithBytes:&startPayload length:sizeof(BL_SKETCH_META_DATA_T)];
        [appMessageLayer sendMessageWithID:MSG_ID_BL_CMD_START andPayload:commandPayload];

        localArduinoOADState = BeanArduinoOADLocalState_SendingStartCommand;
        if(imageSize!=0){
            [self __setArduinoOADTimeout:ARDUINO_OAD_GENERIC_TIMEOUT_SEC];
        }else{
            [self __resetArduinoOADLocals];
        }
    }else{
        NSError* error = [BEAN_Helper basicError:@"Bean isn't connected" domain:NSStringFromClass([self class]) code:100];
        [self __alertDelegateOfArduinoOADCompletion:error];
    }
}
-(void)sendSerialData:(NSData*)data{
    if(![self connected]) {
        return;
    }
    [appMessageLayer sendMessageWithID:MSG_ID_SERIAL_DATA andPayload:data];
}
-(void)sendSerialString:(NSString*)string{
    NSData* data = [string dataUsingEncoding:NSUTF8StringEncoding];
    [self sendSerialData:data];
}
- (void)readRadioConfig {
    if(![self connected]) {
        PTDLog(@"Can't read radio config, not connect.");
        return;
    }
    PTDLog(@"Sending command to read radio config.");
    [appMessageLayer sendMessageWithID:MSG_ID_BT_GET_CONFIG andPayload:nil];
}
-(void)setRadioConfig:(PTDBeanRadioConfig*)config {
    if(![self connected]) {
        return;
    }
    NSError *error;
    if (![config validate:&error]) {

        return;
    }
    BT_RADIOCONFIG_T raw;
    raw.adv_int = config.advertisingInterval;
    raw.conn_int = config.connectionInterval;
    raw.adv_mode = config.advertisingMode;
    raw.ibeacon_uuid = config.iBeacon_UUID;
    raw.ibeacon_major = config.iBeacon_majorID;
    raw.ibeacon_minor = config.iBeacon_minorID;
    
    const UInt8* nameBytes = [[config.name dataUsingEncoding:NSUTF8StringEncoding] bytes];
    UInt8 nameBytesLength = [[config.name dataUsingEncoding:NSUTF8StringEncoding] length];
    memset(&(raw.local_name), ' ', nameBytesLength);
    memcpy(&(raw.local_name), nameBytes, nameBytesLength);
    
    raw.local_name_size = nameBytesLength;
    raw.power = config.power;
    NSData *data = [NSData dataWithBytes:&raw length: sizeof(BT_RADIOCONFIG_T)];
    if ( config.configSave )
        [appMessageLayer sendMessageWithID:MSG_ID_BT_SET_CONFIG andPayload:data];
    else
        [appMessageLayer sendMessageWithID:MSG_ID_BT_SET_CONFIG_NOSAVE andPayload:data];

}
-(void)readAccelerationAxes {
    if(![self connected]) {
        return;
    }
    [appMessageLayer sendMessageWithID:MSG_ID_CC_ACCEL_READ andPayload:nil];
}
//Deprecated
-(void)readAccelerationAxis {
    [self readAccelerationAxes];
}
-(void)readBatteryVoltage{
    if(battery_profile){
        [battery_profile readBattery];
    }
}
-(void)readTemperature {
    if(![self connected]) {
        return;
    }
    [appMessageLayer sendMessageWithID:MSG_ID_CC_TEMP_READ andPayload:nil];
}
#if TARGET_OS_IPHONE
-(void)setLedColor:(UIColor*)color
#else
-(void)setLedColor:(NSColor*)color
#endif
{
    if(![self connected]) {
        return;
    }
    CGFloat red;
    CGFloat green;
    CGFloat blue;
    CGFloat alpha;
    [color getRed:&red green:&green blue:&blue alpha:&alpha];
    
    UInt8 redComponent = (alpha)*(red)*255.0;
    UInt8 greenComponent = (alpha)*(green)*255.0;
    UInt8 blueComponent = (alpha)*(blue)*255.0;
    UInt8 bytes[] = {redComponent,greenComponent,blueComponent};
    NSData *data = [NSData dataWithBytes:bytes length:3];
    
    [appMessageLayer sendMessageWithID:MSG_ID_CC_LED_WRITE_ALL andPayload:data];
}
-(void)readLedColor {
    if(![self connected]) {
        return;
    }
    [appMessageLayer sendMessageWithID:MSG_ID_CC_LED_READ_ALL andPayload:nil];
}
    
//This method is deprecated
-(void)setScratchNumber:(NSInteger)scratchNumber withValue:(NSData*)value{
    [self setScratchBank:scratchNumber data:value];
}
    
-(void)setScratchBank:(NSInteger)bank data:(NSData*)data{
    if(![self connected]) {
        return;
    }
    if(![self validScratchNumber:bank]) {
        return;
    }
    if (data.length>20) {
        if(self.delegate && [self.delegate respondsToSelector:@selector(bean:error:)]) {
            NSError *error = [BEAN_Helper basicError:@"Scratch value exceeds 20 character limit" domain:NSStringFromClass([self class]) code:BeanErrors_InvalidArgument];
            [self.delegate bean:self error:error];
        }
        data = [data subdataWithRange:NSMakeRange(0, 20)];
    }
    UInt8 bankNum = bank;
    NSMutableData *payload = [NSMutableData dataWithBytes:&bankNum length:1];
    [payload appendData:data];
    [appMessageLayer sendMessageWithID:MSG_ID_BT_SET_SCRATCH andPayload:payload];
}
- (void)readScratchBank:(NSInteger)bank {
    if(![self connected]) {
        return;
    }
    if(![self validScratchNumber:bank]) {
        return;
    }
    NSData *data = [NSData dataWithBytes:&bank length: sizeof(UInt8)];
    [appMessageLayer sendMessageWithID:MSG_ID_BT_GET_SCRATCH andPayload:data];
}
-(void)getConfig {
    if(![self connected]) {
        return;
    }
    [appMessageLayer sendMessageWithID:MSG_ID_BT_GET_CONFIG andPayload:nil];
}

-(BOOL)updateFirmwareWithImagePaths:(NSArray*)firmwareImages{
    if(!oad_profile)return FALSE;
    return [oad_profile updateFirmwareWithImagePaths:firmwareImages];
}

-(BOOL)firmwareCurrent{
    if ( [self connected] ) {
        PTDLog(@"Current firmware: %lld newest available firmware: %lld", self.firmwareVersion.longLongValue, self.newestAvailableFirmwareVersion.longLongValue);
        
        // Special case: OAD only image
        if ( self.firmwareVersion.longLongValue >= self.newestAvailableFirmwareVersion.longLongValue )
            return TRUE;
    }
    return FALSE;
}
    
- (void)checkFirmwareUpdateAvailableWithHandler:(void (^)(BOOL updateAvailable, NSError *error))handler{
    

    if ( [self firmwareVersion] ) {
        [[PTDBeanRemoteFirmwareVersionManager sharedInstance] checkForNewFirmwareWithCompletion:^(NSString *mostRecentFirmwareVersion, NSError *error){
            if(error){ return; }
            self.newestAvailableFirmwareVersion = mostRecentFirmwareVersion;
            
            handler( ![self firmwareCurrent], nil );
            
        }];
    } else
        firmwareUpdateAvailableHandler = handler;   // Wait until device info is valid
}

- (void)updateFirmware{
    
    // TODO: make sure OAD profile is valid
    
    _updateInProgress = TRUE;
    if (!firmwareUpdateStartTime) firmwareUpdateStartTime = [NSDate date];
    
    // Shorter connection interval -> faster transfer
    PTDBeanRadioConfig *config = [[PTDBeanRadioConfig alloc] init];
    if (self.radioConfig) {
        config.power = self.radioConfig.power;
        config.name = self.radioConfig.name;
    } else {
        config.power = PTDTxPower_4dB;
        config.name = @"Bean";
    }
    config.connectionInterval = 20;
    config.advertisingInterval = 100;
    config.configSave = FALSE;
    [self setRadioConfig:config];
    
    [[PTDBeanRemoteFirmwareVersionManager sharedInstance] checkForNewFirmwareWithCompletion:^(NSString *mostRecentFirmwareVersion, NSError *error){
        if(error){ return; }
        self.newestAvailableFirmwareVersion = mostRecentFirmwareVersion;
    
    
        [[PTDBeanRemoteFirmwareVersionManager sharedInstance] fetchFirmwareForVersion:self.newestAvailableFirmwareVersion withCompletion:^(NSArray *firmwareImagePaths, NSError *error) {
            PTDLog(@"Updating bean firmware.");
            if (!error)
                [oad_profile updateFirmwareWithImagePaths:firmwareImagePaths];
            
        }];
    }];
}

- (void)cancelFirmwareUpdate{
    if (self.updateInProgress) {
        _updateInProgress = FALSE;
        if (oad_profile)
            [oad_profile cancel];
    }
}

#pragma mark - Protected Methods
-(id)initWithPeripheral:(CBPeripheral*)peripheral beanManager:(id<PTDBeanManager>)manager{
    self = [super initWithPeripheral:peripheral];
    if (self) {
        _beanManager = manager;
        localArduinoOADState = BeanArduinoOADLocalState_Inactive;
        _arduinoPowerState = ArduinoPowerState_Unknown;
    }
    return self;
}

-(void)discoverServices{
    
    oad_profile = nil;
    deviceInfo_profile = nil;
    gatt_serial_profile = nil;
    battery_profile = nil;
    
    [super discoverServices];
    _state = BeanState_ConnectedAndValidated;
    if(_beanManager){
        if([_beanManager respondsToSelector:@selector(bean:hasBeenValidated_error:)]){
            [_beanManager bean:self hasBeenValidated_error:nil];
        }
    }
}
    
-(CBPeripheral*)peripheral{
    return _peripheral;
}
-(void)setState:(BeanState)state{
    _state = state;
}
-(void)setRSSI:(NSNumber*)rssi{
    _RSSI = rssi;
}
-(void)setAdvertisementData:(NSDictionary*)adData{
    _advertisementData = adData;
}
-(void)setLastDiscovered:(NSDate*)date{
    _lastDiscovered = date;
}
-(void)setBeanManager:(id<PTDBeanManager>)manager{
    _beanManager = manager;
}

#pragma mark - Private Methods

-(void)__alertDelegateOfArduinoOADCompletion:(NSError*)error{
    [self __resetArduinoOADLocals];
    if(self.delegate){
        if([self.delegate respondsToSelector:@selector(bean:didProgramArduinoWithError:)]){
            [self.delegate bean:self didProgramArduinoWithError:error];
        }
    } 
}
-(void)__resetArduinoOADLocals{
    arduinoFwImage = nil;
    arduinoFwImage_chunkIndex = 0;
    localArduinoOADState = BeanArduinoOADLocalState_Inactive;
    if (arduinoOADStateTimout) [arduinoOADStateTimout invalidate];
    arduinoOADStateTimout = nil;
    if (arduinoOADChunkSendTimer) [arduinoOADChunkSendTimer invalidate];
    arduinoOADChunkSendTimer = nil;
}
-(void)__setArduinoOADTimeout:(NSTimeInterval)duration{
    if (arduinoOADStateTimout) [arduinoOADStateTimout invalidate];
    arduinoOADStateTimout = [NSTimer scheduledTimerWithTimeInterval:duration target:self selector:@selector(__arduinoOADTimeout:) userInfo:nil repeats:NO];
}
-(void)__arduinoOADTimeout:(NSTimer*)timer{
    NSError* error = [BEAN_Helper basicError:@"Sketch upload failed!" domain:NSStringFromClass([self class]) code:0];
    [self __alertDelegateOfArduinoOADCompletion:error];
}

-(void)__sendArduinoOADChunk{ //Call this once. It will continue until the entire FW has been unloaded
    if(arduinoFwImage_chunkIndex >= arduinoFwImage.length){
        if (arduinoOADChunkSendTimer) [arduinoOADChunkSendTimer invalidate];
        arduinoOADChunkSendTimer = nil;
    }else{
        NSInteger chunksize = (arduinoFwImage_chunkIndex + ARDUINO_OAD_MAX_CHUNK_SIZE > arduinoFwImage.length)? arduinoFwImage.length-arduinoFwImage_chunkIndex:ARDUINO_OAD_MAX_CHUNK_SIZE;
        
        NSData* chunk = [arduinoFwImage subdataWithRange:NSMakeRange(arduinoFwImage_chunkIndex, chunksize)];
        arduinoFwImage_chunkIndex+=chunksize;

        [appMessageLayer sendMessageWithID:MSG_ID_BL_FW_BLOCK andPayload:chunk];
        
        if (arduinoOADChunkSendTimer) [arduinoOADChunkSendTimer invalidate];
        arduinoOADChunkSendTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(__sendArduinoOADChunk) userInfo:nil repeats:NO];
        
        if(self.delegate){
            if([self.delegate respondsToSelector:@selector(bean:ArduinoProgrammingTimeLeft:withPercentage:)]){
                NSNumber* percentComplete = @(arduinoFwImage_chunkIndex * 1.0f / arduinoFwImage.length);
                NSNumber* timeRemaining = @(0.2 * ((arduinoFwImage.length - arduinoFwImage_chunkIndex)/ARDUINO_OAD_MAX_CHUNK_SIZE));
                [self.delegate bean:self ArduinoProgrammingTimeLeft:timeRemaining withPercentage:percentComplete];
            }
        }
    }
}
-(void)__handleArduinoOADRemoteStateChange:(BL_HL_STATE_T)state{
    switch (state) {
        case BL_HL_STATE_NULL:
            break;
        case BL_HL_STATE_INIT:
#if defined(ARDUINO_OAD_RESET_BEFORE_DL)
            if(localArduinoOADState == BeanArduinoOADLocalState_ResettingRemote){
                if (arduinoOADStateTimout) [arduinoOADStateTimout invalidate];
                data = [[NSData alloc] initWithBytes:startBytes length:3];
                [appMessageLayer sendMessageWithID:MSG_ID_BL_CMD andPayload:data];
                localArduinoOADState = BeanArduinoOADLocalState_SendingStartCommand;
                [self __setArduinoOADTimeout:ARDUINO_OAD_GENERIC_TIMEOUT_SEC];
            }
#endif
            break;
        case BL_HL_STATE_READY:
            if(localArduinoOADState == BeanArduinoOADLocalState_SendingStartCommand){
                [self __setArduinoOADTimeout:ARDUINO_OAD_GENERIC_TIMEOUT_SEC];
                //Send first Chunk
                [self __sendArduinoOADChunk];
                localArduinoOADState = BeanArduinoOADLocalState_SendingChunks;
            }else{
                [self __setArduinoOADTimeout:ARDUINO_OAD_GENERIC_TIMEOUT_SEC];
            }
            break;
        case BL_HL_STATE_PROGRAMMING:
            [self __setArduinoOADTimeout:ARDUINO_OAD_GENERIC_TIMEOUT_SEC];
            break;
        case BL_HL_STATE_VERIFY:
            break;
        case BL_HL_STATE_COMPLETE:
            [self __alertDelegateOfArduinoOADCompletion:nil];
            break;
        case BL_HL_STATE_ERROR:
        {
            NSError *error = [BEAN_Helper basicError:@"Sketch upload failed!" domain:NSStringFromClass([self class]) code:0];
            [self __alertDelegateOfArduinoOADCompletion:error];
            break;
        }
        default:
            break;
    }
}
 
-(BOOL)connected {
    if(_state != BeanState_ConnectedAndValidated ||
       _peripheral.state != CBPeripheralStateConnected) //This second conditional is an assertion
    {
        return NO;
    }
    return YES;
}
-(BOOL)validScratchNumber:(NSInteger)scratchNumber {
    if (scratchNumber<1 || scratchNumber>5) {
        if(self.delegate && [self.delegate respondsToSelector:@selector(bean:error:)]) {
            NSError *error = [BEAN_Helper basicError:@"Scratch numbers need to be 1-5" domain:NSStringFromClass([self class]) code:BeanErrors_InvalidArgument];
            [self.delegate bean:self error:error];
        }
        return NO;
    }
    return YES;
}
    
#pragma mark BleDevice Overridden Methods
-(void)rssiDidUpdateWithError:(NSError*)error{
    if (self.delegate && [self.delegate respondsToSelector:@selector(beanDidUpdateRSSI:error:)]) {
        [self.delegate beanDidUpdateRSSI:self error:error];
    }
}

-(void)servicesHaveBeenModified{
    // TODO: Re-Instantiate the Bean object
}
    
#pragma mark Profile Delegate callbacks
-(void)profileDiscovered:(BleProfile*)profile
{

    
    if ([profile isMemberOfClass:[OadProfile class]]) {
        oad_profile = (OadProfile*)profile;

    } else if ([profile isMemberOfClass:[DevInfoProfile class]]) {
        
        deviceInfo_profile = (DevInfoProfile*)profile;
        
        [deviceInfo_profile readFirmwareVersionWithCompletion:^{
            if (self.updateInProgress) {
                if ( [self firmwareCurrent] ) {
                    PTDLog(@"firmware update complete in %f seconds.", -[firmwareUpdateStartTime timeIntervalSinceNow]);
                    firmwareUpdateStartTime = NULL;
                    _updateInProgress = FALSE;
                    if(_delegate){
                        if([_delegate respondsToSelector:@selector(bean:completedFirmwareUploadWithError:)]){
                            [(id<PTDBeanExtendedDelegate>)_delegate bean:self completedFirmwareUploadWithError:NULL];
                        }
                    }
                } else {
                    PTDLog(@"firmware update continues");
                    [self updateFirmware];
                }
            } else if ( [self.firmwareVersion rangeOfString:@"OAD Only"].location != NSNotFound ) {
                    PTDLog(@"Discovered partially updated Bean. Update Required.");
                    [self updateFirmware];
            }
            if ( !self.updateInProgress && firmwareUpdateAvailableHandler ){
                [self checkFirmwareUpdateAvailableWithHandler:firmwareUpdateAvailableHandler];
                firmwareUpdateAvailableHandler = nil;
                
            }
        }];

    }
    else if ([profile isMemberOfClass:[GattSerialProfile class]]) {
        gatt_serial_profile = (GattSerialProfile*)profile;
        appMessageLayer = [[AppMessagingLayer alloc] initWithGattSerialProfile:gatt_serial_profile];
        appMessageLayer.delegate = self;
        gatt_serial_profile.delegate = appMessageLayer;
        __weak typeof(self) weakSelf = self;
        gatt_serial_profile.validationcompletion = ^(NSError* error) {
            if ( !error && [gatt_serial_profile isValid:nil] ) {
                [weakSelf releaseSerialGate];
                //[weakSelf readRadioConfig];
            }
        };
    } else if ([profile isMemberOfClass:[BatteryProfile class]]) {
        battery_profile = (BatteryProfile*)profile;
        __weak typeof(self) weakSelf = self;
        battery_profile.validationcompletion = ^(NSError *error) {
            [weakSelf batteryProfileDidUpdate];
        };
    }
}

    
#pragma mark -
#pragma mark AppMessagingLayerDelegate callbacks
-(void)appMessagingLayer:(AppMessagingLayer*)layer recievedIncomingMessageWithID:(UInt16)identifier andPayload:(NSData*)payload{
    UInt16 identifier_type = identifier & ~(APP_MSG_RESPONSE_BIT);
    switch (identifier_type) {
        case MSG_ID_SERIAL_DATA:
            PTDLog(@"App Message Received: MSG_ID_SERIAL_DATA: %@", payload);
            if (self.delegate && [self.delegate respondsToSelector:@selector(bean:serialDataReceived:)]) {
                [self.delegate bean:self serialDataReceived:payload];
            }
            break;
        case MSG_ID_BT_SET_ADV:
            PTDLog(@"App Message Received: MSG_ID_BT_SET_ADV: %@", payload);
            break;
        case MSG_ID_BT_SET_TX_PWR:
            PTDLog(@"App Message Received: MSG_ID_BT_SET_TX_PWR: %@", payload);
            break;
        case MSG_ID_BT_GET_CONFIG: {
            PTDLog(@"App Message Received: MSG_ID_BT_GET_CONFIG: %@", payload);
            if(payload.length != sizeof(BT_RADIOCONFIG_T)){
                PTDLog(@"Invalid length of MSG_ID_BT_GET_CONFIG. Most likely an outdated version of FW");
                break;
            }

            BT_RADIOCONFIG_T rawData;
            [payload getBytes:&rawData range:NSMakeRange(0, sizeof(BT_RADIOCONFIG_T))];
            PTDBeanRadioConfig *config = [[PTDBeanRadioConfig alloc] init];
            config.advertisingInterval = rawData.adv_int;
            config.connectionInterval = rawData.conn_int;
            // The (rawData.adv_mode != 0xFF) check is to catch a FW bug!
            config.pairingPinEnabled = ((rawData.adv_mode & 0x80) && (rawData.adv_mode != 0xFF) )?TRUE:FALSE;
            config.advertisingMode = rawData.adv_mode & (~0x80);
            config.iBeacon_UUID = rawData.ibeacon_uuid;
            config.iBeacon_majorID = rawData.ibeacon_major;
            config.iBeacon_minorID = rawData.ibeacon_minor;
            
            config.name = [NSString stringWithUTF8String:(char*)rawData.local_name];
            config.power = rawData.power;
            _radioConfig = config;
            
            PTDLog(@"Radio config - Name: '%@' Advertising interval: %d Connection interval: %d", config.name, rawData.adv_int, rawData.conn_int );
            
            if (self.delegate && [self.delegate respondsToSelector:@selector(bean:didUpdateRadioConfig:)]) {
                [self.delegate bean:self didUpdateRadioConfig:config];
            }
            break;
        }
        case MSG_ID_BT_ADV_ONOFF:
            PTDLog(@"App Message Received: MSG_ID_BT_ADV_ONOFF: %@", payload);
            break;
        case MSG_ID_BT_SET_SCRATCH:
            PTDLog(@"App Message Received: MSG_ID_BT_SET_SCRATCH: %@", payload);
            break;
        case MSG_ID_BT_GET_SCRATCH:
            PTDLog(@"App Message Received: MSG_ID_BT_GET_SCRATCH: %@", payload);
            if (self.delegate) {
                BT_SCRATCH_T rawData;
                [payload getBytes:&rawData range:NSMakeRange(0, payload.length)];
                NSData *scratch = [NSData dataWithBytes:rawData.scratch length:payload.length];
                //This delegate call has been deprecated!
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                if([self.delegate respondsToSelector:@selector(bean:didUpdateScratchNumber:withValue:)]){
                    [self.delegate bean:self didUpdateScratchNumber:@(rawData.number) withValue:scratch];
                }
#pragma clang diagnostic pop
                if([self.delegate respondsToSelector:@selector(bean:didUpdateScratchBank:data:)]){
                    [self.delegate bean:self didUpdateScratchBank:rawData.number data:scratch];
                }
            }
            break;
        case MSG_ID_BT_RESTART:
            PTDLog(@"App Message Received: MSG_ID_BT_RESTART: %@", payload);
            break;
        case MSG_ID_BL_CMD_START:
            PTDLog(@"App Message Received: MSG_ID_BL_CMD_START: %@", payload);
            break;
        case MSG_ID_BL_FW_BLOCK:
            PTDLog(@"App Message Received: MSG_ID_BL_FW_BLOCK: %@", payload);
            break;
        case MSG_ID_BL_STATUS:
            PTDLog(@"App Message Received: MSG_ID_BL_STATUS: %@", payload);
            BL_MSG_STATUS_T stateMsg;
            [payload getBytes:&stateMsg range:NSMakeRange(0, sizeof(BL_MSG_STATUS_T))];
            BL_HL_STATE_T highLevelState = stateMsg.hlState;
//            BL_STATE_T internalState = stateMsg.intState;
//            UInt16 blocks = stateMsg.blocksSent;
//            UInt16 bytes = stateMsg.bytesSent;
            [self __handleArduinoOADRemoteStateChange:highLevelState];
            break;
        case MSG_ID_CC_GET_AR_POWER:
            PTDLog(@"App Message Received: MSG_ID_CC_GET_AR_POWER: %@", payload);
            UInt8 powerState;
            [payload getBytes:&powerState range:NSMakeRange(0, 1)];
            _arduinoPowerState = powerState?ArduinoPowerState_On:ArduinoPowerState_Off;
            if (self.delegate && [self.delegate respondsToSelector:@selector(beanDidUpdateArduinoPowerState:)]) {
                [self.delegate beanDidUpdateArduinoPowerState:self];
            }
            break;
        case MSG_ID_BL_GET_META:
        {
            PTDLog(@"App Message Received: MSG_ID_BL_GET_META: %@", payload);
            BL_SKETCH_META_DATA_T meta;
            [payload getBytes:&meta range:NSMakeRange(0, sizeof(BL_SKETCH_META_DATA_T))];
            UInt8 nameSize = (meta.hexNameSize < member_size(BL_SKETCH_META_DATA_T, hexName))? meta.hexNameSize:member_size(BL_SKETCH_META_DATA_T, hexName);
            NSData* nameBytes = [[NSData alloc] initWithBytes:meta.hexName length:nameSize];
            NSString* name = [[NSString alloc] initWithData:nameBytes encoding:NSUTF8StringEncoding];
            NSDate *date = [NSDate dateWithTimeIntervalSince1970:meta.timestamp];
            _sketchName = name;
            _dateProgrammed = date;
            if (self.delegate && [self.delegate respondsToSelector:@selector(bean:didUpdateSketchName:dateProgrammed:crc32:)]) {
                [self.delegate bean:self didUpdateSketchName:name dateProgrammed:date crc32:meta.hexCrc];
            }
        }
            break;
        case MSG_ID_CC_LED_WRITE:
            PTDLog(@"App Message Received: MSG_ID_CC_LED_WRITE: %@", payload);
            break;
        case MSG_ID_CC_LED_WRITE_ALL:
            PTDLog(@"App Message Received: MSG_ID_CC_LED_WRITE_ALL: %@", payload);
            break;
        case MSG_ID_CC_LED_READ_ALL:
            PTDLog(@"App Message Received: MSG_ID_CC_LED_READ_ALL: %@", payload);
            if (self.delegate && [self.delegate respondsToSelector:@selector(bean:didUpdateLedColor:)]) {
                LED_SETTING_T rawData;
                [payload getBytes:&rawData range:NSMakeRange(0, sizeof(LED_SETTING_T))];
#if TARGET_OS_IPHONE
                UIColor *color = [UIColor colorWithRed:rawData.red/255.0f green:rawData.green/255.0f blue:rawData.blue/255.0f alpha:1];
                [self.delegate bean:self didUpdateLedColor:color];
#else
                NSColor *color = [NSColor colorWithRed:rawData.red/255.0f green:rawData.green/255.0f blue:rawData.blue/255.0f alpha:1];
                [self.delegate bean:self didUpdateLedColor:color];
#endif
            }
            break;
        case MSG_ID_CC_ACCEL_READ:
        {
            PTDLog(@"App Message Received: MSG_ID_CC_ACCEL_READ: %@", payload);
            if (self.delegate && [self.delegate respondsToSelector:@selector(bean:didUpdateAccelerationAxes:)]) {
                ACC_READING_T rawData;
                UInt8 sensitivity; //sensitivity is in units of g/512LSB
                if(payload.length == sizeof(ACC_READING_T)){ //This is the latest and greatest Accelerometer message
                    [payload getBytes:&rawData range:NSMakeRange(0, sizeof(ACC_READING_T))];
                    sensitivity = rawData.sensitivity;
                }else if(payload.length == 6){ //Legacy Accelerometer message
                    [payload getBytes:&rawData range:NSMakeRange(0, 6)];
                    sensitivity = 2;
                }else{ // unknown payload
                    break;
                }
                float lsbGConversionFactor = sensitivity/512.0;
                PTDAcceleration acceleration;
                acceleration.x = rawData.xAxis * lsbGConversionFactor;
                acceleration.y = rawData.yAxis * lsbGConversionFactor;
                acceleration.z = rawData.zAxis * lsbGConversionFactor;
                [self.delegate bean:self didUpdateAccelerationAxes:acceleration];
            }
            break;
        }
        case MSG_ID_CC_TEMP_READ:
        {
            PTDLog(@"App Message Received: MSG_ID_CC_TEMP_READ: %@", payload);
            if (self.delegate && [self.delegate respondsToSelector:@selector(bean:didUpdateTemperature:)]) {
                SInt8 temp;
                [payload getBytes:&temp range:NSMakeRange(0, sizeof(SInt8))];
                [self.delegate bean:self didUpdateTemperature:@(temp)];
            }
            break;
        }
        case MSG_ID_DB_COUNTER:
            PTDLog(@"App Message Received: MSG_ID_DB_COUNTER: %@", payload);
            break;
            
        default:
            break;
    }
}
-(void)appMessagingLayer:(AppMessagingLayer*)layer error:(NSError*)error{
    //TODO: Add some more error handling in here
}


#pragma mark OAD callbacks

-(void)device:(OadProfile*)device completedFirmwareUploadWithError:(NSError*)error{
    if(self.delegate){
        if([self.delegate respondsToSelector:@selector(bean:completedFirmwareUploadWithError:)]){
            [(id<PTDBeanExtendedDelegate>)self.delegate bean:self completedFirmwareUploadWithError:error];
        }
    }
}
-(void)device:(OadProfile*)device OADUploadTimeLeft:(NSNumber*)seconds withPercentage:(NSNumber*)percentageComplete{
    if(self.delegate){
        if([self.delegate respondsToSelector:@selector(bean:firmwareUploadTimeLeft:withPercentage:)]){
            [(id<PTDBeanExtendedDelegate>)self.delegate bean:self firmwareUploadTimeLeft:seconds withPercentage:percentageComplete];
        }
    }
}
    
#pragma mark Battery Monitoring Delegate callbacks
-(void)batteryProfileDidUpdate:(BatteryProfile*)profile{
    if(self.delegate){
        if([self.delegate respondsToSelector:@selector(beanDidUpdateBatteryVoltage:error:)]){
            [self.delegate beanDidUpdateBatteryVoltage:self error:nil];
        }
    }
}


@end
