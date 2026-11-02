/* ============================================================
 * font12x12.h - 12x12 CJK character bitmap font
 * Each character: 24 bytes (12 columns x 2 bytes)
 * Column-major format: byte[col*2]=rows 0-7, byte[col*2+1]=rows 8-11
 * bit 0 = top row of column
 * ============================================================ */
#ifndef FONT12X12_H_
#define FONT12X12_H_

#include "xil_types.h"

typedef struct {
    u16 unicode;
    const u8 bitmap[24];
} cjk_glyph_t;

#define CJK_FONT_COUNT 49

/* Font data defined in font12x12.c */
extern const cjk_glyph_t cjk_font[CJK_FONT_COUNT];

/* Lookup glyph bitmap by Unicode codepoint, returns NULL if not found */
const u8 *cjk_find(u16 unicode);

#endif /* FONT12X12_H_ */
