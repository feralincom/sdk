// Bağımlılıksız küçük test çalıştırıcısı ve sahte transport.
#ifndef FERALIN_TEST_SUPPORT_HPP
#define FERALIN_TEST_SUPPORT_HPP

#include <cstdio>
#include <deque>
#include <functional>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "feralin/feralin.hpp"

namespace test {

struct Case {
  const char* name;
  std::function<void()> body;
};

inline std::vector<Case>& registry() {
  static std::vector<Case> cases;
  return cases;
}

struct Register {
  Register(const char* name, std::function<void()> body) { registry().push_back(Case{name, std::move(body)}); }
};

inline int run_all() {
  int failed = 0;
  for (const Case& item : registry()) {
    try {
      item.body();
      std::printf("OK    %s\n", item.name);
    } catch (const std::exception& error) {
      ++failed;
      std::printf("KALDI %s\n      %s\n", item.name, error.what());
    }
  }
  std::printf("%zu test, %zu geçti, %d kaldı\n", registry().size(), registry().size() - static_cast<std::size_t>(failed), failed);
  return failed == 0 ? 0 : 1;
}

template <typename T>
std::string show(const T& value) {
  std::ostringstream out;
  out << value;
  return out.str();
}

}  // namespace test

#define TEST_CASE(name)                                       \
  static void name();                                         \
  static const test::Register register_##name(#name, name);   \
  static void name()

#define ASSERT_TRUE(condition)                                                                                                  \
  do {                                                                                                                          \
    if (!(condition)) throw std::runtime_error(std::string(__FILE__) + ":" + std::to_string(__LINE__) + ": beklenmedi: " #condition); \
  } while (false)

#define ASSERT_EQ(actual, expected)                                                                                               \
  do {                                                                                                                            \
    const auto actual_value = (actual);                                                                                           \
    const auto expected_value = (expected);                                                                                       \
    if (!(actual_value == expected_value)) {                                                                                      \
      throw std::runtime_error(std::string(__FILE__) + ":" + std::to_string(__LINE__) + ": " #actual " = " + test::show(actual_value) + ", beklenen " + test::show(expected_value)); \
    }                                                                                                                             \
  } while (false)

namespace test {

constexpr const char* kTestKey = "pk_test_cpp_unit_0001";

struct ScriptedResponse {
  int status = 202;
  std::string body;
  std::string retry_after;
  bool network_error = false;
  bool lost_after_delivery = false;
};

// Sahte toplayıcı: isteği kaydeder, senaryo boşsa gerçek toplayıcı gibi 202 ve sayaçları döner.
class FakeTransport final : public feralin::Transport {
 public:
  feralin::HttpResponse post(const feralin::HttpRequest& request) override {
    std::lock_guard<std::mutex> guard(mutex_);
    requests_.push_back(request);
    feralin::HttpResponse response;
    if (!script_.empty()) {
      const ScriptedResponse next = script_.front();
      script_.pop_front();
      if (next.network_error) {
        response.error = "sahte ağ hatası";
        return response;
      }
      response.status = next.status;
      response.body = next.body;
      response.retry_after = next.retry_after;
      return response;
    }
    feralin::Value parsed;
    int count = 0;
    if (feralin::wire::parse_json(request.body, parsed) && parsed.find("events") != nullptr) count = static_cast<int>(parsed.find("events")->size());
    response.status = 202;
    response.body = "{\"batch_id\":\"01TESTBATCH0000000000000000\",\"accepted\":" + std::to_string(count) + ",\"rejected\":0}";
    return response;
  }

  void script(std::vector<ScriptedResponse> responses) {
    std::lock_guard<std::mutex> guard(mutex_);
    script_.assign(responses.begin(), responses.end());
  }

  std::size_t count() const {
    std::lock_guard<std::mutex> guard(mutex_);
    return requests_.size();
  }

  feralin::HttpRequest request(std::size_t index) const {
    std::lock_guard<std::mutex> guard(mutex_);
    return requests_.at(index);
  }

 private:
  mutable std::mutex mutex_;
  std::deque<ScriptedResponse> script_;
  std::vector<feralin::HttpRequest> requests_;
};

inline std::string header(const feralin::HttpRequest& request, const std::string& name) {
  for (const auto& item : request.headers) {
    if (item.first == name) return item.second;
  }
  return std::string();
}

inline feralin::Value body_of(const feralin::HttpRequest& request) {
  feralin::Value parsed;
  if (!feralin::wire::parse_json(request.body, parsed)) throw std::runtime_error("istek gövdesi JSON değil");
  return parsed;
}

inline feralin::Value parsed(const std::string& text) {
  feralin::Value value;
  if (!feralin::wire::parse_json(text, value)) throw std::runtime_error("JSON çözülemedi: " + text);
  return value;
}

}  // namespace test

#endif  // FERALIN_TEST_SUPPORT_HPP
