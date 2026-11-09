cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "camera_capture.cpp"
  "routing_applications.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
set_property(TARGET ${BINARY_NAME} PROPERTY CXX_STANDARD 20)
# The tray, dialog and notification text includes Russian literals.
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib" "iphlpapi.lib" "ws2_32.lib" "advapi32.lib" "windowsapp.lib" "windowscodecs.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Explicit native fixture; never launched or packaged with the application.
add_executable(elarni_routing_checks EXCLUDE_FROM_ALL
  "../checks/routing_applications_checks.cpp"
  "utils.cpp")
apply_standard_settings(elarni_routing_checks)
set_property(TARGET elarni_routing_checks PROPERTY CXX_STANDARD 20)
set_property(TARGET elarni_routing_checks PROPERTY
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/checks")
target_compile_definitions(elarni_routing_checks PRIVATE "NOMINMAX")
target_link_libraries(elarni_routing_checks PRIVATE flutter_wrapper_app
  "advapi32.lib" "windowsapp.lib" "windowscodecs.lib" "shell32.lib")
add_custom_command(TARGET elarni_routing_checks POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different "${FLUTTER_LIBRARY}"
    "$<TARGET_FILE_DIR:elarni_routing_checks>"
  VERBATIM)
