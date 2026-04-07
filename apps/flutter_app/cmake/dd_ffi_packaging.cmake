find_program(DD_FFI_CARGO_EXECUTABLE cargo)

if(NOT DD_FFI_CARGO_EXECUTABLE)
  message(FATAL_ERROR "cargo was not found in PATH and is required to package dd-ffi")
endif()

get_filename_component(
  DD_FFI_WORKSPACE_ROOT
  "${CMAKE_CURRENT_LIST_DIR}/../../.."
  ABSOLUTE
)

set(
  DD_FFI_BUILD_SCRIPT
  "${CMAKE_CURRENT_LIST_DIR}/build_and_copy_dd_ffi.cmake"
)

if(WIN32)
  set(DD_FFI_LIBRARY_NAME "dd_ffi.dll")
elseif(APPLE)
  set(DD_FFI_LIBRARY_NAME "libdd_ffi.dylib")
else()
  set(DD_FFI_LIBRARY_NAME "libdd_ffi.so")
endif()

function(dd_ffi_attach_runtime_copy target output_dir)
  add_custom_command(TARGET ${target} POST_BUILD
    COMMAND "${CMAKE_COMMAND}"
      -DWORKSPACE_ROOT=${DD_FFI_WORKSPACE_ROOT}
      -DCARGO_EXECUTABLE=${DD_FFI_CARGO_EXECUTABLE}
      -DPROFILE=$<IF:$<CONFIG:Debug>,debug,release>
      -DLIB_NAME=${DD_FFI_LIBRARY_NAME}
      -DOUTPUT_DIR=${output_dir}
      -P "${DD_FFI_BUILD_SCRIPT}"
    VERBATIM
    COMMENT "Building and staging dd-ffi for ${target}"
  )
endfunction()
