# Makefile for PostgreSQL::Test::Pq
# src/test/perl/PostgreSQL/Test/GNUmakefile

subdir = src/test/perl/PostgreSQL/Test
top_builddir = ../../../../..
include $(top_builddir)/src/Makefile.global

# where to find xsubpp for building XS.
XSUBPPDIR = $(shell $(PERL) -e 'use List::Util qw(first); print first { -r "$$_/ExtUtils/xsubpp" } @INC')

ARCHLIBEXP = $(shell $(PERL) -e 'use Config; print $$Config{archlibexp};')

# only build if we can find xsubpp
ifneq (,$(XSUBPPDIR))

ifeq ($(PORTNAME), win32)
override CPPFLAGS += -DPLPERL_HAVE_UID_GID
# Perl on win32 contains /* within comment all over the header file,
# so disable this warning.
override CPPFLAGS += -Wno-comment
endif

# Note: we need to include the perl_includespec directory last,
# probably because it sometimes contains some header files with names
# that clash with some of ours, or with some that we include, notably on
# Windows.
#
# We need to include the plperl directory for ppport.h
#
override CPPFLAGS := -I. -I$(srcdir) -I$(top_srcdir)/src/pl/plperl -I$(top_srcdir)/src/interfaces/libpq $(CPPFLAGS) -I$(ARCHLIBEXP)/CORE

# this is often, but not always, the same directory named by perl_includespec
# rpathdir = $(perl_archlibexp)/CORE

# Needed to make sure the bootstrap function is visible.
# Is there a better way to do this?
CFLAGS_SL_MODULE :=

NAME = Pq

OBJS = Pq.o

SHLIB_LINK_INTERNAL = $(libpq)


include $(top_srcdir)/src/Makefile.shlib

all: all-lib

Pq.c: Pq.xs
	$(PERL) $(XSUBPPDIR)/ExtUtils/xsubpp $< > $@

# Pq.{so,dll,dylib} should be installed alongside the .pm module
install: all installdirs
	$(INSTALL_SHLIB) Pq$(DLSUFFIX) '$(DESTDIR)$(pgxsdir)/$(subdir)/Pq$(DLSUFFIX)'
	$(INSTALL_DATA) $(top_srcdir)/$(subdir)/Pq.pm '$(DESTDIR)$(pgxsdir)/$(subdir)/Pq.pm'

uninstall:
	rm -f '$(DESTDIR)$(pgxsdir)/$(subdir)/Pq$(DLSUFFIX)'
	rm -f '$(DESTDIR)$(pgxsdir)/$(subdir)/Pq.pm'

else

# no xsubpp, so nothing to build
all:
	@echo Cannot build Pq.$(DLSUFFIX)

endif
