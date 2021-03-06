AC_PREREQ([2.65])
AC_INIT([Cycript], [0.9], [saurik@saurik.com], [cycript], [http://www.cycript.org/])
AC_CONFIG_SRCDIR([Console.cpp])
AC_CONFIG_AUX_DIR([.])
LT_INIT([disable-static])
PKG_PROG_PKG_CONFIG([0.22])
CHECK_GNU_MAKE
AC_SUBST([GMAKE], [$_cv_gnu_make_command])
AS_IF([test "x$GMAKE" = x], [AC_MSG_ERROR([You need GNU make])])
AC_PATH_PROGS([_BASH], [bash])
AS_IF([test "x$_BASH" = x], [AC_MSG_ERROR([You need GNU bash])])
AC_PATH_PROGS([TIME], [time])
AC_DEFUN([CY_CHECK_PROGS_VERSION], [
	AC_MSG_CHECKING(for ]$2[ >= ]$5[)
	AC_PATH_PROGS_FEATURE_CHECK(]$1[, ]$3[,
		AS_VERSION_COMPARE(`$ac_path_]$1[ ]$4[`, ]$5[, ,
			ac_cv_path_]$1[=$ac_path_]$1[
		,
			ac_cv_path_]$1[=$ac_path_]$1[
		)
	,
		AC_MSG_RESULT(no)
		AC_MSG_ERROR(You need ]$2[ ]$5[ or greater)
	)
	AC_SUBST(]$1[, $ac_cv_path_]$1[)
	AC_MSG_RESULT($]$1[)
])
AC_ARG_VAR([BISON], [GNU Project parser generator (yacc replacement)])
CY_CHECK_PROGS_VERSION([BISON], [bison], [bison],
	[-V | $SED -e '1 s/^bison (GNU Bison) \(.*\)$/\1/p;d'], [2.3])
AC_ARG_VAR([FLEX], [the fast lexical analyser generator])
CY_CHECK_PROGS_VERSION([FLEX], [flex], [flex],
	[--version | $SED -e '1 s/^.* \(@<:@0-9.@:>@*\)$/\1/p;d'], [2.5.33])
AC_ARG_VAR([GPERF], [perfect hash function generator])
CY_CHECK_PROGS_VERSION([GPERF], [gperf], [gperf],
	[--version | $SED -e '1 s/^.* \(@<:@0-9.@:>@*\)$/\1/p;d'], [3.0.3])
AC_PROG_INSTALL
AC_MSG_CHECKING([for GNU tar >=1.19])
AC_PATH_PROGS_FEATURE_CHECK([GNUTAR], [tar gtar gnutar], [
	AS_IF([test "x`$ac_path_GNUTAR --version | $SED -e '1 s/^tar (GNU tar)/&/p;d'`" != x], [
		AS_VERSION_COMPARE([`$ac_path_GNUTAR --version | $SED -e '1 s/^tar (GNU tar) \(.*\)$/\1/p;d'`], [1.19], , [
			ac_cv_path_GNUTAR=$ac_path_GNUTAR
		], [
			ac_cv_path_GNUTAR=$ac_path_GNUTAR
		])
	])
])
AS_IF([test "x$ac_cv_path_GNUTAR" != x], [
	AC_SUBST([GNUTAR], [$ac_cv_path_GNUTAR])
	AC_MSG_RESULT([$GNUTAR])
], [
	AC_SUBST([GNUTAR], [:])
	AC_MSG_RESULT([no])
])
AC_CHECK_PROGS([SVN], [svn])
AC_CHECK_PROGS([SVNVERSION], [svnversion])
AC_PROG_CXX
AC_PROG_OBJCXX
AC_DEFUN([CY_CHECK_UNIVERSAL], [
	AC_MSG_CHECKING([for universal binary support])
	AS_CASE([$host_vendor], [apple], [
		AS_CASE([$host_cpu], [i386|x86_64], [
			for cy_arch in i386 x86_64; do
				cy_save_CXXFLAGS=$CXXFLAGS
				AC_LIB_APPENDTOVAR([CXXFLAGS], ["-arch $cy_arch"])
				AC_TRY_LINK([], [], [
					AC_LIB_APPENDTOVAR([cy_arches], [$cy_arch])
					AC_LIB_APPENDTOVAR([CFLAGS], ["-arch $cy_arch"])
					AC_LIB_APPENDTOVAR([LDFLAGS], ["-arch $cy_arch"])
					AC_LIB_APPENDTOVAR([OBJCXXFLAGS], ["-arch $cy_arch"])
				], [
					CXXFLAGS=$cy_save_CXXFLAGS
				])
			done
		])
	])
	AC_MSG_RESULT([${cy_arches-no}])
])
AC_ARG_ENABLE([universal-binary], [AS_HELP_STRING(
	[--disable-universal-binary],
	[do not build with universal binary support on Darwin]
)], [
	AS_CASE([$enableval], [no], [], [CY_CHECK_UNIVERSAL])
], [CY_CHECK_UNIVERSAL])
AC_ARG_WITH([frameworks], [AS_HELP_STRING(
	[--with-frameworks=DIRS],
	[add to DIRS (space separated) to the Darwin include path for frameworks with -F]
)], [
	for cy_framework in $withval; do
		AC_LIB_APPENDTOVAR([CFLAGS], [-F$cy_framework])
		AC_LIB_APPENDTOVAR([CXXFLAGS], [-F$cy_framework])
		AC_LIB_APPENDTOVAR([OBJCCXXFLAGS], [-F$cy_framework])
	done
])
AC_LANG([C++])
APR_FIND_APR([], [], [1], [1])
AS_CASE([$apr_found], [yes], [
	AC_LIB_APPENDTOVAR([CPPFLAGS], [`$apr_config --includes`])
	AC_SUBST([LTLIBAPR], [`$apr_config --link-libtool`])
], [AC_MSG_ERROR([You need apr])])
AC_DEFUN([CY_CHECK_JAVASCRIPTCORE], [
	PKG_CHECK_MODULES([WEBKIT], [webkit-1.0], [
		CY_EXECUTE=1
		AC_LIB_APPENDTOVAR([CXXFLAGS], [`$PKG_CONFIG --cflags webkit-1.0`])
		AC_LIB_APPENDTOVAR([LIBS], [`$PKG_CONFIG --libs webkit-1.0`])
	], [
		PKG_CHECK_MODULES([WEBKIT], [WebKitGtk], [
			CY_EXECUTE=1
			AC_LIB_APPENDTOVAR([CXXFLAGS], [`$PKG_CONFIG --cflags WebKitGtk`])
			AC_LIB_APPENDTOVAR([LIBS], [`$PKG_CONFIG --libs WebKitGtk`])
		], [
			AC_CHECK_FRAMEWORK([JavaScriptCore], [
				#include <JavaScriptCore/JSBase.h>
			], [JSEvaluateScript(0, 0, 0, 0, 0, 0);], [CY_EXECUTE=1])
		])
	])
])
AC_DEFUN([CY_CHECK_JAVASCRIPT], [
	CY_CHECK_JAVASCRIPTCORE
])
AC_ARG_ENABLE([javascript], [AS_HELP_STRING(
	[--enable-javascript@<:@=ENGINE@:>@],
	[use a JavaScript runtime (currently the only available option for ENGINE is JavaScriptCore) @<:@default=yes@:>@]
)], [
	AS_CASE([$enableval], [yes], [CY_CHECK_JAVASCRIPT], [no], [
		AC_SUBST([CY_EXECUTE], [0])
	], [JavaScriptCore], [
		CY_CHECK_JAVASCRIPTCORE
	], [AC_MSG_ERROR([Unknown JavaScript engine: $enableval])])
], [CY_CHECK_JAVASCRIPT])
AC_DEFUN([CY_CHECK_PKG_CONFIG_LIBFFI], [
	PKG_CHECK_MODULES([LIBFFI], [libffi], [
		AC_LIB_APPENDTOVAR([CXXFLAGS], [`$PKG_CONFIG --cflags libffi`])
		AC_LIB_APPENDTOVAR([LIBS], [`$PKG_CONFIG --libs libffi`])
	], [
		AC_MSG_ERROR([You need libffi])
	])
])
AS_CASE([$CY_EXECUTE], [1], [
	AC_SUBST([CY_EXECUTE])
	AC_CHECK_HEADERS([ffi.h ffi/ffi.h], [break])
	AS_IF([test "x$ac_cv_header_ffi_h" = xno && test "x$ac_cv_header_ffi_ffi_h" = xno], [
		CY_CHECK_PKG_CONFIG_LIBFFI
	], [
		AC_SEARCH_LIBS([ffi_call], [ffi])
		AS_CASE([$ac_cv_search_ffi_call], [no], [CY_CHECK_PKG_CONFIG_LIBFFI])
	])
	AC_LANG_PUSH([Objective C++])
	AC_MSG_CHECKING([if we really have Objective C++])
	AC_COMPILE_IFELSE([
		// This space intentionally left blank
	], [
		CY_OBJECTIVEC=1
		AC_MSG_RESULT([yes])
	], [AC_MSG_RESULT([no])])
	AS_IF([test "x$CY_OBJECTIVEC" = x1], [
		AC_CHECK_FRAMEWORK([CoreFoundation], [
			#include <CoreFoundation/CFBase.h>
		], [CFAllocatorGetDefault();], [
			AC_SUBST([CY_OBJECTIVEC])
			AC_CHECK_FRAMEWORK([Foundation], [
				#include <Foundation/NSObject.h>
			], [[[[NSObject alloc] init];]])
			AC_CHECK_FRAMEWORK([WebKit], [
				#include <WebKit/WebScriptObject.h>
			], [[[[WebScriptObject alloc] init];]])
		], [
			AC_ARG_VAR([GNUSTEP_CONFIG], [prints information about the current gnustep installation])
			AC_CHECK_PROGS([GNUSTEP_CONFIG], [gnustep-config])
			AS_IF([test "x$GNUSTEP_CONFIG" != x], [
				AC_SUBST([CY_OBJECTIVEC])
				AC_LIB_APPENDTOVAR([OBJCXXFLAGS], [`$GNUSTEP_CONFIG --objc-flags`])
				AC_LIB_APPENDTOVAR([LIBS], [`$GNUSTEP_CONFIG --base-libs`])
			], [AC_SUBST([CY_OBJECTIVEC], [0])])
		])
	])
	AC_LANG_POP([Objective C++])
])
VL_LIB_READLINE
AS_CASE([$vl_cv_lib_readline], [no], [AC_MSG_ERROR([You need readline])])
AC_LANG_PUSH([C])
AM_ICONV
AS_CASE([$am_cv_func_iconv], [yes], [], [
	for cy_iconv_prefix_arg in $CFLAGS $CXXFLAGS $OBJCXXFLAGS $LDFLAGS $LIBS; do
		AS_CASE([$cy_iconv_prefix_arg], [-I*], [
			AC_LIB_APPENDTOVAR([cy_iconv_prefixes], [`echo $cy_iconv_prefix_arg | sed -e 's/^-I//;s|/include$||'`])
		], [-L*], [
			AC_LIB_APPENDTOVAR([cy_iconv_prefixes], [`echo $cy_iconv_prefix_arg | sed -e 's/^-L//;s|/lib$||'`])
		])
	done
	for with_libiconv_prefix in $cy_iconv_prefixes; do
		AS_UNSET([am_cv_func_iconv])
		AM_ICONV_LINKFLAGS_BODY
		AM_ICONV
	done
])
AS_CASE([$am_cv_func_iconv], [yes], [], [AC_MSG_ERROR([You need iconv])])
AC_LANG_POP([C])
AS_IF([test "x$CY_OBJECTIVEC" = x1], [
	AC_CHECK_HEADER([mach/mach.h], [
		AC_CHECK_TOOLS([_OTOOL], [otool])
		AS_IF([test "x$_OTOOL" = x], [AC_MSG_ERROR([You need otool])])
		AC_CHECK_TOOLS([_LIPO], [lipo])
		AS_IF([test "x$_LIPO" = x], [AC_MSG_ERROR([You need lipo])])
		AC_CHECK_TOOLS([_NM], [nm])
		AS_IF([test "x$_NM" = x], [AC_MSG_ERROR([You need nm])])
		AC_SUBST([SO], [$acl_shlibext])
		AC_SUBST([CY_OBJECTIVEC_MACH], [1])
		AC_SUBST([CY_ATTACH_GROUP], [procmod])
	])
])
AS_IF([test "x$GMAKE" != xmake], [
	AC_CONFIG_FILES([Makefile])
])
AC_CONFIG_FILES([GNUmakefile])
AC_OUTPUT
