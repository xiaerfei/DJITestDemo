/*
 * tvu_irl_str.c
 */

#include "tvu_irl_str.h"

#include <stdlib.h>

static char *tvu_irl_str_dup(const char *src, size_t len) {
    if (len == 0) return NULL;
    char *p = (char *)malloc(len + 1);
    if (!p) abort();
    memcpy(p, src, len);
    p[len] = '\0';
    return p;
}

void tvu_irl_str_init_with_cstr(tvu_irl_str_t *s, const char *cstr) {
    if (!cstr || cstr[0] == '\0') { s->data = NULL; s->length = 0; return; }
    size_t len = strlen(cstr);
    s->data = tvu_irl_str_dup(cstr, len);
    s->length = len;
}

void tvu_irl_str_init_with_view(tvu_irl_str_t *s, tvu_irl_strv_t v) {
    s->data = tvu_irl_str_dup(v.data, v.length);
    s->length = v.length;
}

void tvu_irl_str_destroy(tvu_irl_str_t *s) {
    free(s->data);
    s->data = NULL; s->length = 0;
}

void tvu_irl_str_set(tvu_irl_str_t *s, tvu_irl_strv_t v) {
    free(s->data);
    s->data = tvu_irl_str_dup(v.data, v.length);
    s->length = v.length;
}

char *tvu_irl_str_take(tvu_irl_str_t *s, size_t *out_length) {
    char *p = s->data;
    *out_length = s->length;
    s->data = NULL; s->length = 0;
    return p;
}
