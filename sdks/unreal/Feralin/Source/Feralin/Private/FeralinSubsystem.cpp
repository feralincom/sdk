#include "FeralinSubsystem.h"

#include "Async/Async.h"
#include "FeralinModule.h"
#include "FeralinPlatform.h"
#include "FeralinSettings.h"
#include "HAL/FileManager.h"
#include "HAL/PlatformTime.h"
#include "HttpModule.h"
#include "Interfaces/IHttpRequest.h"
#include "Interfaces/IHttpResponse.h"
#include "Misc/CoreDelegates.h"
#include "Misc/DateTime.h"
#include "Misc/Guid.h"
#include "Misc/OutputDevice.h"
#include "Misc/Paths.h"

// Tel biçimi sdks/cpp ile aynı dosyadır; std kullanır ve exception gerektirmez. Oyun sözleşmeleri (FeralinGame.hpp) motordan bağımsızdır
// ve Unreal olmadan sınanır (tests/game_test.cpp).
THIRD_PARTY_INCLUDES_START
#include "FeralinGame.hpp"
THIRD_PARTY_INCLUDES_END

namespace FeralinInternal
{
	namespace Wire = feralin::wire;
	namespace Game = feralin::game;

	static const char* const SdkName = "feralin-unreal";
	static const char* const SdkVersion = "0.2.0";
	static const char* const SdkPlatform = "unreal";

	static std::string ToUtf8(const FString& Text)
	{
		const FTCHARToUTF8 Converted(*Text);
		return std::string(Converted.Get(), static_cast<std::size_t>(Converted.Length()));
	}

	static FString FromUtf8(const std::string& Text)
	{
		return FString(UTF8_TO_TCHAR(Text.c_str()));
	}

	static int64 NowEpochMs()
	{
		const FDateTime Now = FDateTime::UtcNow();
		return Now.ToUnixTimestamp() * 1000 + Now.GetMillisecond();
	}

	static int64 MonotonicMs()
	{
		return static_cast<int64>(FPlatformTime::Seconds() * 1000.0);
	}

	// Rastgele bayt kaynağı: platform GUID üreteci (ULID rastgele kısmı, AES-GCM IV'si, kuyruk veri anahtarı). Donanım veya cihaz bilgisi okunmaz.
	// Veri anahtarı Android'de Keystore, iOS'ta Keychain ile korunur; diğer platformlarda yalnız dosya izniyle (local_file).
	static void FillRandom(unsigned char* Buffer, std::size_t Length)
	{
		std::size_t Offset = 0;
		while (Offset < Length)
		{
			const FGuid Guid = FGuid::NewGuid();
			const uint32 Parts[4] = {Guid.A, Guid.B, Guid.C, Guid.D};
			for (const uint32 Part : Parts)
			{
				for (int32 Shift = 0; Shift < 32 && Offset < Length; Shift += 8)
				{
					Buffer[Offset++] = static_cast<unsigned char>((Part >> Shift) & 0xFFu);
				}
			}
		}
	}

	static feralin::crypto::Bytes RandomBytes(std::size_t Count)
	{
		feralin::crypto::Bytes Out(Count);
		FillRandom(Out.data(), Count);
		return Out;
	}

	static Wire::Consent ToWire(const FFeralinConsent& Consent)
	{
		Wire::Consent Out;
		Out.analytics = Consent.bAnalytics;
		Out.advertising = Consent.bAdvertising;
		Out.personalization = Consent.bPersonalization;
		Out.session_replay = Consent.bSessionReplay;
		return Out;
	}

	static FFeralinConsent FromWire(const Wire::Consent& Consent)
	{
		FFeralinConsent Out;
		Out.bAnalytics = Consent.analytics;
		Out.bAdvertising = Consent.advertising;
		Out.bPersonalization = Consent.personalization;
		Out.bSessionReplay = Consent.session_replay;
		return Out;
	}

	static Wire::Value StringMap(const TMap<FString, FString>& Map)
	{
		Wire::Value Out = Wire::Value::make_object();
		for (const auto& Pair : Map)
		{
			Out.set(ToUtf8(Pair.Key), Wire::Value(ToUtf8(Pair.Value)));
		}
		return Out;
	}

	// Blueprint'te boş metin "verilmedi" demektir.
	static std::optional<std::string> OptText(const FString& Text)
	{
		if (Text.IsEmpty())
		{
			return std::nullopt;
		}
		return ToUtf8(Text);
	}

