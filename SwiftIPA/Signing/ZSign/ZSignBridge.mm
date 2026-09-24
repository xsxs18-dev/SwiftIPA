#import "ZSignBridge.h"

#if SWIFTIPA_HAS_ZSIGN
#include "bundle.h"
#include "openssl.h"
#include <list>
#include <vector>
#include <QuartzCore/QuartzCore.h>
#include <openssl/x509.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>
#include <openssl/rsa.h>
#include <openssl/evp.h>
#include <openssl/x509v3.h>
#include <openssl/asn1.h>
#include <openssl/bio.h>
#include <time.h>
#include <unistd.h>
#endif

@implementation ZSignResult
@end

@implementation ZSignOptions
@end

@interface ZSignBridge ()
+ (nullable NSDate *)dateFromCertificateData:(NSData *)certificateData notAfter:(BOOL)wantsNotAfter;
#if SWIFTIPA_HAS_ZSIGN
+ (NSString *)captureStdoutDuringBlock:(void (^)(void))block;
+ (nullable NSString *)lastErrorLineFromCapturedOutput:(NSString *)output;
#endif
@end

@implementation ZSignBridge

#if SWIFTIPA_HAS_ZSIGN
+ (NSString *)captureStdoutDuringBlock:(void (^)(void))block {
    int pipeFDs[2];
    if (0 != pipe(pipeFDs)) {
        block();
        return @"";
    }
    int readFD = pipeFDs[0];
    int writeFD = pipeFDs[1];
    int savedStdout = dup(STDOUT_FILENO);
    dup2(writeFD, STDOUT_FILENO);
    close(writeFD);

    NSMutableData *captured = [NSMutableData data];
    dispatch_semaphore_t readerDone = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        uint8_t buffer[4096];
        ssize_t bytesRead;
        while ((bytesRead = read(readFD, buffer, sizeof(buffer))) > 0) {
            [captured appendBytes:buffer length:(NSUInteger)bytesRead];
        }
        close(readFD);
        dispatch_semaphore_signal(readerDone);
    });

    block();

    fflush(stdout);
    dup2(savedStdout, STDOUT_FILENO);
    close(savedStdout);
    dispatch_semaphore_wait(readerDone, DISPATCH_TIME_FOREVER);

    NSString *text = [[NSString alloc] initWithData:captured encoding:NSUTF8StringEncoding];
    return text ?: @"";
}

+ (nullable NSString *)lastErrorLineFromCapturedOutput:(NSString *)output {
    if (output.length == 0) return nil;
    NSError *regexError = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\x1b\\[31m(.*?)\x1b\\[0m"
                                                                             options:NSRegularExpressionDotMatchesLineSeparators
                                                                               error:&regexError];
    if (!regex) return nil;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:output options:0 range:NSMakeRange(0, output.length)];
    if (matches.count == 0) return nil;
    NSTextCheckingResult *lastMatch = matches.lastObject;
    NSString *raw = [output substringWithRange:[lastMatch rangeAtIndex:1]];
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@">>> "]) {
        trimmed = [trimmed substringFromIndex:4];
    }
    return trimmed.length > 0 ? trimmed : nil;
}
#endif

+ (BOOL)isEngineAvailable {
#if SWIFTIPA_HAS_ZSIGN
    return YES;
#else
    return NO;
#endif
}

+ (ZSignResult *)signAppFolderAtPath:(NSString *)folderPath options:(ZSignOptions *)options {
    ZSignResult *result = [ZSignResult new];

#if SWIFTIPA_HAS_ZSIGN
    CFTimeInterval started = CACurrentMediaTime();

    __block bool prepared = false;
    __block bool signed_ = false;

    NSString *capturedOutput = [self captureStdoutDuringBlock:^{
        ZSignAsset asset;
        prepared = asset.Init(
            std::string([options.p12Path UTF8String] ?: ""),
            std::string([options.p12Path UTF8String] ?: ""),
            std::string([options.provisionPath UTF8String] ?: ""),
            std::string(options.entitlementsPath ? [options.entitlementsPath UTF8String] : ""),
            std::string([options.p12Password UTF8String] ?: ""),
            options.adhoc,
            true,
            false
        );
        if (!prepared) {
            return;
        }

        ZBundle bundle;
        bundle.m_bEnableDocuments = false;
        bundle.m_strMinVersion = std::string(options.minimumOSVersion ? [options.minimumOSVersion UTF8String] : "");
        bundle.m_strIconFile = std::string(options.iconPath ? [options.iconPath UTF8String] : "");
        bundle.m_bRemoveExtensions = options.removeExtensions;
        bundle.m_bRemoveWatchApp = options.removeWatchApp;
        bundle.m_bRemoveUISupportedDevices = options.removeUISupportedDevices;
        bundle.m_bInjectExtensions = options.injectIntoExtensions;

        std::vector<std::string> dylibs;
        for (NSString *path in options.dylibPathsToInject) {
            dylibs.push_back(std::string([path UTF8String]));
        }
        std::vector<std::string> removedDylibs;
        for (NSString *name in options.dylibNamesToRemove) {
            removedDylibs.push_back(std::string([name UTF8String]));
        }

        signed_ = bundle.SignFolder(
            &asset,
            std::string([folderPath UTF8String] ?: ""),
            std::string(options.bundleIdentifier ? [options.bundleIdentifier UTF8String] : ""),
            std::string(options.bundleShortVersion ? [options.bundleShortVersion UTF8String] : ""),
            std::string(options.bundleName ? [options.bundleName UTF8String] : ""),
            dylibs,
            removedDylibs,
            options.forceSign,
            options.weakInject,
            false, // zsign's own cache is keyed by folder path, which is new every sign
            options.removeProvisionAfterSigning
        );
    }];

    result.duration = CACurrentMediaTime() - started;
    NSString *detail = [self lastErrorLineFromCapturedOutput:capturedOutput];

    if (!prepared) {
        result.code = ZSignResultCodeInvalidCertificate;
        result.message = detail ?: @"zsign could not load the certificate, private key or provisioning profile.";
        return result;
    }

    if (!signed_) {
        result.code = ZSignResultCodeSigningFailed;
        result.message = detail ?: @"zsign failed to sign the app bundle. Check the certificate, provisioning profile and entitlements.";
        return result;
    }

    result.code = ZSignResultCodeSuccess;
    return result;
#else
    (void)folderPath;
    (void)options;
    result.code = ZSignResultCodeEngineUnavailable;
    result.message = @"The zsign engine is not vendored in this build. Run Scripts/fetch-dependencies.sh and rebuild.";
    return result;
#endif
}

