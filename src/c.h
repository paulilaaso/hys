#ifdef __MINGW32__
#undef  _FORTIFY_SOURCE
#define _FORTIFY_SOURCE 0
#endif

#include <curl/curl.h>
#include <expat.h>
