/* Cycript - Remote Execution Server and Disassembler
 * Copyright (C) 2009  Jay Freeman (saurik)
*/

/* Modified BSD License {{{ */
/*
 *        Redistribution and use in source and binary
 * forms, with or without modification, are permitted
 * provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer in the documentation
 *    and/or other materials provided with the
 *    distribution.
 * 3. The name of the author may not be used to endorse
 *    or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING,
 * BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
 * TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/
/* }}} */

#include <substrate.h>
#include <minimal/sqlite3.h>

#include "Internal.hpp"

#include <dlfcn.h>
#include <iconv.h>

#include "cycript.hpp"

#include "sig/parse.hpp"
#include "sig/ffi_type.hpp"

#include "Pooling.hpp"

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFLogUtilities.h>
#include <JavaScriptCore/JSStringRefCF.h>
#endif

#include <sys/mman.h>

#include <iostream>
#include <ext/stdio_filebuf.h>
#include <set>
#include <map>
#include <iomanip>
#include <sstream>
#include <cmath>

#include "Parser.hpp"
#include "Cycript.tab.hh"

#undef _assert
#undef _trace

void CYThrow(const char *format, ...);

#define _assert(test, args...) do { \
    if (!(test)) \
        throw CYError(context, "*** _assert(%s):%s(%u):%s [errno=%d]", #test, __FILE__, __LINE__, __FUNCTION__, errno); \
} while (false)

#define _trace() do { \
    fprintf(stderr, "_trace():%u\n", __LINE__); \
} while (false)

#ifdef __OBJC__
#define CYCatch_ \
    catch (NSException *error) { \
        CYThrow(context, error, exception); \
        return NULL; \
    }
#else
#define CYCatch_
#endif

#define CYTry \
    try
#define CYCatch \
    catch (const CYError &error) { \
        *exception = error.value_; \
        return NULL; \
    } catch (...) { \
        *exception = CYCastJSValue(context, "catch(...)"); \
        return NULL; \
    }

#ifndef __APPLE__
#define class_getSuperclass GSObjCSuper
#define object_getClass GSObjCClass
#endif

char *sqlite3_column_pooled(apr_pool_t *pool, sqlite3_stmt *stmt, int n) {
    if (const unsigned char *value = sqlite3_column_text(stmt, n))
        return apr_pstrdup(pool, (const char *) value);
    else return NULL;
}

struct CYError {
    JSContextRef context_;
    JSValueRef value_;

    CYError(JSContextRef context, JSValueRef value) :
        context_(context),
        value_(value)
    {
    }

    CYError(JSContextRef context, const char *format, ...);
};

void CYThrow(JSContextRef context, JSValueRef value);

JSValueRef CYSendMessage(apr_pool_t *pool, JSContextRef context, id self, Class super, SEL _cmd, size_t count, const JSValueRef arguments[], bool initialize, JSValueRef *exception);

struct CYUTF8String {
    const char *data;
    size_t size;

    CYUTF8String(const char *data, size_t size) :
        data(data),
        size(size)
    {
    }

    bool operator ==(const char *value) const {
        size_t length(strlen(data));
        return length == size && memcmp(value, data, length) == 0;
    }
};

struct CYUTF16String {
    const uint16_t *data;
    size_t size;

    CYUTF16String(const uint16_t *data, size_t size) :
        data(data),
        size(size)
    {
    }
};

struct CYHooks {
    void *(*ExecuteStart)();
    void (*ExecuteEnd)(void *);
    JSValueRef (*RuntimeProperty)(JSContextRef, CYUTF8String);
    bool (*PoolFFI)(apr_pool_t *, JSContextRef, sig::Type *, ffi_type *, void *, JSValueRef);
    JSValueRef (*FromFFI)(JSContextRef, sig::Type *, ffi_type *, void *, bool, JSObjectRef);
} *hooks_;

/* JavaScript Properties {{{ */
JSValueRef CYGetProperty(JSContextRef context, JSObjectRef object, size_t index) {
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetPropertyAtIndex(context, object, index, &exception));
    CYThrow(context, exception);
    return value;
}

JSValueRef CYGetProperty(JSContextRef context, JSObjectRef object, JSStringRef name) {
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetProperty(context, object, name, &exception));
    CYThrow(context, exception);
    return value;
}

void CYSetProperty(JSContextRef context, JSObjectRef object, size_t index, JSValueRef value) {
    JSValueRef exception(NULL);
    JSObjectSetPropertyAtIndex(context, object, index, value, &exception);
    CYThrow(context, exception);
}

void CYSetProperty(JSContextRef context, JSObjectRef object, JSStringRef name, JSValueRef value, JSPropertyAttributes attributes = kJSPropertyAttributeNone) {
    JSValueRef exception(NULL);
    JSObjectSetProperty(context, object, name, value, attributes, &exception);
    CYThrow(context, exception);
}
/* }}} */
/* JavaScript Strings {{{ */
JSStringRef CYCopyJSString(const char *value) {
    return value == NULL ? NULL : JSStringCreateWithUTF8CString(value);
}

JSStringRef CYCopyJSString(JSStringRef value) {
    return value == NULL ? NULL : JSStringRetain(value);
}

JSStringRef CYCopyJSString(CYUTF8String value) {
    // XXX: this is very wrong
    return CYCopyJSString(value.data);
}

JSStringRef CYCopyJSString(JSContextRef context, JSValueRef value) {
    if (JSValueIsNull(context, value))
        return NULL;
    JSValueRef exception(NULL);
    JSStringRef string(JSValueToStringCopy(context, value, &exception));
    CYThrow(context, exception);
    return string;
}

class CYJSString {
  private:
    JSStringRef string_;

    void Clear_() {
        if (string_ != NULL)
            JSStringRelease(string_);
    }

  public:
    CYJSString(const CYJSString &rhs) :
        string_(CYCopyJSString(rhs.string_))
    {
    }

    template <typename Arg0_>
    CYJSString(Arg0_ arg0) :
        string_(CYCopyJSString(arg0))
    {
    }

    template <typename Arg0_, typename Arg1_>
    CYJSString(Arg0_ arg0, Arg1_ arg1) :
        string_(CYCopyJSString(arg0, arg1))
    {
    }

    CYJSString &operator =(const CYJSString &rhs) {
        Clear_();
        string_ = CYCopyJSString(rhs.string_);
        return *this;
    }

    ~CYJSString() {
        Clear_();
    }

    void Clear() {
        Clear_();
        string_ = NULL;
    }

    operator JSStringRef() const {
        return string_;
    }
};

static CYUTF16String CYCastUTF16String(JSStringRef value) {
    return CYUTF16String(JSStringGetCharactersPtr(value), JSStringGetLength(value));
}

static CYUTF8String CYPoolUTF8String(apr_pool_t *pool, JSContextRef context, JSStringRef value) {
    _assert(pool != NULL);

    CYUTF16String utf16(CYCastUTF16String(value));
    const char *in(reinterpret_cast<const char *>(utf16.data));

    iconv_t conversion(_syscall(iconv_open("UTF-8", "UCS-2-INTERNAL")));

    size_t size(JSStringGetMaximumUTF8CStringSize(value));
    char *out(new(pool) char[size]);
    CYUTF8String utf8(out, size);

    size = utf16.size * 2;
    _syscall(iconv(conversion, const_cast<char **>(&in), &size, &out, &utf8.size));

    *out = '\0';
    utf8.size = out - utf8.data;

    _syscall(iconv_close(conversion));

    return utf8;
}

static const char *CYPoolCString(apr_pool_t *pool, JSContextRef context, JSStringRef value) {
    CYUTF8String utf8(CYPoolUTF8String(pool, context, value));
    _assert(memchr(utf8.data, '\0', utf8.size) == NULL);
    return utf8.data;
}

static const char *CYPoolCString(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    return JSValueIsNull(context, value) ? NULL : CYPoolCString(pool, context, CYJSString(context, value));
}
/* }}} */
/* C Strings {{{ */
// XXX: this macro is unhygenic
#define CYCastCString_(string) ({ \
    char *utf8; \
    if (string == NULL) \
        utf8 = NULL; \
    else { \
        size_t size(JSStringGetMaximumUTF8CStringSize(string)); \
        utf8 = reinterpret_cast<char *>(alloca(size)); \
        JSStringGetUTF8CString(string, utf8, size); \
    } \
    utf8; \
})

// XXX: this macro is unhygenic
#define CYCastCString(context, value) ({ \
    char *utf8; \
    if (value == NULL) \
        utf8 = NULL; \
    else if (JSStringRef string = CYCopyJSString(context, value)) { \
        utf8 = CYCastCString_(string); \
        JSStringRelease(string); \
    } else \
        utf8 = NULL; \
    utf8; \
})

/* }}} */

/* Index Offsets {{{ */
size_t CYGetIndex(const CYUTF8String &value) {
    if (value.data[0] != '0') {
        char *end;
        size_t index(strtoul(value.data, &end, 10));
        if (value.data + value.size == end)
            return index;
    } else if (value.data[1] == '\0')
        return 0;
    return _not(size_t);
}

size_t CYGetIndex(apr_pool_t *pool, JSContextRef context, JSStringRef value) {
    return CYGetIndex(CYPoolUTF8String(pool, context, value));
}

bool CYGetOffset(const char *value, ssize_t &index) {
    if (value[0] != '0') {
        char *end;
        index = strtol(value, &end, 10);
        if (value + strlen(value) == end)
            return true;
    } else if (value[1] == '\0') {
        index = 0;
        return true;
    }

    return false;
}
/* }}} */

/* JavaScript *ify {{{ */
void CYStringify(std::ostringstream &str, const char *data, size_t size) {
    unsigned quot(0), apos(0);
    for (const char *value(data), *end(data + size); value != end; ++value)
        if (*value == '"')
            ++quot;
        else if (*value == '\'')
            ++apos;

    bool single(quot > apos);

    str << (single ? '\'' : '"');

    for (const char *value(data), *end(data + size); value != end; ++value)
        switch (*value) {
            case '\\': str << "\\\\"; break;
            case '\b': str << "\\b"; break;
            case '\f': str << "\\f"; break;
            case '\n': str << "\\n"; break;
            case '\r': str << "\\r"; break;
            case '\t': str << "\\t"; break;
            case '\v': str << "\\v"; break;

            case '"':
                if (!single)
                    str << "\\\"";
                else goto simple;
            break;

            case '\'':
                if (single)
                    str << "\\'";
                else goto simple;
            break;

            default:
                if (*value < 0x20 || *value >= 0x7f)
                    str << "\\x" << std::setbase(16) << std::setw(2) << std::setfill('0') << unsigned(*value);
                else simple:
                    str << *value;
        }

    str << (single ? '\'' : '"');
}

void CYNumerify(std::ostringstream &str, double value) {
    char string[32];
    // XXX: I want this to print 1e3 rather than 1000
    sprintf(string, "%.17g", value);
    str << string;
}

bool CYIsKey(CYUTF8String value) {
    const char *data(value.data);
    size_t size(value.size);

    if (size == 0)
        return false;

    if (DigitRange_[data[0]]) {
        size_t index(CYGetIndex(value));
        if (index == _not(size_t))
            return false;
    } else {
        if (!WordStartRange_[data[0]])
            return false;
        for (size_t i(1); i != size; ++i)
            if (!WordEndRange_[data[i]])
                return false;
    }

    return true;
}
/* }}} */

static JSGlobalContextRef Context_;
static JSObjectRef System_;

static JSClassRef Functor_;
static JSClassRef Pointer_;
static JSClassRef Runtime_;
static JSClassRef Struct_;

static JSObjectRef Array_;
static JSObjectRef Error_;
static JSObjectRef Function_;
static JSObjectRef String_;

static JSStringRef Result_;

static JSStringRef length_;
static JSStringRef message_;
static JSStringRef name_;
static JSStringRef prototype_;
static JSStringRef toCYON_;
static JSStringRef toJSON_;

static JSObjectRef Object_prototype_;
static JSObjectRef Function_prototype_;

static JSObjectRef Array_prototype_;
static JSObjectRef Array_pop_;
static JSObjectRef Array_push_;
static JSObjectRef Array_splice_;

sqlite3 *Bridge_;

void Finalize(JSObjectRef object) {
    delete reinterpret_cast<CYData *>(JSObjectGetPrivate(object));
}

struct CStringMapLess :
    std::binary_function<const char *, const char *, bool>
{
    _finline bool operator ()(const char *lhs, const char *rhs) const {
        return strcmp(lhs, rhs) < 0;
    }
};

void Structor_(apr_pool_t *pool, const char *name, const char *types, sig::Type *&type) {
    if (name == NULL)
        return;

    JSContextRef context(NULL);

    sqlite3_stmt *statement;

    _sqlcall(sqlite3_prepare(Bridge_,
        "select "
            "\"bridge\".\"mode\", "
            "\"bridge\".\"value\" "
        "from \"bridge\" "
        "where"
            " \"bridge\".\"mode\" in (3, 4) and"
            " \"bridge\".\"name\" = ?"
        " limit 1"
    , -1, &statement, NULL));

    _sqlcall(sqlite3_bind_text(statement, 1, name, -1, SQLITE_STATIC));

    int mode;
    const char *value;

    if (_sqlcall(sqlite3_step(statement)) == SQLITE_DONE) {
        mode = -1;
        value = NULL;
    } else {
        mode = sqlite3_column_int(statement, 0);
        value = sqlite3_column_pooled(pool, statement, 1);
    }

    _sqlcall(sqlite3_finalize(statement));

    switch (mode) {
        default:
            _assert(false);
        case -1:
            break;

        case 3: {
            sig::Parse(pool, &type->data.signature, value, &Structor_);
        } break;

        case 4: {
            sig::Signature signature;
            sig::Parse(pool, &signature, value, &Structor_);
            type = signature.elements[0].type;
        } break;
    }
}

JSClassRef Type_privateData::Class_;

struct Pointer :
    CYOwned
{
    Type_privateData *type_;

    Pointer(void *value, JSContextRef context, JSObjectRef owner, sig::Type *type) :
        CYOwned(value, context, owner),
        type_(new(pool_) Type_privateData(type))
    {
    }
};

struct Struct_privateData :
    CYOwned
{
    Type_privateData *type_;

    Struct_privateData(JSContextRef context, JSObjectRef owner) :
        CYOwned(NULL, context, owner)
    {
    }
};

typedef std::map<const char *, Type_privateData *, CStringMapLess> TypeMap;
static TypeMap Types_;

JSObjectRef CYMakeStruct(JSContextRef context, void *data, sig::Type *type, ffi_type *ffi, JSObjectRef owner) {
    Struct_privateData *internal(new Struct_privateData(context, owner));
    apr_pool_t *pool(internal->pool_);
    Type_privateData *typical(new(pool) Type_privateData(type, ffi));
    internal->type_ = typical;

    if (owner != NULL)
        internal->value_ = data;
    else {
        size_t size(typical->GetFFI()->size);
        void *copy(apr_palloc(internal->pool_, size));
        memcpy(copy, data, size);
        internal->value_ = copy;
    }

    return JSObjectMake(context, Struct_, internal);
}

