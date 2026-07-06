# Minimal build for `mpx-tuner` -- the stripped RTL-SDR -> MPX helper bundled
# with MPX Prime Meter. A subset of FM-SDR-Tuner (GPL-3.0); see README.md.
# Deps: librtlsdr + liquid-dsp (libliquid). Build a universal binary with:
#   cmake -S tuner -B tuner/build -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"
#   cmake --build tuner/build
cmake_minimum_required(VERSION 3.16)
project(mpx-tuner CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Locate librtlsdr + liquid-dsp. Prefer pkg-config IMPORTED_TARGETs (they
# carry the -L lib dir + include dirs); fall back to find_library full paths.
find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(PC_RTLSDR QUIET IMPORTED_TARGET librtlsdr)
  pkg_check_modules(PC_LIQUID QUIET IMPORTED_TARGET liquid)
endif()

if(TARGET PkgConfig::PC_RTLSDR)
  set(RTLSDR_LINK PkgConfig::PC_RTLSDR)
else()
  find_path(RTLSDR_INCLUDE_DIR NAMES rtl-sdr.h)
  find_library(RTLSDR_LIB NAMES rtlsdr)
  if(NOT RTLSDR_INCLUDE_DIR OR NOT RTLSDR_LIB)
    message(FATAL_ERROR "librtlsdr not found. Install librtlsdr (brew install librtlsdr).")
  endif()
  set(RTLSDR_LINK ${RTLSDR_LIB})
endif()

if(TARGET PkgConfig::PC_LIQUID)
  set(LIQUID_LINK PkgConfig::PC_LIQUID)
else()
  find_path(LIQUID_INCLUDE_DIR NAMES liquid/liquid.h)
  find_library(LIQUID_LIB NAMES liquid)
  if(NOT LIQUID_INCLUDE_DIR OR NOT LIQUID_LIB)
    message(FATAL_ERROR "liquid-dsp not found. Install liquid-dsp (brew install liquid-dsp).")
  endif()
  set(LIQUID_LINK ${LIQUID_LIB})
endif()

add_executable(mpx-tuner
  src/mpx_tuner_main.cpp
  src/rtl_sdr_device.cpp
  src/fm_demod.cpp
  src/wav_writer.cpp
  src/dsp/liquid_primitives.cpp
  src/dsp/multipath_eq.cpp
)
target_include_directories(mpx-tuner PRIVATE include ${RTLSDR_INCLUDE_DIR} ${LIQUID_INCLUDE_DIR})
target_compile_definitions(mpx-tuner PRIVATE FM_TUNER_HAS_RTLSDR)
target_link_libraries(mpx-tuner PRIVATE ${RTLSDR_LINK} ${LIQUID_LINK})
