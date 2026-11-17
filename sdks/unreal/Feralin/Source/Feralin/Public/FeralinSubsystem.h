#pragma once

#include "CoreMinimal.h"
#include "Containers/Ticker.h"
#include "Subsystems/GameInstanceSubsystem.h"
#include "Interfaces/IHttpRequest.h"

#include "FeralinSubsystem.generated.h"

struct FFeralinCore;
class FFeralinLogCapture;

// İzin anlık görüntüsü. Analytics kapalıyken olay üretilmez; Advertising kapalıyken fr_click çıkarılır.
USTRUCT(BlueprintType)
struct FERALIN_API FFeralinConsent
{
	GENERATED_BODY()

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Feralin")
	bool bAnalytics = false;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Feralin")
	bool bAdvertising = false;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Feralin")
	bool bPersonalization = false;

	UPROPERTY(EditAnywhere, BlueprintReadWrite, Category = "Feralin")
	bool bSessionReplay = false;
};

// Bir Flush turunun toplu sonucu. bTemporaryFailure: olaylar kuyrukta, aynı Idempotency-Key ile yeniden denenecek.
USTRUCT(BlueprintType)
struct FERALIN_API FFeralinFlushResult
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	bool bSuccess = true;

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	bool bTemporaryFailure = false;

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	int32 HttpStatus = 0;

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	int32 Sent = 0;

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	int32 Accepted = 0;

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	int32 Rejected = 0;

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	int32 Retained = 0;

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	FString BatchId;

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	FString Error;
};

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FFeralinFlushCompleted, const FFeralinFlushResult&, Result);

// Satın alma türü (feralin_purchase.purchase_type); Android, Flutter, React Native ve Unity ile aynı değerler.
UENUM(BlueprintType)
enum class EFeralinPurchaseType : uint8
{
	Purchase,
	SubscriptionStart,
	SubscriptionRenew,
	SubscriptionCancel
};

// Makbuzu doğrulayacak sağlayıcı; None makbuz göndermez.
UENUM(BlueprintType)
enum class EFeralinReceiptProvider : uint8
{
	None,
	Apple,
	Google,
	Stripe
};

UENUM(BlueprintType)
enum class EFeralinAdFormat : uint8
{
	Banner,
	Interstitial,
	Rewarded,
	RewardedInterstitial,
	Native,
	AppOpen,
	Other
};

UENUM(BlueprintType)
enum class EFeralinAdPrecision : uint8
{
	Estimated,
	PublisherProvided,
	Precise,
	Unknown
};

// BindInstall sonucu. Status: received, skipped_no_consent, not_configured, unsupported, token_unavailable, rejected, temporary_failure.
// InstallId rastgele kurulum kimliğidir (cihaz kimliği değildir); reklam izni yoksa boştur. Kesin tekil atıf iddia edilmez.
USTRUCT(BlueprintType)
struct FERALIN_API FFeralinInstallBinding
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	FString Status;

	UPROPERTY(BlueprintReadOnly, Category = "Feralin")
	FString InstallId;
};

DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FFeralinInstallBound, const FFeralinInstallBinding&, Binding);

// UTP v1 olaylarını FHttpModule ile gönderen oyun örneği alt sistemi. Bütün çağrılar oyun iş parçacığından yapılmalıdır.
UCLASS()
class FERALIN_API UFeralinSubsystem : public UGameInstanceSubsystem
{
	GENERATED_BODY()

public:
	virtual void Initialize(FSubsystemCollectionBase& Collection) override;
	virtual void Deinitialize() override;

	// Olayı doğrular ve kuyruğa ekler; ağ çağrısı yapmaz. İzin yoksa veya olay geçersizse false döner (geçersizlik loglanır).
	UFUNCTION(BlueprintCallable, Category = "Feralin", meta = (AutoCreateRefTerm = "Properties"))
	bool Track(const FString& EventName, const TMap<FString, FString>& Properties);

	// Metin ve sayı özellikleriyle olay.
	UFUNCTION(BlueprintCallable, Category = "Feralin", meta = (AutoCreateRefTerm = "Properties,NumberProperties"))
	bool TrackWithNumbers(const FString& EventName, const TMap<FString, FString>& Properties, const TMap<FString, double>& NumberProperties);

	// PropertiesJson bir JSON nesnesi olmalıdır; iç içe değerler için.
	UFUNCTION(BlueprintCallable, Category = "Feralin")
	bool TrackJson(const FString& EventName, const FString& PropertiesJson);

