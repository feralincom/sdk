#pragma once

#include "CoreMinimal.h"
#include "Engine/DeveloperSettings.h"

#include "FeralinSettings.generated.h"

// Proje Ayarları içinde Feralin bölümü. Değerler DefaultGame.ini içine yazılır; pk_ anahtarı istemcide bulunması beklenen public anahtardır.
UCLASS(Config = Game, DefaultConfig, meta = (DisplayName = "Feralin"))
class FERALIN_API UFeralinSettings : public UDeveloperSettings
{
	GENERATED_BODY()

public:
	// Yalnız public proje anahtarı (pk_). Gizli anahtar (sk_) reddedilir.
	UPROPERTY(Config, EditAnywhere, Category = "Feralin")
	FString ProjectKey;

	// Toplayıcının http(s) kök adresi; olaylar {kök}/v1/batch adresine gider.
	UPROPERTY(Config, EditAnywhere, Category = "Feralin")
	FString CollectUrl;

	// Arka plan gönderim aralığı (saniye). 0 otomatik gönderimi kapatır; yalnız Flush gönderir.
	UPROPERTY(Config, EditAnywhere, Category = "Feralin", meta = (ClampMin = "0"))
	float FlushIntervalSeconds = 2.0f;

	UPROPERTY(Config, EditAnywhere, Category = "Feralin", meta = (ClampMin = "1", ClampMax = "500"))
	int32 BatchSize = 100;

	// Aşılırsa en eski olay atılır.
	UPROPERTY(Config, EditAnywhere, Category = "Feralin", meta = (ClampMin = "1"))
	int32 QueueLimit = 1000;

	UPROPERTY(Config, EditAnywhere, Category = "Feralin", meta = (ClampMin = "1"))
	float TimeoutSeconds = 10.0f;

	// Olaylar diskte AES-256-GCM ile şifreli tutulur (Saved/Feralin). Kapalıysa kuyruk yalnız bellektedir. Anahtar alınamazsa düz metne düşülmez.
	UPROPERTY(Config, EditAnywhere, Category = "Feralin")
	bool bPersistQueue = true;

	// Boş bırakılırsa Saved/Feralin kullanılır.
	UPROPERTY(Config, EditAnywhere, Category = "Feralin")
	FString QueueDirectory;

	// Otomatik oturumun zaman aşımı (dakika): arka planda bu kadar kalınca yeni session_id üretilir. 0 oturumu kapatır.
	UPROPERTY(Config, EditAnywhere, Category = "Feralin", meta = (ClampMin = "0"))
	int32 SessionTimeoutMinutes = 30;

	// BindInstall için API kökü (ör. https://api.feralin.com) ve proje kimliği. İkisi de boşsa BindInstall not_configured döner.
	UPROPERTY(Config, EditAnywhere, Category = "Feralin|Attribution")
	FString AttributionApiUrl;

	UPROPERTY(Config, EditAnywhere, Category = "Feralin|Attribution")
	FString ProjectId;

	// Panelin verdiği kurulum eşleştirme kodu (10-16 karakter, Crockford Base32; tire, boşluk ve alt çizgi ayraç). İlk olayla
	// fr_install_code olarak gider ve o oturumda bir daha gönderilmez. Biçime uymayan değer yok sayılır. Eşleşme bittikten sonra
	// boşaltın; çalışma anında SetInstallCode da kullanılabilir.
	UPROPERTY(Config, EditAnywhere, Category = "Feralin|Attribution")
	FString InstallCode;

	// Motor günlüğündeki Error düzeyi kayıtlar fr_error olarak gönderilir (kişisel veriden arındırılır, hız sınırlıdır).
	UPROPERTY(Config, EditAnywhere, Category = "Feralin|Errors")
	bool bCaptureLogErrors = false;

	UPROPERTY(Config, EditAnywhere, Category = "Feralin|Errors", meta = (ClampMin = "0", ClampMax = "1"))
	float ErrorSampleRate = 1.0f;

	UPROPERTY(Config, EditAnywhere, Category = "Feralin|Errors", meta = (ClampMin = "0"))
	int32 MaxErrorsPerMinute = 10;

	UPROPERTY(Config, EditAnywhere, Category = "Feralin|Errors", meta = (ClampMin = "0"))
	int32 MaxErrorsPerFingerprintPerMinute = 2;
};