struct Functor_privateData :
    CYValue
{
    sig::Signature signature_;
    ffi_cif cif_;

    Functor_privateData(const char *type, void (*value)()) :
        CYValue(reinterpret_cast<void *>(value))
    {
        sig::Parse(pool_, &signature_, type, &Structor_);
        sig::sig_ffi_cif(pool_, &sig::ObjectiveC, &signature_, &cif_);
    }

    void (*GetValue())() const {
        return reinterpret_cast<void (*)()>(value_);
}
};

struct Closure_privateData :
    Functor_privateData
{
    JSContextRef context_;
    JSObjectRef function_;

    Closure_privateData(JSContextRef context, JSObjectRef function, const char *type) :
        Functor_privateData(type, NULL),
        context_(context),
        function_(function)
    {
        JSValueProtect(context_, function_);
    }

    virtual ~Closure_privateData() {
        JSValueUnprotect(context_, function_);
    }
};

JSValueRef CYCastJSValue(JSContextRef context, bool value) {
    return JSValueMakeBoolean(context, value);
}

JSValueRef CYCastJSValue(JSContextRef context, double value) {
    return JSValueMakeNumber(context, value);
}

#define CYCastJSValue_(Type_) \
    JSValueRef CYCastJSValue(JSContextRef context, Type_ value) { \
        return JSValueMakeNumber(context, static_cast<double>(value)); \
    }

CYCastJSValue_(int)
CYCastJSValue_(unsigned int)
CYCastJSValue_(long int)
CYCastJSValue_(long unsigned int)
CYCastJSValue_(long long int)
CYCastJSValue_(long long unsigned int)

JSValueRef CYJSUndefined(JSContextRef context) {
    return JSValueMakeUndefined(context);
}

double CYCastDouble(const char *value, size_t size) {
    char *end;
    double number(strtod(value, &end));
    if (end != value + size)
        return NAN;
    return number;
}

double CYCastDouble(const char *value) {
    return CYCastDouble(value, strlen(value));
}

double CYCastDouble(JSContextRef context, JSValueRef value) {
    JSValueRef exception(NULL);
    double number(JSValueToNumber(context, value, &exception));
    CYThrow(context, exception);
    return number;
}

bool CYCastBool(JSContextRef context, JSValueRef value) {
    return JSValueToBoolean(context, value);
}

JSValueRef CYJSNull(JSContextRef context) {
    return JSValueMakeNull(context);
}

JSValueRef CYCastJSValue(JSContextRef context, JSStringRef value) {
    return value == NULL ? CYJSNull(context) : JSValueMakeString(context, value);
}

JSValueRef CYCastJSValue(JSContextRef context, const char *value) {
    return CYCastJSValue(context, CYJSString(value));
}

JSObjectRef CYCastJSObject(JSContextRef context, JSValueRef value) {
    JSValueRef exception(NULL);
    JSObjectRef object(JSValueToObject(context, value, &exception));
    CYThrow(context, exception);
    return object;
}

JSValueRef CYCallAsFunction(JSContextRef context, JSObjectRef function, JSObjectRef _this, size_t count, JSValueRef arguments[]) {
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectCallAsFunction(context, function, _this, count, arguments, &exception));
    CYThrow(context, exception);
    return value;
}

bool CYIsCallable(JSContextRef context, JSValueRef value) {
    return value != NULL && JSValueIsObject(context, value) && JSObjectIsFunction(context, (JSObjectRef) value);
}

const char *CYPoolCCYON(apr_pool_t *pool, JSContextRef context, JSObjectRef object);

static JSValueRef System_print(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count == 0)
        printf("\n");
    else
        printf("%s\n", CYCastCString(context, arguments[0]));
    return CYJSUndefined(context);
} CYCatch }

static size_t Nonce_(0);

static JSValueRef $cyq(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    char name[16];
    sprintf(name, "%s%zu", CYCastCString(context, arguments[0]), Nonce_++);
    return CYCastJSValue(context, name);
}

static JSValueRef Cycript_gc_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    JSGarbageCollect(context);
    return CYJSUndefined(context);
}

const char *CYPoolCCYON(apr_pool_t *pool, JSContextRef context, JSValueRef value, JSValueRef *exception) { CYTry {
    switch (JSType type = JSValueGetType(context, value)) {
        case kJSTypeUndefined:
            return "undefined";
        case kJSTypeNull:
            return "null";
        case kJSTypeBoolean:
            return CYCastBool(context, value) ? "true" : "false";

        case kJSTypeNumber: {
            std::ostringstream str;
            CYNumerify(str, CYCastDouble(context, value));
            std::string value(str.str());
            return apr_pstrmemdup(pool, value.c_str(), value.size());
        } break;

        case kJSTypeString: {
            std::ostringstream str;
            CYUTF8String string(CYPoolUTF8String(pool, context, CYJSString(context, value)));
            CYStringify(str, string.data, string.size);
            std::string value(str.str());
            return apr_pstrmemdup(pool, value.c_str(), value.size());
        } break;

        case kJSTypeObject:
            return CYPoolCCYON(pool, context, (JSObjectRef) value);
        default:
            throw CYError(context, "JSValueGetType() == 0x%x", type);
    }
} CYCatch }

const char *CYPoolCCYON(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    JSValueRef exception(NULL);
    const char *cyon(CYPoolCCYON(pool, context, value, &exception));
    CYThrow(context, exception);
    return cyon;
}

const char *CYPoolCCYON(apr_pool_t *pool, JSContextRef context, JSObjectRef object) {
    JSValueRef toCYON(CYGetProperty(context, object, toCYON_));
    if (CYIsCallable(context, toCYON)) {
        JSValueRef value(CYCallAsFunction(context, (JSObjectRef) toCYON, object, 0, NULL));
        return CYPoolCString(pool, context, value);
    }

    JSValueRef toJSON(CYGetProperty(context, object, toJSON_));
    if (CYIsCallable(context, toJSON)) {
        JSValueRef arguments[1] = {CYCastJSValue(context, CYJSString(""))};
        JSValueRef exception(NULL);
        const char *cyon(CYPoolCCYON(pool, context, CYCallAsFunction(context, (JSObjectRef) toJSON, object, 1, arguments), &exception));
        CYThrow(context, exception);
        return cyon;
    }

    std::ostringstream str;

    str << '{';

    // XXX: this is, sadly, going to leak
    JSPropertyNameArrayRef names(JSObjectCopyPropertyNames(context, object));

    bool comma(false);

    for (size_t index(0), count(JSPropertyNameArrayGetCount(names)); index != count; ++index) {
        JSStringRef name(JSPropertyNameArrayGetNameAtIndex(names, index));
        JSValueRef value(CYGetProperty(context, object, name));

        if (comma)
            str << ',';
        else
            comma = true;

        CYUTF8String string(CYPoolUTF8String(pool, context, name));
        if (CYIsKey(string))
            str << string.data;
        else
            CYStringify(str, string.data, string.size);

        str << ':' << CYPoolCCYON(pool, context, value);
    }

    str << '}';

    JSPropertyNameArrayRelease(names);

    std::string string(str.str());
    return apr_pstrmemdup(pool, string.c_str(), string.size());
}

static JSValueRef Array_callAsFunction_toCYON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    CYPool pool;
    std::ostringstream str;

    str << '[';

    JSValueRef length(CYGetProperty(context, _this, length_));
    bool comma(false);

    for (size_t index(0), count(CYCastDouble(context, length)); index != count; ++index) {
        JSValueRef value(CYGetProperty(context, _this, index));

        if (comma)
            str << ',';
        else
            comma = true;

        if (!JSValueIsUndefined(context, value))
            str << CYPoolCCYON(pool, context, value);
        else {
            str << ',';
            comma = false;
        }
    }

    str << ']';

    std::string value(str.str());
    return CYCastJSValue(context, CYJSString(CYUTF8String(value.c_str(), value.size())));
} CYCatch }

static JSObjectRef CYMakePointer(JSContextRef context, void *pointer, sig::Type *type, ffi_type *ffi, JSObjectRef owner) {
    Pointer *internal(new Pointer(pointer, context, owner, type));
    return JSObjectMake(context, Pointer_, internal);
}

static JSObjectRef CYMakeFunctor(JSContextRef context, void (*function)(), const char *type) {
    Functor_privateData *internal(new Functor_privateData(type, function));
    return JSObjectMake(context, Functor_, internal);
}

static bool CYGetOffset(apr_pool_t *pool, JSContextRef context, JSStringRef value, ssize_t &index) {
    return CYGetOffset(CYPoolCString(pool, context, value), index);
}

static void *CYCastPointer_(JSContextRef context, JSValueRef value) {
    switch (JSValueGetType(context, value)) {
        case kJSTypeNull:
            return NULL;
        /*case kJSTypeString:
            return dlsym(RTLD_DEFAULT, CYCastCString(context, value));
        case kJSTypeObject:
            if (JSValueIsObjectOfClass(context, value, Pointer_)) {
                Pointer *internal(reinterpret_cast<Pointer *>(JSObjectGetPrivate((JSObjectRef) value)));
                return internal->value_;
            }*/
        default:
            double number(CYCastDouble(context, value));
            if (std::isnan(number))
                throw CYError(context, "cannot convert value to pointer");
            return reinterpret_cast<void *>(static_cast<uintptr_t>(static_cast<long long>(number)));
    }
}

template <typename Type_>
static _finline Type_ CYCastPointer(JSContextRef context, JSValueRef value) {
    return reinterpret_cast<Type_>(CYCastPointer_(context, value));
}

#define CYObjectiveTry \
    try
#define CYObjectiveCatch \
    catch (const CYError &error) { \
        @throw CYCastNSObject(NULL, error.context_, error.value_); \
    }

#define CYPoolTry { \
    id _saved(nil); \
    NSAutoreleasePool *_pool([[NSAutoreleasePool alloc] init]); \
    @try
#define CYPoolCatch(value) \
    @catch (NSException *error) { \
        _saved = [error retain]; \
        throw CYError(context, CYCastJSValue(context, error)); \
        return value; \
    } @finally { \
        [_pool release]; \
        if (_saved != nil) \
            [_saved autorelease]; \
    } \
}

static void CYPoolFFI(apr_pool_t *pool, JSContextRef context, sig::Type *type, ffi_type *ffi, void *data, JSValueRef value) {
    switch (type->primitive) {
        case sig::boolean_P:
            *reinterpret_cast<bool *>(data) = JSValueToBoolean(context, value);
        break;

#define CYPoolFFI_(primitive, native) \
        case sig::primitive ## _P: \
            *reinterpret_cast<native *>(data) = CYCastDouble(context, value); \
        break;

        CYPoolFFI_(uchar, unsigned char)
        CYPoolFFI_(char, char)
        CYPoolFFI_(ushort, unsigned short)
        CYPoolFFI_(short, short)
        CYPoolFFI_(ulong, unsigned long)
        CYPoolFFI_(long, long)
        CYPoolFFI_(uint, unsigned int)
        CYPoolFFI_(int, int)
        CYPoolFFI_(ulonglong, unsigned long long)
        CYPoolFFI_(longlong, long long)
        CYPoolFFI_(float, float)
        CYPoolFFI_(double, double)

        case sig::pointer_P:
            *reinterpret_cast<void **>(data) = CYCastPointer<void *>(context, value);
        break;

        case sig::string_P:
            *reinterpret_cast<const char **>(data) = CYPoolCString(pool, context, value);
        break;

        case sig::struct_P: {
            uint8_t *base(reinterpret_cast<uint8_t *>(data));
            JSObjectRef aggregate(JSValueIsObject(context, value) ? (JSObjectRef) value : NULL);
            for (size_t index(0); index != type->data.signature.count; ++index) {
                sig::Element *element(&type->data.signature.elements[index]);
                ffi_type *field(ffi->elements[index]);

                JSValueRef rhs;
                if (aggregate == NULL)
                    rhs = value;
                else {
                    rhs = CYGetProperty(context, aggregate, index);
                    if (JSValueIsUndefined(context, rhs)) {
                        if (element->name != NULL)
                            rhs = CYGetProperty(context, aggregate, CYJSString(element->name));
                        else
                            goto undefined;
                        if (JSValueIsUndefined(context, rhs)) undefined:
                            throw CYError(context, "unable to extract structure value");
                    }
                }

                CYPoolFFI(pool, context, element->type, field, base, rhs);
                // XXX: alignment?
                base += field->size;
            }
        } break;

        case sig::void_P:
        break;

        default:
            if (hooks_ != NULL && hooks_->PoolFFI != NULL)
                if ((*hooks_->PoolFFI)(pool, context, type, ffi, data, value))
                    return;

            fprintf(stderr, "CYPoolFFI(%c)\n", type->primitive);
            _assert(false);
    }
}

static JSValueRef CYFromFFI(JSContextRef context, sig::Type *type, ffi_type *ffi, void *data, bool initialize = false, JSObjectRef owner = NULL) {
    switch (type->primitive) {
        case sig::boolean_P:
            return CYCastJSValue(context, *reinterpret_cast<bool *>(data));

#define CYFromFFI_(primitive, native) \
        case sig::primitive ## _P: \
            return CYCastJSValue(context, *reinterpret_cast<native *>(data)); \

        CYFromFFI_(uchar, unsigned char)
        CYFromFFI_(char, char)
        CYFromFFI_(ushort, unsigned short)
        CYFromFFI_(short, short)
        CYFromFFI_(ulong, unsigned long)
        CYFromFFI_(long, long)
        CYFromFFI_(uint, unsigned int)
        CYFromFFI_(int, int)
        CYFromFFI_(ulonglong, unsigned long long)
        CYFromFFI_(longlong, long long)
        CYFromFFI_(float, float)
        CYFromFFI_(double, double)

        case sig::pointer_P:
            if (void *pointer = *reinterpret_cast<void **>(data))
                return CYMakePointer(context, pointer, type->data.data.type, ffi, owner);
            else goto null;

        case sig::string_P:
            if (char *utf8 = *reinterpret_cast<char **>(data))
                return CYCastJSValue(context, utf8);
            else goto null;

        case sig::struct_P:
            return CYMakeStruct(context, data, type, ffi, owner);
        case sig::void_P:
            return CYJSUndefined(context);

        null:
            return CYJSNull(context);
        default:
            if (hooks_ != NULL && hooks_->FromFFI != NULL)
                if (JSValueRef value = (*hooks_->FromFFI)(context, type, ffi, data, initialize, owner))
                    return value;

            fprintf(stderr, "CYFromFFI(%c)\n", type->primitive);
            _assert(false);
    }
}

static void FunctionClosure_(ffi_cif *cif, void *result, void **arguments, void *arg) {
    Closure_privateData *internal(reinterpret_cast<Closure_privateData *>(arg));

    JSContextRef context(internal->context_);

    size_t count(internal->cif_.nargs);
    JSValueRef values[count];

    for (size_t index(0); index != count; ++index)
        values[index] = CYFromFFI(context, internal->signature_.elements[1 + index].type, internal->cif_.arg_types[index], arguments[index]);

    JSValueRef value(CYCallAsFunction(context, internal->function_, NULL, count, values));
    CYPoolFFI(NULL, context, internal->signature_.elements[0].type, internal->cif_.rtype, result, value);
}

