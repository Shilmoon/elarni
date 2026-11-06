# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "elarni")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.elarni.Elarni")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(INDICATOR REQUIRED IMPORTED_TARGET ayatana-appindicator3-0.1)
pkg_check_modules(GSTREAMER REQUIRED IMPORTED_TARGET gstreamer-app-1.0)
pkg_check_modules(EPOXY REQUIRED IMPORTED_TARGET epoxy)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|amd64)$")
  message(FATAL_ERROR "Elarni Linux currently targets x86-64.")
endif()
find_program(CARGO_EXECUTABLE cargo REQUIRED)
find_program(GO_EXECUTABLE go REQUIRED)
get_filename_component(ELARNI_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
set(ELARNI_NATIVE "${CMAKE_CURRENT_BINARY_DIR}/native")
set(ELARNI_DOMAIN "${ELARNI_NATIVE}/rust/release/libelarni_domain.so")
set(ELARNI_CORE "${ELARNI_NATIVE}/elarni-core")
set(ELARNI_CLI "${ELARNI_NATIVE}/elarni-cli")
# The CLI uses the Dart of the Flutter SDK building this app, whose path only the flutter directory sets.
get_directory_property(FLUTTER_ROOT DIRECTORY "${FLUTTER_MANAGED_DIR}" DEFINITION FLUTTER_ROOT)
find_program(DART_EXECUTABLE dart HINTS "${FLUTTER_ROOT}/bin" "${ELARNI_ROOT}/.toolchains/flutter/bin" REQUIRED)
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
    --target-dir "${ELARNI_NATIVE}/rust"
  COMMAND ${CMAKE_COMMAND} -E env CGO_ENABLED=0
    "${GO_EXECUTABLE}" build -trimpath ${ELARNI_GO_TAGS} -o "${ELARNI_CORE}"
    ./Vendor/libXray/cmd/elarni-core
  COMMAND "${DART_EXECUTABLE}" compile exe ${ELARNI_CLI_DEFINES} bin/elarni.dart -o "${ELARNI_CLI}"
  WORKING_DIRECTORY "${ELARNI_ROOT}"
  BYPRODUCTS "${ELARNI_DOMAIN}" "${ELARNI_CORE}" "${ELARNI_CLI}"
  VERBATIM
)
add_dependencies(${BINARY_NAME} elarni_native)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)
install(PROGRAMS "${ELARNI_CORE}" DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(PROGRAMS "${ELARNI_CLI}" DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/elarni.png" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)
install(FILES "${ELARNI_DOMAIN}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
install(FILES "${ELARNI_ROOT}/LICENSE" "${ELARNI_ROOT}/NOTICE"
  "${ELARNI_ROOT}/THIRD_PARTY_NOTICES"
  "${ELARNI_ROOT}/windows/GOZXING_LICENSE.txt"
  "${ELARNI_ROOT}/windows/XERRORS_LICENSE.txt"
  DESTINATION "${CMAKE_INSTALL_PREFIX}" COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
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
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
