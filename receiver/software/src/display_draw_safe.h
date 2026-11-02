/* ============================================================
 * display_draw_safe.h - PS framebuffer-only drawing primitives
 * Surface dimensions follow display_ctrl.h (native 1920x1200 here).
 * Include once in main.c; header implementation needs no new BSP/build unit.
 * No DPDMA, algorithm, ownership or hardware-register operations here.
 * Coordinates stay signed until clipping; all writes end at lcd_set_pixel.
 * ============================================================ */
#ifndef DISPLAY_DRAW_SAFE_H
#define DISPLAY_DRAW_SAFE_H
#include <stdint.h>
#include <stddef.h>
#include <limits.h>

static int64_t lcd_add_positive_sat(int64_t origin, int64_t extent)
{
    return origin > INT64_MAX - extent ? INT64_MAX : origin + extent;
}

static int lcd_surface_valid(const u8 *frame, u32 stride)
{
    return frame != NULL && stride == DISPLAY_STRIDE;
}

void lcd_set_pixel(u8 *frame, int64_t x, int64_t y, u32 stride,
                   u8 r, u8 g, u8 b)
{
    u8 *p;
    if (!lcd_surface_valid(frame, stride) || x < 0 || y < 0 ||
        x >= (int64_t)DISPLAY_WIDTH || y >= (int64_t)DISPLAY_HEIGHT)
        return;
    /* Address arithmetic only AFTER signed bounds checks. */
    p = frame + (size_t)y * stride + (size_t)x * DISPLAY_BPP;
    p[0] = r; p[1] = g; p[2] = b; p[3] = 0xFF;
}

void lcd_draw_rect(u8 *frame, u32 stride, int64_t x, int64_t y,
                   int64_t w, int64_t h, u8 r, u8 g, u8 b)
{
    int64_t right, bottom, px, py;
    if (!lcd_surface_valid(frame, stride) || w <= 0 || h <= 0) return;
    right = lcd_add_positive_sat(x, w);
    bottom = lcd_add_positive_sat(y, h);
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (right > DISPLAY_WIDTH) right = DISPLAY_WIDTH;
    if (bottom > DISPLAY_HEIGHT) bottom = DISPLAY_HEIGHT;
    for (py = y; py < bottom; ++py)
        for (px = x; px < right; ++px)
            lcd_set_pixel(frame, px, py, stride, r, g, b);
}

void lcd_draw_hline(u8 *frame, u32 stride, int64_t x0, int64_t x1,
                    int64_t y, u8 r, u8 g, u8 b)
{
    int64_t x;
    if (!lcd_surface_valid(frame, stride) || y < 0 || y >= DISPLAY_HEIGHT) return;
    if (x0 < 0) x0 = 0;
    if (x1 >= DISPLAY_WIDTH) x1 = DISPLAY_WIDTH - 1;
    for (x = x0; x <= x1; ++x) lcd_set_pixel(frame, x, y, stride, r, g, b);
}

void lcd_draw_vline(u8 *frame, u32 stride, int64_t x,
                    int64_t y0, int64_t y1, u8 r, u8 g, u8 b)
{
    int64_t y;
    if (!lcd_surface_valid(frame, stride) || x < 0 || x >= DISPLAY_WIDTH) return;
    if (y0 < 0) y0 = 0;
    if (y1 >= DISPLAY_HEIGHT) y1 = DISPLAY_HEIGHT - 1;
    for (y = y0; y <= y1; ++y) lcd_set_pixel(frame, x, y, stride, r, g, b);
}

static unsigned lcd_line_outcode(int64_t x, int64_t y)
{
    return (x < 0 ? 1U : x >= DISPLAY_WIDTH ? 2U : 0U) |
           (y < 0 ? 4U : y >= DISPLAY_HEIGHT ? 8U : 0U);
}

void lcd_draw_line(u8 *frame, u32 stride, int x0, int y0, int x1, int y1,
                   u8 r, u8 g, u8 b)
{
    int64_t ax=x0, ay=y0, bx=x1, by=y1;
    int64_t dx, dy, sx, sy, err;
    if (!lcd_surface_valid(frame, stride)) return;
    /* Clip BEFORE Bresenham: off-screen/extreme endpoints cannot cause
     * billions of iterations or overflow 32-bit dx/err. In-bounds lines keep
     * exactly the original rasterization. Intersections truncate toward zero. */
    for (;;) {
        unsigned a=lcd_line_outcode(ax,ay), z=lcd_line_outcode(bx,by), c;
        int64_t x,y;
        if (!(a|z)) break;
        if (a&z) return;
        c = a ? a : z;
        if (c&8U) {
            y=DISPLAY_HEIGHT-1;
            x=ax+(int64_t)((long double)(bx-ax)*(y-ay)/(by-ay));
        } else if (c&4U) {
            y=0; x=ax+(int64_t)((long double)(bx-ax)*(y-ay)/(by-ay));
        } else if (c&2U) {
            x=DISPLAY_WIDTH-1;
            y=ay+(int64_t)((long double)(by-ay)*(x-ax)/(bx-ax));
        } else {
            x=0; y=ay+(int64_t)((long double)(by-ay)*(x-ax)/(bx-ax));
        }
        if (a) { ax=x; ay=y; } else { bx=x; by=y; }
    }
    dx=bx>ax ? bx-ax : ax-bx;
    dy=by>ay ? by-ay : ay-by;
    sx=ax<bx ? 1 : -1; sy=ay<by ? 1 : -1; err=dx-dy;
    for (;;) {
        int64_t twice;
        lcd_set_pixel(frame,ax,ay,stride,r,g,b);
        if (ax==bx && ay==by) break;
        twice=2*err;
        if (twice > -dy) { err-=dy; ax+=sx; }
        if (twice < dx) { err+=dx; ay+=sy; }
    }
}