static Closure_privateData *CYMakeFunctor_(JSContextRef context, JSObjectRef function, const char *type, void (*callback)(ffi_cif *, void *, void **, void *)) {
    // XXX: in case of exceptions this will leak
    // XXX: in point of fact, this may /need/ to leak :(
    Closure_privateData *internal(new Closure_privateData(CYGetJSContext(), function, type));

    ffi_closure *closure((ffi_closure *) _syscall(mmap(
        NULL, sizeof(ffi_closure),
        PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE,
        -1, 0
    )));

    ffi_status status(ffi_prep_closure(closure, &internal->cif_, callback, internal));
    _assert(status == FFI_OK);

    _syscall(mprotect(closure, sizeof(*closure), PROT_READ | PROT_EXEC));

    internal->value_ = closure;

    return internal;
}

static JSObjectRef CYMakeFunctor(JSContextRef context, JSObjectRef function, const char *type) {
    Closure_privateData *internal(CYMakeFunctor_(context, function, type, &FunctionClosure_));
    return JSObjectMake(context, Functor_, internal);
}

static JSObjectRef CYMakeFunctor(JSContextRef context, JSValueRef value, const char *type) {
    JSValueRef exception(NULL);
    bool function(JSValueIsInstanceOfConstructor(context, value, Function_, &exception));
    CYThrow(context, exception);

    if (function) {
        JSObjectRef function(CYCastJSObject(context, value));
        return CYMakeFunctor(context, function, type);
    } else {
        void (*function)()(CYCastPointer<void (*)()>(context, value));
        return CYMakeFunctor(context, function, type);
    }
}

static bool Index_(apr_pool_t *pool, JSContextRef context, Struct_privateData *internal, JSStringRef property, ssize_t &index, uint8_t *&base) {
    Type_privateData *typical(internal->type_);
    sig::Type *type(typical->type_);
    if (type == NULL)
        return false;

    const char *name(CYPoolCString(pool, context, property));
    size_t length(strlen(name));
    double number(CYCastDouble(name, length));

    size_t count(type->data.signature.count);

    if (std::isnan(number)) {
        if (property == NULL)
            return false;

        sig::Element *elements(type->data.signature.elements);

        for (size_t local(0); local != count; ++local) {
            sig::Element *element(&elements[local]);
            if (element->name != NULL && strcmp(name, element->name) == 0) {
                index = local;
                goto base;
            }
        }

        return false;
    } else {
        index = static_cast<ssize_t>(number);
        if (index != number || index < 0 || static_cast<size_t>(index) >= count)
            return false;
    }

  base:
    ffi_type **elements(typical->GetFFI()->elements);

    base = reinterpret_cast<uint8_t *>(internal->value_);
    for (ssize_t local(0); local != index; ++local)
        base += elements[local]->size;

    return true;
}

static JSValueRef Pointer_getIndex(JSContextRef context, JSObjectRef object, size_t index, JSValueRef *exception) { CYTry {
    Pointer *internal(reinterpret_cast<Pointer *>(JSObjectGetPrivate(object)));
    Type_privateData *typical(internal->type_);

    ffi_type *ffi(typical->GetFFI());

    uint8_t *base(reinterpret_cast<uint8_t *>(internal->value_));
    base += ffi->size * index;

    JSObjectRef owner(internal->GetOwner() ?: object);
    return CYFromFFI(context, typical->type_, ffi, base, false, owner);
} CYCatch }

static JSValueRef Pointer_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    CYPool pool;
    Pointer *internal(reinterpret_cast<Pointer *>(JSObjectGetPrivate(object)));
    Type_privateData *typical(internal->type_);

    if (typical->type_ == NULL)
        return NULL;

    ssize_t offset;
    if (!CYGetOffset(pool, context, property, offset))
        return NULL;

    return Pointer_getIndex(context, object, offset, exception);
}

static JSValueRef Pointer_getProperty_$cyi(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    return Pointer_getIndex(context, object, 0, exception);
}

static bool Pointer_setIndex(JSContextRef context, JSObjectRef object, size_t index, JSValueRef value, JSValueRef *exception) { CYTry {
    Pointer *internal(reinterpret_cast<Pointer *>(JSObjectGetPrivate(object)));
    Type_privateData *typical(internal->type_);

    ffi_type *ffi(typical->GetFFI());

    uint8_t *base(reinterpret_cast<uint8_t *>(internal->value_));
    base += ffi->size * index;

    CYPoolFFI(NULL, context, typical->type_, ffi, base, value);
    return true;
} CYCatch }

static bool Pointer_setProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) {
    CYPool pool;
    Pointer *internal(reinterpret_cast<Pointer *>(JSObjectGetPrivate(object)));
    Type_privateData *typical(internal->type_);

    if (typical->type_ == NULL)
        return NULL;

    ssize_t offset;
    if (!CYGetOffset(pool, context, property, offset))
        return NULL;

    return Pointer_setIndex(context, object, offset, value, exception);
}

static bool Pointer_setProperty_$cyi(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) {
    return Pointer_setIndex(context, object, 0, value, exception);
}

static JSValueRef Struct_callAsFunction_$cya(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    Struct_privateData *internal(reinterpret_cast<Struct_privateData *>(JSObjectGetPrivate(_this)));
    Type_privateData *typical(internal->type_);
    return CYMakePointer(context, internal->value_, typical->type_, typical->ffi_, _this);
}

static JSValueRef Struct_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    CYPool pool;
    Struct_privateData *internal(reinterpret_cast<Struct_privateData *>(JSObjectGetPrivate(object)));
    Type_privateData *typical(internal->type_);

    ssize_t index;
    uint8_t *base;

    if (!Index_(pool, context, internal, property, index, base))
        return NULL;

    JSObjectRef owner(internal->GetOwner() ?: object);

    return CYFromFFI(context, typical->type_->data.signature.elements[index].type, typical->GetFFI()->elements[index], base, false, owner);
} CYCatch }

static bool Struct_setProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) { CYTry {
    CYPool pool;
    Struct_privateData *internal(reinterpret_cast<Struct_privateData *>(JSObjectGetPrivate(object)));
    Type_privateData *typical(internal->type_);

    ssize_t index;
    uint8_t *base;

    if (!Index_(pool, context, internal, property, index, base))
        return false;

    CYPoolFFI(NULL, context, typical->type_->data.signature.elements[index].type, typical->GetFFI()->elements[index], base, value);
    return true;
} CYCatch }

static void Struct_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    Struct_privateData *internal(reinterpret_cast<Struct_privateData *>(JSObjectGetPrivate(object)));
    Type_privateData *typical(internal->type_);
    sig::Type *type(typical->type_);

    if (type == NULL)
        return;

    size_t count(type->data.signature.count);
    sig::Element *elements(type->data.signature.elements);

    char number[32];

    for (size_t index(0); index != count; ++index) {
        const char *name;
        name = elements[index].name;

        if (name == NULL) {
            sprintf(number, "%lu", index);
            name = number;
        }

        JSPropertyNameAccumulatorAddName(names, CYJSString(name));
    }
}

JSValueRef CYCallFunction(apr_pool_t *pool, JSContextRef context, size_t setups, void *setup[], size_t count, const JSValueRef arguments[], bool initialize, JSValueRef *exception, sig::Signature *signature, ffi_cif *cif, void (*function)()) { CYTry {
    if (setups + count != signature->count - 1)
        throw CYError(context, "incorrect number of arguments to ffi function");

    size_t size(setups + count);
    void *values[size];
    memcpy(values, setup, sizeof(void *) * setups);

    for (size_t index(setups); index != size; ++index) {
        sig::Element *element(&signature->elements[index + 1]);
        ffi_type *ffi(cif->arg_types[index]);
        // XXX: alignment?
        values[index] = new(pool) uint8_t[ffi->size];
        CYPoolFFI(pool, context, element->type, ffi, values[index], arguments[index - setups]);
    }

    uint8_t value[cif->rtype->size];
    ffi_call(cif, function, value, values);

    return CYFromFFI(context, signature->elements[0].type, cif->rtype, value, initialize);
} CYCatch }

static JSValueRef Functor_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYPool pool;
    Functor_privateData *internal(reinterpret_cast<Functor_privateData *>(JSObjectGetPrivate(object)));
    return CYCallFunction(pool, context, 0, NULL, count, arguments, false, exception, &internal->signature_, &internal->cif_, internal->GetValue());
}

static JSObjectRef CYMakeType(JSContextRef context, const char *type) {
    Type_privateData *internal(new Type_privateData(NULL, type));
    return JSObjectMake(context, Type_privateData::Class_, internal);
}

static JSObjectRef CYMakeType(JSContextRef context, sig::Type *type) {
    Type_privateData *internal(new Type_privateData(type));
    return JSObjectMake(context, Type_privateData::Class_, internal);
}

static void *CYCastSymbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static JSValueRef Runtime_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    CYPool pool;
    CYUTF8String name(CYPoolUTF8String(pool, context, property));

    if (hooks_ != NULL && hooks_->RuntimeProperty != NULL)
        if (JSValueRef value = (*hooks_->RuntimeProperty)(context, name))
            return value;

    sqlite3_stmt *statement;

    _sqlcall(sqlite3_prepare(Bridge_,
        "select "
            "\"bridge\".\"mode\", "
            "\"bridge\".\"value\" "
        "from \"bridge\" "
        "where"
            " \"bridge\".\"name\" = ?"
        " limit 1"
    , -1, &statement, NULL));

    _sqlcall(sqlite3_bind_text(statement, 1, name.data, name.size, SQLITE_STATIC));

    int mode;
    const char *value;

    if (_sqlcall(sqlite3_step(statement)) == SQLITE_DONE) {
        mode = -1;
        value = NULL;
    } else {
        mode = sqlite3_column_int(statement, 0);
        value = sqlite3_column_pooled(pool, statement, 1);
    }

    _sqlcall(sqlite3_finalize(statement));

    switch (mode) {
        default:
            _assert(false);
        case -1:
            return NULL;

        case 0:
            return JSEvaluateScript(CYGetJSContext(), CYJSString(value), NULL, NULL, 0, NULL);
        case 1:
            return CYMakeFunctor(context, reinterpret_cast<void (*)()>(CYCastSymbol(name.data)), value);

        case 2: {
            // XXX: this is horrendously inefficient
            sig::Signature signature;
            sig::Parse(pool, &signature, value, &Structor_);
            ffi_cif cif;
            sig::sig_ffi_cif(pool, &sig::ObjectiveC, &signature, &cif);
            return CYFromFFI(context, signature.elements[0].type, cif.rtype, CYCastSymbol(name.data));
        }

        // XXX: implement case 3
        case 4:
            return CYMakeType(context, value);
    }
} CYCatch }

static JSObjectRef Pointer_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 2)
        throw CYError(context, "incorrect number of arguments to Functor constructor");

    void *value(CYCastPointer<void *>(context, arguments[0]));
    const char *type(CYCastCString(context, arguments[1]));

    CYPool pool;

    sig::Signature signature;
    sig::Parse(pool, &signature, type, &Structor_);

    return CYMakePointer(context, value, signature.elements[0].type, NULL, NULL);
} CYCatch }

static JSObjectRef Type_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 1)
        throw CYError(context, "incorrect number of arguments to Type constructor");
    const char *type(CYCastCString(context, arguments[0]));
    return CYMakeType(context, type);
} CYCatch }

static JSValueRef Type_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    Type_privateData *internal(reinterpret_cast<Type_privateData *>(JSObjectGetPrivate(object)));

    sig::Type type;

    if (JSStringIsEqualToUTF8CString(property, "$cyi")) {
        type.primitive = sig::pointer_P;
        type.data.data.size = 0;
    } else {
        CYPool pool;
        size_t index(CYGetIndex(pool, context, property));
        if (index == _not(size_t))
            return NULL;
        type.primitive = sig::array_P;
        type.data.data.size = index;
    }

    type.name = NULL;
    type.flags = 0;

    type.data.data.type = internal->type_;

    return CYMakeType(context, &type);
} CYCatch }

static JSValueRef Type_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    Type_privateData *internal(reinterpret_cast<Type_privateData *>(JSObjectGetPrivate(object)));

    if (count != 1)
        throw CYError(context, "incorrect number of arguments to type cast function");
    sig::Type *type(internal->type_);
    ffi_type *ffi(internal->GetFFI());
    // XXX: alignment?
    uint8_t value[ffi->size];
    CYPool pool;
    CYPoolFFI(pool, context, type, ffi, value, arguments[0]);
    return CYFromFFI(context, type, ffi, value);
} CYCatch }

static JSObjectRef Type_callAsConstructor(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 0)
        throw CYError(context, "incorrect number of arguments to type cast function");
    Type_privateData *internal(reinterpret_cast<Type_privateData *>(JSObjectGetPrivate(object)));

    sig::Type *type(internal->type_);
    size_t size;

    if (type->primitive != sig::array_P)
        size = 0;
    else {
        size = type->data.data.size;
        type = type->data.data.type;
    }

    void *value(malloc(internal->GetFFI()->size));
    return CYMakePointer(context, value, type, NULL, NULL);
} CYCatch }

static JSObjectRef Functor_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 2)
        throw CYError(context, "incorrect number of arguments to Functor constructor");
    const char *type(CYCastCString(context, arguments[1]));
    return CYMakeFunctor(context, arguments[0], type);
} CYCatch }

static JSValueRef CYValue_callAsFunction_valueOf(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    CYValue *internal(reinterpret_cast<CYValue *>(JSObjectGetPrivate(_this)));
    return CYCastJSValue(context, reinterpret_cast<uintptr_t>(internal->value_));
} CYCatch }

static JSValueRef CYValue_callAsFunction_toJSON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    return CYValue_callAsFunction_valueOf(context, object, _this, count, arguments, exception);
}

static JSValueRef CYValue_callAsFunction_toCYON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
CYValue *internal(reinterpret_cast<CYValue *>(JSObjectGetPrivate(_this)));
    char string[32];
    sprintf(string, "%p", internal->value_);

    return CYCastJSValue(context, string);
} CYCatch }

static JSValueRef Type_callAsFunction_toString(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    Type_privateData *internal(reinterpret_cast<Type_privateData *>(JSObjectGetPrivate(_this)));
    CYPool pool;
    const char *type(sig::Unparse(pool, internal->type_));
    return CYCastJSValue(context, CYJSString(type));
} CYCatch }

static JSValueRef Type_callAsFunction_toCYON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    Type_privateData *internal(reinterpret_cast<Type_privateData *>(JSObjectGetPrivate(_this)));
    CYPool pool;
    const char *type(sig::Unparse(pool, internal->type_));
    size_t size(strlen(type));
    char *cyon(new(pool) char[12 + size + 1]);
    memcpy(cyon, "new Type(\"", 10);
    cyon[12 + size] = '\0';
    cyon[12 + size - 2] = '"';
    cyon[12 + size - 1] = ')';
    memcpy(cyon + 10, type, size);
    return CYCastJSValue(context, CYJSString(cyon));
} CYCatch }

static JSValueRef Type_callAsFunction_toJSON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    return Type_callAsFunction_toString(context, object, _this, count, arguments, exception);
}

static JSStaticValue Pointer_staticValues[2] = {
    {"$cyi", &Pointer_getProperty_$cyi, &Pointer_setProperty_$cyi, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, NULL, 0}
};

