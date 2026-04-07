if(NOT DEFINED WORKSPACE_ROOT OR WORKSPACE_ROOT STREQUAL "")
  message(FATAL_ERROR "WORKSPACE_ROOT must be set")
endif()

if(NOT DEFINED OUTPUT_DIR OR OUTPUT_DIR STREQUAL "")
  message(FATAL_ERROR "OUTPUT_DIR must be set")
endif()

if(NOT DEFINED LIB_NAME OR LIB_NAME STREQUAL "")
  message(FATAL_ERROR "LIB_NAME must be set")
endif()

if(NOT DEFINED PROFILE OR PROFILE STREQUAL "")
  set(PROFILE "debug")
endif()

if(NOT DEFINED CARGO_EXECUTABLE OR CARGO_EXECUTABLE STREQUAL "")
  find_program(CARGO_EXECUTABLE cargo)
endif()

if(NOT CARGO_EXECUTABLE)
  message(FATAL_ERROR "cargo was not found in PATH")
endif()

set(CARGO_ARGS build -p dd-ffi)
if(NOT PROFILE STREQUAL "debug")
  list(APPEND CARGO_ARGS --release)
endif()

execute_process(
  COMMAND "${CARGO_EXECUTABLE}" ${CARGO_ARGS}
  WORKING_DIRECTORY "${WORKSPACE_ROOT}"
  RESULT_VARIABLE DD_FFI_BUILD_RESULT
)

if(NOT DD_FFI_BUILD_RESULT EQUAL 0)
  message(FATAL_ERROR "cargo build for dd-ffi failed with exit code ${DD_FFI_BUILD_RESULT}")
endif()

set(SOURCE_LIBRARY "${WORKSPACE_ROOT}/target/${PROFILE}/${LIB_NAME}")
if(NOT EXISTS "${SOURCE_LIBRARY}")
  message(FATAL_ERROR "expected dd-ffi library was not produced at ${SOURCE_LIBRARY}")
endif()

file(MAKE_DIRECTORY "${OUTPUT_DIR}")
file(COPY "${SOURCE_LIBRARY}" DESTINATION "${OUTPUT_DIR}")
