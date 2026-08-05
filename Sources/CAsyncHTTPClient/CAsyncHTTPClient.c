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

#if defined(_WIN32)
#include <string.h>
#include <ctype.h>
// Windows does not provide strptime/strptime_l. Implement a tiny parser that
// supports the three date formats used for cookie parsing in this package:
// 1) "%a, %d %b %Y %H:%M:%S"
// 2) "%a, %d-%b-%y %H:%M:%S"
// 3) "%a %b %d %H:%M:%S %Y"

static int month_from_abbrev(const char *p) {
    // Return 0-11 for Jan..Dec, or -1 on failure.
    if (!p) return -1;
    switch (p[0]) {
        case 'J':
            if (p[1] == 'a' && p[2] == 'n') return 0;      // Jan
            if (p[1] == 'u' && p[2] == 'n') return 5;      // Jun
            if (p[1] == 'u' && p[2] == 'l') return 6;      // Jul
            break;
        case 'F':
            if (p[1] == 'e' && p[2] == 'b') return 1;      // Feb
            break;
        case 'M':
            if (p[1] == 'a' && p[2] == 'r') return 2;      // Mar
            if (p[1] == 'a' && p[2] == 'y') return 4;      // May
            break;
        case 'A':
            if (p[1] == 'p' && p[2] == 'r') return 3;      // Apr
            if (p[1] == 'u' && p[2] == 'g') return 7;      // Aug
            break;
        case 'S':
            if (p[1] == 'e' && p[2] == 'p') return 8;      // Sep
            break;
        case 'O':
            if (p[1] == 'c' && p[2] == 't') return 9;      // Oct
            break;
        case 'N':
            if (p[1] == 'o' && p[2] == 'v') return 10;     // Nov
            break;
        case 'D':
            if (p[1] == 'e' && p[2] == 'c') return 11;     // Dec
            break;
    }
    return -1;
}

static int is_wkday_abbrev(const char *p) {
    // Check for valid weekday abbreviation (Mon..Sun)
    // Expect exactly 3 ASCII letters.
    if (!p) return 0;
    char a = p[0], b = p[1], c = p[2];
    if (!isalpha((unsigned char)a) || !isalpha((unsigned char)b) || !isalpha((unsigned char)c)) return 0;
    // Accept common English abbreviations, case-sensitive as typically emitted.
    return (a=='M'&&b=='o'&&c=='n')||(a=='T'&&b=='u'&&c=='e')||(a=='W'&&b=='e'&&c=='d')||
           (a=='T'&&b=='h'&&c=='u')||(a=='F'&&b=='r'&&c=='i')||(a=='S'&&b=='a'&&c=='t')||
           (a=='S'&&b=='u'&&c=='n');
}

static int parse_1to2_digits(const char **pp) {
    const char *p = *pp;
    if (!isdigit((unsigned char)p[0])) return -1;
    int val = p[0]-'0';
    p++;
    if (isdigit((unsigned char)p[0])) {
        val = val*10 + (p[0]-'0');
        p++;
    }
    *pp = p;
    return val;
}

static int parse_fixed2(const char **pp) {
    const char *p = *pp;
    if (!isdigit((unsigned char)p[0]) || !isdigit((unsigned char)p[1])) return -1;
    int val = (p[0]-'0')*10 + (p[1]-'0');
    p += 2;
    *pp = p;
    return val;
}

static int parse_fixed4(const char **pp) {
    const char *p = *pp;
    for (int i = 0; i < 4; i++) {
        if (!isdigit((unsigned char)p[i])) return -1;
    }
    int val = (p[0]-'0')*1000 + (p[1]-'0')*100 + (p[2]-'0')*10 + (p[3]-'0');
    p += 4;
    *pp = p;
    return val;
}

static int expect_char(const char **pp, char c) {
    if (**pp != c) return 0;
    (*pp)++;
    return 1;
}

static int expect_space(const char **pp) {
    if (**pp != ' ') return 0;
    (*pp)++;
    return 1;
}

static int parse_time_hms(const char **pp, int *h, int *m, int *s) {
    int hh = parse_fixed2(pp); if (hh < 0) return 0;
    if (!expect_char(pp, ':')) return 0;
    int mm = parse_fixed2(pp); if (mm < 0) return 0;
    if (!expect_char(pp, ':')) return 0;
    int ss = parse_fixed2(pp); if (ss < 0) return 0;
    if (hh > 23 || mm > 59 || ss > 60) return 0; // allow leap second 60
    *h = hh; *m = mm; *s = ss;
    return 1;
}