static JSStaticFunction Pointer_staticFunctions[4] = {
    {"toCYON", &CYValue_callAsFunction_toCYON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toJSON", &CYValue_callAsFunction_toJSON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"valueOf", &CYValue_callAsFunction_valueOf, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

static JSStaticFunction Struct_staticFunctions[2] = {
    {"$cya", &Struct_callAsFunction_$cya, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

static JSStaticFunction Functor_staticFunctions[4] = {
    {"toCYON", &CYValue_callAsFunction_toCYON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toJSON", &CYValue_callAsFunction_toJSON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"valueOf", &CYValue_callAsFunction_valueOf, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

static JSStaticFunction Type_staticFunctions[4] = {
    {"toCYON", &Type_callAsFunction_toCYON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toJSON", &Type_callAsFunction_toJSON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toString", &Type_callAsFunction_toString, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

void CYSetArgs(int argc, const char *argv[]) {
    JSContextRef context(CYGetJSContext());
    JSValueRef args[argc];
    for (int i(0); i != argc; ++i)
        args[i] = CYCastJSValue(context, argv[i]);
    JSValueRef exception(NULL);
    JSObjectRef array(JSObjectMakeArray(context, argc, args, &exception));
    CYThrow(context, exception);
    CYSetProperty(context, System_, CYJSString("args"), array);
}

JSObjectRef CYGetGlobalObject(JSContextRef context) {
    return JSContextGetGlobalObject(context);
}

const char *CYExecute(apr_pool_t *pool, const char *code) {
    JSContextRef context(CYGetJSContext());
    JSValueRef exception(NULL), result;

    void *handle;
    if (hooks_ != NULL && hooks_->ExecuteStart != NULL)
        handle = (*hooks_->ExecuteStart)();
    else
        handle = NULL;

    const char *json;

    try {
        result = JSEvaluateScript(context, CYJSString(code), NULL, NULL, 0, &exception);
    } catch (const char *error) {
        return error;
    }

    if (exception != NULL) { error:
        result = exception;
        exception = NULL;
    }

    if (JSValueIsUndefined(context, result))
        return NULL;

    try {
        json = CYPoolCCYON(pool, context, result, &exception);
    } catch (const char *error) {
        return error;
    }

    if (exception != NULL)
        goto error;

    CYSetProperty(context, CYGetGlobalObject(context), Result_, result);

    if (hooks_ != NULL && hooks_->ExecuteEnd != NULL)
        (*hooks_->ExecuteEnd)(handle);
    return json;
}

static apr_pool_t *Pool_;

apr_pool_t *CYGetGlobalPool() {
    return Pool_;
}

MSInitialize {
    JSContextRef context(NULL);
    _aprcall(apr_initialize());
    _aprcall(apr_pool_create(&Pool_, NULL));
    _sqlcall(sqlite3_open("/usr/lib/libcycript.db", &Bridge_));
}

void CYThrow(JSContextRef context, JSValueRef value) {
    if (value == NULL)
        return;
    throw CYError(context, value);
}

CYError::CYError(JSContextRef context, const char *format, ...) {
    if (context == NULL)
        context = CYGetJSContext();

    CYPool pool;

    va_list args;
    va_start (args, format);
    const char *message(apr_pvsprintf(pool, format, args));
    va_end (args);

    JSValueRef arguments[1] = {CYCastJSValue(context, CYJSString(message))};

    JSValueRef exception(NULL);
    value_ = JSObjectCallAsConstructor(context, Error_, 1, arguments, &exception);
    CYThrow(context, exception);
}

void CYObjectiveC(JSContextRef context, JSObjectRef global);

#ifdef __OBJC__
/* Objective-C {{{ */
#include <Foundation/Foundation.h>
#include "ObjectiveC/Internal.hpp"
#include "Struct.hpp"

#ifdef __APPLE__
#include <WebKit/WebScriptObject.h>
#endif

/* Objective-C Pool Release {{{ */
apr_status_t CYPoolRelease_(void *data) {
    id object(reinterpret_cast<id>(data));
    [object release];
    return APR_SUCCESS;
}

id CYPoolRelease_(apr_pool_t *pool, id object) {
    if (object == nil)
        return nil;
    else if (pool == NULL)
        return [object autorelease];
    else {
        apr_pool_cleanup_register(pool, object, &CYPoolRelease_, &apr_pool_cleanup_null);
        return object;
    }
}

template <typename Type_>
Type_ CYPoolRelease(apr_pool_t *pool, Type_ object) {
    return (Type_) CYPoolRelease_(pool, (id) object);
}
/* }}} */
/* Objective-C Strings {{{ */
const char *CYPoolCString(apr_pool_t *pool, JSContextRef context, NSString *value) {
    if (pool == NULL)
        return [value UTF8String];
    else {
        size_t size([value maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1);
        char *string(new(pool) char[size]);
        if (![value getCString:string maxLength:size encoding:NSUTF8StringEncoding])
            throw CYError(context, "[NSString getCString:maxLength:encoding:] == NO");
        return string;
    }
}

JSStringRef CYCopyJSString_(NSString *value) {
#ifdef __APPLE__
    return JSStringCreateWithCFString(reinterpret_cast<CFStringRef>(value));
#else
    CYPool pool;
    return CYCopyJSString(CYPoolCString(pool, value));
#endif
}

JSStringRef CYCopyJSString(id value) {
    if (value == nil)
        return NULL;
    // XXX: this definition scares me; is anyone using this?!
    NSString *string([value description]);
    return CYCopyJSString_(string);
}

NSString *CYCopyNSString(const CYUTF8String &value) {
#ifdef __APPLE__
    return (NSString *) CFStringCreateWithBytes(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(value.data), value.size, kCFStringEncodingUTF8, true);
#else
    return [[NSString alloc] initWithBytes:value.data length:value.size encoding:NSUTF8StringEncoding];
#endif
}

NSString *CYCopyNSString(JSStringRef value) {
#ifdef __APPLE__
    return (NSString *) JSStringCopyCFString(kCFAllocatorDefault, value);
#else
    return CYCopyNSString(CYCastCString_(value));
#endif
}

NSString *CYCopyNSString(JSContextRef context, JSValueRef value) {
    return CYCopyNSString(CYJSString(context, value));
}

NSString *CYCastNSString(apr_pool_t *pool, const CYUTF8String &value) {
    return CYPoolRelease(pool, CYCopyNSString(value));
}

NSString *CYCastNSString(apr_pool_t *pool, SEL sel) {
    const char *name(sel_getName(sel));
    return CYPoolRelease(pool, CYCopyNSString(CYUTF8String(name, strlen(name))));
}

NSString *CYCastNSString(apr_pool_t *pool, JSStringRef value) {
    return CYPoolRelease(pool, CYCopyNSString(value));
}

CYUTF8String CYCastUTF8String(NSString *value) {
    NSData *data([value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO]);
    return CYUTF8String(reinterpret_cast<const char *>([data bytes]), [data length]);
}
/* }}} */

void CYThrow(JSContextRef context, NSException *error, JSValueRef *exception) {
    if (exception == NULL)
        throw error;
    *exception = CYCastJSValue(context, error);
}

size_t CYGetIndex(NSString *value) {
    return CYGetIndex(CYCastUTF8String(value));
}

bool CYGetOffset(apr_pool_t *pool, JSContextRef context, NSString *value, ssize_t &index) {
    return CYGetOffset(CYPoolCString(pool, context, value), index);
}

static JSClassRef Instance_;
static JSClassRef Internal_;
static JSClassRef Message_;
static JSClassRef Messages_;
static JSClassRef Selector_;
static JSClassRef Super_;

static JSClassRef ObjectiveC_Classes_;
static JSClassRef ObjectiveC_Image_Classes_;
static JSClassRef ObjectiveC_Images_;
static JSClassRef ObjectiveC_Protocols_;

static JSObjectRef Instance_prototype_;

#ifdef __APPLE__
static Class NSCFBoolean_;
static Class NSCFType_;
#endif

static Class NSArray_;
static Class NSDictionary_;
static Class NSMessageBuilder_;
static Class NSZombie_;
static Class Object_;

static Type_privateData *Object_type;
static Type_privateData *Selector_type;

Type_privateData *Instance::GetType() const {
    return Object_type;
}

Type_privateData *Selector_privateData::GetType() const {
    return Selector_type;
}

// XXX: trick this out with associated objects!
JSValueRef CYGetClassPrototype(JSContextRef context, id self) {
    if (self == nil)
        return Instance_prototype_;

    // XXX: I need to think through multi-context
    typedef std::map<id, JSValueRef> CacheMap;
    static CacheMap cache_;

    JSValueRef &value(cache_[self]);
    if (value != NULL)
        return value;

    JSClassRef _class(NULL);
    JSValueRef prototype;

    if (self == NSArray_)
        prototype = Array_prototype_;
    else if (self == NSDictionary_)
        prototype = Object_prototype_;
    else
        prototype = CYGetClassPrototype(context, class_getSuperclass(self));

    JSObjectRef object(JSObjectMake(context, _class, NULL));
    JSObjectSetPrototype(context, object, prototype);

    JSValueProtect(context, object);
    value = object;
    return object;
}

JSObjectRef Messages::Make(JSContextRef context, Class _class, bool array) {
    JSObjectRef value(JSObjectMake(context, Messages_, new Messages(_class)));
    if (_class == NSArray_)
        array = true;
    if (Class super = class_getSuperclass(_class))
        JSObjectSetPrototype(context, value, Messages::Make(context, super, array));
    /*else if (array)
        JSObjectSetPrototype(context, value, Array_prototype_);*/
    return value;
}

JSObjectRef Internal::Make(JSContextRef context, id object, JSObjectRef owner) {
    return JSObjectMake(context, Internal_, new Internal(object, context, owner));
}

namespace cy {
JSObjectRef Super::Make(JSContextRef context, id object, Class _class) {
    JSObjectRef value(JSObjectMake(context, Super_, new Super(object, _class)));
    return value;
} }

JSObjectRef Instance::Make(JSContextRef context, id object, Flags flags) {
    JSObjectRef value(JSObjectMake(context, Instance_, new Instance(object, flags)));
    JSObjectSetPrototype(context, value, CYGetClassPrototype(context, object_getClass(object)));
    return value;
}

Instance::~Instance() {
    if ((flags_ & Transient) == 0)
        // XXX: does this handle background threads correctly?
        // XXX: this simply does not work on the console because I'm stupid
        [GetValue() performSelector:@selector(release) withObject:nil afterDelay:0];
}

struct Message_privateData :
Functor_privateData
{
    SEL sel_;

    Message_privateData(SEL sel, const char *type, IMP value = NULL) :
        Functor_privateData(type, reinterpret_cast<void (*)()>(value)),
        sel_(sel)
    {
    }
};

JSObjectRef CYMakeInstance(JSContextRef context, id object, bool transient) {
    Instance::Flags flags;

    if (transient)
        flags = Instance::Transient;
    else {
        flags = Instance::None;
        object = [object retain];
    }

    return Instance::Make(context, object, flags);
}

@interface NSMethodSignature (Cycript)
- (NSString *) _typeString;
@end

@interface NSObject (Cycript)

- (JSValueRef) cy$JSValueInContext:(JSContextRef)context;
- (JSType) cy$JSType;

- (NSObject *) cy$toJSON:(NSString *)key;
- (NSString *) cy$toCYON;
- (NSString *) cy$toKey;

- (bool) cy$hasProperty:(NSString *)name;
- (NSObject *) cy$getProperty:(NSString *)name;
- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value;
- (bool) cy$deleteProperty:(NSString *)name;

@end

@protocol Cycript
- (JSValueRef) cy$JSValueInContext:(JSContextRef)context;
@end

NSString *CYCastNSCYON(id value) {
    NSString *string;

    if (value == nil)
        string = @"nil";
    else {
        Class _class(object_getClass(value));
        SEL sel(@selector(cy$toCYON));

        if (objc_method *toCYON = class_getInstanceMethod(_class, sel))
            string = reinterpret_cast<NSString *(*)(id, SEL)>(method_getImplementation(toCYON))(value, sel);
        else if (objc_method *methodSignatureForSelector = class_getInstanceMethod(_class, @selector(methodSignatureForSelector:))) {
            if (reinterpret_cast<NSMethodSignature *(*)(id, SEL, SEL)>(method_getImplementation(methodSignatureForSelector))(value, @selector(methodSignatureForSelector:), sel) != nil)
                string = [value cy$toCYON];
            else goto fail;
        } else fail: {
            if (value == NSZombie_)
                string = @"_NSZombie_";
            else if (_class == NSZombie_)
                string = [NSString stringWithFormat:@"<_NSZombie_: %p>", value];
            // XXX: frowny /in/ the pants
            else if (value == NSMessageBuilder_ || value == Object_)
                string = nil;
            else
                string = [NSString stringWithFormat:@"%@", value];
        }

        // XXX: frowny pants
        if (string == nil)
            string = @"undefined";
    }

    return string;
}

#ifdef __APPLE__
struct PropertyAttributes {
    CYPool pool_;

    const char *name;

    const char *variable;

    const char *getter_;
    const char *setter_;

    bool readonly;
    bool copy;
    bool retain;
    bool nonatomic;
    bool dynamic;
    bool weak;
    bool garbage;

    PropertyAttributes(objc_property_t property) :
        variable(NULL),
        getter_(NULL),
        setter_(NULL),
        readonly(false),
        copy(false),
        retain(false),
        nonatomic(false),
        dynamic(false),
        weak(false),
        garbage(false)
    {
        name = property_getName(property);
        const char *attributes(property_getAttributes(property));

        for (char *state, *token(apr_strtok(apr_pstrdup(pool_, attributes), ",", &state)); token != NULL; token = apr_strtok(NULL, ",", &state)) {
            switch (*token) {
                case 'R': readonly = true; break;
                case 'C': copy = true; break;
                case '&': retain = true; break;
                case 'N': nonatomic = true; break;
                case 'G': getter_ = token + 1; break;
                case 'S': setter_ = token + 1; break;
                case 'V': variable = token + 1; break;
            }
        }

        /*if (variable == NULL) {
            variable = property_getName(property);
            size_t size(strlen(variable));
            char *name(new(pool_) char[size + 2]);
            name[0] = '_';
            memcpy(name + 1, variable, size);
            name[size + 1] = '\0';
            variable = name;
        }*/
    }

    const char *Getter() {
        if (getter_ == NULL)
            getter_ = apr_pstrdup(pool_, name);
        return getter_;
    }

    const char *Setter() {
        if (setter_ == NULL && !readonly) {
            size_t length(strlen(name));

            char *temp(new(pool_) char[length + 5]);
            temp[0] = 's';
            temp[1] = 'e';
            temp[2] = 't';

            if (length != 0) {
                temp[3] = toupper(name[0]);
                memcpy(temp + 4, name + 1, length - 1);
            }

            temp[length + 3] = ':';
            temp[length + 4] = '\0';
            setter_ = temp;
        }

        return setter_;
    }

};
#endif

#ifdef __APPLE__
NSObject *NSCFType$cy$toJSON(id self, SEL sel, NSString *key) {
    return [(NSString *) CFCopyDescription((CFTypeRef) self) autorelease];
}
#endif

#ifndef __APPLE__
@interface CYWebUndefined : NSObject {
}

+ (CYWebUndefined *) undefined;

@end

@implementation CYWebUndefined

+ (CYWebUndefined *) undefined {
    static CYWebUndefined *instance_([[CYWebUndefined alloc] init]);
    return instance_;
}

@end

#define WebUndefined CYWebUndefined
#endif

/* Bridge: CYJSObject {{{ */
@interface CYJSObject : NSMutableDictionary {
    JSObjectRef object_;
    JSContextRef context_;
}

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context;

- (NSObject *) cy$toJSON:(NSString *)key;

- (NSUInteger) count;
- (id) objectForKey:(id)key;
- (NSEnumerator *) keyEnumerator;
- (void) setObject:(id)object forKey:(id)key;
- (void) removeObjectForKey:(id)key;

@end
/* }}} */
/* Bridge: CYJSArray {{{ */
@interface CYJSArray : NSMutableArray {
    JSObjectRef object_;
    JSContextRef context_;
}

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context;

- (NSUInteger) count;
- (id) objectAtIndex:(NSUInteger)index;

- (void) addObject:(id)anObject;
- (void) insertObject:(id)anObject atIndex:(NSUInteger)index;
- (void) removeLastObject;
- (void) removeObjectAtIndex:(NSUInteger)index;
- (void) replaceObjectAtIndex:(NSUInteger)index withObject:(id)anObject;

@end
/* }}} */

NSObject *CYCastNSObject_(apr_pool_t *pool, JSContextRef context, JSObjectRef object) {
    JSValueRef exception(NULL);
    bool array(JSValueIsInstanceOfConstructor(context, object, Array_, &exception));
    CYThrow(context, exception);
    id value(array ? [CYJSArray alloc] : [CYJSObject alloc]);
    return CYPoolRelease(pool, [value initWithJSObject:object inContext:context]);
}

NSObject *CYCastNSObject(apr_pool_t *pool, JSContextRef context, JSObjectRef object) {
    if (!JSValueIsObjectOfClass(context, object, Instance_))
        return CYCastNSObject_(pool, context, object);
    else {
        Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
        return internal->GetValue();
    }
}

NSNumber *CYCopyNSNumber(JSContextRef context, JSValueRef value) {
    return [[NSNumber alloc] initWithDouble:CYCastDouble(context, value)];
}

id CYNSObject(apr_pool_t *pool, JSContextRef context, JSValueRef value, bool cast) {
    id object;
    bool copy;

    switch (JSType type = JSValueGetType(context, value)) {
        case kJSTypeUndefined:
            object = [WebUndefined undefined];
            copy = false;
        break;

        case kJSTypeNull:
            return NULL;
        break;

        case kJSTypeBoolean:
#ifdef __APPLE__
            object = (id) (CYCastBool(context, value) ? kCFBooleanTrue : kCFBooleanFalse);
            copy = false;
#else
            object = [[NSNumber alloc] initWithBool:CYCastBool(context, value)];
            copy = true;
#endif
        break;

        case kJSTypeNumber:
            object = CYCopyNSNumber(context, value);
            copy = true;
        break;

        case kJSTypeString:
            object = CYCopyNSString(context, value);
            copy = true;
        break;

        case kJSTypeObject:
            // XXX: this might could be more efficient
            object = CYCastNSObject(pool, context, (JSObjectRef) value);
            copy = false;
        break;

        default:
            throw CYError(context, "JSValueGetType() == 0x%x", type);
        break;
    }

    if (cast != copy)
        return object;
    else if (copy)
        return CYPoolRelease(pool, object);
    else
        return [object retain];
}

NSObject *CYCastNSObject(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    return CYNSObject(pool, context, value, true);
}

NSObject *CYCopyNSObject(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    return CYNSObject(pool, context, value, false);
}

/* Bridge: NSArray {{{ */
@implementation NSArray (Cycript)

- (NSString *) cy$toCYON {
    NSMutableString *json([[[NSMutableString alloc] init] autorelease]);
    [json appendString:@"["];

    bool comma(false);
#ifdef __APPLE__
    for (id object in self) {
#else
    for (size_t index(0), count([self count]); index != count; ++index) {
        id object([self objectAtIndex:index]);
#endif
        if (comma)
            [json appendString:@","];
        else
            comma = true;
        if (object == nil || [object cy$JSType] != kJSTypeUndefined)
            [json appendString:CYCastNSCYON(object)];
        else {
            [json appendString:@","];
            comma = false;
        }
    }

    [json appendString:@"]"];
    return json;
}

- (bool) cy$hasProperty:(NSString *)name {
    if ([name isEqualToString:@"length"])
        return true;

    size_t index(CYGetIndex(name));
    if (index == _not(size_t) || index >= [self count])
        return [super cy$hasProperty:name];
    else
        return true;
}

- (NSObject *) cy$getProperty:(NSString *)name {
    if ([name isEqualToString:@"length"]) {
        NSUInteger count([self count]);
#ifdef __APPLE__
        return [NSNumber numberWithUnsignedInteger:count];
#else
        return [NSNumber numberWithUnsignedInt:count];
#endif
    }

    size_t index(CYGetIndex(name));
    if (index == _not(size_t) || index >= [self count])
        return [super cy$getProperty:name];
    else
        return [self objectAtIndex:index];
}

@end
/* }}} */
/* Bridge: NSDictionary {{{ */
@implementation NSDictionary (Cycript)

- (NSString *) cy$toCYON {
    NSMutableString *json([[[NSMutableString alloc] init] autorelease]);
    [json appendString:@"{"];

    bool comma(false);
#ifdef __APPLE__
    for (id key in self) {
#else
    NSEnumerator *keys([self keyEnumerator]);
    while (id key = [keys nextObject]) {
#endif
        if (comma)
            [json appendString:@","];
        else
            comma = true;
        [json appendString:[key cy$toKey]];
        [json appendString:@":"];
        NSObject *object([self objectForKey:key]);
        [json appendString:CYCastNSCYON(object)];
    }

    [json appendString:@"}"];
    return json;
}

- (bool) cy$hasProperty:(NSString *)name {
    return [self objectForKey:name] != nil;
}

- (NSObject *) cy$getProperty:(NSString *)name {
    return [self objectForKey:name];
}

@end
/* }}} */
/* Bridge: NSMutableArray {{{ */
@implementation NSMutableArray (Cycript)

- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value {
    if ([name isEqualToString:@"length"]) {
        // XXX: is this not intelligent?
        NSNumber *number(reinterpret_cast<NSNumber *>(value));
#ifdef __APPLE__
        NSUInteger size([number unsignedIntegerValue]);
#else
        NSUInteger size([number unsignedIntValue]);
#endif
        NSUInteger count([self count]);
        if (size < count)
            [self removeObjectsInRange:NSMakeRange(size, count - size)];
        else if (size != count) {
            WebUndefined *undefined([WebUndefined undefined]);
            for (size_t i(count); i != size; ++i)
                [self addObject:undefined];
        }
        return true;
    }

    size_t index(CYGetIndex(name));
    if (index == _not(size_t))
        return [super cy$setProperty:name to:value];

    id object(value ?: [NSNull null]);

    size_t count([self count]);
    if (index < count)
        [self replaceObjectAtIndex:index withObject:object];
    else {
        if (index != count) {
            WebUndefined *undefined([WebUndefined undefined]);
            for (size_t i(count); i != index; ++i)
                [self addObject:undefined];
        }

        [self addObject:object];
    }

    return true;
}

- (bool) cy$deleteProperty:(NSString *)name {
    size_t index(CYGetIndex(name));
    if (index == _not(size_t) || index >= [self count])
        return [super cy$deleteProperty:name];
    [self replaceObjectAtIndex:index withObject:[WebUndefined undefined]];
    return true;
}

@end
/* }}} */
/* Bridge: NSMutableDictionary {{{ */
@implementation NSMutableDictionary (Cycript)

- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value {
    [self setObject:(value ?: [NSNull null]) forKey:name];
    return true;
}

- (bool) cy$deleteProperty:(NSString *)name {
    if ([self objectForKey:name] == nil)
        return false;
    else {
        [self removeObjectForKey:name];
        return true;
    }
}

@end
/* }}} */
/* Bridge: NSNumber {{{ */
@implementation NSNumber (Cycript)

- (JSType) cy$JSType {
#ifdef __APPLE__
    // XXX: this just seems stupid
    if ([self class] == NSCFBoolean_)
        return kJSTypeBoolean;
#endif
    return kJSTypeNumber;
}

- (NSObject *) cy$toJSON:(NSString *)key {
    return self;
}

- (NSString *) cy$toCYON {
    return [self cy$JSType] != kJSTypeBoolean ? [self stringValue] : [self boolValue] ? @"true" : @"false";
}

- (JSValueRef) cy$JSValueInContext:(JSContextRef)context { CYObjectiveTry {
    return [self cy$JSType] != kJSTypeBoolean ? CYCastJSValue(context, [self doubleValue]) : CYCastJSValue(context, [self boolValue]);
} CYObjectiveCatch }

@end
/* }}} */
/* Bridge: NSNull {{{ */
@implementation NSNull (Cycript)

- (JSType) cy$JSType {
    return kJSTypeNull;
}

- (NSObject *) cy$toJSON:(NSString *)key {
    return self;
}

- (NSString *) cy$toCYON {
    return @"null";
}

@end
/* }}} */
/* Bridge: NSObject {{{ */
@implementation NSObject (Cycript)

- (JSValueRef) cy$JSValueInContext:(JSContextRef)context { CYObjectiveTry {
    return CYMakeInstance(context, self, false);
} CYObjectiveCatch }

- (JSType) cy$JSType {
    return kJSTypeObject;
}

- (NSObject *) cy$toJSON:(NSString *)key {
    return [self description];
}

- (NSString *) cy$toCYON {
    return [[self cy$toJSON:@""] cy$toCYON];
}

- (NSString *) cy$toKey {
    return [self cy$toCYON];
}

- (bool) cy$hasProperty:(NSString *)name {
    return false;
}

- (NSObject *) cy$getProperty:(NSString *)name {
    return nil;
}

- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value {
    return false;
}

- (bool) cy$deleteProperty:(NSString *)name {
    return false;
}

@end
/* }}} */
/* Bridge: NSProxy {{{ */
@implementation NSProxy (Cycript)

- (NSObject *) cy$toJSON:(NSString *)key {
    return [self description];
}

- (NSString *) cy$toCYON {
    return [[self cy$toJSON:@""] cy$toCYON];
}

@end
/* }}} */
/* Bridge: NSString {{{ */
@implementation NSString (Cycript)

- (JSType) cy$JSType {
    return kJSTypeString;
}

- (NSObject *) cy$toJSON:(NSString *)key {
    return self;
}

- (NSString *) cy$toCYON {
    std::ostringstream str;
    CYUTF8String string(CYCastUTF8String(self));
    CYStringify(str, string.data, string.size);
    std::string value(str.str());
    return CYCastNSString(NULL, CYUTF8String(value.c_str(), value.size()));
}

- (NSString *) cy$toKey {
    if (CYIsKey(CYCastUTF8String(self)))
        return self;
    return [self cy$toCYON];
}

@end
/* }}} */
/* Bridge: WebUndefined {{{ */
@implementation WebUndefined (Cycript)

- (JSType) cy$JSType {
    return kJSTypeUndefined;
}

- (NSObject *) cy$toJSON:(NSString *)key {
    return self;
}

- (NSString *) cy$toCYON {
    return @"undefined";
}

- (JSValueRef) cy$JSValueInContext:(JSContextRef)context { CYObjectiveTry {
    return CYJSUndefined(context);
} CYObjectiveCatch }

@end
/* }}} */

static bool CYIsClass(id self) {
    // XXX: this is a lame object_isClass
    return class_getInstanceMethod(object_getClass(self), @selector(alloc)) != NULL;
}

Class CYCastClass(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    id self(CYCastNSObject(pool, context, value));
    if (CYIsClass(self))
        return (Class) self;
    throw CYError(context, "got something that is not a Class");
    return NULL;
}

NSArray *CYCastNSArray(JSPropertyNameArrayRef names) {
    CYPool pool;
    size_t size(JSPropertyNameArrayGetCount(names));
    NSMutableArray *array([NSMutableArray arrayWithCapacity:size]);
    for (size_t index(0); index != size; ++index)
        [array addObject:CYCastNSString(pool, JSPropertyNameArrayGetNameAtIndex(names, index))];
    return array;
}

JSValueRef CYCastJSValue(JSContextRef context, id value) { CYPoolTry {
    if (value == nil)
        return CYJSNull(context);
    else if ([value respondsToSelector:@selector(cy$JSValueInContext:)])
        return [value cy$JSValueInContext:context];
    else
        return CYMakeInstance(context, value, false);
} CYPoolCatch(NULL) }

@implementation CYJSObject

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context { CYObjectiveTry {
    if ((self = [super init]) != nil) {
        object_ = object;
        context_ = context;
        JSValueProtect(context_, object_);
    } return self;
} CYObjectiveCatch }

- (void) dealloc { CYObjectiveTry {
    JSValueUnprotect(context_, object_);
    [super dealloc];
} CYObjectiveCatch }

- (NSObject *) cy$toJSON:(NSString *)key { CYObjectiveTry {
    JSValueRef toJSON(CYGetProperty(context_, object_, toJSON_));
    if (!CYIsCallable(context_, toJSON))
        return [super cy$toJSON:key];
    else {
        JSValueRef arguments[1] = {CYCastJSValue(context_, key)};
        JSValueRef value(CYCallAsFunction(context_, (JSObjectRef) toJSON, object_, 1, arguments));
        // XXX: do I really want an NSNull here?!
        return CYCastNSObject(NULL, context_, value) ?: [NSNull null];
    }
} CYObjectiveCatch }

- (NSString *) cy$toCYON { CYObjectiveTry {
    CYPool pool;
    JSValueRef exception(NULL);
    const char *cyon(CYPoolCCYON(pool, context_, object_));
    CYThrow(context_, exception);
    if (cyon == NULL)
        return [super cy$toCYON];
    else
        return [NSString stringWithUTF8String:cyon];
} CYObjectiveCatch }

- (NSUInteger) count { CYObjectiveTry {
    JSPropertyNameArrayRef names(JSObjectCopyPropertyNames(context_, object_));
    size_t size(JSPropertyNameArrayGetCount(names));
    JSPropertyNameArrayRelease(names);
    return size;
} CYObjectiveCatch }

- (id) objectForKey:(id)key { CYObjectiveTry {
    JSValueRef value(CYGetProperty(context_, object_, CYJSString(key)));
    if (JSValueIsUndefined(context_, value))
        return nil;
    return CYCastNSObject(NULL, context_, value) ?: [NSNull null];
} CYObjectiveCatch }

- (NSEnumerator *) keyEnumerator { CYObjectiveTry {
    JSPropertyNameArrayRef names(JSObjectCopyPropertyNames(context_, object_));
    NSEnumerator *enumerator([CYCastNSArray(names) objectEnumerator]);
    JSPropertyNameArrayRelease(names);
    return enumerator;
} CYObjectiveCatch }

- (void) setObject:(id)object forKey:(id)key { CYObjectiveTry {
    CYSetProperty(context_, object_, CYJSString(key), CYCastJSValue(context_, object));
} CYObjectiveCatch }

- (void) removeObjectForKey:(id)key { CYObjectiveTry {
    JSValueRef exception(NULL);
    (void) JSObjectDeleteProperty(context_, object_, CYJSString(key), &exception);
    CYThrow(context_, exception);
} CYObjectiveCatch }

@end

@implementation CYJSArray

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context { CYObjectiveTry {
    if ((self = [super init]) != nil) {
        object_ = object;
        context_ = context;
        JSValueProtect(context_, object_);
    } return self;
} CYObjectiveCatch }

- (void) dealloc { CYObjectiveTry {
    JSValueUnprotect(context_, object_);
    [super dealloc];
} CYObjectiveCatch }

- (NSUInteger) count { CYObjectiveTry {
    return CYCastDouble(context_, CYGetProperty(context_, object_, length_));
} CYObjectiveCatch }

- (id) objectAtIndex:(NSUInteger)index { CYObjectiveTry {
    size_t bounds([self count]);
    if (index >= bounds)
        @throw [NSException exceptionWithName:NSRangeException reason:[NSString stringWithFormat:@"*** -[CYJSArray objectAtIndex:]: index (%zu) beyond bounds (%zu)", index, bounds] userInfo:nil];
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetPropertyAtIndex(context_, object_, index, &exception));
    CYThrow(context_, exception);
    return CYCastNSObject(NULL, context_, value) ?: [NSNull null];
} CYObjectiveCatch }

- (void) addObject:(id)object { CYObjectiveTry {
    JSValueRef exception(NULL);
    JSValueRef arguments[1];
    arguments[0] = CYCastJSValue(context_, object);
    JSObjectCallAsFunction(context_, Array_push_, object_, 1, arguments, &exception);
    CYThrow(context_, exception);
} CYObjectiveCatch }

- (void) insertObject:(id)object atIndex:(NSUInteger)index { CYObjectiveTry {
    size_t bounds([self count] + 1);
    if (index >= bounds)
        @throw [NSException exceptionWithName:NSRangeException reason:[NSString stringWithFormat:@"*** -[CYJSArray insertObject:atIndex:]: index (%zu) beyond bounds (%zu)", index, bounds] userInfo:nil];
    JSValueRef exception(NULL);
    JSValueRef arguments[3];
    arguments[0] = CYCastJSValue(context_, index);
    arguments[1] = CYCastJSValue(context_, 0);
    arguments[2] = CYCastJSValue(context_, object);
    JSObjectCallAsFunction(context_, Array_splice_, object_, 3, arguments, &exception);
    CYThrow(context_, exception);
} CYObjectiveCatch }

- (void) removeLastObject { CYObjectiveTry {
    JSValueRef exception(NULL);
    JSObjectCallAsFunction(context_, Array_pop_, object_, 0, NULL, &exception);
    CYThrow(context_, exception);
} CYObjectiveCatch }

- (void) removeObjectAtIndex:(NSUInteger)index { CYObjectiveTry {
    size_t bounds([self count]);
    if (index >= bounds)
        @throw [NSException exceptionWithName:NSRangeException reason:[NSString stringWithFormat:@"*** -[CYJSArray removeObjectAtIndex:]: index (%zu) beyond bounds (%zu)", index, bounds] userInfo:nil];
    JSValueRef exception(NULL);
    JSValueRef arguments[2];
    arguments[0] = CYCastJSValue(context_, index);
    arguments[1] = CYCastJSValue(context_, 1);
    JSObjectCallAsFunction(context_, Array_splice_, object_, 2, arguments, &exception);
    CYThrow(context_, exception);
} CYObjectiveCatch }

- (void) replaceObjectAtIndex:(NSUInteger)index withObject:(id)object { CYObjectiveTry {
    size_t bounds([self count]);
    if (index >= bounds)
        @throw [NSException exceptionWithName:NSRangeException reason:[NSString stringWithFormat:@"*** -[CYJSArray replaceObjectAtIndex:withObject:]: index (%zu) beyond bounds (%zu)", index, bounds] userInfo:nil];
    CYSetProperty(context_, object_, index, CYCastJSValue(context_, object));
} CYObjectiveCatch }

@end

// XXX: use objc_getAssociatedObject and objc_setAssociatedObject on 10.6
struct CYInternal :
    CYData
{
    JSObjectRef object_;

    CYInternal() :
        object_(NULL)
    {
    }

    ~CYInternal() {
        // XXX: delete object_? ;(
    }

    static CYInternal *Get(id self) {
        CYInternal *internal(NULL);
        if (object_getInstanceVariable(self, "cy$internal_", reinterpret_cast<void **>(&internal)) == NULL) {
            // XXX: do something epic? ;P
        }

        return internal;
    }

    static CYInternal *Set(id self) {
        CYInternal *internal(NULL);
        if (Ivar ivar = object_getInstanceVariable(self, "cy$internal_", reinterpret_cast<void **>(&internal))) {
            if (internal == NULL) {
                internal = new CYInternal();
                object_setIvar(self, ivar, reinterpret_cast<id>(internal));
            }
        } else {
            // XXX: do something epic? ;P
        }

        return internal;
    }

    bool HasProperty(JSContextRef context, JSStringRef name) {
        if (object_ == NULL)
            return false;
        return JSObjectHasProperty(context, object_, name);
    }

    JSValueRef GetProperty(JSContextRef context, JSStringRef name) {
        if (object_ == NULL)
            return NULL;
        return CYGetProperty(context, object_, name);
    }

    void SetProperty(JSContextRef context, JSStringRef name, JSValueRef value) {
        if (object_ == NULL)
            object_ = JSObjectMake(context, NULL, NULL);
        CYSetProperty(context, object_, name, value);
    }
};

static JSObjectRef CYMakeSelector(JSContextRef context, SEL sel) {
    Selector_privateData *internal(new Selector_privateData(sel));
    return JSObjectMake(context, Selector_, internal);
}

static SEL CYCastSEL(JSContextRef context, JSValueRef value) {
    if (JSValueIsObjectOfClass(context, value, Selector_)) {
        Selector_privateData *internal(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate((JSObjectRef) value)));
        return reinterpret_cast<SEL>(internal->value_);
    } else
        return CYCastPointer<SEL>(context, value);
}

void *CYObjectiveC_ExecuteStart() {
    return (void *) [[NSAutoreleasePool alloc] init];
}

void CYObjectiveC_ExecuteEnd(void *handle) {
    return [(NSAutoreleasePool *) handle release];
}

JSValueRef CYObjectiveC_RuntimeProperty(JSContextRef context, CYUTF8String name) {
    if (name == "nil")
        return Instance::Make(context, nil);
    if (Class _class = objc_getClass(name.data))
        return CYMakeInstance(context, _class, true);
    return NULL;
}

static bool CYObjectiveC_PoolFFI(apr_pool_t *pool, JSContextRef context, sig::Type *type, ffi_type *ffi, void *data, JSValueRef value) {
    switch (type->primitive) {
        case sig::object_P:
        case sig::typename_P:
            *reinterpret_cast<id *>(data) = CYCastNSObject(pool, context, value);
        break;

        case sig::selector_P:
            *reinterpret_cast<SEL *>(data) = CYCastSEL(context, value);
        break;

        default:
            return false;
    }

    return true;
}

static JSValueRef CYObjectiveC_FromFFI(JSContextRef context, sig::Type *type, ffi_type *ffi, void *data, bool initialize, JSObjectRef owner) {
    switch (type->primitive) {
        case sig::object_P:
            if (id object = *reinterpret_cast<id *>(data)) {
                JSValueRef value(CYCastJSValue(context, object));
                if (initialize)
                    [object release];
                return value;
            } else goto null;

        case sig::typename_P:
            return CYMakeInstance(context, *reinterpret_cast<Class *>(data), true);

        case sig::selector_P:
            if (SEL sel = *reinterpret_cast<SEL *>(data))
                return CYMakeSelector(context, sel);
            else goto null;

        null:
            return CYJSNull(context);
        default:
            return NULL;
    }
}

CYHooks CYObjectiveCHooks = {
    &CYObjectiveC_ExecuteStart,
    &CYObjectiveC_ExecuteEnd,
    &CYObjectiveC_RuntimeProperty,
    &CYObjectiveC_PoolFFI,
    &CYObjectiveC_FromFFI,
};

static bool CYImplements(id object, Class _class, SEL selector, bool devoid) {
    if (objc_method *method = class_getInstanceMethod(_class, selector)) {
        if (!devoid)
            return true;
        char type[16];
        method_getReturnType(method, type, sizeof(type));
        if (type[0] != 'v')
            return true;
    }

    // XXX: possibly use a more "awesome" check?
    return false;
}

static const char *CYPoolTypeEncoding(apr_pool_t *pool, JSContextRef context, Class _class, SEL sel, objc_method *method) {
    if (method != NULL)
        return method_getTypeEncoding(method);

    const char *name(sel_getName(sel));

    sqlite3_stmt *statement;

    _sqlcall(sqlite3_prepare(Bridge_,
        "select "
            "\"bridge\".\"mode\", "
            "\"bridge\".\"value\" "
        "from \"bridge\" "
        "where"
            " \"bridge\".\"mode\" in (3, 4) and"
            " \"bridge\".\"name\" = ?"
        " limit 1"
    , -1, &statement, NULL));

    _sqlcall(sqlite3_bind_text(statement, 1, name, -1, SQLITE_STATIC));

    int mode;
    const char *value;

    if (_sqlcall(sqlite3_step(statement)) == SQLITE_DONE) {
        mode = -1;
        value = NULL;
    } else {
        mode = sqlite3_column_int(statement, 0);
        value = sqlite3_column_pooled(pool, statement, 1);
    }

    _sqlcall(sqlite3_finalize(statement));

    if (value != NULL)
        return value;

    return NULL;
}

static void MessageClosure_(ffi_cif *cif, void *result, void **arguments, void *arg) {
    Closure_privateData *internal(reinterpret_cast<Closure_privateData *>(arg));

    JSContextRef context(internal->context_);

    size_t count(internal->cif_.nargs);
    JSValueRef values[count];

    for (size_t index(0); index != count; ++index)
        values[index] = CYFromFFI(context, internal->signature_.elements[1 + index].type, internal->cif_.arg_types[index], arguments[index]);

    JSObjectRef _this(CYCastJSObject(context, values[0]));

    JSValueRef value(CYCallAsFunction(context, internal->function_, _this, count - 2, values + 2));
    CYPoolFFI(NULL, context, internal->signature_.elements[0].type, internal->cif_.rtype, result, value);
}

static JSObjectRef CYMakeMessage(JSContextRef context, SEL sel, IMP imp, const char *type) {
    Message_privateData *internal(new Message_privateData(sel, type, imp));
    return JSObjectMake(context, Message_, internal);
}

static IMP CYMakeMessage(JSContextRef context, JSValueRef value, const char *type) {
    JSObjectRef function(CYCastJSObject(context, value));
    Closure_privateData *internal(CYMakeFunctor_(context, function, type, &MessageClosure_));
    return reinterpret_cast<IMP>(internal->GetValue());
}

static bool Messages_hasProperty(JSContextRef context, JSObjectRef object, JSStringRef property) {
    Messages *internal(reinterpret_cast<Messages *>(JSObjectGetPrivate(object)));
    Class _class(internal->GetValue());

    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));

    if (SEL sel = sel_getUid(name))
        if (class_getInstanceMethod(_class, sel) != NULL)
            return true;

    return false;
}

static JSValueRef Messages_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    Messages *internal(reinterpret_cast<Messages *>(JSObjectGetPrivate(object)));
    Class _class(internal->GetValue());

    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));

    if (SEL sel = sel_getUid(name))
        if (objc_method *method = class_getInstanceMethod(_class, sel))
            return CYMakeMessage(context, sel, method_getImplementation(method), method_getTypeEncoding(method));

    return NULL;
}

static bool Messages_setProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) {
    Messages *internal(reinterpret_cast<Messages *>(JSObjectGetPrivate(object)));
    Class _class(internal->GetValue());

    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));

    SEL sel(sel_registerName(name));

    objc_method *method(class_getInstanceMethod(_class, sel));

    const char *type;
    IMP imp;

    if (JSValueIsObjectOfClass(context, value, Message_)) {
        Message_privateData *message(reinterpret_cast<Message_privateData *>(JSObjectGetPrivate((JSObjectRef) value)));
        type = sig::Unparse(pool, &message->signature_);
        imp = reinterpret_cast<IMP>(message->GetValue());
    } else {
        type = CYPoolTypeEncoding(pool, context, _class, sel, method);
        imp = CYMakeMessage(context, value, type);
    }

    if (method != NULL)
        method_setImplementation(method, imp);
    else
        class_replaceMethod(_class, sel, imp, type);

    return true;
}

#if !__OBJC2__
static bool Messages_deleteProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    Messages *internal(reinterpret_cast<Messages *>(JSObjectGetPrivate(object)));
    Class _class(internal->GetValue());

    CYPool pool;
    const char *name(CYPoolCString(pool, property));

    if (SEL sel = sel_getUid(name))
        if (objc_method *method = class_getInstanceMethod(_class, sel)) {
            objc_method_list list = {NULL, 1, {method}};
            class_removeMethods(_class, &list);
            return true;
        }

    return false;
}
#endif

