#include "gost3411-2012-core.c"
void hh_streebog512(const unsigned char *data, size_t count, unsigned char *digest) {
    GOST34112012Context context;
    GOST34112012Init(&context, 512);
    if (count) GOST34112012Update(&context, data, count);
    GOST34112012Final(&context, digest);
    GOST34112012Cleanup(&context);
}
