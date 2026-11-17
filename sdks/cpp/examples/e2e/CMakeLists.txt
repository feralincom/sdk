# Temiz kurulum tüketicisi: scripts/sdk-e2e/targets/cpp.mjs bu dizini boş bir yere kopyalar ve kurulu paketle derler.
cmake_minimum_required(VERSION 3.16)
project(feralin_clean_install LANGUAGES C CXX)

find_package(feralin CONFIG REQUIRED)

add_executable(e2e_consumer e2e_consumer.cpp)
target_link_libraries(e2e_consumer PRIVATE feralin::feralin)

add_executable(e2e_consumer_c e2e_consumer_c.c)
set_target_properties(e2e_consumer_c PROPERTIES C_STANDARD 99 C_STANDARD_REQUIRED ON C_EXTENSIONS OFF LINKER_LANGUAGE CXX)
target_link_libraries(e2e_consumer_c PRIVATE feralin::feralin)

# MinGW çalışma zamanı DLL'i PATH'teki başka bir araç zincirinden yüklenmesin.
if(MINGW)
  target_link_options(e2e_consumer PRIVATE -static)
  target_link_options(e2e_consumer_c PRIVATE -static)
endif()
