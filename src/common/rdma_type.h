// clang-format off
#pragma once

#if defined(ASTATE_RDMA_BACKEND_UTRANS)

#include <libutrans/utrans.h>
#include <libutrans/utrans_define.h>

#elif defined(ASTATE_RDMA_BACKEND_UCX)

#include "utrans/utrans.h"
#include "utrans/utrans_define.h"
#include "utrans/utrans_internal.h"

#else
#error "No RDMA backend selected: ASTATE_RDMA_BACKEND_UTRANS or ASTATE_RDMA_BACKEND_UCX must be defined"
#endif
// clang-format on