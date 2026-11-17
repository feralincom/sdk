// UE'NİN GERÇEK BAŞLIKLARI DEĞİLDİR. Bu makinede Unreal yokken eklentinin yapıştırıcı kodunu g++ ile derleyip sınamak için
// en küçük taklit. Motor API'sinin doğruluğunu kanıtlamaz; yalnız bizim kodumuzun sözdizimini ve akışını sınar.
#pragma once

#include <cstdarg>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

using int32 = std::int32_t;
using int64 = std::int64_t;
using uint8 = std::uint8_t;
using uint32 = std::uint32_t;
using TCHAR = char;

#define TEXT(x) x
#define THIRD_PARTY_INCLUDES_START
#define THIRD_PARTY_INCLUDES_END
#define FERALIN_API
#define UCLASS(...)
#define USTRUCT(...)
#define UPROPERTY(...)
#define UFUNCTION(...)
#define UPARAM(...)
#define GENERATED_BODY() using Super = UGameInstanceSubsystem;
#define IMPLEMENT_MODULE(Type, Name)
#define DECLARE_LOG_CATEGORY_EXTERN(Name, Default, Compile) extern int Name;
#define DEFINE_LOG_CATEGORY(Name) int Name = 0;

class FString {
 public:
  FString() = default;
  FString(const char* text) : text_(text != nullptr ? text : "") {}
  const char* operator*() const { return text_.c_str(); }
  bool IsEmpty() const { return text_.empty(); }
  const std::string& std_string() const { return text_; }
  bool operator==(const FString& other) const { return text_ == other.text_; }

 private:
  std::string text_;
};

class FTCHARToUTF8 {
 public:
  explicit FTCHARToUTF8(const char* text) : text_(text) {}
  const char* Get() const { return text_; }
  int32 Length() const { return static_cast<int32>(std::strlen(text_)); }

 private:
  const char* text_;
};

#define UTF8_TO_TCHAR(x) (x)

inline std::vector<std::string>& stub_log_lines() {
  static std::vector<std::string> lines;
  return lines;
}

inline void stub_log(const char* format, ...) {
  char buffer[1024];
  va_list args;
  va_start(args, format);
  std::vsnprintf(buffer, sizeof(buffer), format, args);
  va_end(args);
  stub_log_lines().emplace_back(buffer);
}

#define UE_LOG(Category, Verbosity, ...) stub_log(__VA_ARGS__)

template <typename T>
T&& MoveTemp(T& value) {
  return static_cast<T&&>(value);
}

template <typename T>
class TArray {
 public:
  void Append(const T* data, int32 count) { items_.insert(items_.end(), data, data + count); }
  const T* GetData() const { return items_.data(); }
  int32 Num() const { return static_cast<int32>(items_.size()); }

 private:
  std::vector<T> items_;
};

template <typename K, typename V>
struct TPair {
  K Key;
  V Value;
};

template <typename K, typename V>
class TMap {
 public:
  void Add(const K& key, const V& value) { items_.push_back(TPair<K, V>{key, value}); }
  int32 Num() const { return static_cast<int32>(items_.size()); }
  auto begin() const { return items_.begin(); }
  auto end() const { return items_.end(); }

 private:
  std::vector<TPair<K, V>> items_;
};

namespace ESPMode {
struct ThreadSafe {};
}  // namespace ESPMode

template <typename T, typename Mode = ESPMode::ThreadSafe>
class TSharedPtr {
 public:
  TSharedPtr() = default;
  TSharedPtr(std::nullptr_t) {}
  explicit TSharedPtr(std::shared_ptr<T> value) : value_(std::move(value)) {}
  bool IsValid() const { return value_ != nullptr; }
  void Reset() { value_.reset(); }
  T* operator->() const { return value_.get(); }
  T* Get() const { return value_.get(); }

 private:
  std::shared_ptr<T> value_;
};

template <typename T, typename Mode = ESPMode::ThreadSafe>
class TSharedRef {
 public:
  explicit TSharedRef(std::shared_ptr<T> value) : value_(std::move(value)) {}
  T* operator->() const { return value_.get(); }

 private:
  std::shared_ptr<T> value_;
};

template <typename T, typename... Args>
TSharedPtr<T> MakeShared(Args&&... args) {
  return TSharedPtr<T>(std::make_shared<T>(std::forward<Args>(args)...));
}

struct FMath {
  template <typename T>
  static T Max(T a, T b) { return a > b ? a : b; }
  template <typename T>
  static T Min(T a, T b) { return a < b ? a : b; }
};

