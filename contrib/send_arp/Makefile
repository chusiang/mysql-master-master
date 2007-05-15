all: send_arp

FLAGS = `libnet-config --defines --cflags`
LIBS = `libnet-config --libs` -lnet

#LIBNET_VERSION=1_0
LIBNET_VERSION=1_1

send_arp.o:   send_arp.c
	gcc -o send_arp.o $(FLAGS) -DHAVE_LIBNET_$(LIBNET_VERSION)_API -c send_arp.c

send_arp: send_arp.o
	gcc -o send_arp send_arp.o $(LIBS) -s

clean:
	rm -f send_arp send_arp.o

install: send_arp
	rm -f ../../bin/sys/send_arp
	cp send_arp ../../bin/sys