static void init_tm_utc(struct tm *out) {
    memset(out, 0, sizeof(*out));
    out->tm_isdst = 0;
}

static bool parse_cookie_format1(const char *p, struct tm *out) {
    // "%a, %d %b %Y %H:%M:%S"
    if (!is_wkday_abbrev(p)) return false;
    p += 3;
    if (!expect_char(&p, ',')) return false;
    if (!expect_space(&p)) return false;
    int mday = parse_1to2_digits(&p); if (mday < 1 || mday > 31) return false;
    if (!expect_space(&p)) return false;
    int mon = month_from_abbrev(p); if (mon < 0) return false; p += 3;
    if (!expect_space(&p)) return false;
    int year = parse_fixed4(&p); if (year < 1601) return false;
    if (!expect_space(&p)) return false;
    int hh, mm, ss; if (!parse_time_hms(&p, &hh, &mm, &ss)) return false;
    if (*p != '\0') return false;
    init_tm_utc(out);
    out->tm_mday = mday;
    out->tm_mon = mon;
    out->tm_year = year - 1900;
    out->tm_hour = hh; out->tm_min = mm; out->tm_sec = ss;
    return true;
}

static bool parse_cookie_format2(const char *p, struct tm *out) {
    // "%a, %d-%b-%y %H:%M:%S"
    if (!is_wkday_abbrev(p)) return false;
    p += 3;
    if (!expect_char(&p, ',')) return false;
    if (!expect_space(&p)) return false;
    int mday = parse_1to2_digits(&p); if (mday < 1 || mday > 31) return false;
    if (!expect_char(&p, '-')) return false;
    int mon = month_from_abbrev(p); if (mon < 0) return false; p += 3;
    if (!expect_char(&p, '-')) return false;
    int y2 = parse_fixed2(&p); if (y2 < 0) return false;
    int year = (y2 >= 70) ? (1900 + y2) : (2000 + y2);
    if (!expect_space(&p)) return false;
    int hh, mm, ss; if (!parse_time_hms(&p, &hh, &mm, &ss)) return false;
    if (*p != '\0') return false;
    init_tm_utc(out);
    out->tm_mday = mday;
    out->tm_mon = mon;
    out->tm_year = year - 1900;
    out->tm_hour = hh; out->tm_min = mm; out->tm_sec = ss;
    return true;
}

static bool parse_cookie_format3(const char *p, struct tm *out) {
    // "%a %b %d %H:%M:%S %Y"
    if (!is_wkday_abbrev(p)) return false;
    p += 3;
    if (!expect_space(&p)) return false;
    int mon = month_from_abbrev(p); if (mon < 0) return false; p += 3;
    if (!expect_space(&p)) return false;
    int mday = parse_1to2_digits(&p); if (mday < 1 || mday > 31) return false;
    if (!expect_space(&p)) return false;
    int hh, mm, ss; if (!parse_time_hms(&p, &hh, &mm, &ss)) return false;
    if (!expect_space(&p)) return false;
    int year = parse_fixed4(&p); if (year < 1601) return false;
    if (*p != '\0') return false;
    init_tm_utc(out);
    out->tm_mday = mday;
    out->tm_mon = mon;
    out->tm_year = year - 1900;
    out->tm_hour = hh; out->tm_min = mm; out->tm_sec = ss;
    return true;
}

static bool parse_cookie_timestamp_windows(const char *string, const char *format, struct tm *result) {
    (void)format; // format ignored: we try the three known patterns regardless.
    return parse_cookie_format1(string, result) ||
           parse_cookie_format2(string, result) ||
           parse_cookie_format3(string, result);
}

bool swiftahc_cshims_strptime(const char * string, const char * format, struct tm * result) {
    return parse_cookie_timestamp_windows(string, format, result);
}

bool swiftahc_cshims_strptime_l(const char * string, const char * format, struct tm * result, void * locale) {
    (void)locale; // locale is ignored on Windows; we always use POSIX month/weekday names.
    return parse_cookie_timestamp_windows(string, format, result);
}
#endif // _WIN32

#if !defined(_WIN32)
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
#endif // _WIN32