class IHttpResponse {
 public:
  int32 Code = 0;
  std::string Body;
  std::string RetryAfter;
  TArray<uint8> ContentBytes;

  void Prepare() { ContentBytes.Append(reinterpret_cast<const uint8*>(Body.data()), static_cast<int32>(Body.size())); }
  int32 GetResponseCode() const { return Code; }
  const TArray<uint8>& GetContent() const { return ContentBytes; }
  FString GetHeader(const FString& name) const { return std::string(*name) == "Retry-After" ? FString(RetryAfter.c_str()) : FString(); }
};

class IHttpRequest;
using FHttpRequestPtr = TSharedPtr<IHttpRequest>;
using FHttpResponsePtr = TSharedPtr<IHttpResponse>;

class FHttpRequestCompleteDelegate {
 public:
  template <typename Object, typename Lambda>
  void BindWeakLambda(Object*, Lambda lambda) { function_ = std::move(lambda); }
  void Unbind() { function_ = nullptr; }
  void Execute(FHttpResponsePtr response, bool connected) const {
    if (function_) function_(FHttpRequestPtr(), std::move(response), connected);
  }

 private:
  std::function<void(FHttpRequestPtr, FHttpResponsePtr, bool)> function_;
};

class IHttpRequest {
 public:
  std::string Url;
  std::string Verb;
  std::vector<std::pair<std::string, std::string>> Headers;
  std::string Body;
  float Timeout = 0.0f;
  FHttpRequestCompleteDelegate Delegate;

  void SetURL(const FString& url) { Url = *url; }
  void SetVerb(const FString& verb) { Verb = *verb; }
  void SetHeader(const FString& name, const FString& value) { Headers.emplace_back(*name, *value); }
  void SetContent(TArray<uint8>&& data) { Body.assign(reinterpret_cast<const char*>(data.GetData()), static_cast<std::size_t>(data.Num())); }
  void SetTimeout(float seconds) { Timeout = seconds; }
  FHttpRequestCompleteDelegate& OnProcessRequestComplete() { return Delegate; }
  bool ProcessRequest();

  std::string header(const std::string& name) const {
    for (const auto& item : Headers) {
      if (item.first == name) return item.second;
    }
    return std::string();
  }
};

// Sahte HTTP modülü: istekler sıraya girer, test elle tamamlar.
class FHttpModule {
 public:
  static FHttpModule& Get() {
    static FHttpModule module;
    return module;
  }
  TSharedRef<IHttpRequest, ESPMode::ThreadSafe> CreateRequest() {
    auto request = std::make_shared<IHttpRequest>();
    created.push_back(request);
    return TSharedRef<IHttpRequest, ESPMode::ThreadSafe>(request);
  }

  std::vector<std::shared_ptr<IHttpRequest>> created;
  std::vector<std::shared_ptr<IHttpRequest>> processed;
  bool refuse_next = false;
};

inline bool IHttpRequest::ProcessRequest() {
  FHttpModule& module = FHttpModule::Get();
  if (module.refuse_next) {
    module.refuse_next = false;
    return false;
  }
  for (const auto& request : module.created) {
    if (request.get() == this) module.processed.push_back(request);
  }
  return true;
}

class FTickerDelegate {
 public:
  template <typename Object, typename Method>
  static FTickerDelegate CreateUObject(Object* object, Method method) {
    FTickerDelegate out;
    out.function_ = [object, method](float delta) { return (object->*method)(delta); };
    return out;
  }
  bool Execute(float delta) const { return function_(delta); }
  bool IsBound() const { return static_cast<bool>(function_); }

 private:
  std::function<bool(float)> function_;
};

class FTSTicker {
 public:
  struct FDelegateHandle {
    int Id = 0;
  };
  static FTSTicker& GetCoreTicker() {
    static FTSTicker ticker;
    return ticker;
  }
  FDelegateHandle AddTicker(const FTickerDelegate& delegate, float interval) {
    delegate_ = delegate;
    Interval = interval;
    return FDelegateHandle{1};
  }
  void RemoveTicker(const FDelegateHandle&) { delegate_ = FTickerDelegate(); }
  bool HasTicker() const { return delegate_.IsBound(); }
  void Fire() { delegate_.Execute(Interval); }

  float Interval = 0.0f;

 private:
  FTickerDelegate delegate_;
};

class FDateTime {
 public:
  static FDateTime UtcNow() { return FDateTime(); }
  int64 ToUnixTimestamp() const { return 1793690400; }
  int32 GetMillisecond() const { return 123; }
};