static void Messages_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    Messages *internal(reinterpret_cast<Messages *>(JSObjectGetPrivate(object)));
    Class _class(internal->GetValue());

    unsigned int size;
    objc_method **data(class_copyMethodList(_class, &size));
    for (size_t i(0); i != size; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(sel_getName(method_getName(data[i]))));
    free(data);
}

static bool Instance_hasProperty(JSContextRef context, JSObjectRef object, JSStringRef property) {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    if (JSStringIsEqualToUTF8CString(property, "$cyi"))
        return true;

    CYPool pool;
    NSString *name(CYCastNSString(pool, property));

    if (CYInternal *internal = CYInternal::Get(self))
        if (internal->HasProperty(context, property))
            return true;

    Class _class(object_getClass(self));

    CYPoolTry {
        // XXX: this is an evil hack to deal with NSProxy; fix elsewhere
        if (CYImplements(self, _class, @selector(cy$hasProperty:), false))
            if ([self cy$hasProperty:name])
                return true;
    } CYPoolCatch(false)

    const char *string(CYPoolCString(pool, context, name));

    if (class_getProperty(_class, string) != NULL)
        return true;

    if (SEL sel = sel_getUid(string))
        if (CYImplements(self, _class, sel, true))
            return true;

    return false;
}

static JSValueRef Instance_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    if (JSStringIsEqualToUTF8CString(property, "$cyi"))
        return Internal::Make(context, self, object);

    CYPool pool;
    NSString *name(CYCastNSString(pool, property));

    if (CYInternal *internal = CYInternal::Get(self))
        if (JSValueRef value = internal->GetProperty(context, property))
            return value;

    CYPoolTry {
        if (NSObject *data = [self cy$getProperty:name])
            return CYCastJSValue(context, data);
    } CYPoolCatch(NULL)

    const char *string(CYPoolCString(pool, context, name));
    Class _class(object_getClass(self));

