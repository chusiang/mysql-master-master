SOURCES := $(wildcard *.txt)
MANS := $(patsubst %.txt, ../1/%.1, $(SOURCES))

all:	$(MANS)

../1/%.1:	%.txt
	txt2man -t $(patsubst %.txt, %, $<) -r "MySQL Master-Master Manager" < $< > $@

clean:
	rm -f ../1/*