	// Blueprint'te negatif sayı "verilmedi" demektir.
	static std::optional<std::int64_t> OptNumber(int64 Number)
	{
		if (Number < 0)
		{
			return std::nullopt;
		}
		return static_cast<std::int64_t>(Number);
	}

	static std::string DefaultQueueDirectory(const UFeralinSettings* Settings)
	{
		FString Directory = Settings->QueueDirectory.IsEmpty() ? FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("Feralin")) : Settings->QueueDirectory;
		IFileManager::Get().MakeDirectory(*Directory, true);
		return ToUtf8(Directory);
	}
}

// Motor günlüğündeki Error ve Fatal kayıtlarını dinler; kayıt başka iş parçacığından gelebilir, işlem oyun iş parçacığında yapılır.
class FFeralinLogCapture : public FOutputDevice
{
public:
	explicit FFeralinLogCapture(UFeralinSubsystem* InOwner) : Owner(InOwner) {}

	virtual void Serialize(const TCHAR* Message, ELogVerbosity::Type Verbosity, const FName& Category) override
	{
		if (Verbosity != ELogVerbosity::Error && Verbosity != ELogVerbosity::Fatal)
		{
			return;
		}
		// Eklentinin kendi günlükleri Error düzeyinde yazılmaz; yine de döngüyü kesmek için kategori elenir.
		const FString CategoryName = Category.ToString();
		if (CategoryName == TEXT("LogFeralin"))
		{
			return;
		}
		const bool bFatal = Verbosity == ELogVerbosity::Fatal;
		const FString Text(Message);
		UFeralinSubsystem* Target = Owner;
		if (IsInGameThread())
		{
			Target->HandleLogRecord(bFatal, CategoryName, Text);
		}
		else
		{
			AsyncTask(ENamedThreads::GameThread, [Target, bFatal, CategoryName, Text]() { Target->HandleLogRecord(bFatal, CategoryName, Text); });
		}
	}

private:
	UFeralinSubsystem* Owner;
};

struct FFeralinCore
{
	FFeralinCore(const feralin::game::Options& Options, const feralin::game::Environment& Env, std::unique_ptr<feralin::crypto::EventStore> Store, const std::string& InEndpoint, float InTimeoutSeconds)
		: Client(Options, Env, std::move(Store))
		, ProjectKey(Options.project_key)
		, Endpoint(InEndpoint)
		, TimeoutSeconds(InTimeoutSeconds)
	{
	}

	feralin::wire::EventCore& Events() { return Client.core(); }

	feralin::game::Client Client;
	feralin::wire::Batch InFlight;
	std::string ProjectKey;
	std::string Endpoint;
	float TimeoutSeconds;
	bool bInstallBinding = false;
};

namespace
{
	using FeralinInternal::OptNumber;
	using FeralinInternal::OptText;
	using FeralinInternal::ToUtf8;
	namespace Game = feralin::game;
}

