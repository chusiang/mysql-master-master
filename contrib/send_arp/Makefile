all: send_arp

send_arp.o:   send_arp.c
	gcc -o send_arp.o -c send_arp.c

send_arp: send_arp.o
	gcc -o send_arp send_arp.o -lnet -static -s

clean:
	rm -f send_arp send_arp.o

install: send_arp
	rm -f ../../bin/sys/send_arp
	cp send_arp ../../bin/sys