struct FGuid {
  uint32 A = 0, B = 0, C = 0, D = 0;
  static FGuid NewGuid() {
    static uint32 counter = 1;
    FGuid out;
    out.A = counter++ * 2654435761u;
    out.B = counter++ * 2654435761u;
    out.C = counter++ * 2654435761u;
    out.D = counter++ * 2654435761u;
    return out;
  }
};

struct FPlatformTime {
  static double& Now() {
    static double now = 1000.0;
    return now;
  }
  static double Seconds() { return Now(); }
};

class FSubsystemCollectionBase {};

class UGameInstanceSubsystem {
 public:
  virtual ~UGameInstanceSubsystem() = default;
  virtual void Initialize(FSubsystemCollectionBase&) {}
  virtual void Deinitialize() {}
};

class UDeveloperSettings {};

class IModuleInterface {
 public:
  virtual ~IModuleInterface() = default;
};

template <typename T>
T* MutableDefault() {
  static T instance;
  return &instance;
}

template <typename T>
const T* GetDefault() {
  return MutableDefault<T>();
}

// ---- v0.2.0 eklemeleri: UENUM, delegeler, günlük, dosya, yol, iş parçacığı.
#define UENUM(...)

using FDelegateHandle = int;

template <typename... Args>
class TStubMulticast {
 public:
  template <typename Object, typename Method>
  FDelegateHandle AddUObject(Object* object, Method method) {
    handlers_.push_back({++next_, [object, method](Args... args) { (object->*method)(args...); }});
    return next_;
  }
  void Remove(FDelegateHandle handle) {
    for (auto it = handlers_.begin(); it != handlers_.end(); ++it) {
      if (it->first == handle) {
        handlers_.erase(it);
        break;
      }
    }
  }
  void Broadcast(Args... args) const {
    for (const auto& item : handlers_) item.second(args...);
  }
  std::size_t Count() const { return handlers_.size(); }

 private:
  std::vector<std::pair<FDelegateHandle, std::function<void(Args...)>>> handlers_;
  FDelegateHandle next_ = 0;
};

struct FCoreDelegates {
  static inline TStubMulticast<> ApplicationWillEnterBackgroundDelegate;
  static inline TStubMulticast<> ApplicationHasEnteredForegroundDelegate;
};

class FName {
 public:
  FName() = default;
  FName(const char* text) : text_(text) {}
  FString ToString() const { return FString(text_.c_str()); }

 private:
  std::string text_;
};

namespace ELogVerbosity {
enum Type { Fatal, Error, Warning, Display, Log, Verbose };
}

class FOutputDevice {
 public:
  virtual ~FOutputDevice() = default;
  virtual void Serialize(const TCHAR* Message, ELogVerbosity::Type Verbosity, const FName& Category) = 0;
};

struct FStubLog {
  std::vector<FOutputDevice*> devices;
  void AddOutputDevice(FOutputDevice* device) { devices.push_back(device); }
  void RemoveOutputDevice(FOutputDevice* device) {
    for (auto it = devices.begin(); it != devices.end(); ++it) {
      if (*it == device) {
        devices.erase(it);
        break;
      }
    }
  }
  void Emit(const char* message, ELogVerbosity::Type verbosity, const char* category) {
    for (FOutputDevice* device : devices) device->Serialize(message, verbosity, FName(category));
  }
};
inline FStubLog* StubLog() {
  static FStubLog log;
  return &log;
}
#define GLog StubLog()

inline bool IsInGameThread() { return true; }

namespace ENamedThreads {
enum Type { GameThread };
}
template <typename F>
void AsyncTask(ENamedThreads::Type, F&& f) {
  f();
}

struct FPaths {
  static std::string& SavedDir() {
    static std::string dir = ".";
    return dir;
  }
  static FString ProjectSavedDir() { return FString(SavedDir().c_str()); }
  static FString Combine(const FString& a, const char* b) { return FString((a.std_string() + "/" + b).c_str()); }
};

struct IFileManager {
  static IFileManager& Get() {
    static IFileManager manager;
    return manager;
  }
  bool MakeDirectory(const char*, bool) { return true; }
};

#define DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(Name, ParamType, ParamName) \
  class Name {                                                                  \
   public:                                                                      \
    std::vector<std::function<void(ParamType)>> Handlers;                       \
    void Broadcast(ParamType value) const {                                     \
      for (const auto& handler : Handlers) handler(value);                      \
    }                                                                           \
  };
