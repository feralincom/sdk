// Feralin Unity SDK iOS köprüsü: Keychain (kuyruk veri anahtarı), AdServices token'ı ve App Tracking Transparency durumu.
// Bu dosya Xcode ile derlenmemiştir ve cihazda sınanmamıştır: iOS oyuncu derlemesi bu depoda yoktur.
//
// AdServices ve AppTrackingTransparency sistem çerçeveleridir; Xcode projesine bağlama gerektirmesin diye çalışma zamanında yüklenir
// (sınıf bulunamazsa köprü "desteklenmiyor" döner). Security çerçevesi Unity iOS şablonunda bağlıdır; bağlı değilse Xcode'da
// Security.framework eklenmelidir.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/message.h>

static NSString *const kFeralinKeychainService = @"com.feralin.sdk";

static NSMutableDictionary *FeralinKeychainQuery(const char *account) {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrService] = kFeralinKeychainService;
    query[(__bridge id)kSecAttrAccount] = [NSString stringWithUTF8String:account ? account : ""];
    return query;
}

extern "C" {

// Anahtarı okur; okunan bayt sayısını, yoksa 0, hatada -1 döndürür.
int feralin_keychain_load(const char *account, unsigned char *buffer, int capacity) {
    NSMutableDictionary *query = FeralinKeychainQuery(account);
    query[(__bridge id)kSecReturnData] = (__bridge id)kCFBooleanTrue;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecItemNotFound) {
        return 0;
    }
    if (status != errSecSuccess || result == NULL) {
        return -1;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    if ((int)data.length > capacity) {
        return -1;
    }
    memcpy(buffer, data.bytes, data.length);
    return (int)data.length;
}

// Anahtarı yazar (varsa değiştirir); cihaz ilk kez kilit açıldıktan sonra erişilebilir, yedekle başka cihaza taşınmaz. Başarıda 0.
int feralin_keychain_save(const char *account, const unsigned char *data, int length) {
    NSMutableDictionary *query = FeralinKeychainQuery(account);
    SecItemDelete((__bridge CFDictionaryRef)query);
    query[(__bridge id)kSecValueData] = [NSData dataWithBytes:data length:(NSUInteger)length];
    query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    return SecItemAdd((__bridge CFDictionaryRef)query, NULL) == errSecSuccess ? 0 : -1;
}

int feralin_keychain_delete(const char *account) {
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)FeralinKeychainQuery(account));
    return (status == errSecSuccess || status == errSecItemNotFound) ? 0 : -1;
}

// ATT durumu: 0 belirsiz, 1 kısıtlı, 2 reddedildi, 3 izin verildi; iOS 14'ten eskiyse ya da çerçeve yoksa 4 (platformda ATT yok).
int feralin_att_status(void) {
    [[NSBundle bundleWithPath:@"/System/Library/Frameworks/AppTrackingTransparency.framework"] load];
    Class manager = NSClassFromString(@"ATTrackingManager");
    SEL selector = NSSelectorFromString(@"trackingAuthorizationStatus");
    if (manager == nil || ![manager respondsToSelector:selector]) {
        return 4;
    }
    NSUInteger status = ((NSUInteger (*)(id, SEL))objc_msgSend)(manager, selector);
    return (int)status;
}

// AdServices token'ı: UTF-8 uzunluğu (>0), desteklenmiyorsa 0 (iOS 14.3 öncesi ya da çerçeve yok), hatada -1. Token loglanmaz.
int feralin_adservices_token(char *buffer, int capacity) {
    [[NSBundle bundleWithPath:@"/System/Library/Frameworks/AdServices.framework"] load];
    Class attribution = NSClassFromString(@"AAAttribution");
    SEL selector = NSSelectorFromString(@"attributionTokenWithError:");
    if (attribution == nil || ![attribution respondsToSelector:selector]) {
        return 0;
    }
    NSError *error = nil;
    NSString *token = ((NSString * (*)(id, SEL, NSError **))objc_msgSend)(attribution, selector, &error);
    if (token == nil || error != nil) {
        return -1;
    }
    const char *utf8 = [token UTF8String];
    int length = (int)strlen(utf8);
    if (length <= 0 || length >= capacity) {
        return -1;
    }
    memcpy(buffer, utf8, (size_t)length + 1);
    return length;
}

}
