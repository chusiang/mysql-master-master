#include <utmpx.h>

int main() {
    int nBootTime = 0;
    int nCurrentTime = time(NULL);
    struct utmpx * ent;
  
    while ((ent = getutxent())) {
        if (!strcmp("system boot", ent->ut_line)) {
            nBootTime = ent->ut_tv.tv_sec;
        }
    }
    printf ("%d\n", nCurrentTime - nBootTime);
}
