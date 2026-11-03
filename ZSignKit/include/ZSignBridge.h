#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ZSignResultCode) {
    ZSignResultCodeSuccess = 0,
    ZSignResultCodeInvalidCertificate = 1,
    ZSignResultCodeInvalidBundle = 2,
    ZSignResultCodeSigningFailed = 3,
    ZSignResultCodeEngineUnavailable = 4
};

@interface ZSignResult : NSObject
@property (nonatomic, assign) ZSignResultCode code;
@property (nonatomic, copy, nullable) NSString *message;
/// Everything zsign printed while signing, without color codes.
@property (nonatomic, copy, nullable) NSString *log;
@property (nonatomic, assign) NSTimeInterval duration;
@end

@interface ZSignOptions : NSObject
@property (nonatomic, copy) NSString *p12Path;
@property (nonatomic, copy) NSString *p12Password;
@property (nonatomic, copy) NSString *provisionPath;
@property (nonatomic, copy, nullable) NSString *entitlementsPath;
@property (nonatomic, copy, nullable) NSString *bundleIdentifier;
@property (nonatomic, copy, nullable) NSString *bundleName;
@property (nonatomic, copy, nullable) NSString *bundleVersion;
@property (nonatomic, copy, nullable) NSString *bundleShortVersion;
@property (nonatomic, assign) BOOL forceSign;
@property (nonatomic, assign) BOOL weakInject;
@property (nonatomic, assign) BOOL injectIntoExtensions;
@property (nonatomic, assign) BOOL adhoc;
@property (nonatomic, copy) NSArray<NSString *> *dylibPathsToInject;
@property (nonatomic, copy) NSArray<NSString *> *dylibNamesToRemove;
@property (nonatomic, assign) BOOL removeExtensions;
@property (nonatomic, assign) BOOL removeWatchApp;
@property (nonatomic, assign) BOOL removeUISupportedDevices;
@property (nonatomic, copy, nullable) NSString *minimumOSVersion;
@property (nonatomic, copy, nullable) NSString *iconPath;
@property (nonatomic, assign) BOOL removeProvisionAfterSigning;
@end

@interface ZSignBridge : NSObject

+ (BOOL)isEngineAvailable;
+ (ZSignResult *)signAppFolderAtPath:(NSString *)folderPath
                              options:(ZSignOptions *)options
    NS_SWIFT_NAME(signAppFolder(atPath:options:));
+ (BOOL)generateSelfSignedIdentityAtP12Path:(NSString *)p12Path
                                    password:(NSString *)password
                                  commonName:(NSString *)commonName
                              validityInDays:(NSInteger)validityInDays
                                       error:(NSString * _Nullable * _Nullable)error
    NS_SWIFT_NAME(generateSelfSignedIdentity(atP12Path:password:commonName:validityInDays:error:));
+ (nullable NSData *)cmsContentFromData:(NSData *)data NS_SWIFT_NAME(cmsContent(from:));
+ (nullable NSDate *)notBeforeDateForCertificateData:(NSData *)certificateData NS_SWIFT_NAME(notBeforeDate(forCertificateData:));
+ (nullable NSDate *)notAfterDateForCertificateData:(NSData *)certificateData NS_SWIFT_NAME(notAfterDate(forCertificateData:));

@end

NS_ASSUME_NONNULL_END