	// Analytics kapanırsa bekleyen olaylar atılır.
	UFUNCTION(BlueprintCallable, Category = "Feralin")
	void SetConsent(const FFeralinConsent& Consent);

	UFUNCTION(BlueprintPure, Category = "Feralin")
	FFeralinConsent GetConsent() const;

	// Oyunun kendi kullanıcı kimliği; PII olmamalı. Boş değer kaldırır.
	UFUNCTION(BlueprintCallable, Category = "Feralin")
	bool Identify(const FString& UserId);

	// SDK kimlik üretmez, cihaz bilgisi okumaz. Oyunun kendi ürettiği rastgele kimliği verilebilir. Boş değer kaldırır.
	UFUNCTION(BlueprintCallable, Category = "Feralin")
	bool SetAnonymousId(const FString& AnonymousId);

	// Kuyruktaki olayları batch'ler hâlinde gönderir; geri çekilme beklemez. Sonuç OnFlushCompleted ile gelir.
	UFUNCTION(BlueprintCallable, Category = "Feralin")
	void Flush();

	UFUNCTION(BlueprintPure, Category = "Feralin")
	int32 GetQueueLength() const;

	// Çıkış: kimlikler, kuyruk ve diskteki olaylar silinir; yeni oturum başlar.
	UFUNCTION(BlueprintCallable, Category = "Feralin")
	void Reset();

	// Satın alma ya da abonelik beyanı (feralin_purchase). İstemci beyanıdır: verified gönderilmez; sunucu yalnız makbuz doğrulayıcısı
	// onaylarsa REAL_VERIFIED sayar. AmountMinor küçük birimdir (49,99 TL için 4999). Sözleşme dışı girdide olay üretilmez ve false döner.
	UFUNCTION(BlueprintCallable, Category = "Feralin|Revenue", meta = (AutoCreateRefTerm = "ProductId,ReceiptToken,Properties"))
	bool TrackRevenue(const FString& TransactionId, int64 AmountMinor, const FString& Currency, const FString& ProductId, int32 Quantity, EFeralinPurchaseType PurchaseType,
		EFeralinReceiptProvider ReceiptProvider, const FString& ReceiptToken, const TMap<FString, FString>& Properties);

	// Reklam geliri (fr_ad_revenue): satın alma gelirinden ayrıdır, deftere feralin_purchase olarak girmez. RevenueMicros para biriminin milyonda biridir.
	UFUNCTION(BlueprintCallable, Category = "Feralin|Revenue", meta = (AutoCreateRefTerm = "AdUnit,Placement,ImpressionId,Properties"))
	bool TrackAdRevenue(const FString& Network, EFeralinAdFormat AdFormat, int64 RevenueMicros, const FString& Currency, const FString& AdUnit, EFeralinAdPrecision Precision,
		const FString& Placement, const FString& ImpressionId, const TMap<FString, FString>& Properties);

	// Kullanıcıyı gruba bağlar (fr_group) ve kullanıcı özelliklerini bildirir (fr_user_properties). Kişisel veri vermeyin.
	UFUNCTION(BlueprintCallable, Category = "Feralin|Identity", meta = (AutoCreateRefTerm = "Traits"))
	bool Group(const FString& GroupId, const TMap<FString, FString>& Traits);

	UFUNCTION(BlueprintCallable, Category = "Feralin|Identity")
	bool SetUserProperties(const TMap<FString, FString>& Properties);

	// Oyun olayları (packages/schemas/utp/v1/game-events.md). Verilmeyen isteğe bağlı sayı için -1, metin için boş bırakın.
	UFUNCTION(BlueprintCallable, Category = "Feralin|Game")
	bool TrackLevelStart(const FString& LevelId, int64 Attempt = -1);

	UFUNCTION(BlueprintCallable, Category = "Feralin|Game")
	bool TrackLevelComplete(const FString& LevelId, int64 Attempt = -1, int64 Score = -1, int64 DurationMs = -1);

	UFUNCTION(BlueprintCallable, Category = "Feralin|Game")
	bool TrackLevelFail(const FString& LevelId, int64 Attempt = -1, int64 Score = -1, int64 DurationMs = -1, const FString& FailReason = TEXT(""));

