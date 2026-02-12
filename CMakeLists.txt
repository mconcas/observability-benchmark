cmake_minimum_required(VERSION 3.10)
project(FluentBitStressBench VERSION 1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Compiler flags for optimization and warnings
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -O3 -march=native")

# Add the executable
add_executable(syslog_injector syslog_injector.cpp)

# Link pthread library (required for std::thread)
target_link_libraries(syslog_injector pthread)

# Installation
install(TARGETS syslog_injector DESTINATION bin)
install(FILES injector_config.conf DESTINATION etc)
install(DIRECTORY profiles/ DESTINATION etc/profiles)
