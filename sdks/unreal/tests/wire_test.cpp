// Eklentinin saf tel biçimi kopyası (FeralinWire.hpp): sdks/cpp ile aynı test vektörleri. UE gibi exception ve RTTI kapalı derlenir.
#include <cstdio>
#include <sstream>

#include "FeralinWire.hpp"

namespace {

struct Case {
  const char* name;
  void (*body)();
};

std::vector<Case>& registry() {
  static std::vector<Case> cases;
  return cases;
}

bool register_case(const char* name, void (*body)()) {
  registry().push_back(Case{name, body});
  return true;
}

int g_current_failures = 0;

template <typename T>
std::string show(const T& value) {
  std::ostringstream out;
  out << value;
  return out.str();
}

}  // namespace

#define TEST_CASE(name)                                       \
  static void name();                                         \
  static const bool registered_##name = register_case(#name, name); \
  static void name()

#define ASSERT_TRUE(condition)                                                \
  do {                                                                        \
    if (!(condition)) {                                                       \
      std::printf("      %s:%d: beklenmedi: %s\n", __FILE__, __LINE__, #condition); \
      ++g_current_failures;                                                   \
      return;                                                                 \
    }                                                                         \
  } while (false)

#define ASSERT_EQ(actual, expected)                                           \
  do {                                                                        \
    const auto actual_value = (actual);                                       \
    const auto expected_value = (expected);                                   \
    if (!(actual_value == expected_value)) {                                  \
      std::printf("      %s:%d: %s = %s, beklenen %s\n", __FILE__, __LINE__, #actual, show(actual_value).c_str(), show(expected_value).c_str()); \
      ++g_current_failures;                                                   \
      return;                                                                 \
    }                                                                         \
  } while (false)

#define WIRE_TEST_IDENTITY (feralin::wire::SdkIdentity{"feralin-unreal", "0.1.0", "unreal"})
#include "wire_cases.inc"

int main() {
  int failed = 0;
  for (const Case& item : registry()) {
    g_current_failures = 0;
    item.body();
    if (g_current_failures == 0) {
      std::printf("OK    %s\n", item.name);
    } else {
      ++failed;
      std::printf("KALDI %s\n", item.name);
    }
  }
  std::printf("%zu test, %zu geçti, %d kaldı\n", registry().size(), registry().size() - static_cast<std::size_t>(failed), failed);
  return failed == 0 ? 0 : 1;
}
