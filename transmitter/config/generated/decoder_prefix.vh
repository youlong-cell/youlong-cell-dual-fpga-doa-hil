// 自动生成：scripts/generate_mode_catalog.py；只修改config/hil_mode_catalog.json。
// 定义SHA256：aaa209c91ce45993f3c7821e18a5b1b717453d3785ccda53a18e4d9862cf8682
case(line_length)
    n+7:case(line[n*8+:56])
        "SET 1M ":band=0;
        "SET 2M ":band=1;
        "SET 5M ":band=2;
        default:prefix_ok=0;
    endcase
    n+8:case(line[n*8+:64])
        "SET 1M +":band=0;
        "SET 1M -":begin band=0;negative=1;end
        "SET 2M +":band=1;
        "SET 2M -":begin band=1;negative=1;end
        "SET 5M +":band=2;
        "SET 5M -":begin band=2;negative=1;end
        "SET 10M ":band=3;
        default:prefix_ok=0;
    endcase
    n+9:case(line[n*8+:72])
        "SET 10M +":band=3;
        "SET 10M -":begin band=3;negative=1;end
        default:prefix_ok=0;
    endcase
    default:prefix_ok=0;
endcase