void UFeralinSubsystem::Initialize(FSubsystemCollectionBase& Collection)
{
	Super::Initialize(Collection);

	const UFeralinSettings* Settings = GetDefault<UFeralinSettings>();
	std::string Key;
	feralin::wire::Error Failure = feralin::wire::normalize_project_key(ToUtf8(Settings->ProjectKey), Key);
	std::string Endpoint;
	if (!Failure.failed())
	{
		Failure = feralin::wire::collect_endpoint(ToUtf8(Settings->CollectUrl), Endpoint);
	}
	if (Failure.failed())
	{
		// Yanlış yapılandırma oyunu düşürmez; alt sistem olay üretmeden kapalı kalır.
		UE_LOG(LogFeralin, Warning, TEXT("Feralin kapalı: %s"), *FeralinInternal::FromUtf8(Failure.message));
		return;
	}

	Game::Options Options;
	Options.sdk = feralin::wire::SdkIdentity{FeralinInternal::SdkName, FeralinInternal::SdkVersion, FeralinInternal::SdkPlatform};
	Options.project_key = Key;
	Options.attribution_api_url = ToUtf8(Settings->AttributionApiUrl);
	Options.project_id = ToUtf8(Settings->ProjectId);
	Options.batch_size = Settings->BatchSize;
	Options.queue_limit = Settings->QueueLimit;
	Options.session_timeout_ms = static_cast<std::int64_t>(FMath::Max(0, Settings->SessionTimeoutMinutes)) * 60 * 1000;
	Options.errors.sample_rate = Settings->ErrorSampleRate;
	Options.errors.max_per_minute = Settings->MaxErrorsPerMinute;
	Options.errors.max_per_fingerprint_per_minute = Settings->MaxErrorsPerFingerprintPerMinute;
	Options.tracking_status = FeralinPlatform::MakeTrackingStatus();
	Options.queue_protection = "none";
	Options.install_code = ToUtf8(Settings->InstallCode);

	Game::Environment Env;
	Env.now_ms = []() { return static_cast<std::int64_t>(FeralinInternal::NowEpochMs()); };
	Env.mono_ms = []() { return static_cast<std::int64_t>(FeralinInternal::MonotonicMs()); };
	Env.fill = FeralinInternal::FillRandom;
	Env.unit_random = []()
	{
		unsigned char Bytes[4];
		FeralinInternal::FillRandom(Bytes, sizeof(Bytes));
		const uint32 Value = (static_cast<uint32>(Bytes[0]) << 24) | (static_cast<uint32>(Bytes[1]) << 16) | (static_cast<uint32>(Bytes[2]) << 8) | static_cast<uint32>(Bytes[3]);
		return static_cast<double>(Value) / 4294967296.0;
	};
	Env.log = [](const std::string& Message) { UE_LOG(LogFeralin, Warning, TEXT("%s"), *FeralinInternal::FromUtf8(Message)); };

	// Kalıcı şifreli kuyruk: veri anahtarı alınamazsa düz metne düşülmez, kuyruk bellekte kalır.
	std::unique_ptr<feralin::crypto::EventStore> Store;
	if (Settings->bPersistQueue)
	{
		const std::string Directory = FeralinInternal::DefaultQueueDirectory(Settings);
		feralin::crypto::WrappedFileKeyProvider Provider(Directory, FeralinPlatform::MakeKeyProtector(), FeralinInternal::RandomBytes);
		const feralin::crypto::Bytes DataKey = Provider.get_or_create();
		if (DataKey.size() == 32)
		{
			Options.queue_protection = Provider.protection();
			feralin::crypto::AesGcmPayloadCipher Cipher(DataKey, []() { return FeralinInternal::RandomBytes(feralin::crypto::kIvBytes); });
			Store = std::make_unique<feralin::crypto::EncryptedEventStore>(std::make_unique<feralin::crypto::FileEventStore>(Directory), std::move(Cipher));
		}
		else
		{
			UE_LOG(LogFeralin, Warning, TEXT("Kuyruk anahtarı alınamadı: kalıcı kuyruk kapalı, olaylar yalnız bellekte tutulur"));
		}
	}

	Core = MakeShared<FFeralinCore>(Options, Env, std::move(Store), Endpoint, FMath::Max(0.1f, Settings->TimeoutSeconds));
	if (Settings->FlushIntervalSeconds > 0.0f)
	{
		TickerHandle = FTSTicker::GetCoreTicker().AddTicker(FTickerDelegate::CreateUObject(this, &UFeralinSubsystem::OnTick), Settings->FlushIntervalSeconds);
		bHasTicker = true;
	}
	BackgroundHandle = FCoreDelegates::ApplicationWillEnterBackgroundDelegate.AddUObject(this, &UFeralinSubsystem::HandleEnteredBackground);
	ForegroundHandle = FCoreDelegates::ApplicationHasEnteredForegroundDelegate.AddUObject(this, &UFeralinSubsystem::HandleEnteredForeground);
	if (Settings->bCaptureLogErrors)
	{
		LogCapture = MakeShared<FFeralinLogCapture>(this);
		GLog->AddOutputDevice(LogCapture.Get());
	}
	StartAttribution();
}

void UFeralinSubsystem::Deinitialize()
{
	if (bHasTicker)
	{
		FTSTicker::GetCoreTicker().RemoveTicker(TickerHandle);
		bHasTicker = false;
	}
	FCoreDelegates::ApplicationWillEnterBackgroundDelegate.Remove(BackgroundHandle);
	FCoreDelegates::ApplicationHasEnteredForegroundDelegate.Remove(ForegroundHandle);
	if (LogCapture.IsValid())
	{
		GLog->RemoveOutputDevice(LogCapture.Get());
		LogCapture.Reset();
	}
	// Son gönderim en iyi çabadır: motor kapanırken yanıt beklenmez. Kalıcı kuyrukta kalan olaylar sonraki açılışta aynı event_id ile gönderilir.
	if (Core.IsValid() && !bRequestInFlight && Core->Events().queued() > 0)
	{
		RoundsLeft = 1;
		SendNextBatch();
	}
	bRoundActive = false;
	bFlushRequested = false;
	Core.Reset();
	Super::Deinitialize();
}

