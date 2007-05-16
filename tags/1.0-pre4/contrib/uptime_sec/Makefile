all: uptime_sec

uptime_sec: uptime_sec.c
       gcc -o uptime_sec uptime_sec.c

clean:
       rm -f uptime_sec

install: uptime_sec
       cp uptime_sec ../../bin/sys/
