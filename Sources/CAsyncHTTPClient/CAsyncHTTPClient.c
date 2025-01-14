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

#if __APPLE__
    #include <xlocale.h>
#elif __linux__
    #include <locale.h>
#endif

#include <stdbool.h>
#include <time.h>

bool swiftahc_cshims_strptime(const char * string, const char * format, struct tm * result) {
    const char * firstNonProcessed = strptime(string, format, result);
    if (firstNonProcessed) {
        return *firstNonProcessed == 0;
    }
    return false;
}

bool swiftahc_cshims_strptime_l(const char * string, const char * format, struct tm * result, void * locale) {
    // The pointer cast is fine as long we make sure it really points to a locale_t.
#if defined(__musl__) || defined(__ANDROID__)
    const char * firstNonProcessed = strptime(string, format, result);
#else
    const char * firstNonProcessed = strptime_l(string, format, result, (locale_t)locale);
#endif
    if (firstNonProcessed) {
        return *firstNonProcessed == 0;
    }
    return false;
}