void UFeralinSubsystem::StartAttribution()
{
	// Referrer yalnız Android'de okunur ve yalnız reklam izni verilince; ilk açılış olayı kalıcı işaretle bir kez üretilir.
	const Game::ReferrerReader Reader = FeralinPlatform::MakeReferrerReader();
	if (Reader && Core.IsValid())
	{
		Core->Client.start_attribution(Reader);
	}
}

bool UFeralinSubsystem::Track(const FString& EventName, const TMap<FString, FString>& Properties)
{
	return TrackWithNumbers(EventName, Properties, TMap<FString, double>());
}

bool UFeralinSubsystem::TrackWithNumbers(const FString& EventName, const TMap<FString, FString>& Properties, const TMap<FString, double>& NumberProperties)
{
	if (!Core.IsValid())
	{
		return false;
	}
	feralin::wire::Value Wire;
	if (Properties.Num() > 0 || NumberProperties.Num() > 0)
	{
		Wire = FeralinInternal::StringMap(Properties);
		for (const auto& Pair : NumberProperties)
		{
			Wire.set(ToUtf8(Pair.Key), feralin::wire::Value(Pair.Value));
		}
	}
	const Game::TrackResult Result = Core->Client.track(ToUtf8(EventName), Wire);
	AfterTrack(Result.queue_full);
	return Result.produced;
}

bool UFeralinSubsystem::TrackJson(const FString& EventName, const FString& PropertiesJson)
{
	if (!Core.IsValid())
	{
		return false;
	}
	feralin::wire::Value Wire;
	if (!PropertiesJson.IsEmpty() && !feralin::wire::parse_json(ToUtf8(PropertiesJson), Wire))
	{
		UE_LOG(LogFeralin, Warning, TEXT("PropertiesJson geçerli JSON değil"));
		return false;
	}
	const Game::TrackResult Result = Core->Client.track(ToUtf8(EventName), Wire);
	AfterTrack(Result.queue_full);
	return Result.produced;
}

void UFeralinSubsystem::AfterTrack(bool bQueueFull)
{
	// Kuyruk batch boyutuna ulaştıysa aralığı beklemeden gönderilir; otomatik gönderim kapalıysa yalnız Flush gönderir.
	if (bQueueFull && bHasTicker && !bRequestInFlight && !Core->Events().in_backoff(FeralinInternal::MonotonicMs()))
	{
		BeginRound();
	}
}

void UFeralinSubsystem::SetConsent(const FFeralinConsent& Consent)
{
	if (Core.IsValid())
	{
		Core->Client.set_consent(FeralinInternal::ToWire(Consent));
	}
}

FFeralinConsent UFeralinSubsystem::GetConsent() const
{
	return Core.IsValid() ? FeralinInternal::FromWire(Core->Client.consent()) : FFeralinConsent();
}

bool UFeralinSubsystem::Identify(const FString& UserId)
{
	if (!Core.IsValid())
	{
		return false;
	}
	const feralin::wire::Error Failure = Core->Events().identify(ToUtf8(UserId));
	if (Failure.failed())
	{
		UE_LOG(LogFeralin, Warning, TEXT("Identify reddedildi: %s"), *FeralinInternal::FromUtf8(Failure.message));
		return false;
	}
	return true;
}

bool UFeralinSubsystem::SetAnonymousId(const FString& AnonymousId)
{
	if (!Core.IsValid())
	{
		return false;
	}
	const std::string Value = ToUtf8(AnonymousId);
	const feralin::wire::Error Failure = feralin::wire::validate_text(Value, feralin::wire::kMaxIdentifierLength, "anonymous_id");
	if (Failure.failed())
	{
		UE_LOG(LogFeralin, Warning, TEXT("SetAnonymousId reddedildi: %s"), *FeralinInternal::FromUtf8(Failure.message));
		return false;
	}
	Core->Client.set_anonymous_id(Value);
	return true;
}

void UFeralinSubsystem::Reset()
{
	if (Core.IsValid())
	{
		Core->Client.reset();
	}
}