#ifdef __APPLE__
    if (objc_property_t property = class_getProperty(_class, string)) {
        PropertyAttributes attributes(property);
        SEL sel(sel_registerName(attributes.Getter()));
        return CYSendMessage(pool, context, self, NULL, sel, 0, NULL, false, exception);
    }
#endif

    if (SEL sel = sel_getUid(string))
        if (CYImplements(self, _class, sel, true))
            return CYSendMessage(pool, context, self, NULL, sel, 0, NULL, false, exception);

    return NULL;
} CYCatch }

static bool Instance_setProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    CYPool pool;

    NSString *name(CYCastNSString(pool, property));
    NSObject *data(CYCastNSObject(pool, context, value));

    CYPoolTry {
        if ([self cy$setProperty:name to:data])
            return true;
    } CYPoolCatch(NULL)

    const char *string(CYPoolCString(pool, context, name));
    Class _class(object_getClass(self));

#ifdef __APPLE__
    if (objc_property_t property = class_getProperty(_class, string)) {
        PropertyAttributes attributes(property);
        if (const char *setter = attributes.Setter()) {
            SEL sel(sel_registerName(setter));
            JSValueRef arguments[1] = {value};
            CYSendMessage(pool, context, self, NULL, sel, 1, arguments, false, exception);
            return true;
        }
    }