	// Oyun içi sanal para (gerçek para değildir). Amount 1..10^12.
	UFUNCTION(BlueprintCallable, Category = "Feralin|Game")
	bool TrackEconomySource(const FString& CurrencyName, int64 Amount, const FString& Reason = TEXT(""), const FString& ItemId = TEXT(""));

	UFUNCTION(BlueprintCallable, Category = "Feralin|Game")
	bool TrackEconomySink(const FString& CurrencyName, int64 Amount, const FString& Reason = TEXT(""), const FString& ItemId = TEXT(""));

	UFUNCTION(BlueprintCallable, Category = "Feralin|Game")
	bool TrackRewardedAdShown(const FString& Placement, const FString& Network = TEXT(""));

	UFUNCTION(BlueprintCallable, Category = "Feralin|Game")
	bool TrackRewardedAdComplete(const FString& Placement, const FString& Network = TEXT(""), int64 RewardAmount = -1, const FString& RewardCurrency = TEXT(""));

	UFUNCTION(BlueprintCallable, Category = "Feralin|Game")
	bool TrackIapOfferShown(const FString& ProductId, const FString& Placement = TEXT(""));

	UFUNCTION(BlueprintCallable, Category = "Feralin|Game")
	bool TrackIapInitiated(const FString& ProductId, const FString& Placement = TEXT(""), const FString& TransactionId = TEXT(""));

	// Hata olayı (fr_error). İleti ve yığın kişisel veriden arındırılır; örnekleme ve hız sınırı uygulanır. Native çökme ve ANR yakalanmaz.
	UFUNCTION(BlueprintCallable, Category = "Feralin|Errors")
	bool CaptureError(const FString& ErrorType, const FString& Message, const FString& StackTrace, bool bHandled = true);

	// Uygulama bağlantısı (App Link, Universal Link): deep_link_opened. Yalnız http(s); ham URL saklanmaz, yalnız fr_click ve utm_* okunur.
	UFUNCTION(BlueprintCallable, Category = "Feralin|Attribution")
	void HandleDeepLink(const FString& Url);

	// Panelin verdiği kurulum eşleştirme kodu: ilk üretilen olayla fr_install_code olarak gider, sonra silinir. Biçim
	// 10-16 karakter Crockford Base32 (tire, boşluk, alt çizgi ayraç); uymazsa false döner. Proje ayarındaki InstallCode ile aynıdır.
	UFUNCTION(BlueprintCallable, Category = "Feralin|Attribution")
	bool SetInstallCode(const FString& Code);

	// Play Install Referrer'dan gelen ertelenmiş uygulama içi yolu bir kez verir; yoksa boş.
	UFUNCTION(BlueprintCallable, Category = "Feralin|Attribution")
	FString ConsumeDeferredDeepLink();

	// iOS: AdServices token'ını kurulum kimliğiyle sunucuya iletir; sonuç OnInstallBound ile gelir. Kesin tekil atıf değildir.
	UFUNCTION(BlueprintCallable, Category = "Feralin|Attribution")
	void BindInstall();

	UPROPERTY(BlueprintAssignable, Category = "Feralin")
	FFeralinFlushCompleted OnFlushCompleted;

	UPROPERTY(BlueprintAssignable, Category = "Feralin|Attribution")
	FFeralinInstallBound OnInstallBound;

	// Motor katmanı çağırır (uygulama arka plana geçti ya da döndü, günlük kaydı geldi).
	void HandleEnteredBackground();
	void HandleEnteredForeground();
	void HandleLogRecord(bool bFatal, const FString& Category, const FString& Message);

private:
	bool OnTick(float DeltaSeconds);
	void StartAttribution();
	void AfterTrack(bool bQueueFull);
	void BeginRound();
	void SendNextBatch();
	void HandleResponse(FHttpResponsePtr Response, bool bConnected);
	void FinishRound();

	// Tel biçimi ve kuyruk çekirdeği; yalnız .cpp içinde tanımlıdır. TSharedPtr, üretilen kodda tam tür istemez.
	TSharedPtr<FFeralinCore> Core;
	TSharedPtr<FFeralinLogCapture> LogCapture;
	FDelegateHandle BackgroundHandle;
	FDelegateHandle ForegroundHandle;
	FTSTicker::FDelegateHandle TickerHandle;
	bool bHasTicker = false;
	bool bRequestInFlight = false;
	bool bRoundActive = false;
	bool bFlushRequested = false;
	int32 RoundsLeft = 0;
	FFeralinFlushResult RoundResult;
};
