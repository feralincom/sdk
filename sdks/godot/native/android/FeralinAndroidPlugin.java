package com.feralin.godot;

import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import androidx.annotation.NonNull;

import com.android.installreferrer.api.InstallReferrerClient;
import com.android.installreferrer.api.InstallReferrerStateListener;

import org.godotengine.godot.Godot;
import org.godotengine.godot.plugin.GodotPlugin;
import org.godotengine.godot.plugin.SignalInfo;
import org.godotengine.godot.plugin.UsedByGodot;

import java.security.KeyStore;
import java.util.Arrays;
import java.util.Collections;
import java.util.Set;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Godot Android eklentisi "FeralinAndroid" (Godot 4.2+ eklenti API'si): kuyruk veri anahtarını Android Keystore AES-256-GCM anahtarıyla
 * sarar ve Google Play Install Referrer'ı bir kez okur. Biçim Unity FeralinKeystore ile aynıdır (12 bayt IV, şifreli metin, 16 bayt etiket).
 * Hata olursa wrap/unwrap boş dizi döner; GDScript tarafı kuyruğu bellekte tutar, düz metne düşmez.
 * BU SINIF HİÇ DERLENMEDİ VE CİHAZDA SINANMADI: bu makinede Godot ve Android araç zinciri yoktur. Paketleme: native/README.md.
 */
public class FeralinAndroidPlugin extends GodotPlugin {
    private static final String PROVIDER = "AndroidKeyStore";
    private static final String ALIAS = "com.feralin.sdk.queue.wrap.v1";
    private static final String TRANSFORMATION = "AES/GCM/NoPadding";
    private static final int IV_BYTES = 12;
    private static final int TAG_BITS = 128;

    private boolean referrerRequested = false;

    public FeralinAndroidPlugin(Godot godot) {
        super(godot);
    }

    @NonNull
    @Override
    public String getPluginName() {
        return "FeralinAndroid";
    }

    @NonNull
    @Override
    public Set<SignalInfo> getPluginSignals() {
        // install_referrer(has_value: bool, raw: String): sonuç tam bir kez bildirilir.
        return Collections.singleton(new SignalInfo("install_referrer", Boolean.class, String.class));
    }

    @UsedByGodot
    public byte[] wrap(byte[] data) {
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
            return new byte[0];
        }
    }

    @UsedByGodot
    public byte[] unwrap(byte[] data) {
        try {
            if (data == null || data.length <= IV_BYTES + TAG_BITS / 8) {
                return new byte[0];
            }
            Cipher cipher = Cipher.getInstance(TRANSFORMATION);
            cipher.init(Cipher.DECRYPT_MODE, key(), new GCMParameterSpec(TAG_BITS, data, 0, IV_BYTES));
            return cipher.doFinal(Arrays.copyOfRange(data, IV_BYTES, data.length));
        } catch (Throwable error) {
            return new byte[0];
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

    /** Install Referrer'ı okur; install_referrer sinyali tam bir kez gelir. Yalnız reklam izniyle çağrılmalıdır (GDScript çekirdeği bunu sağlar). */
    @UsedByGodot
    public synchronized void readInstallReferrer() {
        if (referrerRequested || getActivity() == null) {
            return;
        }
        referrerRequested = true;
        final boolean[] settled = {false};
        try {
            final InstallReferrerClient client = InstallReferrerClient.newBuilder(getActivity().getApplicationContext()).build();
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
                    finish(settled, raw);
                }

                @Override
                public void onInstallReferrerServiceDisconnected() {
                    finish(settled, null);
                }
            });
        } catch (Throwable error) {
            // Kitaplık uygulamadan çıkarılmış ya da servis yok: kanıt yoktur.
            finish(settled, null);
        }
    }

    private synchronized void finish(boolean[] settled, String raw) {
        if (settled[0]) {
            return;
        }
        settled[0] = true;
        emitSignal("install_referrer", raw != null, raw == null ? "" : raw);
    }
}