#endif

    size_t length(strlen(string));

    char set[length + 5];

    set[0] = 's';
    set[1] = 'e';
    set[2] = 't';

    if (string[0] != '\0') {
        set[3] = toupper(string[0]);
        memcpy(set + 4, string + 1, length - 1);
    }

    set[length + 3] = ':';
    set[length + 4] = '\0';

    if (SEL sel = sel_getUid(set))
        if (CYImplements(self, _class, sel, false)) {
            JSValueRef arguments[1] = {value};
            CYSendMessage(pool, context, self, NULL, sel, 1, arguments, false, exception);
        }

    if (CYInternal *internal = CYInternal::Set(self)) {
        internal->SetProperty(context, property, value);
        return true;
    }

    return false;
} CYCatch }

static bool Instance_deleteProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    CYPoolTry {
        NSString *name(CYCastNSString(NULL, property));
        return [self cy$deleteProperty:name];
    } CYPoolCatch(NULL)
} CYCatch }

static void Instance_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    CYPool pool;
    Class _class(object_getClass(self));

#ifdef __APPLE__
    {
        unsigned int size;
        objc_property_t *data(class_copyPropertyList(_class, &size));
        for (size_t i(0); i != size; ++i)
            JSPropertyNameAccumulatorAddName(names, CYJSString(property_getName(data[i])));
        free(data);
    }
#endif
}

static JSObjectRef Instance_callAsConstructor(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    JSObjectRef value(Instance::Make(context, [internal->GetValue() alloc], Instance::Uninitialized));
    return value;
} CYCatch }

static bool Instance_hasInstance(JSContextRef context, JSObjectRef constructor, JSValueRef instance, JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate((JSObjectRef) constructor)));
    Class _class(internal->GetValue());
    if (!CYIsClass(_class))
        return false;

    if (JSValueIsObjectOfClass(context, instance, Instance_)) {
        Instance *linternal(reinterpret_cast<Instance *>(JSObjectGetPrivate((JSObjectRef) instance)));
        // XXX: this isn't always safe
        return [linternal->GetValue() isKindOfClass:_class];
    }

    return false;
} CYCatch }

static bool Internal_hasProperty(JSContextRef context, JSObjectRef object, JSStringRef property) {
    Internal *internal(reinterpret_cast<Internal *>(JSObjectGetPrivate(object)));
    CYPool pool;

    id self(internal->GetValue());
    const char *name(CYPoolCString(pool, context, property));

    if (object_getInstanceVariable(self, name, NULL) != NULL)
        return true;

    return false;
}

static JSValueRef Internal_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    Internal *internal(reinterpret_cast<Internal *>(JSObjectGetPrivate(object)));
    CYPool pool;

    id self(internal->GetValue());
    const char *name(CYPoolCString(pool, context, property));

    if (Ivar ivar = object_getInstanceVariable(self, name, NULL)) {
        Type_privateData type(pool, ivar_getTypeEncoding(ivar));
        return CYFromFFI(context, type.type_, type.GetFFI(), reinterpret_cast<uint8_t *>(self) + ivar_getOffset(ivar));
    }

    return NULL;
} CYCatch }

static bool Internal_setProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) { CYTry {
    Internal *internal(reinterpret_cast<Internal *>(JSObjectGetPrivate(object)));
    CYPool pool;

    id self(internal->GetValue());
    const char *name(CYPoolCString(pool, context, property));

    if (Ivar ivar = object_getInstanceVariable(self, name, NULL)) {
        Type_privateData type(pool, ivar_getTypeEncoding(ivar));
        CYPoolFFI(pool, context, type.type_, type.GetFFI(), reinterpret_cast<uint8_t *>(self) + ivar_getOffset(ivar), value);
        return true;
    }

    return false;
} CYCatch }

static void Internal_getPropertyNames_(Class _class, JSPropertyNameAccumulatorRef names) {
    if (Class super = class_getSuperclass(_class))
        Internal_getPropertyNames_(super, names);

    unsigned int size;
    Ivar *data(class_copyIvarList(_class, &size));
    for (size_t i(0); i != size; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(ivar_getName(data[i])));
    free(data);
}

static void Internal_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    Internal *internal(reinterpret_cast<Internal *>(JSObjectGetPrivate(object)));
    CYPool pool;

    id self(internal->GetValue());
    Class _class(object_getClass(self));

    Internal_getPropertyNames_(_class, names);
}

static JSValueRef Internal_callAsFunction_$cya(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    Internal *internal(reinterpret_cast<Internal *>(JSObjectGetPrivate(object)));
    return internal->GetOwner();
}

static JSValueRef ObjectiveC_Classes_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    CYPool pool;
    NSString *name(CYCastNSString(pool, property));
    if (Class _class = NSClassFromString(name))
        return CYMakeInstance(context, _class, true);
    return NULL;
} CYCatch }

static void ObjectiveC_Classes_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    size_t size(objc_getClassList(NULL, 0));
    Class *data(reinterpret_cast<Class *>(malloc(sizeof(Class) * size)));

  get:
    size_t writ(objc_getClassList(data, size));
    if (size < writ) {
        size = writ;
        if (Class *copy = reinterpret_cast<Class *>(realloc(data, sizeof(Class) * writ))) {
            data = copy;
            goto get;
        } else goto done;
    }

    for (size_t i(0); i != writ; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(class_getName(data[i])));

  done:
    free(data);
}

static JSValueRef ObjectiveC_Image_Classes_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    const char *internal(reinterpret_cast<const char *>(JSObjectGetPrivate(object)));

    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));
    unsigned int size;
    const char **data(objc_copyClassNamesForImage(internal, &size));
    JSValueRef value;
    for (size_t i(0); i != size; ++i)
        if (strcmp(name, data[i]) == 0) {
            if (Class _class = objc_getClass(name)) {
                value = CYMakeInstance(context, _class, true);
                goto free;
            } else
                break;
        }
    value = NULL;
  free:
    free(data);
    return value;
} CYCatch }

static void ObjectiveC_Image_Classes_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    const char *internal(reinterpret_cast<const char *>(JSObjectGetPrivate(object)));
    unsigned int size;
    const char **data(objc_copyClassNamesForImage(internal, &size));
    for (size_t i(0); i != size; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(data[i]));
    free(data);
}

static JSValueRef ObjectiveC_Images_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));
    unsigned int size;
    const char **data(objc_copyImageNames(&size));
    for (size_t i(0); i != size; ++i)
        if (strcmp(name, data[i]) == 0) {
            name = data[i];
            goto free;
        }
    name = NULL;
  free:
    free(data);
    if (name == NULL)
        return NULL;
    JSObjectRef value(JSObjectMake(context, NULL, NULL));
    CYSetProperty(context, value, CYJSString("classes"), JSObjectMake(context, ObjectiveC_Image_Classes_, const_cast<char *>(name)));
    return value;
} CYCatch }

static void ObjectiveC_Images_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    unsigned int size;
    const char **data(objc_copyImageNames(&size));
    for (size_t i(0); i != size; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(data[i]));
    free(data);
}

static JSValueRef ObjectiveC_Protocols_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    CYPool pool;
    NSString *name(CYCastNSString(pool, property));
    if (Protocol *protocol = NSProtocolFromString(name))
        return CYMakeInstance(context, protocol, true);
    return NULL;
} CYCatch }

static void ObjectiveC_Protocols_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    unsigned int size;
    Protocol **data(objc_copyProtocolList(&size));
    for (size_t i(0); i != size; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(protocol_getName(data[i])));
    free(data);
}

static bool stret(ffi_type *ffi_type) {
    return ffi_type->type == FFI_TYPE_STRUCT && (
        ffi_type->size > OBJC_MAX_STRUCT_BY_VALUE ||
        struct_forward_array[ffi_type->size] != 0
    );
}

JSValueRef CYSendMessage(apr_pool_t *pool, JSContextRef context, id self, Class _class, SEL _cmd, size_t count, const JSValueRef arguments[], bool initialize, JSValueRef *exception) { CYTry {
    const char *type;

    if (_class == NULL)
        _class = object_getClass(self);

    if (objc_method *method = class_getInstanceMethod(_class, _cmd))
        type = method_getTypeEncoding(method);
    else {
        CYPoolTry {
            NSMethodSignature *method([self methodSignatureForSelector:_cmd]);
            if (method == nil)
                throw CYError(context, "unrecognized selector %s sent to object %p", sel_getName(_cmd), self);
            type = CYPoolCString(pool, context, [method _typeString]);
        } CYPoolCatch(NULL)
    }

    objc_super super = {self, _class};
    void *arg0 = &super;

    void *setup[2];
    setup[0] = &arg0;
    setup[1] = &_cmd;

    sig::Signature signature;
    sig::Parse(pool, &signature, type, &Structor_);

    ffi_cif cif;
    sig::sig_ffi_cif(pool, &sig::ObjectiveC, &signature, &cif);

    void (*function)() = stret(cif.rtype) ? reinterpret_cast<void (*)()>(&objc_msgSendSuper_stret) : reinterpret_cast<void (*)()>(&objc_msgSendSuper);
    return CYCallFunction(pool, context, 2, setup, count, arguments, initialize, exception, &signature, &cif, function);
} CYCatch }

static JSValueRef $objc_msgSend(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count < 2)
        throw CYError(context, "too few arguments to objc_msgSend");

    CYPool pool;

    bool uninitialized;

    id self;
    SEL _cmd;
    Class _class;

    if (JSValueIsObjectOfClass(context, arguments[0], Super_)) {
        cy::Super *internal(reinterpret_cast<cy::Super *>(JSObjectGetPrivate((JSObjectRef) arguments[0])));
        self = internal->GetValue();
        _class = internal->class_;;
        uninitialized = false;
    } else if (JSValueIsObjectOfClass(context, arguments[0], Instance_)) {
        Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate((JSObjectRef) arguments[0])));
        self = internal->GetValue();
        _class = nil;
        uninitialized = internal->IsUninitialized();
        if (uninitialized)
            internal->value_ = nil;
    } else {
        self = CYCastNSObject(pool, context, arguments[0]);
        _class = nil;
        uninitialized = false;
    }

    if (self == nil)
        return CYJSNull(context);

    _cmd = CYCastSEL(context, arguments[1]);

    return CYSendMessage(pool, context, self, _class, _cmd, count - 2, arguments + 2, uninitialized, exception);
} CYCatch }

/* Hook: objc_registerClassPair {{{ */
// XXX: replace this with associated objects

MSHook(void, CYDealloc, id self, SEL sel) {
    CYInternal *internal;
    object_getInstanceVariable(self, "cy$internal_", reinterpret_cast<void **>(&internal));
    if (internal != NULL)
        delete internal;
    _CYDealloc(self, sel);
}

MSHook(void, objc_registerClassPair, Class _class) {
    Class super(class_getSuperclass(_class));
    if (super == NULL || class_getInstanceVariable(super, "cy$internal_") == NULL) {
        class_addIvar(_class, "cy$internal_", sizeof(CYInternal *), log2(sizeof(CYInternal *)), "^{CYInternal}");
        MSHookMessage(_class, @selector(dealloc), MSHake(CYDealloc));
    }

    _objc_registerClassPair(_class);
}

static JSValueRef objc_registerClassPair_(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 1)
        throw CYError(context, "incorrect number of arguments to objc_registerClassPair");
    CYPool pool;
    NSObject *value(CYCastNSObject(pool, context, arguments[0]));
    if (value == NULL || !CYIsClass(value))
        throw CYError(context, "incorrect number of arguments to objc_registerClassPair");
    Class _class((Class) value);
    $objc_registerClassPair(_class);
    return CYJSUndefined(context);
} CYCatch }
/* }}} */

static JSValueRef Selector_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    JSValueRef setup[count + 2];
    setup[0] = _this;
    setup[1] = object;
    memcpy(setup + 2, arguments, sizeof(JSValueRef) * count);
    return $objc_msgSend(context, NULL, NULL, count + 2, setup, exception);
}

static JSValueRef Message_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYPool pool;
    Message_privateData *internal(reinterpret_cast<Message_privateData *>(JSObjectGetPrivate(object)));

    // XXX: handle Instance::Uninitialized?
    id self(CYCastNSObject(pool, context, _this));

    void *setup[2];
    setup[0] = &self;
    setup[1] = &internal->sel_;

    return CYCallFunction(pool, context, 2, setup, count, arguments, false, exception, &internal->signature_, &internal->cif_, internal->GetValue());
}

static JSObjectRef Super_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 2)
        throw CYError(context, "incorrect number of arguments to Super constructor");
    CYPool pool;
    id self(CYCastNSObject(pool, context, arguments[0]));
    Class _class(CYCastClass(pool, context, arguments[1]));
    return cy::Super::Make(context, self, _class);
} CYCatch }

static JSObjectRef Selector_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 1)
        throw CYError(context, "incorrect number of arguments to Selector constructor");
    const char *name(CYCastCString(context, arguments[0]));
    return CYMakeSelector(context, sel_registerName(name));
} CYCatch }

static JSObjectRef Instance_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count > 1)
        throw CYError(context, "incorrect number of arguments to Instance constructor");
    id self(count == 0 ? nil : CYCastPointer<id>(context, arguments[0]));
    return Instance::Make(context, self);
} CYCatch }

static JSValueRef CYValue_getProperty_value(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    CYValue *internal(reinterpret_cast<CYValue *>(JSObjectGetPrivate(object)));
    return CYCastJSValue(context, reinterpret_cast<uintptr_t>(internal->value_));
}

static JSValueRef CYValue_callAsFunction_$cya(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYValue *internal(reinterpret_cast<CYValue *>(JSObjectGetPrivate(_this)));
    Type_privateData *typical(internal->GetType());

    sig::Type *type;
    ffi_type *ffi;

    if (typical == NULL) {
        type = NULL;
        ffi = NULL;
    } else {
        type = typical->type_;
        ffi = typical->ffi_;
    }

    return CYMakePointer(context, &internal->value_, type, ffi, object);
}

static JSValueRef Instance_getProperty_constructor(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    return Instance::Make(context, object_getClass(internal->GetValue()));
}

static JSValueRef Instance_getProperty_protocol(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());
    if (!CYIsClass(self))
        return CYJSUndefined(context);
    return CYGetClassPrototype(context, self);
} CYCatch }

static JSValueRef Instance_getProperty_messages(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());
    if (class_getInstanceMethod(object_getClass(self), @selector(alloc)) == NULL)
        return CYJSUndefined(context);
    return Messages::Make(context, self);
}