bool UFeralinSubsystem::TrackRevenue(const FString& TransactionId, int64 AmountMinor, const FString& Currency, const FString& ProductId, int32 Quantity, EFeralinPurchaseType PurchaseType,
	EFeralinReceiptProvider ReceiptProvider, const FString& ReceiptToken, const TMap<FString, FString>& Properties)
{
	if (!Core.IsValid())
	{
		return false;
	}
	Game::RevenueInput Input;
	Input.transaction_id = ToUtf8(TransactionId);
	Input.amount_minor = static_cast<std::int64_t>(AmountMinor);
	Input.currency = ToUtf8(Currency);
	Input.product_id = OptText(ProductId);
	Input.quantity = Quantity;
	switch (PurchaseType)
	{
	case EFeralinPurchaseType::SubscriptionStart: Input.purchase_type = Game::PurchaseType::subscription_start; break;
	case EFeralinPurchaseType::SubscriptionRenew: Input.purchase_type = Game::PurchaseType::subscription_renew; break;
	case EFeralinPurchaseType::SubscriptionCancel: Input.purchase_type = Game::PurchaseType::subscription_cancel; break;
	default: Input.purchase_type = Game::PurchaseType::purchase; break;
	}
	if (ReceiptProvider != EFeralinReceiptProvider::None)
	{
		Game::Receipt Receipt;
		Receipt.provider = ReceiptProvider == EFeralinReceiptProvider::Google ? Game::ReceiptProvider::google : ReceiptProvider == EFeralinReceiptProvider::Stripe ? Game::ReceiptProvider::stripe : Game::ReceiptProvider::apple;
		Receipt.token = ToUtf8(ReceiptToken);
		Input.receipt = Receipt;
	}
	Input.properties = FeralinInternal::StringMap(Properties);
	const Game::TrackResult Result = Core->Client.track_revenue(Input);
	AfterTrack(Result.queue_full);
	return Result.produced;
}

bool UFeralinSubsystem::TrackAdRevenue(const FString& Network, EFeralinAdFormat AdFormat, int64 RevenueMicros, const FString& Currency, const FString& AdUnit, EFeralinAdPrecision Precision,
	const FString& Placement, const FString& ImpressionId, const TMap<FString, FString>& Properties)
{
	if (!Core.IsValid())
	{
		return false;
	}
	Game::AdRevenueInput Input;
	Input.network = ToUtf8(Network);
	static const Game::AdFormat Formats[] = {Game::AdFormat::banner, Game::AdFormat::interstitial, Game::AdFormat::rewarded, Game::AdFormat::rewarded_interstitial, Game::AdFormat::native, Game::AdFormat::app_open, Game::AdFormat::other};
	static const Game::AdPrecision Precisions[] = {Game::AdPrecision::estimated, Game::AdPrecision::publisher_provided, Game::AdPrecision::precise, Game::AdPrecision::unknown};
	Input.ad_format = Formats[static_cast<int>(AdFormat)];
	Input.precision = Precisions[static_cast<int>(Precision)];
	Input.revenue_micros = static_cast<std::int64_t>(RevenueMicros);
	Input.currency = ToUtf8(Currency);
	Input.ad_unit = OptText(AdUnit);
	Input.placement = OptText(Placement);
	Input.impression_id = OptText(ImpressionId);
	Input.properties = FeralinInternal::StringMap(Properties);
	const Game::TrackResult Result = Core->Client.track_ad_revenue(Input);
	AfterTrack(Result.queue_full);
	return Result.produced;
}

bool UFeralinSubsystem::Group(const FString& GroupId, const TMap<FString, FString>& Traits)
{
	if (!Core.IsValid())
	{
		return false;
	}
	const Game::TrackResult Result = Core->Client.group(ToUtf8(GroupId), FeralinInternal::StringMap(Traits));
	AfterTrack(Result.queue_full);
	return Result.produced;
}

bool UFeralinSubsystem::SetUserProperties(const TMap<FString, FString>& Properties)
{
	if (!Core.IsValid())
	{
		return false;
	}
	const Game::TrackResult Result = Core->Client.set_user_properties(FeralinInternal::StringMap(Properties));
	AfterTrack(Result.queue_full);
	return Result.produced;
}

