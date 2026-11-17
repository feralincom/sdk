# SDK'yı paket deposu olmadan, herkese açık depodaki Git etiketinden derleyen tüketici örneği.
#   cmake -S sdks/cpp/examples/fetchcontent -B build-fc && cmake --build build-fc
# Etiket gönderilmeden önce yerel bir kopyayla denemek için:
#   -DFERALIN_GIT_REPOSITORY=file:///yerel/depo   (aynı etiketi taşıyan yerel Git deposu)
#   -DFETCHCONTENT_SOURCE_DIR_FERALIN=/yerel/depo (Git'siz, doğrudan kaynak dizini; SOURCE_SUBDIR yine uygulanır)
cmake_minimum_required(VERSION 3.18) # SOURCE_SUBDIR için 3.18 gerekir

project(feralin_fetchcontent_example LANGUAGES C CXX)

set(FERALIN_GIT_REPOSITORY "https://github.com/feralincom/sdk.git" CACHE STRING "Feralin SDK deposu")
set(FERALIN_GIT_TAG "sdks/cpp/v0.1.0" CACHE STRING "Feralin C/C++ SDK sürüm etiketi (sdks/cpp/v<sürüm>)")

include(FetchContent)
FetchContent_Declare(
  feralin
  GIT_REPOSITORY "${FERALIN_GIT_REPOSITORY}"
  GIT_TAG "${FERALIN_GIT_TAG}"
  GIT_SHALLOW TRUE
  SOURCE_SUBDIR sdks/cpp)
FetchContent_MakeAvailable(feralin)

add_executable(feralin_fetchcontent_example "${CMAKE_CURRENT_SOURCE_DIR}/../basic.cpp")
target_link_libraries(feralin_fetchcontent_example PRIVATE feralin::feralin)