static JSValueRef Instance_callAsFunction_toCYON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (!JSValueIsObjectOfClass(context, _this, Instance_))
        return NULL;

    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(_this)));
    return CYCastJSValue(context, CYJSString(CYCastNSCYON(internal->GetValue())));
} CYCatch }

static JSValueRef Instance_callAsFunction_toJSON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (!JSValueIsObjectOfClass(context, _this, Instance_))
        return NULL;

    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(_this)));

    CYPoolTry {
        NSString *key(count == 0 ? nil : CYCastNSString(NULL, CYJSString(context, arguments[0])));
        // XXX: check for support of cy$toJSON?
        return CYCastJSValue(context, CYJSString([internal->GetValue() cy$toJSON:key]));
    } CYPoolCatch(NULL)
} CYCatch }

static JSValueRef Instance_callAsFunction_toString(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (!JSValueIsObjectOfClass(context, _this, Instance_))
        return NULL;

    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(_this)));

    CYPoolTry {
        // XXX: this seems like a stupid implementation; what if it crashes? why not use the CYONifier backend?
        return CYCastJSValue(context, CYJSString([internal->GetValue() description]));
    } CYPoolCatch(NULL)
} CYCatch }

static JSValueRef Selector_callAsFunction_toString(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    Selector_privateData *internal(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate(_this)));
    return CYCastJSValue(context, sel_getName(internal->GetValue()));
} CYCatch }

static JSValueRef Selector_callAsFunction_toJSON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    return Selector_callAsFunction_toString(context, object, _this, count, arguments, exception);
}

static JSValueRef Selector_callAsFunction_toCYON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    Selector_privateData *internal(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate(_this)));
    const char *name(sel_getName(internal->GetValue()));

    CYPoolTry {
        return CYCastJSValue(context, CYJSString([NSString stringWithFormat:@"@selector(%s)", name]));
    } CYPoolCatch(NULL)
} CYCatch }

static JSValueRef Selector_callAsFunction_type(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 1)
        throw CYError(context, "incorrect number of arguments to Selector.type");
    CYPool pool;
    Selector_privateData *internal(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate(_this)));
    if (Class _class = CYCastClass(pool, context, arguments[0])) {
        SEL sel(internal->GetValue());
        if (objc_method *method = class_getInstanceMethod(_class, sel))
            if (const char *type = CYPoolTypeEncoding(pool, context, _class, sel, method))
                return CYCastJSValue(context, CYJSString(type));
    }

    // XXX: do a lookup of some kind
    return CYJSNull(context);
} CYCatch }

static JSStaticValue Selector_staticValues[2] = {
    {"value", &CYValue_getProperty_value, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete},
    {NULL, NULL, NULL, 0}
};

static JSStaticValue Instance_staticValues[5] = {
    {"constructor", &Instance_getProperty_constructor, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"messages", &Instance_getProperty_messages, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"prototype", &Instance_getProperty_protocol, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"value", &CYValue_getProperty_value, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, NULL, 0}
};

static JSStaticFunction Instance_staticFunctions[5] = {
    {"$cya", &CYValue_callAsFunction_$cya, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toCYON", &Instance_callAsFunction_toCYON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toJSON", &Instance_callAsFunction_toJSON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toString", &Instance_callAsFunction_toString, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

static JSStaticFunction Internal_staticFunctions[2] = {
    {"$cya", &Internal_callAsFunction_$cya, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

static JSStaticFunction Selector_staticFunctions[5] = {
    {"toCYON", &Selector_callAsFunction_toCYON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toJSON", &Selector_callAsFunction_toJSON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toString", &Selector_callAsFunction_toString, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"type", &Selector_callAsFunction_type, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

void CYObjectiveC(JSContextRef context, JSObjectRef global) {
    hooks_ = &CYObjectiveCHooks;

    Object_type = new(Pool_) Type_privateData(Pool_, "@");
    Selector_type = new(Pool_) Type_privateData(Pool_, ":");

#ifdef __APPLE__
    NSCFBoolean_ = objc_getClass("NSCFBoolean");
    NSCFType_ = objc_getClass("NSCFType");
#endif

    NSArray_ = objc_getClass("NSArray");
    NSDictionary_ = objc_getClass("NSDictonary");
    NSMessageBuilder_ = objc_getClass("NSMessageBuilder");
    NSZombie_ = objc_getClass("_NSZombie_");
    Object_ = objc_getClass("Object");

    JSClassDefinition definition;

    definition = kJSClassDefinitionEmpty;
    definition.className = "Instance";
    definition.staticValues = Instance_staticValues;
    definition.staticFunctions = Instance_staticFunctions;
    definition.hasProperty = &Instance_hasProperty;
    definition.getProperty = &Instance_getProperty;
    definition.setProperty = &Instance_setProperty;
    definition.deleteProperty = &Instance_deleteProperty;
    definition.getPropertyNames = &Instance_getPropertyNames;
    definition.callAsConstructor = &Instance_callAsConstructor;
    definition.hasInstance = &Instance_hasInstance;
    definition.finalize = &Finalize;
    Instance_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Internal";
    definition.staticFunctions = Internal_staticFunctions;
    definition.hasProperty = &Internal_hasProperty;
    definition.getProperty = &Internal_getProperty;
    definition.setProperty = &Internal_setProperty;
    definition.getPropertyNames = &Internal_getPropertyNames;
    definition.finalize = &Finalize;
    Internal_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Message";
    definition.staticFunctions = Functor_staticFunctions;
    definition.callAsFunction = &Message_callAsFunction;
    definition.finalize = &Finalize;
    Message_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Messages";
    definition.hasProperty = &Messages_hasProperty;
    definition.getProperty = &Messages_getProperty;
    definition.setProperty = &Messages_setProperty;
#if !__OBJC2__
    definition.deleteProperty = &Messages_deleteProperty;
#endif
    definition.getPropertyNames = &Messages_getPropertyNames;
    definition.finalize = &Finalize;
    Messages_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Selector";
    definition.staticValues = Selector_staticValues;
    definition.staticFunctions = Selector_staticFunctions;
    definition.callAsFunction = &Selector_callAsFunction;
    definition.finalize = &Finalize;
    Selector_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Super";
    definition.staticFunctions = Internal_staticFunctions;
    definition.finalize = &Finalize;
    Super_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "ObjectiveC::Classes";
    definition.getProperty = &ObjectiveC_Classes_getProperty;
    definition.getPropertyNames = &ObjectiveC_Classes_getPropertyNames;
    ObjectiveC_Classes_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "ObjectiveC::Images";
    definition.getProperty = &ObjectiveC_Images_getProperty;
    definition.getPropertyNames = &ObjectiveC_Images_getPropertyNames;
    ObjectiveC_Images_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "ObjectiveC::Image::Classes";
    definition.getProperty = &ObjectiveC_Image_Classes_getProperty;
    definition.getPropertyNames = &ObjectiveC_Image_Classes_getPropertyNames;
    ObjectiveC_Image_Classes_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "ObjectiveC::Protocols";
    definition.getProperty = &ObjectiveC_Protocols_getProperty;
    definition.getPropertyNames = &ObjectiveC_Protocols_getPropertyNames;
    ObjectiveC_Protocols_ = JSClassCreate(&definition);

    JSObjectRef ObjectiveC(JSObjectMake(context, NULL, NULL));
    CYSetProperty(context, global, CYJSString("ObjectiveC"), ObjectiveC);

    CYSetProperty(context, ObjectiveC, CYJSString("classes"), JSObjectMake(context, ObjectiveC_Classes_, NULL));
    CYSetProperty(context, ObjectiveC, CYJSString("images"), JSObjectMake(context, ObjectiveC_Images_, NULL));
    CYSetProperty(context, ObjectiveC, CYJSString("protocols"), JSObjectMake(context, ObjectiveC_Protocols_, NULL));

    JSObjectRef Instance(JSObjectMakeConstructor(context, Instance_, &Instance_new));
    JSObjectRef Message(JSObjectMakeConstructor(context, Message_, NULL));
    JSObjectRef Selector(JSObjectMakeConstructor(context, Selector_, &Selector_new));
    JSObjectRef Super(JSObjectMakeConstructor(context, Super_, &Super_new));

    Instance_prototype_ = (JSObjectRef) CYGetProperty(context, Instance, prototype_);
    JSValueProtect(context, Instance_prototype_);

    CYSetProperty(context, global, CYJSString("Instance"), Instance);
    CYSetProperty(context, global, CYJSString("Selector"), Selector);
    CYSetProperty(context, global, CYJSString("Super"), Super);

    CYSetProperty(context, global, CYJSString("objc_registerClassPair"), JSObjectMakeFunctionWithCallback(context, CYJSString("objc_registerClassPair"), &objc_registerClassPair_));
    CYSetProperty(context, global, CYJSString("objc_msgSend"), JSObjectMakeFunctionWithCallback(context, CYJSString("objc_msgSend"), &$objc_msgSend));

    JSObjectSetPrototype(context, (JSObjectRef) CYGetProperty(context, Message, prototype_), Function_prototype_);
    JSObjectSetPrototype(context, (JSObjectRef) CYGetProperty(context, Selector, prototype_), Function_prototype_);

    MSHookFunction(&objc_registerClassPair, MSHake(objc_registerClassPair));

#ifdef __APPLE__
    class_addMethod(NSCFType_, @selector(cy$toJSON:), reinterpret_cast<IMP>(&NSCFType$cy$toJSON), "@12@0:4@8");
#endif
}
/* }}} */
#endif

JSGlobalContextRef CYGetJSContext() {
    if (Context_ == NULL) {
        JSClassDefinition definition;

        definition = kJSClassDefinitionEmpty;
        definition.className = "Functor";
        definition.staticFunctions = Functor_staticFunctions;
        definition.callAsFunction = &Functor_callAsFunction;
        definition.finalize = &Finalize;
        Functor_ = JSClassCreate(&definition);

        definition = kJSClassDefinitionEmpty;
        definition.className = "Pointer";
        definition.staticValues = Pointer_staticValues;
        definition.staticFunctions = Pointer_staticFunctions;
        definition.getProperty = &Pointer_getProperty;
        definition.setProperty = &Pointer_setProperty;
        definition.finalize = &Finalize;
        Pointer_ = JSClassCreate(&definition);

        definition = kJSClassDefinitionEmpty;
        definition.className = "Struct";
        definition.staticFunctions = Struct_staticFunctions;
        definition.getProperty = &Struct_getProperty;
        definition.setProperty = &Struct_setProperty;
        definition.getPropertyNames = &Struct_getPropertyNames;
        definition.finalize = &Finalize;
        Struct_ = JSClassCreate(&definition);

        definition = kJSClassDefinitionEmpty;
        definition.className = "Type";
        definition.staticFunctions = Type_staticFunctions;
        definition.getProperty = &Type_getProperty;
        definition.callAsFunction = &Type_callAsFunction;
        definition.callAsConstructor = &Type_callAsConstructor;
        definition.finalize = &Finalize;
        Type_privateData::Class_ = JSClassCreate(&definition);

        definition = kJSClassDefinitionEmpty;
        definition.className = "Runtime";
        definition.getProperty = &Runtime_getProperty;
        Runtime_ = JSClassCreate(&definition);

        definition = kJSClassDefinitionEmpty;
        //definition.getProperty = &Global_getProperty;
        JSClassRef Global(JSClassCreate(&definition));

        JSGlobalContextRef context(JSGlobalContextCreate(Global));
        Context_ = context;
        JSObjectRef global(CYGetGlobalObject(context));

        JSObjectSetPrototype(context, global, JSObjectMake(context, Runtime_, NULL));

        Array_ = CYCastJSObject(context, CYGetProperty(context, global, CYJSString("Array")));
        JSValueProtect(context, Array_);

        Error_ = CYCastJSObject(context, CYGetProperty(context, global, CYJSString("Error")));
        JSValueProtect(context, Error_);

        Function_ = CYCastJSObject(context, CYGetProperty(context, global, CYJSString("Function")));
        JSValueProtect(context, Function_);

        String_ = CYCastJSObject(context, CYGetProperty(context, global, CYJSString("String")));
        JSValueProtect(context, String_);

        length_ = JSStringCreateWithUTF8CString("length");
        message_ = JSStringCreateWithUTF8CString("message");
        name_ = JSStringCreateWithUTF8CString("name");
        prototype_ = JSStringCreateWithUTF8CString("prototype");
        toCYON_ = JSStringCreateWithUTF8CString("toCYON");
        toJSON_ = JSStringCreateWithUTF8CString("toJSON");

        JSObjectRef Object(CYCastJSObject(context, CYGetProperty(context, global, CYJSString("Object"))));
        Object_prototype_ = CYCastJSObject(context, CYGetProperty(context, Object, prototype_));
        JSValueProtect(context, Object_prototype_);

        Array_prototype_ = CYCastJSObject(context, CYGetProperty(context, Array_, prototype_));
        Array_pop_ = CYCastJSObject(context, CYGetProperty(context, Array_prototype_, CYJSString("pop")));
        Array_push_ = CYCastJSObject(context, CYGetProperty(context, Array_prototype_, CYJSString("push")));
        Array_splice_ = CYCastJSObject(context, CYGetProperty(context, Array_prototype_, CYJSString("splice")));

        CYSetProperty(context, Array_prototype_, toCYON_, JSObjectMakeFunctionWithCallback(context, toCYON_, &Array_callAsFunction_toCYON), kJSPropertyAttributeDontEnum);

        JSValueProtect(context, Array_prototype_);
        JSValueProtect(context, Array_pop_);
        JSValueProtect(context, Array_push_);
        JSValueProtect(context, Array_splice_);

        JSObjectRef Functor(JSObjectMakeConstructor(context, Functor_, &Functor_new));

        Function_prototype_ = (JSObjectRef) CYGetProperty(context, Function_, prototype_);
        JSValueProtect(context, Function_prototype_);

        JSObjectSetPrototype(context, (JSObjectRef) CYGetProperty(context, Functor, prototype_), Function_prototype_);

        CYSetProperty(context, global, CYJSString("Functor"), Functor);
        CYSetProperty(context, global, CYJSString("Pointer"), JSObjectMakeConstructor(context, Pointer_, &Pointer_new));
        CYSetProperty(context, global, CYJSString("Type"), JSObjectMakeConstructor(context, Type_privateData::Class_, &Type_new));

        JSObjectRef cycript(JSObjectMake(context, NULL, NULL));
        CYSetProperty(context, global, CYJSString("Cycript"), cycript);
        CYSetProperty(context, cycript, CYJSString("gc"), JSObjectMakeFunctionWithCallback(context, CYJSString("gc"), &Cycript_gc_callAsFunction));

        CYSetProperty(context, global, CYJSString("$cyq"), JSObjectMakeFunctionWithCallback(context, CYJSString("$cyq"), &$cyq));

        System_ = JSObjectMake(context, NULL, NULL);
        JSValueProtect(context, System_);

        CYSetProperty(context, global, CYJSString("system"), System_);
        CYSetProperty(context, System_, CYJSString("args"), CYJSNull(context));
        //CYSetProperty(context, System_, CYJSString("global"), global);

        CYSetProperty(context, System_, CYJSString("print"), JSObjectMakeFunctionWithCallback(context, CYJSString("print"), &System_print));

        Result_ = JSStringCreateWithUTF8CString("_");

        CYObjectiveC(context, global);
    }

    return Context_;
}