// Oyun olayları: kurallar FeralinGame.hpp içindedir (game-events.md).
#define FERALIN_GAME_EVENT(Name, Expression)                                         \
	if (!Core.IsValid())                                                              \
	{                                                                                 \
		return false;                                                                 \
	}                                                                                 \
	const Game::TrackResult Result = Core->Client.track_game(Name, Expression);        \
	AfterTrack(Result.queue_full);                                                    \
	return Result.produced;

bool UFeralinSubsystem::TrackLevelStart(const FString& LevelId, int64 Attempt)
{
	FERALIN_GAME_EVENT("level_start", Game::level_properties(ToUtf8(LevelId), OptNumber(Attempt), std::nullopt, std::nullopt, std::nullopt, feralin::wire::Value()))
}

bool UFeralinSubsystem::TrackLevelComplete(const FString& LevelId, int64 Attempt, int64 Score, int64 DurationMs)
{
	FERALIN_GAME_EVENT("level_complete", Game::level_properties(ToUtf8(LevelId), OptNumber(Attempt), OptNumber(Score), OptNumber(DurationMs), std::nullopt, feralin::wire::Value()))
}

bool UFeralinSubsystem::TrackLevelFail(const FString& LevelId, int64 Attempt, int64 Score, int64 DurationMs, const FString& FailReason)
{
	FERALIN_GAME_EVENT("level_fail", Game::level_properties(ToUtf8(LevelId), OptNumber(Attempt), OptNumber(Score), OptNumber(DurationMs), OptText(FailReason), feralin::wire::Value()))
}

bool UFeralinSubsystem::TrackEconomySource(const FString& CurrencyName, int64 Amount, const FString& Reason, const FString& ItemId)
{
	FERALIN_GAME_EVENT("economy_source", Game::economy_properties(ToUtf8(CurrencyName), static_cast<std::int64_t>(Amount), OptText(Reason), OptText(ItemId), feralin::wire::Value()))
}

bool UFeralinSubsystem::TrackEconomySink(const FString& CurrencyName, int64 Amount, const FString& Reason, const FString& ItemId)
{
	FERALIN_GAME_EVENT("economy_sink", Game::economy_properties(ToUtf8(CurrencyName), static_cast<std::int64_t>(Amount), OptText(Reason), OptText(ItemId), feralin::wire::Value()))
}

bool UFeralinSubsystem::TrackRewardedAdShown(const FString& Placement, const FString& Network)
{
	FERALIN_GAME_EVENT("rewarded_ad_shown", Game::rewarded_shown_properties(ToUtf8(Placement), OptText(Network), feralin::wire::Value()))
}

bool UFeralinSubsystem::TrackRewardedAdComplete(const FString& Placement, const FString& Network, int64 RewardAmount, const FString& RewardCurrency)
{
	FERALIN_GAME_EVENT("rewarded_ad_complete", Game::rewarded_complete_properties(ToUtf8(Placement), OptText(Network), OptNumber(RewardAmount), OptText(RewardCurrency), feralin::wire::Value()))
}

bool UFeralinSubsystem::TrackIapOfferShown(const FString& ProductId, const FString& Placement)
{
	FERALIN_GAME_EVENT("iap_offer_shown", Game::iap_offer_properties(ToUtf8(ProductId), OptText(Placement), feralin::wire::Value()))
}

bool UFeralinSubsystem::TrackIapInitiated(const FString& ProductId, const FString& Placement, const FString& TransactionId)
{
	FERALIN_GAME_EVENT("iap_initiated", Game::iap_initiated_properties(ToUtf8(ProductId), OptText(Placement), OptText(TransactionId), feralin::wire::Value()))
}

bool UFeralinSubsystem::CaptureError(const FString& ErrorType, const FString& Message, const FString& StackTrace, bool bHandled)
{
	if (!Core.IsValid())
	{
		return false;
	}
	const Game::TrackResult Result = Core->Client.capture_error(ToUtf8(ErrorType), ToUtf8(Message), ToUtf8(StackTrace), bHandled, bHandled ? Game::error_source::manual : Game::error_source::unhandled_exception);
	AfterTrack(Result.queue_full);
	return Result.produced;
}

void UFeralinSubsystem::HandleLogRecord(bool bFatal, const FString& Category, const FString& Message)
{
	if (!Core.IsValid())
	{
		return;
	}
	const Game::TrackResult Result = Core->Client.capture_error(ToUtf8(Category.IsEmpty() ? FString(TEXT("LogError")) : Category), ToUtf8(Message), std::string(), !bFatal, bFatal ? Game::error_source::log_fatal : Game::error_source::log_error);
	AfterTrack(Result.queue_full);
}

