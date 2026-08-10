# Injected via -DCMAKE_PROJECT_INCLUDE=<this file>, processed right after
# flang/CMakeLists.txt's project() call — before it reaches line ~497's
# include(FlangCommon).
#
# flang/cmake/modules/FlangCommon.cmake calls cmake_push_check_state() /
# cmake_pop_check_state() (in its quadmath.h detection) but only
# include()s CheckCSourceCompiles and CheckIncludeFile itself — not the
# CMakePushCheckState module that actually defines those commands. In an
# in-tree LLVM super-build this goes unnoticed because some other
# processed file happens to include it first (CMake module state is
# global per configure run); building flang standalone/out-of-tree, as
# every recipe in this project does, hits it directly:
#
#   CMake Error at cmake/modules/FlangCommon.cmake:78 (cmake_push_check_state):
#     Unknown CMake command "cmake_push_check_state".
#
# Fixing it here (rather than patching the vendored source) keeps the
# workaround entirely on our side and self-documenting.
include(CMakePushCheckState)
