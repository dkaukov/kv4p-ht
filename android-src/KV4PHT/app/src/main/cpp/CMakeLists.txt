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

FetchContent_Declare(codec2_upstream
    GIT_REPOSITORY https://github.com/drowe67/codec2.git
    GIT_TAG 1.2.0
    GIT_SHALLOW TRUE)
FetchContent_GetProperties(codec2_upstream)
if(NOT codec2_upstream_POPULATED)
    FetchContent_Populate(codec2_upstream)
endif()

set(C2 ${codec2_upstream_SOURCE_DIR}/src)
set(C2GEN ${codec2_upstream_BINARY_DIR}/generated)
file(MAKE_DIRECTORY ${C2GEN}/codec2)

# Follow Codec2Talkie's cross-build pattern: build the codebook generator for
# the host, then compile only the required Codec2 sources with the Android NDK.
find_program(HOST_C_COMPILER NAMES cc clang gcc REQUIRED)
set(CODEBOOK_GENERATOR ${codec2_upstream_BINARY_DIR}/generate_codebook)
execute_process(
    COMMAND ${HOST_C_COMPILER} ${C2}/generate_codebook.c -o ${CODEBOOK_GENERATOR} -lm
    RESULT_VARIABLE CODEBOOK_COMPILER_RESULT)
if(NOT CODEBOOK_COMPILER_RESULT EQUAL 0)
    message(FATAL_ERROR "Unable to build Codec2 codebook generator")
endif()

function(generate_codec2_codebook output symbol)
    execute_process(
        COMMAND ${CODEBOOK_GENERATOR} ${symbol} ${ARGN}
        OUTPUT_FILE ${C2GEN}/${output}
        RESULT_VARIABLE CODEBOOK_RESULT)
    if(NOT CODEBOOK_RESULT EQUAL 0)
        message(FATAL_ERROR "Unable to generate Codec2 ${output}")
    endif()
endfunction()

set(CB ${C2}/codebook)
generate_codec2_codebook(codebook.c lsp_cb
    ${CB}/lsp1.txt ${CB}/lsp2.txt ${CB}/lsp3.txt ${CB}/lsp4.txt ${CB}/lsp5.txt
    ${CB}/lsp6.txt ${CB}/lsp7.txt ${CB}/lsp8.txt ${CB}/lsp9.txt ${CB}/lsp10.txt)
generate_codec2_codebook(codebookd.c lsp_cbd
    ${CB}/dlsp1.txt ${CB}/dlsp2.txt ${CB}/dlsp3.txt ${CB}/dlsp4.txt ${CB}/dlsp5.txt
    ${CB}/dlsp6.txt ${CB}/dlsp7.txt ${CB}/dlsp8.txt ${CB}/dlsp9.txt ${CB}/dlsp10.txt)
generate_codec2_codebook(codebookjmv.c lsp_cbjmv
    ${CB}/lspjmv1.txt ${CB}/lspjmv2.txt ${CB}/lspjmv3.txt)
generate_codec2_codebook(codebookge.c ge_cb ${CB}/gecb.txt)
generate_codec2_codebook(codebooknewamp1.c newamp1vq_cb
    ${CB}/train_120_1.txt ${CB}/train_120_2.txt)
generate_codec2_codebook(codebooknewamp1_energy.c newamp1_energy_cb
    ${CB}/newamp1_energy_q.txt)
generate_codec2_codebook(codebooknewamp2.c newamp2vq_cb ${CB}/codes_450.txt)
generate_codec2_codebook(codebooknewamp2_energy.c newamp2_energy_cb
    ${CB}/newamp2_energy_q.txt)

set(CODEC2_VERSION_MAJOR 1)
set(CODEC2_VERSION_MINOR 2)
set(CODEC2_VERSION_PATCH 0)
set(CODEC2_VERSION "1.2.0")
configure_file(${codec2_upstream_SOURCE_DIR}/cmake/version.h.in
    ${C2GEN}/codec2/version.h)

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
target_link_libraries(kv4p-codec2 PRIVATE codec2 log)