void UFeralinSubsystem::HandleEnteredBackground()
{
	if (Core.IsValid())
	{
		Core->Client.notify_background();
		// Mobilde süreç her an durabilir: arka plana geçişte gönderim denenir.
		if (!bRoundActive && Core->Events().queued() > 0)
		{
			BeginRound();
		}
	}
}

void UFeralinSubsystem::HandleEnteredForeground()
{
	if (Core.IsValid())
	{
		Core->Client.notify_foreground();
	}
}

void UFeralinSubsystem::HandleDeepLink(const FString& Url)
{
	if (Core.IsValid())
	{
		Core->Client.handle_deep_link(ToUtf8(Url));
	}
}

bool UFeralinSubsystem::SetInstallCode(const FString& Code)
{
	return Core.IsValid() && Core->Client.set_install_code(ToUtf8(Code));
}

FString UFeralinSubsystem::ConsumeDeferredDeepLink()
{
	return Core.IsValid() ? FeralinInternal::FromUtf8(Core->Client.consume_deferred_deep_link()) : FString();
}

void UFeralinSubsystem::BindInstall()
{
	if (!Core.IsValid())
	{
		FFeralinInstallBinding Binding;
		Binding.Status = TEXT("not_configured");
		OnInstallBound.Broadcast(Binding);
		return;
	}
	const Game::HttpPost Post = [this](const std::string& Url, const feralin::wire::Headers& Headers, const std::string& Body, std::function<void(int)> Done)
	{
		TArray<uint8> Payload;
		Payload.Append(reinterpret_cast<const uint8*>(Body.data()), static_cast<int32>(Body.size()));
		const TSharedRef<IHttpRequest, ESPMode::ThreadSafe> Request = FHttpModule::Get().CreateRequest();
		Request->SetURL(FeralinInternal::FromUtf8(Url));
		Request->SetVerb(TEXT("POST"));
		for (const auto& Header : Headers)
		{
			Request->SetHeader(FeralinInternal::FromUtf8(Header.first), FeralinInternal::FromUtf8(Header.second));
		}
		Request->SetContent(MoveTemp(Payload));
		Request->SetTimeout(Core.IsValid() ? Core->TimeoutSeconds : 10.0f);
		Request->OnProcessRequestComplete().BindWeakLambda(this, [Done](FHttpRequestPtr, FHttpResponsePtr Response, bool bConnected)
		{
			Done(bConnected && Response.IsValid() ? Response->GetResponseCode() : 0);
		});
		if (!Request->ProcessRequest())
		{
			Request->OnProcessRequestComplete().Unbind();
			Done(0);
		}
	};
	Core->Client.bind_install(FeralinPlatform::MakeTokenReader(), Post, [this](const Game::InstallBinding& Result)
	{
		FFeralinInstallBinding Binding;
		Binding.Status = FeralinInternal::FromUtf8(Result.status);
		Binding.InstallId = FeralinInternal::FromUtf8(Result.install_id);
		OnInstallBound.Broadcast(Binding);
	});
}

void UFeralinSubsystem::Flush()
{
	if (!Core.IsValid())
	{
		FFeralinFlushResult Result;
		Result.bSuccess = false;
		Result.Error = TEXT("Feralin yapılandırılmadı");
		OnFlushCompleted.Broadcast(Result);
		return;
	}
	bFlushRequested = true;
	// Süren tur varsa sonucu bu çağrıya da yetişir; aynı anda tek istek kuralı korunur.
	if (!bRoundActive)
	{
		BeginRound();
	}
}

int32 UFeralinSubsystem::GetQueueLength() const
{
	return Core.IsValid() ? static_cast<int32>(Core->Events().queued()) : 0;
}

bool UFeralinSubsystem::OnTick(float DeltaSeconds)
{
	if (Core.IsValid() && !bRoundActive && Core->Events().queued() > 0 && !Core->Events().in_backoff(FeralinInternal::MonotonicMs()))
	{
		BeginRound();
	}
	return true;
}

void UFeralinSubsystem::BeginRound()
{
	bRoundActive = true;
	RoundResult = FFeralinFlushResult();
	RoundsLeft = Core->Events().max_rounds();
	SendNextBatch();
}

