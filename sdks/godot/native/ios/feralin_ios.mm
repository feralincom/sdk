// Godot iOS eklentisi "FeralinIOS": Keychain (kuyruk veri anahtarı), AdServices token'ı ve App Tracking Transparency durumu.
// GDScript tarafı Engine.get_singleton("FeralinIOS") ile şu yöntemleri çağırır: keychain_save, keychain_load, att_status, adservices_token.
// BU DOSYA XCODE İLE HİÇ DERLENMEDİ ve cihazda sınanmadı (macOS ve Godot yok). Paketleme ve godot-cpp/iOS eklenti şablonu native/README.md içinde.
// AdServices ve AppTrackingTransparency çalışma zamanında yüklenir; çerçeve yoksa "desteklenmiyor" döner.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/message.h>

#include "core/object/class_db.h"
#include "core/object/object.h"

static NSString *const kFeralinKeychainService = @"com.feralin.sdk";

static NSMutableDictionary *FeralinKeychainQuery(NSString *account) {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrService] = kFeralinKeychainService;
    query[(__bridge id)kSecAttrAccount] = account;
    return query;
}

class FeralinIOS : public Object {
    GDCLASS(FeralinIOS, Object);

protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("keychain_save", "account", "data"), &FeralinIOS::keychain_save);
        ClassDB::bind_method(D_METHOD("keychain_load", "account"), &FeralinIOS::keychain_load);
        ClassDB::bind_method(D_METHOD("att_status"), &FeralinIOS::att_status);
        ClassDB::bind_method(D_METHOD("adservices_token"), &FeralinIOS::adservices_token);
    }

public:
    // Cihaz ilk kez kilit açıldıktan sonra erişilebilir, yedekle başka cihaza taşınmaz. Başarıda 0.
    int keychain_save(const String &account, const PackedByteArray &data) {
        NSString *name = [NSString stringWithUTF8String:account.utf8().get_data()];
        NSMutableDictionary *query = FeralinKeychainQuery(name);
        SecItemDelete((__bridge CFDictionaryRef)query);
        query[(__bridge id)kSecValueData] = [NSData dataWithBytes:data.ptr() length:(NSUInteger)data.size()];
        query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        return SecItemAdd((__bridge CFDictionaryRef)query, NULL) == errSecSuccess ? 0 : -1;
    }

    // Yoksa ya da hatada boş dizi.
    PackedByteArray keychain_load(const String &account) {
        PackedByteArray out;
        NSString *name = [NSString stringWithUTF8String:account.utf8().get_data()];
        NSMutableDictionary *query = FeralinKeychainQuery(name);
        query[(__bridge id)kSecReturnData] = (__bridge id)kCFBooleanTrue;
        query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
        CFTypeRef result = NULL;
        if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || result == NULL) {
            return out;
        }
        NSData *data = (__bridge_transfer NSData *)result;
        out.resize((int64_t)data.length);
        memcpy(out.ptrw(), data.bytes, data.length);
        return out;
    }

    // 0 belirsiz, 1 kısıtlı, 2 reddedildi, 3 izin verildi; iOS 14'ten eskiyse ya da çerçeve yoksa 4.
    int att_status() {
        [[NSBundle bundleWithPath:@"/System/Library/Frameworks/AppTrackingTransparency.framework"] load];
        Class manager = NSClassFromString(@"ATTrackingManager");
        SEL selector = NSSelectorFromString(@"trackingAuthorizationStatus");
        if (manager == nil || ![manager respondsToSelector:selector]) {
            return 4;
        }
        return (int)((NSUInteger (*)(id, SEL))objc_msgSend)(manager, selector);
    }

    // Token; desteklenmiyorsa boş metin, hatada "!error". Token loglanmaz.
    String adservices_token() {
        [[NSBundle bundleWithPath:@"/System/Library/Frameworks/AdServices.framework"] load];
        Class attribution = NSClassFromString(@"AAAttribution");
        SEL selector = NSSelectorFromString(@"attributionTokenWithError:");
        if (attribution == nil || ![attribution respondsToSelector:selector]) {
            return String();
        }
        NSError *error = nil;
        NSString *token = ((NSString * (*)(id, SEL, NSError **))objc_msgSend)(attribution, selector, &error);
        if (token == nil || error != nil) {
            return String("!error");
        }
        return String::utf8([token UTF8String]);
    }
};
