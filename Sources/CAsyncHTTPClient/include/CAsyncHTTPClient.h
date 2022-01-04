//===----------------------------------------------------------------------===//
//
// This source file is part of the AsyncHTTPClient open source project
//
// Copyright (c) 2018-2021 Apple Inc. and the AsyncHTTPClient project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of AsyncHTTPClient project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#ifndef CASYNC_HTTP_CLIENT_H
#define CASYNC_HTTP_CLIENT_H

#include <stdbool.h>
#include <time.h>

bool swiftahc_cshims_strptime(
    const char * _Nonnull input,
    const char * _Nonnull format,
    struct tm * _Nonnull result
);

bool swiftahc_cshims_strptime_l(
    const char * _Nonnull input,
    const char * _Nonnull format,
    struct tm * _Nonnull result,
    void * _Nullable locale
);

#endif // CASYNC_HTTP_CLIENT_H