void UFeralinSubsystem::SendNextBatch()
{
	feralin::wire::Batch Batch = Core->Events().peek();
	if (Batch.empty() || RoundsLeft <= 0)
	{
		FinishRound();
		return;
	}
	--RoundsLeft;

	const std::string Body = feralin::wire::EventCore::batch_body(Batch, FeralinInternal::NowEpochMs());
	const feralin::wire::Headers Headers = feralin::wire::request_headers(Core->ProjectKey, feralin::wire::EventCore::batch_key(Batch), Core->Events().identity());

	TArray<uint8> Payload;
	Payload.Append(reinterpret_cast<const uint8*>(Body.data()), static_cast<int32>(Body.size()));

	const TSharedRef<IHttpRequest, ESPMode::ThreadSafe> Request = FHttpModule::Get().CreateRequest();
	Request->SetURL(FeralinInternal::FromUtf8(Core->Endpoint));
	Request->SetVerb(TEXT("POST"));
	for (const auto& Header : Headers)
	{
		Request->SetHeader(FeralinInternal::FromUtf8(Header.first), FeralinInternal::FromUtf8(Header.second));
	}
	Request->SetContent(MoveTemp(Payload));
	Request->SetTimeout(Core->TimeoutSeconds);
	Request->OnProcessRequestComplete().BindWeakLambda(this, [this](FHttpRequestPtr, FHttpResponsePtr Response, bool bConnected)
	{
		HandleResponse(Response, bConnected);
	});

	Core->InFlight = MoveTemp(Batch);
	bRequestInFlight = true;
	if (!Request->ProcessRequest())
	{
		// İstek başlatılamadı (ör. izinli alan listesi): ağ hatası gibi işlenir, tamamlanma geri çağrısı beklenmez.
		Request->OnProcessRequestComplete().Unbind();
		HandleResponse(nullptr, false);
	}
}

void UFeralinSubsystem::HandleResponse(FHttpResponsePtr Response, bool bConnected)
{
	bRequestInFlight = false;
	if (!Core.IsValid())
	{
		return;
	}
	const feralin::wire::Batch Batch = MoveTemp(Core->InFlight);
	Core->InFlight.clear();

	feralin::wire::DeliveryResult Result;
	if (!bConnected || !Response.IsValid() || Response->GetResponseCode() <= 0)
	{
		Result = Core->Client.deliver_network_error(Batch, "bağlantı kurulamadı veya zaman aşımı");
	}
	else
	{
		const TArray<uint8>& Content = Response->GetContent();
		const std::size_t Length = FMath::Min(static_cast<std::size_t>(Content.Num()), feralin::wire::kMaxResponseBody);
		const std::string Body(reinterpret_cast<const char*>(Content.GetData()), Length);
		Result = Core->Client.deliver_response(Batch, Response->GetResponseCode(), Body, ToUtf8(Response->GetHeader(TEXT("Retry-After"))));
	}

	RoundResult.Sent += Result.sent;
	RoundResult.Accepted += Result.accepted;
	RoundResult.Rejected += Result.rejected;
	RoundResult.HttpStatus = Result.status;
	if (!Result.batch_id.empty())
	{
		RoundResult.BatchId = FeralinInternal::FromUtf8(Result.batch_id);
	}
	if (Result.error.failed())
	{
		RoundResult.bSuccess = false;
		RoundResult.bTemporaryFailure = Result.error.code == feralin::wire::ErrorCode::temporary;
		RoundResult.Error = FeralinInternal::FromUtf8(Result.error.message);
		if (Result.error.code == feralin::wire::ErrorCode::rejected)
		{
			UE_LOG(LogFeralin, Warning, TEXT("Batch kalıcı olarak reddedildi: %s"), *RoundResult.Error);
		}
		else
		{
			UE_LOG(LogFeralin, Verbose, TEXT("Batch kuyrukta tutuldu: %s"), *RoundResult.Error);
		}
		FinishRound();
		return;
	}
	SendNextBatch();
}

void UFeralinSubsystem::FinishRound()
{
	bRoundActive = false;
	RoundResult.Retained = Core.IsValid() ? static_cast<int32>(Core->Events().queued()) : 0;
	const bool bBroadcast = bFlushRequested;
	bFlushRequested = false;
	if (bBroadcast)
	{
		const FFeralinFlushResult Result = RoundResult;
		OnFlushCompleted.Broadcast(Result);
	}
}
