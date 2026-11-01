# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(elarni LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "elarni")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# The first Windows target is x64. Native builds remain incremental in Cargo/Go.
if(NOT CMAKE_GENERATOR_PLATFORM STREQUAL "x64")
  message(FATAL_ERROR "Elarni currently supports Windows x64 builds only.")
endif()
find_program(CARGO_EXECUTABLE cargo)
find_program(GO_EXECUTABLE go)
if(NOT CARGO_EXECUTABLE OR NOT GO_EXECUTABLE)
  message(FATAL_ERROR "Install Rust and Go and make cargo and go available on PATH.")
endif()
get_filename_component(ELARNI_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(ELARNI_NATIVE "${CMAKE_CURRENT_BINARY_DIR}/native")
set(ELARNI_DOMAIN "${ELARNI_NATIVE}/rust/x86_64-pc-windows-msvc/release/elarni_domain.dll")
set(ELARNI_CORE "${ELARNI_NATIVE}/elarni-core.exe")
set(ELARNI_CLI "${ELARNI_NATIVE}/elarni-cli.exe")
# The CLI uses the Dart of the Flutter SDK building this app, whose path only the flutter directory sets.
get_directory_property(FLUTTER_ROOT DIRECTORY "${FLUTTER_MANAGED_DIR}" DEFINITION FLUTTER_ROOT)
find_program(DART_EXECUTABLE NAMES dart.bat dart HINTS "${FLUTTER_ROOT}/bin" REQUIRED)
# The elevated helper loads only these DLLs; update wintunSHA256 in
# Vendor/libXray/cmd/elarni-core/wintun_windows.go with this archive.
set(WINTUN_ARCHIVE "${ELARNI_ROOT}/.build/windows-dependencies/wintun-0.14.1.zip")
file(MAKE_DIRECTORY "${ELARNI_ROOT}/.build/windows-dependencies" "${ELARNI_NATIVE}")
file(DOWNLOAD "https://www.wintun.net/builds/wintun-0.14.1.zip" "${WINTUN_ARCHIVE}"
  EXPECTED_HASH SHA256=07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51
  TLS_VERIFY ON)
execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xf "${WINTUN_ARCHIVE}"
  WORKING_DIRECTORY "${ELARNI_NATIVE}" RESULT_VARIABLE WINTUN_EXTRACT)
if(NOT WINTUN_EXTRACT EQUAL 0)
  message(FATAL_ERROR "The pinned Wintun archive could not be extracted.")
endif()
# A build made with --dart-define=ELARNI_RECORDING=true also compiles the core's connection
# recorder and the CLI's daemon with it. Flutter base64-encodes each define; this is that one's.
get_directory_property(FLUTTER_TOOL_ENVIRONMENT DIRECTORY "${FLUTTER_MANAGED_DIR}" DEFINITION FLUTTER_TOOL_ENVIRONMENT)
set(ELARNI_GO_TAGS "")
set(ELARNI_CLI_DEFINES "")
if(FLUTTER_TOOL_ENVIRONMENT MATCHES "DART_DEFINES=([^;]*,)?RUxBUk5JX1JFQ09SRElORz10cnVl(,|;|$)")
  set(ELARNI_GO_TAGS "-tags=elarni_recording")
  set(ELARNI_CLI_DEFINES "-DELARNI_RECORDING=true")
endif()
add_custom_target(elarni_native
  COMMAND ${CMAKE_COMMAND} -E make_directory "${ELARNI_NATIVE}"
  COMMAND "${CARGO_EXECUTABLE}" build -p elarni-domain --locked --release
    --target x86_64-pc-windows-msvc --target-dir "${ELARNI_NATIVE}/rust"
  COMMAND ${CMAKE_COMMAND} -E env GOOS=windows GOARCH=amd64 CGO_ENABLED=0
    "${GO_EXECUTABLE}" build -trimpath ${ELARNI_GO_TAGS} -o "${ELARNI_CORE}"
    ./Vendor/libXray/cmd/elarni-core
  COMMAND "${DART_EXECUTABLE}" compile exe ${ELARNI_CLI_DEFINES} bin/elarni.dart -o "${ELARNI_CLI}"
  WORKING_DIRECTORY "${ELARNI_ROOT}"
  BYPRODUCTS "${ELARNI_DOMAIN}" "${ELARNI_CORE}" "${ELARNI_CLI}"
  VERBATIM
)
add_dependencies(${BINARY_NAME} elarni_native)

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)
install(FILES "${ELARNI_DOMAIN}" "${ELARNI_CORE}" "${ELARNI_CLI}"
  "${ELARNI_NATIVE}/wintun/bin/amd64/wintun.dll"
  "${CMAKE_CURRENT_SOURCE_DIR}/GOZXING_LICENSE.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/XERRORS_LICENSE.txt"
  "${CMAKE_CURRENT_SOURCE_DIR}/WIREGUARD_WINDOWS_LICENSE.txt"
  "${ELARNI_ROOT}/LICENSE" "${ELARNI_ROOT}/NOTICE"
  "${ELARNI_ROOT}/THIRD_PARTY_NOTICES"
  "${ELARNI_ROOT}/docs/HEADLESS.md"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${ELARNI_NATIVE}/wintun/LICENSE.txt"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" RENAME WINTUN_LICENSE.txt COMPONENT Runtime)
# elarni.exe and elarni_domain.dll import the VC++ runtime, which a clean Windows
# lacks, so it ships next to the exe. Windows 10 and later include the UCRT.
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
include(InstallRequiredSystemLibraries)
list(FILTER CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS INCLUDE
  REGEX "/(msvcp140|vcruntime140|vcruntime140_1)\\.dll$")
list(LENGTH CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS ELARNI_VC_RUNTIME_COUNT)
if(NOT ELARNI_VC_RUNTIME_COUNT EQUAL 3)
  message(FATAL_ERROR "Install the MSVC C++ redistributable files with Visual Studio.")
endif()
install(FILES ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS}
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