+ (BOOL)generateSelfSignedIdentityAtP12Path:(NSString *)p12Path
                                    password:(NSString *)password
                                  commonName:(NSString *)commonName
                              validityInDays:(NSInteger)validityInDays
                                       error:(NSString **)error {
#if SWIFTIPA_HAS_ZSIGN
    EVP_PKEY *pkey = EVP_RSA_gen(2048);
    if (!pkey) {
        if (error) *error = @"Could not generate an RSA key pair.";
        return NO;
    }

    X509 *x509 = X509_new();
    ASN1_INTEGER_set(X509_get_serialNumber(x509), (long)arc4random());
    X509_gmtime_adj(X509_get_notBefore(x509), 0);
    X509_gmtime_adj(X509_get_notAfter(x509), 60L * 60L * 24L * (long)validityInDays);
    X509_set_pubkey(x509, pkey);

    X509_NAME *name = X509_get_subject_name(x509);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, (const unsigned char *)[commonName UTF8String], -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, (const unsigned char *)"SwiftIPA", -1, -1, 0);
    X509_set_issuer_name(x509, name);

    X509V3_CTX ctx;
    X509V3_set_ctx_nodb(&ctx);
    X509V3_set_ctx(&ctx, x509, x509, NULL, NULL, 0);
    X509_EXTENSION *basicConstraints = X509V3_EXT_conf_nid(NULL, &ctx, NID_basic_constraints, (char *)"critical,CA:TRUE");
    if (basicConstraints) {
        X509_add_ext(x509, basicConstraints, -1);
        X509_EXTENSION_free(basicConstraints);
    }
    X509_EXTENSION *keyUsage = X509V3_EXT_conf_nid(NULL, &ctx, NID_key_usage, (char *)"critical,digitalSignature,keyEncipherment,keyCertSign");
    if (keyUsage) {
        X509_add_ext(x509, keyUsage, -1);
        X509_EXTENSION_free(keyUsage);
    }

    if (!X509_sign(x509, pkey, EVP_sha256())) {
        if (error) *error = @"Could not sign the local server certificate.";
        X509_free(x509);
        EVP_PKEY_free(pkey);
        return NO;
    }

    PKCS12 *p12 = PKCS12_create(
        [password UTF8String],
        [commonName UTF8String],
        pkey,
        x509,
        NULL, 0, 0, 0, 0, 0
    );

    BOOL success = NO;
    if (p12) {
        FILE *file = fopen([p12Path UTF8String], "wb");
        if (file) {
            success = i2d_PKCS12_fp(file, p12) == 1;
            fclose(file);
        }
        PKCS12_free(p12);
    }

    X509_free(x509);
    EVP_PKEY_free(pkey);

    if (!success && error) {
        *error = @"Could not write the local server identity to disk.";
    }
    return success;
#else
    if (error) *error = @"The zsign engine is not vendored in this build.";
    return NO;
#endif
}

+ (NSDate *)notBeforeDateForCertificateData:(NSData *)certificateData {
    return [self dateFromCertificateData:certificateData notAfter:NO];
}

+ (NSDate *)notAfterDateForCertificateData:(NSData *)certificateData {
    return [self dateFromCertificateData:certificateData notAfter:YES];
}

+ (NSDate *)dateFromCertificateData:(NSData *)certificateData notAfter:(BOOL)wantsNotAfter {
#if SWIFTIPA_HAS_ZSIGN
    const unsigned char *bytes = static_cast<const unsigned char *>(certificateData.bytes);
    X509 *cert = d2i_X509(NULL, &bytes, (long)certificateData.length);
    if (!cert) {
        return nil;
    }

    const ASN1_TIME *asn1Time = wantsNotAfter ? X509_get0_notAfter(cert) : X509_get0_notBefore(cert);
    if (!asn1Time) {
        X509_free(cert);
        return nil;
    }

    struct tm timeComponents;
    memset(&timeComponents, 0, sizeof(timeComponents));
    if (!ASN1_TIME_to_tm(asn1Time, &timeComponents)) {
        X509_free(cert);
        return nil;
    }
    X509_free(cert);

    time_t seconds = timegm(&timeComponents);
    if (seconds == (time_t)-1) {
        return nil;
    }
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)seconds];
#else
    (void)certificateData;
    (void)wantsNotAfter;
    return nil;
#endif
}

+ (NSData *)cmsContentFromData:(NSData *)data {
#if SWIFTIPA_HAS_ZSIGN
    std::string input(static_cast<const char *>(data.bytes), data.length);
    std::string output;
    if (!ZSignAsset::GetCMSContent(input, output)) {
        return nil;
    }
    return [NSData dataWithBytes:output.data() length:output.size()];
#else
    (void)data;
    return nil;
#endif
}

@end
