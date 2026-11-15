#import <React/RCTBridgeModule.h>

// The bridge's method list; SignOpsRN.swift does the work through the SignOps Swift SDK.
@interface RCT_EXTERN_MODULE(SignOpsRN, NSObject)
RCT_EXTERN_METHOD(approveStatus:(NSString *)key base:(NSString *)base resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(approveEnroll:(NSString *)key base:(NSString *)base token:(NSString *)token pushToken:(NSString *)pushToken name:(NSString *)name resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(approvePending:(NSString *)key base:(NSString *)base resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(approveApprove:(NSString *)key base:(NSString *)base req:(NSDictionary *)req picked:(NSString *)picked title:(NSString *)title resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(approveDeny:(NSString *)key base:(NSString *)base req:(NSDictionary *)req resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(approveUpdatePushToken:(NSString *)key base:(NSString *)base token:(NSString *)token resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(approveForget:(NSString *)key base:(NSString *)base resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(pushOpened:(NSString *)key base:(NSString *)base data:(NSDictionary *)data action:(NSString *)action resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(passkeysRegister:(NSString *)key base:(NSString *)base token:(NSString *)token name:(NSString *)name resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
RCT_EXTERN_METHOD(passkeysSignIn:(NSString *)key base:(NSString *)base userId:(NSString *)userId resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject)
+ (BOOL)requiresMainQueueSetup { return NO; }
@end
