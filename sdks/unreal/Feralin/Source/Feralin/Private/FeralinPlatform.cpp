#include "FeralinPlatform.h"

#include "Async/Async.h"

#if PLATFORM_ANDROID
#include <jni.h>
#include <map>
#include <mutex>
#include "Android/AndroidApplication.h"
#include "Android/AndroidJNI.h"
#endif

#if PLATFORM_IOS
extern "C"
{
	int feralin_keychain_load(const char* Account, unsigned char* Buffer, int Capacity);
	int feralin_keychain_save(const char* Account, const unsigned char* Data, int Length);
	int feralin_att_status(void);
	int feralin_adservices_token(char* Buffer, int Capacity);
}
#endif

namespace FeralinPlatform
{
	using feralin::crypto::Bytes;

#if PLATFORM_ANDROID
	// FeralinAndroid.java: wrap/unwrap statik yöntemleri. Hata null döner (boş Bytes).
	class FAndroidKeyProtector : public feralin::crypto::KeyProtector
	{
	public:
		std::string protection() const override { return "android_keystore"; }
		Bytes protect(const Bytes& Data) override { return Call("wrap", Data); }
		Bytes unprotect(const Bytes& Data) override { return Call("unwrap", Data); }

	private:
		static Bytes Call(const char* Method, const Bytes& Data)
		{
			JNIEnv* Env = FAndroidApplication::GetJavaEnv();
			jclass Class = FAndroidApplication::FindJavaClassGlobalRef("com/feralin/unreal/FeralinAndroid");
			if (Env == nullptr || Class == nullptr) return Bytes();
			jmethodID Id = Env->GetStaticMethodID(Class, Method, "([B)[B");
			if (Id == nullptr) return Bytes();
			jbyteArray Input = Env->NewByteArray(static_cast<jsize>(Data.size()));
			Env->SetByteArrayRegion(Input, 0, static_cast<jsize>(Data.size()), reinterpret_cast<const jbyte*>(Data.data()));
			jbyteArray Output = static_cast<jbyteArray>(Env->CallStaticObjectMethod(Class, Id, Input));
			Env->DeleteLocalRef(Input);
			if (Env->ExceptionCheck()) { Env->ExceptionClear(); return Bytes(); }
			if (Output == nullptr) return Bytes();
			const jsize Length = Env->GetArrayLength(Output);
			Bytes Result(static_cast<size_t>(Length));
			Env->GetByteArrayRegion(Output, 0, Length, reinterpret_cast<jbyte*>(Result.data()));
			Env->DeleteLocalRef(Output);
			return Result;
		}
	};

	static std::mutex GReferrerGate;
	static std::map<jlong, std::function<void(bool, const std::string&)>> GReferrerCallbacks;
	static jlong GNextReferrerId = 1;
#endif

	std::shared_ptr<feralin::crypto::KeyProtector> MakeKeyProtector()
	{
#if PLATFORM_ANDROID
		return std::make_shared<FAndroidKeyProtector>();
#elif PLATFORM_IOS
		// Keychain kaydı sarılmış değil, anahtarın kendisini tutar: queue.key dosyası yalnızca bir işaretçidir.
		class FIosKeyProtector : public feralin::crypto::KeyProtector
		{
		public:
			std::string protection() const override { return "ios_keychain"; }
			Bytes protect(const Bytes& Data) override
			{
				return feralin_keychain_save("queue_key", Data.data(), static_cast<int>(Data.size())) == 0 ? Bytes{1} : Bytes();
			}
			Bytes unprotect(const Bytes&) override
			{
				Bytes Key(64);
				const int Length = feralin_keychain_load("queue_key", Key.data(), static_cast<int>(Key.size()));
				if (Length <= 0) return Bytes();
				Key.resize(static_cast<size_t>(Length));
				return Key;
			}
		};
		return std::make_shared<FIosKeyProtector>();
#else
		return std::make_shared<feralin::crypto::PlainKeyProtector>();
#endif
	}

	feralin::game::ReferrerReader MakeReferrerReader()
	{
#if PLATFORM_ANDROID
		return [](std::function<void(bool, const std::string&)> Done)
		{
			jlong Id;
			{
				std::lock_guard<std::mutex> Lock(GReferrerGate);
				Id = GNextReferrerId++;
				GReferrerCallbacks[Id] = MoveTemp(Done);
			}
			JNIEnv* Env = FAndroidApplication::GetJavaEnv();
			jclass Class = FAndroidApplication::FindJavaClassGlobalRef("com/feralin/unreal/FeralinAndroid");
			jmethodID Method = Class != nullptr ? Env->GetStaticMethodID(Class, "readInstallReferrer", "(Landroid/app/Activity;J)V") : nullptr;
			if (Method == nullptr)
			{
				std::function<void(bool, const std::string&)> Callback;
				{
					std::lock_guard<std::mutex> Lock(GReferrerGate);
					Callback = GReferrerCallbacks[Id];
					GReferrerCallbacks.erase(Id);
				}
				Callback(false, std::string());
				return;
			}
			Env->CallStaticVoidMethod(Class, Method, FJavaWrapper::GameActivityThis, Id);
		};
#else
		return nullptr;
#endif
	}

	feralin::game::TokenReader MakeTokenReader()
	{
#if PLATFORM_IOS
		return [](std::function<void(const feralin::game::TokenResult&)> Done)
		{
			char Buffer[8192];
			const int Length = feralin_adservices_token(Buffer, static_cast<int>(sizeof(Buffer)));
			feralin::game::TokenResult Result;
			if (Length > 0) { Result.status = "token"; Result.token.assign(Buffer, static_cast<size_t>(Length)); }
			else if (Length == 0) { Result.status = "unsupported"; }
			else { Result.status = "failed"; }
			Done(Result);
		};
#else
		return nullptr;
#endif
	}

	std::function<feralin::game::TrackingStatus()> MakeTrackingStatus()
	{
#if PLATFORM_IOS
		return []() { return static_cast<feralin::game::TrackingStatus>(feralin_att_status()); };
#else
		return nullptr;
#endif
	}
}

#if PLATFORM_ANDROID
// Java tarafı bu yöntemi Install Referrer sonucuyla çağırır; sonuç oyun iş parçacığına taşınır.
extern "C" JNIEXPORT void JNICALL Java_com_feralin_unreal_FeralinAndroid_nativeOnReferrer(JNIEnv* Env, jclass, jlong CallbackId, jboolean HasValue, jstring Raw)
{
	std::string Text;
	if (HasValue && Raw != nullptr)
	{
		const char* Chars = Env->GetStringUTFChars(Raw, nullptr);
		if (Chars != nullptr) { Text = Chars; Env->ReleaseStringUTFChars(Raw, Chars); }
	}
	std::function<void(bool, const std::string&)> Callback;
	{
		std::lock_guard<std::mutex> Lock(FeralinPlatform::GReferrerGate);
		auto It = FeralinPlatform::GReferrerCallbacks.find(CallbackId);
		if (It == FeralinPlatform::GReferrerCallbacks.end()) return;
		Callback = It->second;
		FeralinPlatform::GReferrerCallbacks.erase(It);
	}
	const bool bHas = HasValue != JNI_FALSE;
	AsyncTask(ENamedThreads::GameThread, [Callback, bHas, Text]() { Callback(bHas, Text); });
}
#endif
