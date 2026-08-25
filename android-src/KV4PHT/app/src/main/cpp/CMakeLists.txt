cmake_minimum_required(VERSION 3.22.1)
project(kv4p_codec2 LANGUAGES C CXX)

include(FetchContent)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(LPCNET OFF CACHE BOOL "" FORCE)
set(UNITTEST OFF CACHE BOOL "" FORCE)
set(CODEC2_MODE_EN_DEFAULT 0 CACHE STRING "" FORCE)
set(CODEC2_MODE_1300_EN 1 CACHE STRING "" FORCE)
set(FREEDV_MODE_EN_DEFAULT 0 CACHE STRING "" FORCE)

FetchContent_Declare(freedv2400b
    GIT_REPOSITORY git@github.com:dkaukov/esp32-freedv2400b-modem.git
    GIT_TAG 6b441a51bcecf286c600a0edc9f7125ae36c6c2d
    GIT_SHALLOW FALSE)
FetchContent_GetProperties(freedv2400b)
if(NOT freedv2400b_POPULATED)
    FetchContent_Populate(freedv2400b)
endif()

set(C2 ${freedv2400b_SOURCE_DIR}/third_party/codec2/src)
set(C2GEN ${freedv2400b_SOURCE_DIR}/third_party/codec2_generated)
add_library(codec2 STATIC
    ${C2}/codec2.c ${C2}/codec2_fft.c ${C2}/dump.c ${C2}/fdmdv.c
    ${C2}/filter.c ${C2}/interp.c ${C2}/kiss_fft.c ${C2}/kiss_fftr.c
    ${C2}/lpc.c ${C2}/lsp.c ${C2}/mbest.c ${C2}/newamp1.c ${C2}/nlp.c
    ${C2}/pack.c ${C2}/phase.c ${C2}/postfilter.c ${C2}/quantise.c ${C2}/sine.c
    ${C2GEN}/codebook.c ${C2GEN}/codebookd.c ${C2GEN}/codebookge.c
    ${C2GEN}/codebookjmv.c ${C2GEN}/codebooknewamp1.c
    ${C2GEN}/codebooknewamp1_energy.c ${C2GEN}/codebooknewamp2.c
    ${C2GEN}/codebooknewamp2_energy.c)
target_compile_definitions(codec2 PRIVATE
    CODEC2_MODE_EN_DEFAULT=0 CODEC2_MODE_1300_EN=1)
target_include_directories(codec2 PUBLIC ${C2} ${C2GEN} ${C2GEN}/codec2)

add_library(kv4p-codec2 SHARED codec2_jni.cpp)
target_include_directories(kv4p-codec2 PRIVATE
    ${C2} ${C2GEN} ${C2GEN}/codec2)
target_link_libraries(kv4p-codec2 PRIVATE codec2 log)
