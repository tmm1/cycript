ifndef PKG_TARG
target :=
else
target := $(PKG_TARG)-
endif

#flags := -g3 -O0 -DYYDEBUG=1
flags := -g0 -O3
flags += -Wall -Werror -I. -fno-common

svn := $(shell svnversion)

all:
all := libcycript.plist cycript

dpkg_architecture := $(shell dpkg-architecture &>/dev/null)
ifneq ($(dpkg_architecture),)
arch := $(shell $(dpkg_architecture) -qDEB_HOST_ARCH)
endif

header := Cycript.tab.hh Parser.hpp Pooling.hpp cycript.hpp

dll := so

uname_s := $(shell uname -s)
uname_p := $(shell uname -p)
-include $(uname_s).mk
-include $(uname_s)-$(uname_p).mk

all += libcycript.$(dll)

ifdef arch
deb := $(shell grep ^Package: control | cut -d ' ' -f 2-)_$(shell grep ^Version: control | cut -d ' ' -f 2 | sed -e 's/\#/$(svn)/')_$(arch).deb

all: $(deb)

$(deb): $(all)
	rm -rf package
	mkdir -p package/DEBIAN
	sed -e 's/#/$(svn)/' control >package/DEBIAN/control
	mkdir -p package/System/Library/LaunchDaemons
	#cp -a com.saurik.Cyrver.plist package/System/Library/LaunchDaemons
	mkdir -p package/Library/MobileSubstrate/DynamicLibraries
	if [[ -e Settings.plist ]]; then \
	    mkdir -p package/Library/PreferenceLoader/Preferences; \
	    cp -a Settings.png package/Library/PreferenceLoader/Preferences/CycriptIcon.png; \
	    cp -a Settings.plist package/Library/PreferenceLoader/Preferences/Cycript.plist; \
	fi
	if [[ -e Tweak.plist ]]; then cp -a Tweak.plist package/Library/MobileSubstrate/DynamicLibraries/Cycript.plist; fi
	cp -a Cycript.dylib package/Library/MobileSubstrate/DynamicLibraries
	mkdir -p package/usr/{bin,lib,sbin}
	cp -a libcycript.dylib package/usr/lib
	cp -a cycript package/usr/bin
	#cp -a cyrver package/usr/sbin
	cp -a libcycript.plist package/usr/lib
	dpkg-deb -b package $(deb)
endif

all: $(all)

clean:
	rm -f *.o libcycript.dylib cycript libcycript.plist Struct.hpp lex.cy.c Cycript.tab.cc Cycript.tab.hh location.hh position.hh stack.hh cyrver

libcycript.plist: Bridge.def
	{ \
	    echo '({'; \
	    grep '^[CFV]' Bridge.def | sed -e 's/^C/0/;s/^F/1/;s/^V/2/' | sed -e 's/"/\\"/g;s/^\([^ ]*\) \([^ ]*\) \(.*\)$$/\2 = (\1, \"\3\");/'; \
	    echo '},{'; \
	    grep '^:' Bridge.def | sed -e 's/^: \([^ ]*\) \(.*\)/"\1" = "\2";/'; \
	    echo '},{'; \
	    grep '^[EST]' Bridge.def | sed -e 's/^S/0/;s/^T/1/;s/^E/2/' | sed -e 's/^2\(.*\)$$/1\1 i/' | sed -e 's/"/\\"/g;s/^\([^ ]*\) \([^ ]*\) \(.*\)$$/\2 = (\1, \"\3\");/'; \
	    echo '})'; \
	} >$@

Cycript.tab.cc Cycript.tab.hh location.hh position.hh: Cycript.y
	bison -v --report=state $<

lex.cy.c: Cycript.l
	flex $<

#Parser.hpp: Parser.py Parser.dat
#	./Parser.py <Parser.dat >$@

%.o: sig/%.cpp
	$(target)g++ $(flags) -c -o $@ $<

Cycript.tab.o: Cycript.tab.cc Cycript.tab.hh Parser.hpp Pooling.hpp
	$(target)g++ $(flags) -c -o $@ $<

lex.cy.o: lex.cy.c Cycript.tab.hh Parser.hpp Pooling.hpp
	$(target)g++ $(flags) -c -o $@ $<

%.o: %.cpp $(header)
	$(target)g++ $(flags) -c -o $@ $<

%.o: %.mm $(header)
	$(target)g++ $(flags) -c -o $@ $<

cyrver: Server.o
	$(target)g++ $(flags) -o $@ $(filter %.o,$^) \
	    -lobjc -lapr-1 -lsubstrate \
	    -framework CoreFoundation -framework CFNetwork
	ldid -S $@

libcycript.$(dll): ffi_type.o parse.o Replace.o Output.o Cycript.tab.o lex.cy.o Library.o
	$(target)g++ $(flags) -dynamiclib -o $@ $(filter %.o,$^) \
	    -install_name /usr/lib/libcycript.dylib \
	    -lobjc -lapr-1 -lffi -lsubstrate \
	    -framework CoreFoundation -framework Foundation \
	    -framework CFNetwork \
	    -framework JavaScriptCore -framework WebCore
	ldid -S $@

cycript: Console.o libcycript.dylib
	$(target)g++ $(flags) -o $@ $(filter %.o,$^) \
	    -lobjc -lapr-1 -lreadline \
	    -L. -lcycript \
	    -framework Foundation -framework CoreFoundation \
	    -framework JavaScriptCore -framework UIKit
	ldid -S cycript

package: $(deb)

test: $(deb)
	dpkg -i $(deb)
	cycript test.cy

.PHONY: all clean extra package