/* Positive, bounded scale; reject invalid input rather than wrap products. */
static int lcd_scale_valid(int scale)
{
    return scale > 0 && scale <= (int)DISPLAY_HEIGHT;
}

void lcd_draw_char(u8 *frame, u32 stride, int64_t x, int64_t y, char c,
                   u8 r, u8 g, u8 b, int scale)
{
    int col,row;
    const u8 *glyph;
    if (!lcd_surface_valid(frame,stride) || !lcd_scale_valid(scale) ||
        x>=DISPLAY_WIDTH || y>=DISPLAY_HEIGHT ||
        lcd_add_positive_sat(x,5*(int64_t)scale)<=0 ||
        lcd_add_positive_sat(y,7*(int64_t)scale)<=0) return;
    if ((unsigned char)c < 32 || (unsigned char)c > 127) c='?';
    glyph=font5x7[(unsigned char)c-32];
    for (col=0;col<5;++col)
        for (row=0;row<7;++row)
            if (glyph[col] & (1U<<row))
                lcd_draw_rect(frame,stride,x+col*(int64_t)scale,
                              y+row*(int64_t)scale,scale,scale,r,g,b);
}

static void lcd_draw_cjk(u8 *frame, u32 stride, int64_t x, int64_t y,
                         const u8 *bitmap, u8 r, u8 g, u8 b, int scale)
{
    int col,row;
    if (!bitmap || !lcd_surface_valid(frame,stride) || !lcd_scale_valid(scale) ||
        x>=DISPLAY_WIDTH || y>=DISPLAY_HEIGHT ||
        lcd_add_positive_sat(x,12*(int64_t)scale)<=0 ||
        lcd_add_positive_sat(y,12*(int64_t)scale)<=0) return;
    for (col=0;col<12;++col) {
        u16 bits=bitmap[col*2] | ((u16)bitmap[col*2+1]<<8);
        for (row=0;row<12;++row)
            if (bits & (1U<<row))
                lcd_draw_rect(frame,stride,x+col*(int64_t)scale,
                              y+row*(int64_t)scale,scale,scale,r,g,b);
    }
}

/* Decode only complete sequences; no str[i+2] read across a trailing NUL.
 * Current fonts support ASCII and BMP CJK. Unsupported sequences keep their
 * previous skip behavior. Malformed/truncated bytes advance one byte. */
static size_t lcd_text_token(const unsigned char *p, u16 *unicode, int *cells)
{
    *unicode=0; *cells=0;
    if (*p<0x80) { *unicode=*p; *cells=6; return 1; }
    if ((*p&0xF0)==0xE0 && p[1] && (p[1]&0xC0)==0x80 &&
        p[2] && (p[2]&0xC0)==0x80) {
        *unicode=((u16)(p[0]&15)<<12)|((u16)(p[1]&63)<<6)|(p[2]&63);
        *cells=12; return 3;
    }
    if ((*p&0xE0)==0xC0 && p[1] && (p[1]&0xC0)==0x80) return 2;
    return 1;
}

static int str_pixel_width(const char *str, int scale)
{
    int64_t width=0;
    const unsigned char *p=(const unsigned char *)str;
    if (!str || !lcd_scale_valid(scale)) return 0;
    while (*p) {
        u16 code; int cells;
        p+=lcd_text_token(p,&code,&cells);
        width+=cells*(int64_t)scale;
        if (width>=INT_MAX) return INT_MAX;
    }
    return (int)width;
}

void lcd_draw_text(u8 *frame, u32 stride, int64_t x, int64_t y,
                   const char *str, u8 r, u8 g, u8 b, int scale)
{
    const unsigned char *p=(const unsigned char *)str;
    if (!str || !lcd_surface_valid(frame,stride) || !lcd_scale_valid(scale) ||
        y>=DISPLAY_HEIGHT || lcd_add_positive_sat(y,12*(int64_t)scale)<=0) return;
    /* Stop at the actual right edge: overlong dynamic strings neither wrap
     * cursor arithmetic nor write into the next row/frame. */
    while (*p && x<DISPLAY_WIDTH) {
        u16 code; int cells;
        size_t step=lcd_text_token(p,&code,&cells);
        if (cells==6) lcd_draw_char(frame,stride,x,y,(char)code,r,g,b,scale);
        else if (cells==12) {
            const u8 *bitmap=cjk_find(code);
            if (bitmap) lcd_draw_cjk(frame,stride,x,y,bitmap,r,g,b,scale);
            else lcd_draw_char(frame,stride,x,y,'?',r,g,b,scale);
        }
        x=lcd_add_positive_sat(x,cells*(int64_t)scale);
        p+=step;
    }
}
#endif /* DISPLAY_DRAW_SAFE_H */
