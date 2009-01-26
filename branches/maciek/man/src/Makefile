SOURCES := $(wildcard *.txt)
MANS := $(patsubst %.txt, ../man1/%.1, $(SOURCES))

all:	$(MANS)

../man1/%.1:	%.txt
	txt2man -t $(patsubst %.txt, %, $<) -s 1 -r "MySQL Master-Master Manager" < $< > $@

clean:
	rm -f ../man1/*
