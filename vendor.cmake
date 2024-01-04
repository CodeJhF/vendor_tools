include_guard(GLOBAL)

if (EMSCRIPTEN)
    set(ARCH wasm)
elseif (ANDROID OR IOS)
    if (CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
        if (SDK_NAME STREQUAL iphonesimulator)
            set(ARCH arm64-simulator)
        else ()
            set(ARCH arm64)
        endif ()
    elseif (CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
        set(ARCH x64)
    else ()
        set(ARCH arm)
    endif ()
else ()
    if (MSVC)
        string(TOLOWER ${MSVC_C_ARCHITECTURE_ID} ARCH)
    elseif (CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64" OR $CMAKE_SYSTEM_PROCESSOR STREQUAL "amd64")
        set(ARCH x64)
    elseif (CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64" OR CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
        set(ARCH arm64)
    else ()
        set(ARCH x86)
    endif ()
endif ()

if (EMSCRIPTEN)
    set(WEB TRUE)
    set(PLATFORM web)
elseif (ANDROID)
    set(PLATFORM android)
elseif (IOS)
    set(PLATFORM ios)
elseif (APPLE)
    set(MACOS TRUE)
    set(PLATFORM mac)
elseif (WIN32)
    set(PLATFORM win)
elseif (CMAKE_HOST_SYSTEM_NAME MATCHES "Linux")
    set(LINUX TRUE)
    set(PLATFORM linux)
endif ()

if (CMAKE_ANDROID_NDK)
    message("Using Android NDK: ${CMAKE_ANDROID_NDK}")
    set(ENV{CMAKE_ANDROID_NDK} ${CMAKE_ANDROID_NDK})
endif ()

# Sets the default build type to release.
if (NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE "Release")
endif ()

if (WIN32 AND CMAKE_BUILD_TYPE STREQUAL "Debug")
    set(VENDOR_DEBUG ON)
endif ()

if (VENDOR_DEBUG)
    set(LIBRARY_ENTRY debug/${PLATFORM}/${ARCH})
    set(INCLUDE_ENTRY debug/${PLATFORM}/include)
    set(VENDOR_DEBUG_FLAG -d)
else ()
    set(LIBRARY_ENTRY ${PLATFORM}/${ARCH})
    set(INCLUDE_ENTRY ${PLATFORM}/include)
endif ()

set(VENDOR_TOOLS_DIR ${CMAKE_CURRENT_LIST_DIR})

# merge_libraries_into(target [staticLibraries...])
function(merge_libraries_into target)
    if (ARGC GREATER 2)
        list(JOIN ARGN "\" \"" STATIC_LIBRARIES)
    else ()
        list(APPEND STATIC_LIBRARIES ${ARGN})
    endif ()
    separate_arguments(STATIC_LIBRARIES_LIST NATIVE_COMMAND "\"${STATIC_LIBRARIES}\"")
    add_custom_command(TARGET ${target} POST_BUILD
            COMMAND node ${VENDOR_TOOLS_DIR}/lib-merge -p ${PLATFORM} -a ${ARCH} -v
            $<TARGET_FILE:${target}> ${STATIC_LIBRARIES_LIST} -o $<TARGET_FILE:${target}>
            VERBATIM USES_TERMINAL)
endfunction()

# add_vendor_target(targetName [STATIC_VENDORS] <vendorNames...> [SHARED_VENDORS] <vendorNames...> [CONFIG_DIR] <configDir>)
function(add_vendor_target targetName)
    set(IS_SHARED FALSE)
    set(IS_CONFIG_DIR FALSE)
    set(CONFIG_DIR ${CMAKE_CURRENT_LIST_DIR})
    foreach (arg ${ARGN})
        if (arg STREQUAL "STATIC_VENDORS")
            set(IS_SHARED FALSE)
            continue()
        endif ()
        if (arg STREQUAL "SHARED_VENDORS")
            set(IS_SHARED TRUE)
            continue()
        endif ()
        if (arg STREQUAL "CONFIG_DIR")
            set(IS_CONFIG_DIR TRUE)
            continue()
        endif ()
        if (IS_CONFIG_DIR)
            set(CONFIG_DIR ${arg})
            set(IS_CONFIG_DIR FALSE)
        elseif (IS_SHARED)
            list(APPEND sharedVendors ${arg})
        else ()
            list(APPEND staticVendors ${arg})
        endif ()
    endforeach ()

    if (NOT sharedVendors AND NOT staticVendors)
        return()
    endif ()

    set(VENDOR_STATIC_LIBRARIES)
    set(VENDOR_SHARED_LIBRARIES)
    set(VENDOR_OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/CMakeFiles/${targetName}.dir)

    if (staticVendors)
        set(VENDOR_OUTPUT_LIB "${VENDOR_OUTPUT_DIR}/${ARCH}/lib${targetName}${CMAKE_STATIC_LIBRARY_SUFFIX}")
        list(APPEND VENDOR_STATIC_LIBRARIES ${VENDOR_OUTPUT_LIB})
    endif ()

    foreach (sharedVendor ${sharedVendors})
        file(GLOB SHARED_LIBS third_party/out/${sharedVendor}/${LIBRARY_ENTRY}/*${CMAKE_SHARED_LIBRARY_SUFFIX})
        if (NOT SHARED_LIBS)
            # Build shared libraries immediately if they don't exist to gather output files initially.
            execute_process(COMMAND node ${VENDOR_TOOLS_DIR}/vendor-build ${sharedVendor} -p ${PLATFORM} -a ${ARCH} -v ${VENDOR_DEBUG_FLAG}
                    WORKING_DIRECTORY ${CONFIG_DIR})
        endif ()
        file(GLOB SHARED_LIBS third_party/out/${sharedVendor}/${LIBRARY_ENTRY}/*${CMAKE_SHARED_LIBRARY_SUFFIX})
        list(APPEND VENDOR_SHARED_LIBRARIES ${SHARED_LIBS})
    endforeach ()

    if (CMAKE_ANDROID_NDK)
        set(ENV_CMD ${CMAKE_COMMAND} -E env CMAKE_ANDROID_NDK=${CMAKE_ANDROID_NDK})
    endif ()
    set(VENDOR_CMD ${ENV_CMD} node ${VENDOR_TOOLS_DIR}/vendor-build -p ${PLATFORM} -a ${ARCH} -v ${VENDOR_DEBUG_FLAG} -o ${VENDOR_OUTPUT_DIR})

    add_custom_target(${targetName} COMMAND ${VENDOR_CMD} ${staticVendors} ${sharedVendors} WORKING_DIRECTORY ${CONFIG_DIR}
            VERBATIM USES_TERMINAL BYPRODUCTS ${VENDOR_STATIC_LIBRARIES} ${VENDOR_SHARED_LIBRARIES} ${VENDOR_OUTPUT_DIR}/.${ARCH}.md5)

    # set the target properties:
    if (VENDOR_STATIC_LIBRARIES)
        string(REPLACE ";" " " VENDOR_STATIC_LIBS "${VENDOR_STATIC_LIBRARIES}")
        set_target_properties(${targetName} PROPERTIES STATIC_LIBRARIES ${VENDOR_STATIC_LIBS})
    endif ()
    if (VENDOR_SHARED_LIBRARIES)
        string(REPLACE ";" " " VENDOR_SHARED_LIBS "${VENDOR_SHARED_LIBRARIES}")
        set_target_properties(${targetName} PROPERTIES SHARED_LIBRARIES ${VENDOR_SHARED_LIBS})
    endif ()
endfunction()


# find_vendor_libraries(target [STATIC] <STATIC_LIBRARIES_VAR> [SHARED] <SHARED_LIBRARIES_VAR>)
function(find_vendor_libraries target)
    set(STATIC_LIBRARIES_VAR)
    set(SHARED_LIBRARIES_VAR)
    set(IS_STATIC FALSE)
    set(IS_SHARED FALSE)
    foreach (arg ${ARGN})
        if (arg STREQUAL "STATIC")
            set(IS_STATIC TRUE)
            continue()
        endif ()
        if (arg STREQUAL "SHARED")
            set(IS_SHARED TRUE)
            continue()
        endif ()
        if (IS_STATIC)
            set(STATIC_LIBRARIES_VAR ${arg})
            set(IS_STATIC FALSE)
        elseif (IS_SHARED)
            set(SHARED_LIBRARIES_VAR ${arg})
            set(IS_SHARED FALSE)
        endif ()
    endforeach ()

    if (NOT STATIC_LIBRARIES_VAR AND NOT SHARED_LIBRARIES_VAR)
        return()
    endif ()

    get_target_property(VENDOR_STATIC_LIBS ${target} STATIC_LIBRARIES)
    string(REPLACE " " ";" VENDOR_STATIC_LIBRARIES "${VENDOR_STATIC_LIBS}")
    get_target_property(VENDOR_SHARED_LIBS ${target} SHARED_LIBRARIES)
    string(REPLACE " " ";" VENDOR_SHARED_LIBRARIES "${VENDOR_SHARED_LIBS}")
    if (STATIC_LIBRARIES_VAR)
        if (VENDOR_STATIC_LIBRARIES)
            set(${STATIC_LIBRARIES_VAR} ${VENDOR_STATIC_LIBRARIES} PARENT_SCOPE)
        else ()
            set(${STATIC_LIBRARIES_VAR} PARENT_SCOPE)
        endif ()
    endif ()
    if (SHARED_LIBRARIES_VAR)
        if (VENDOR_SHARED_LIBRARIES)
            set(${SHARED_LIBRARIES_VAR} ${VENDOR_SHARED_LIBRARIES} PARENT_SCOPE)
        else ()
            set(${SHARED_LIBRARIES_VAR} PARENT_SCOPE)
        endif ()
    endif ()
endfunction()

# Synchronizes the third-party dependencies of current platform.
if (WIN32)
    execute_process(COMMAND cmd /C depsync ${PLATFORM} WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR} ENCODING NONE)
else ()
    execute_process(COMMAND depsync ${PLATFORM} WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
endif ()
