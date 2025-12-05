list(
  APPEND
  TRANSFER_SRCS
  ${CMAKE_CURRENT_LIST_DIR}/tensor_transfer_pull.cpp
)

add_library(astate_transfer STATIC ${TRANSFER_SRCS})

set_target_properties(astate_transfer PROPERTIES
  POSITION_INDEPENDENT_CODE ON
)

target_link_libraries(astate_transfer PUBLIC
  ${ASTATE_COMMON_DEPS}
  astate_common
  astate_protocol
  astate_discovery
)

if(USE_ASTATE_RDMA_IMPL)
  target_link_libraries(astate_transfer PUBLIC
    astate_utrans
  )
else()
  target_link_libraries(astate_transfer PUBLIC
    utrans
  )
endif()

target_include_directories(astate_transfer
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
        $<INSTALL_INTERFACE:include/astate_transfer>
)

install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/
    DESTINATION include/astate_transfer
    FILES_MATCHING
        PATTERN "*.h"  PATTERN "*.hpp" PATTERN "*.hh"
)
