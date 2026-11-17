package com.feralin.unreal;

import android.app.Activity;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import com.android.installreferrer.api.InstallReferrerClient;
import com.android.installreferrer.api.InstallReferrerStateListener;

import java.security.KeyStore;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Unreal eklentisinin Android köprüsü: kuyruk veri anahtarını Android Keystore AES-256-GCM anahtarıyla sarar ve Google Play Install
 * Referrer'ı bir kez okur. Biçim Unity FeralinKeystore ile aynıdır (12 bayt IV, şifreli metin, 16 bayt etiket). Hata olursa null döner;
 * C++ tarafı kuyruğu bellekte tutar, düz metne düşmez.
 * BU SINIF HİÇ DERLENMEDİ VE CİHAZDA SINANMADI: bu makinede Unreal ve Android araç zinciri yoktur.
 */
public final class FeralinAndroid {
    private static final String PROVIDER = "AndroidKeyStore";
    private static final String ALIAS = "com.feralin.sdk.queue.wrap.v1";
    private static final String TRANSFORMATION = "AES/GCM/NoPadding";
    private static final int IV_BYTES = 12;
    private static final int TAG_BITS = 128;

    private FeralinAndroid() {
    }

    /** Referrer sonucu: hasValue=false ise kanıt yok (servis yok, desteklenmiyor, zaman aşımı). Çağrı bir kez yapılır. */
    public static native void nativeOnReferrer(long callbackId, boolean hasValue, String raw);

    public static byte[] wrap(byte[] data) {
        try {
            Cipher cipher = Cipher.getInstance(TRANSFORMATION);
            // IV'yi sağlayıcı üretir: Keystore anahtarları çağıranın IV vermesini reddeder.
            cipher.init(Cipher.ENCRYPT_MODE, key());
            byte[] iv = cipher.getIV();
            byte[] body = cipher.doFinal(data);
            byte[] out = new byte[iv.length + body.length];
            System.arraycopy(iv, 0, out, 0, iv.length);
            System.arraycopy(body, 0, out, iv.length, body.length);
            return out;
        } catch (Throwable error) {
            return null;
        }
    }

    public static byte[] unwrap(byte[] data) {
        try {
            if (data == null || data.length <= IV_BYTES + TAG_BITS / 8) {
                return null;
            }
            Cipher cipher = Cipher.getInstance(TRANSFORMATION);
            cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(TAG_BITS, data, 0, IV_BYTES));
            return cipher.doFinal(Arrays.copyOfRange(data, IV_BYTES, data.length));
        } catch (Throwable error) {
            return null;
        }
    }

    private static SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance(PROVIDER);
        store.load(null);
        SecretKey existing = (SecretKey) store.getKey(ALIAS, null);
        if (existing != null) {
            return existing;
        }
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER);
        generator.init(new KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
        return generator.generateKey();
    }

    /** Install Referrer'ı okur; sonuç nativeOnReferrer ile tam bir kez bildirilir. Yalnız reklam izniyle çağrılmalıdır. */
    public static void readInstallReferrer(final Activity activity, final long callbackId) {
        final boolean[] settled = {false};
        try {
            final InstallReferrerClient client = InstallReferrerClient.newBuilder(activity.getApplicationContext()).build();
            client.startConnection(new InstallReferrerStateListener() {
                @Override
                public void onInstallReferrerSetupFinished(int responseCode) {
                    String raw = null;
                    if (responseCode == InstallReferrerClient.InstallReferrerResponse.OK) {
                        try {
                            raw = client.getInstallReferrer().getInstallReferrer();
                        } catch (Throwable ignored) {
                            raw = null;
                        }
                    }
                    try {
                        client.endConnection();
                    } catch (Throwable ignored) {
                        // bağlantı zaten kapalı
                    }
                    finish(settled, callbackId, raw);
                }

                @Override
                public void onInstallReferrerServiceDisconnected() {
                    finish(settled, callbackId, null);
                }
            });
        } catch (Throwable error) {
            // Kitaplık uygulamadan çıkarılmış ya da servis yok: kanıt yoktur.
            finish(settled, callbackId, null);
        }
    }

    private static synchronized void finish(boolean[] settled, long callbackId, String raw) {
        if (settled[0]) {
            return;
        }
        settled[0] = true;
        nativeOnReferrer(callbackId, raw != null, raw == null ? "" : raw);
    }
}
