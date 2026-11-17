package com.feralin.unity;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.security.KeyStore;
import java.util.Arrays;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Unity C# tarafındaki 32 baytlık kuyruk veri anahtarını Android Keystore AES-256-GCM anahtarıyla sarar. Keystore anahtarı cihaz
 * donanımına bağlıdır, dışarı aktarılamaz ve yedekle başka cihaza taşınmaz. Biçim: 12 bayt IV, ardından şifreli metin ve 16 bayt etiket.
 * Herhangi bir hata (API 23 öncesi, Keystore bozuk) null döndürür; C# tarafı kuyruğu bellekte tutar, düz metne düşmez.
 * Bu sınıf cihazda sınanmamıştır: Android oyuncu derlemesi bu depoda yoktur.
 */
public final class FeralinKeystore {
    private static final String PROVIDER = "AndroidKeyStore";
    private static final String ALIAS = "com.feralin.sdk.queue.wrap.v1";
    private static final String TRANSFORMATION = "AES/GCM/NoPadding";
    private static final int IV_BYTES = 12;
    private static final int TAG_BITS = 128;

    private FeralinKeystore() {
    }

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
}
