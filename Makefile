CSC = csc
DOCGEN = scm2wiki
DOCS = bintracker-core.md bt-gui.md bt-state.md bt-types.md bt-db.md bt-emulation.md
LIBFLAGS = -s -d3 #-profile-name $@.PROFILE
ifdef RELEASE
 LIBFLAGS += -O3
endif
IMPORTFLAGS = -s -d0
ifdef CHICKEN_REPOSITORY_PATH
 CHICKEN_REPO_PATH = $(CHICKEN_REPOSITORY_PATH)
else
 CHICKEN_REPO_PATH = $(shell if [ ! -f "chicken-repository-path" ]; then\
 find /usr /home/ -type d 2>/dev/null | grep -P "lib.*?\/chicken\/9" >chicken-repository-path; fi;\
 head -n 1 chicken-repository-path)
endif
ALL_SOURCE_FILES = bt-types.scm bt-state.scm bt-gui.scm bintracker-core.scm\
 bt-db.scm bt-emulation.scm\
 libmdal/schemta.scm libmdal/md-parser.scm libmdal/md-config.scm\
 libmdal/md-command.scm libmdal/utils/md-note-table.scm libmdal/md-types.scm\
 libmdal/md-helpers.scm libmdal/mdal.scm
MAKE_ETAGS = yes
ifeq ($(MAKE_ETAGS),yes)
 DO_TAGS = TAGS
endif

# Might need to use csc -compile-syntax in places. See:
# https://lists.nongnu.org/archive/html/chicken-users/2017-08/msg00004.html

bintracker: bintracker.scm bintracker-core.import.so
	export CHICKEN_REPOSITORY_PATH=$(CHICKEN_REPO_PATH):${PWD}/libmdal;\
	$(CSC) bintracker.scm -d3 -O2 -compile-syntax -profile -o bintracker

# build bintracker-core
bintracker-core.so: bintracker-core.scm bt-state.import.so bt-types.import.so\
	bt-gui.import.so bt-db.import.so bt-emulation.import.so\
	libmdal/mdal.import.so $(DO_TAGS)
	export CHICKEN_REPOSITORY_PATH=$(CHICKEN_REPO_PATH):${PWD}/libmdal;\
	$(CSC) $(LIBFLAGS) bintracker-core.scm -j bintracker-core
	$(CSC) $(IMPORTFLAGS) bintracker-core.import.scm

bintracker-core.import.so: bintracker-core.so
	$(CSC) $(IMPORTFLAGS) bintracker-core.import.scm

bt-types.so: bt-types.scm
	$(CSC) $(LIBFLAGS) bt-types.scm -j bt-types

bt-types.import.so: bt-types.so
	$(CSC) $(IMPORTFLAGS) bt-types.import.scm

bt-state.so: bt-state.scm bt-types.import.so bt-db.import.so\
 bt-emulation.import.so libmdal/mdal.import.so
	export CHICKEN_REPOSITORY_PATH=$(CHICKEN_REPO_PATH):${PWD}/libmdal;\
	$(CSC) $(LIBFLAGS) bt-state.scm -j bt-state

bt-state.import.so: bt-state.so
	$(CSC) $(IMPORTFLAGS) bt-state.import.scm

bt-db.so: bt-db.scm libmdal/mdal.import.so
	export CHICKEN_REPOSITORY_PATH=$(CHICKEN_REPO_PATH):${PWD}/libmdal;\
	$(CSC) $(LIBFLAGS) bt-db.scm -j bt-db

bt-db.import.so: bt-db.so
	$(CSC) $(IMPORTFLAGS) bt-db.import.scm

bt-emulation.so: bt-emulation.scm
	$(CSC) $(LIBFLAGS) bt-emulation.scm -j bt-emulation

bt-emulation.import.so: bt-emulation.so
	$(CSC) $(IMPORTFLAGS) bt-emulation.import.scm

bt-gui.so: bt-gui.scm bt-state.import.so bt-types.import.so bt-db.import.so
	export CHICKEN_REPOSITORY_PATH=$(CHICKEN_REPO_PATH):${PWD}/libmdal;\
	$(CSC) $(LIBFLAGS) bt-gui.scm -j bt-gui

bt-gui.import.so: bt-gui.so
	$(CSC) $(IMPORTFLAGS) bt-gui.import.scm

TAGS: $(ALL_SOURCE_FILES)
	etags -r '"  (def.*? "' $(ALL_SOURCE_FILES)

%.md: %.scm
	$(DOCGEN) -i $< -o docs/generated/$@

bintracker-core.md: bintracker-core.scm
bt-gui.md: bt-gui.scm
bt-state.md: bt-state.scm
bt-types.md: bt-types.scm
bt-emulation.md: bt-emulation.scm
bt-db.md: bt-db.scm

docs: $(DOCS)
	$(MAKE) docs -C libmdal
	mkdir -p docs/libmdal
	cp -r libmdal/docs/* docs/libmdal/
	mkdocs build


libmdal/mdal.import.so:
	$(MAKE) -C libmdal

.PHONY: clean
clean:
	-rm *.so *.import.scm
	$(MAKE) -C libmdal clean
