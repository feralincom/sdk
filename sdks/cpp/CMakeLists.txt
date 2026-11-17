cmake_minimum_required(VERSION 3.16)

# Sürümün tek kaynağı feralin.h içindeki FERALIN_SDK_VERSION satırıdır.
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/include/feralin/feralin.h" FERALIN_VERSION_LINE REGEX "^#define FERALIN_SDK_VERSION ")
string(REGEX REPLACE "^#define FERALIN_SDK_VERSION \"([^\"]+)\".*$" "\\1" FERALIN_VERSION "${FERALIN_VERSION_LINE}")

project(feralin VERSION ${FERALIN_VERSION} LANGUAGES C CXX)

include(CMakePackageConfigHelpers)
include(CTest)
include(GNUInstallDirs)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
  set(FERALIN_TOP_LEVEL ON)
else()
  set(FERALIN_TOP_LEVEL OFF)
endif()

option(FERALIN_BUILD_TESTS "Birim testlerini derle" ${FERALIN_TOP_LEVEL})
option(FERALIN_WERROR "Uyarıları hata say" OFF)
set(FERALIN_TRANSPORT "AUTO" CACHE STRING "HTTP katmanı: AUTO, WINHTTP, CURL veya NONE")
set_property(CACHE FERALIN_TRANSPORT PROPERTY STRINGS AUTO WINHTTP CURL NONE)

if(FERALIN_TRANSPORT STREQUAL "AUTO")
  if(WIN32)
    set(FERALIN_TRANSPORT_RESOLVED "WINHTTP")
  else()
    set(FERALIN_TRANSPORT_RESOLVED "CURL")
  endif()
else()
  set(FERALIN_TRANSPORT_RESOLVED "${FERALIN_TRANSPORT}")
endif()

if(FERALIN_TRANSPORT_RESOLVED STREQUAL "WINHTTP")
  set(FERALIN_TRANSPORT_SOURCE src/transport_winhttp.cpp)
elseif(FERALIN_TRANSPORT_RESOLVED STREQUAL "CURL")
  set(FERALIN_TRANSPORT_SOURCE src/transport_curl.cpp)
elseif(FERALIN_TRANSPORT_RESOLVED STREQUAL "NONE")
  set(FERALIN_TRANSPORT_SOURCE src/transport_none.cpp)
else()
  message(FATAL_ERROR "FERALIN_TRANSPORT geçersiz: ${FERALIN_TRANSPORT}")
endif()

find_package(Threads REQUIRED)

add_library(feralin src/client.cpp src/c_api.cpp ${FERALIN_TRANSPORT_SOURCE})
add_library(feralin::feralin ALIAS feralin)
target_compile_features(feralin PUBLIC cxx_std_17)
set_target_properties(feralin PROPERTIES
  CXX_EXTENSIONS OFF
  VERSION ${PROJECT_VERSION}
  SOVERSION ${PROJECT_VERSION_MAJOR}
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)
target_include_directories(feralin PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)
target_compile_definitions(feralin PRIVATE FERALIN_BUILDING)
if(BUILD_SHARED_LIBS)
  target_compile_definitions(feralin PUBLIC FERALIN_SHARED)
endif()
target_link_libraries(feralin PRIVATE Threads::Threads)

if(FERALIN_TRANSPORT_RESOLVED STREQUAL "WINHTTP")
  target_link_libraries(feralin PRIVATE winhttp)
elseif(FERALIN_TRANSPORT_RESOLVED STREQUAL "CURL")
  find_package(CURL REQUIRED)
  target_link_libraries(feralin PRIVATE CURL::libcurl)
endif()

# Türkçe hata metinleri UTF-8 kaynak: MSVC başlığı tüketen kodda da aynı bayrağı ister.
target_compile_options(feralin PUBLIC $<$<CXX_COMPILER_ID:MSVC>:/utf-8>)
target_compile_options(feralin PRIVATE
  $<$<OR:$<CXX_COMPILER_ID:GNU>,$<CXX_COMPILER_ID:Clang>,$<CXX_COMPILER_ID:AppleClang>>:-Wall -Wextra -Wshadow -Wconversion -Wsign-conversion>
  $<$<CXX_COMPILER_ID:MSVC>:/W4>)
if(FERALIN_WERROR)
  target_compile_options(feralin PRIVATE
    $<$<OR:$<CXX_COMPILER_ID:GNU>,$<CXX_COMPILER_ID:Clang>,$<CXX_COMPILER_ID:AppleClang>>:-Werror>
    $<$<CXX_COMPILER_ID:MSVC>:/WX>)
endif()

install(TARGETS feralin
  EXPORT feralinTargets
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(DIRECTORY include/ DESTINATION ${CMAKE_INSTALL_INCLUDEDIR})
install(FILES README.md DESTINATION ${CMAKE_INSTALL_DOCDIR})
install(EXPORT feralinTargets NAMESPACE feralin:: DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/feralin)

configure_package_config_file(
  cmake/feralinConfig.cmake.in
  "${CMAKE_CURRENT_BINARY_DIR}/feralinConfig.cmake"
  INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/feralin)
write_basic_package_version_file(
  "${CMAKE_CURRENT_BINARY_DIR}/feralinConfigVersion.cmake"
  VERSION ${PROJECT_VERSION}
  COMPATIBILITY SameMajorVersion)
install(FILES
  "${CMAKE_CURRENT_BINARY_DIR}/feralinConfig.cmake"
  "${CMAKE_CURRENT_BINARY_DIR}/feralinConfigVersion.cmake"
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/feralin)

if(FERALIN_BUILD_TESTS AND BUILD_TESTING)
  add_subdirectory(tests)
endif()
