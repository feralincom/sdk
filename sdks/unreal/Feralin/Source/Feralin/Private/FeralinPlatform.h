#pragma once

#include <memory>

#include "CoreMinimal.h"

THIRD_PARTY_INCLUDES_START
#include "FeralinGame.hpp"
THIRD_PARTY_INCLUDES_END

// Platform köprüleri. Android: Keystore ve Play Install Referrer (JNI, FeralinAndroid.java). iOS: Keychain, AdServices, ATT (FeralinNative.mm).
// Diğer platformlarda anahtar dosyada sarmalanmadan durur ve koruma düzeyi açıkça "local_file" bildirilir.
// Yanıtlar motorun iş parçacığından gelebilir; geri çağrılar oyun iş parçacığına taşınarak verilir.
namespace FeralinPlatform
{
	std::shared_ptr<feralin::crypto::KeyProtector> MakeKeyProtector();

	// Yalnız Android'de dolu; başka platformda boş (atıf başlatılmaz).
	feralin::game::ReferrerReader MakeReferrerReader();

	// Yalnız iOS'ta dolu.
	feralin::game::TokenReader MakeTokenReader();

	// iOS ATT durumu; başka platformda boş.
	std::function<feralin::game::TrackingStatus()> MakeTrackingStatus();
}
