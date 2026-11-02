/* PS-only mapping of the existing six PL KEY1 codes. No hardware writes. */
#include "debug_ui.h"
enum debug_page debug_page_from_pl_mode(unsigned mode)
{
    static const enum debug_page pages[6]={PAGE_DOA,PAGE_FFT,PAGE_ADC,PAGE_SYSTEM,PAGE_FFT,PAGE_ADC};
    return mode<6?pages[mode]:PAGE_SYSTEM;
}
const char *debug_page_name(enum debug_page page)
{
    switch(page){case PAGE_DOA:return "DOA RESULT";case PAGE_FFT:return "HIL VALIDATION";
        case PAGE_ADC:return "ENGINEERING DETAIL";default:return "SYSTEM DETAIL";}
}
