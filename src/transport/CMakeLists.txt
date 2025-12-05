list(
  APPEND
  TRANSPORT_SRCS
  ${CMAKE_CURRENT_LIST_DIR}/atensor_serializer.cpp
  ${CMAKE_CURRENT_LIST_DIR}/brpc_transport.cpp
  ${CMAKE_CURRENT_LIST_DIR}/http_transporter.cpp
  ${CMAKE_CURRENT_LIST_DIR}/rdma_transporter.cpp
)

add_library(astate_transport STATIC ${TRANSPORT_SRCS})

set_target_properties(astate_transport PROPERTIES
  POSITION_INDEPENDENT_CODE ON
)

target_link_libraries(astate_transport PUBLIC
  ${ASTATE_COMMON_DEPS}
  astate_common
  astate_protocol
)

if(USE_ASTATE_RDMA_IMPL)
  target_link_libraries(astate_transport PUBLIC
    astate_utrans
  )
else()
  target_link_libraries(astate_transport PUBLIC
    utrans
  )
endif()

target_include_directories(astate_transport
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
        $<INSTALL_INTERFACE:include/astate_transport>
)

install(DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/
    DESTINATION include/astate_transport
    FILES_MATCHING
        PATTERN "*.h"  PATTERN "*.hpp" PATTERN "*.hh"
)